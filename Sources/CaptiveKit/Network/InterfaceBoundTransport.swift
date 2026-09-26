import Foundation
import Network

/// Transport HTTP lié à une interface : un seul aller-retour, sans suivre les
/// redirections (le client s'en charge, avec son jar de cookies).
public protocol BoundTransport: Sendable {
    func send(_ request: URLRequest, verifyTLS: Bool, timeout: TimeInterval,
              maxBodyBytes: Int) async throws -> (Data, HTTPURLResponse)
}

/// HTTP/1.1 minimal sur Network.framework, lié à un type d'interface.
///
/// Pourquoi : quand macOS rejoint un réseau captif, il affiche sa fenêtre de
/// connexion et donne à la Wi-Fi le rang « Never » jusqu'à l'authentification.
/// URLSession ne sait pas lier une requête à une interface : elle échoue en
/// -1009 alors que le portail est joignable. Une connexion liée explicitement
/// à la Wi-Fi passe, comme celle de la fenêtre système (résolution DNS
/// comprise, restreinte à cette interface).
public struct InterfaceBoundTransport: BoundTransport {
    public var interface: NWInterface.InterfaceType

    public init(interface: NWInterface.InterfaceType = .wifi) { self.interface = interface }

    public func send(_ request: URLRequest, verifyTLS: Bool, timeout: TimeInterval,
                     maxBodyBytes: Int) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, let host = url.host,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw HTTPError.transport("URL non prise en charge : \(request.url?.absoluteString ?? "?")")
        }
        let tls = scheme == "https"
        let port = url.port ?? (tls ? 443 : 80)
        let parameters: NWParameters
        if tls {
            let options = NWProtocolTLS.Options()
            if !verifyTLS {
                sec_protocol_options_set_verify_block(options.securityProtocolOptions,
                                                      { _, _, complete in complete(true) }, .global())
            }
            parameters = NWParameters(tls: options)
        } else {
            parameters = .tcp
        }
        parameters.requiredInterfaceType = interface
        let payload = Self.serialize(request, url: url, host: host, port: port, tls: tls)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port))!,
                                      using: parameters)
        let raw = try await Self.exchange(connection, payload: payload, timeout: timeout,
                                          limit: maxBodyBytes + 65_536)
        return try Self.parse(raw, url: url)
    }

    // MARK: sérialisation

    static func serialize(_ request: URLRequest, url: URL, host: String, port: Int, tls: Bool) -> Data {
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var target = parts?.percentEncodedPath ?? "/"
        if target.isEmpty { target = "/" }
        if let query = parts?.percentEncodedQuery { target += "?" + query }
        let defaultPort = port == (tls ? 443 : 80)
        var headers = request.allHTTPHeaderFields ?? [:]
        let hostHeader = headers.first { $0.key.caseInsensitiveCompare("Host") == .orderedSame }?.value
            ?? (defaultPort ? host : "\(host):\(port)")
        // Host et Connection sont posés ici ; pas d'Accept-Encoding : corps en clair.
        let reserved: Set<String> = ["host", "connection", "content-length", "accept-encoding", "transfer-encoding"]
        headers = headers.filter { !reserved.contains($0.key.lowercased()) }
        var head = "\(request.httpMethod ?? "GET") \(target) HTTP/1.1\r\nHost: \(hostHeader)\r\n"
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) { head += "\(key): \(value)\r\n" }
        if let body = request.httpBody { head += "Content-Length: \(body.count)\r\n" }
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        if let body = request.httpBody { data.append(body) }
        return data
    }

    // MARK: échange

    /// Envoie la requête et lit jusqu'à la fermeture (`Connection: close`) ou `limit` octets.
    static func exchange(_ connection: NWConnection, payload: Data, timeout: TimeInterval,
                         limit: Int) async throws -> Data {
        let once = Once()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                guard once.arm(connection, cont) else { return connection.cancel() }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        connection.send(content: payload, completion: .contentProcessed { error in
                            if let error { once.fail(transportError(error)) }
                        })
                        receive(connection, into: Data(), limit: limit, once: once)
                    case .waiting(let error), .failed(let error):
                        once.fail(transportError(error))
                    case .cancelled:
                        once.fail(HTTPError.transport("connexion annulée", code: URLError.cancelled.rawValue))
                    default:
                        break
                    }
                }
                connection.start(queue: .global())
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    once.fail(HTTPError.transport("The request timed out.", code: URLError.timedOut.rawValue))
                }
            }
        } onCancel: {
            once.fail(CancellationError())
        }
    }

    private static func receive(_ connection: NWConnection, into buffer: Data, limit: Int, once: Once) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, eof, error in
            var acc = buffer
            if let data { acc.append(data) }
            if eof || acc.count >= limit || (error != nil && !acc.isEmpty) {
                once.succeed(acc)
            } else if let error {
                once.fail(transportError(error))
            } else {
                receive(connection, into: acc, limit: limit, once: once)
            }
        }
    }

    /// Codes URLError équivalents : la sonde réagit au code, pas au message.
    static func transportError(_ error: NWError) -> HTTPError {
        switch error {
        case .posix(let code) where [.ENETDOWN, .ENETUNREACH, .ENOTCONN].contains(code):
            return .transport(error.localizedDescription, code: URLError.notConnectedToInternet.rawValue)
        case .posix(.ETIMEDOUT):
            return .transport(error.localizedDescription, code: URLError.timedOut.rawValue)
        case .posix(.ECONNREFUSED):
            return .transport(error.localizedDescription, code: URLError.cannotConnectToHost.rawValue)
        case .dns:
            return .transport(error.localizedDescription, code: URLError.cannotFindHost.rawValue)
        default:
            return .transport(error.localizedDescription)
        }
    }

    // MARK: analyse de la réponse

    static func parse(_ raw: Data, url: URL) throws -> (Data, HTTPURLResponse) {
        let separator = Data("\r\n\r\n".utf8)
        guard let end = raw.range(of: separator) else { throw HTTPError.notHTTP }
        let head = String(decoding: raw[..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst().split(separator: " ", maxSplits: 2)
        guard statusLine.count >= 2, statusLine[0].hasPrefix("HTTP/"), let status = Int(statusLine[1]) else {
            throw HTTPError.notHTTP
        }
        // En-têtes répétés (Set-Cookie…) fusionnés par une virgule, comme Foundation.
        var headers: [String: String] = [:]
        var order: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let key = order[name.lowercased()] ?? name
            order[name.lowercased()] = key
            headers[key] = headers[key].map { "\($0), \(value)" } ?? value
        }
        func header(_ name: String) -> String? { order[name.lowercased()].flatMap { headers[$0] } }

        var body = Data(raw[end.upperBound...])
        if header("Transfer-Encoding")?.lowercased().contains("chunked") == true {
            body = dechunk(body)
            if let key = order["transfer-encoding"] { headers[key] = nil }
        } else if let length = header("Content-Length").flatMap({ Int($0) }), length < body.count {
            body = body.prefix(length)
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: String(statusLine[0]),
                                             headerFields: headers) else { throw HTTPError.notHTTP }
        return (body, response)
    }

    /// Tolérant : un corps tronqué (limite atteinte) garde les morceaux complets.
    static func dechunk(_ data: Data) -> Data {
        var out = Data()
        var index = data.startIndex
        let crlf = Data("\r\n".utf8)
        while let lineEnd = data.range(of: crlf, in: index..<data.endIndex) {
            let sizeText = String(decoding: data[index..<lineEnd.lowerBound], as: UTF8.self)
                .split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard let size = Int(sizeText, radix: 16), size > 0 else { break }
            let start = lineEnd.upperBound
            let stop = data.index(start, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
            out.append(data[start..<stop])
            guard stop < data.endIndex, let next = data.index(stop, offsetBy: 2, limitedBy: data.endIndex) else { break }
            index = next
        }
        return out
    }
}

/// Reprise unique de la continuation (réponse, erreur, délai ou annulation,
/// selon ce qui arrive en premier) puis fermeture de la connexion.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NWConnection?
    private var continuation: CheckedContinuation<Data, Error>?
    private var early: Error?

    /// false : déjà annulé, la continuation est reprise et la connexion ne doit pas démarrer.
    func arm(_ connection: NWConnection, _ continuation: CheckedContinuation<Data, Error>) -> Bool {
        let pending: Error? = lock.locked {
            if let early { return early }
            self.connection = connection
            self.continuation = continuation
            return nil
        }
        guard let pending else { return true }
        continuation.resume(throwing: pending)
        return false
    }

    func succeed(_ data: Data) { finish(.success(data)) }
    func fail(_ error: Error) { finish(.failure(error)) }

    private func finish(_ result: Result<Data, Error>) {
        let taken: (NWConnection?, CheckedContinuation<Data, Error>?) = lock.locked {
            guard continuation != nil else {
                // Annulé avant l'armement : mémorisé pour la reprise immédiate.
                if connection == nil, early == nil, case .failure(let e) = result { early = e }
                return (nil, nil)
            }
            defer { continuation = nil; connection = nil }
            return (connection, continuation)
        }
        guard let cont = taken.1 else { return }
        taken.0?.stateUpdateHandler = nil
        taken.0?.cancel()
        cont.resume(with: result)
    }
}
