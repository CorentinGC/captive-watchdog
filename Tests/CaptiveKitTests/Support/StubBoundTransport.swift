import Foundation
@testable import CaptiveKit

/// Remplace le transport lié à la Wi-Fi : même format de réponses que
/// `StubURLProtocol`, sans suivre les redirections (c'est le client qui le fait).
/// nil = interface indisponible.
final class StubBoundTransport: BoundTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [StubURLProtocol.Request] = []
    private let handler: (StubURLProtocol.Request) -> StubURLProtocol.Reply?

    init(_ handler: @escaping (StubURLProtocol.Request) -> StubURLProtocol.Reply?) { self.handler = handler }

    var requests: [StubURLProtocol.Request] { lock.locked { recorded } }

    func send(_ request: URLRequest, verifyTLS: Bool, timeout: TimeInterval,
              maxBodyBytes: Int) async throws -> (Data, HTTPURLResponse) {
        let req = StubURLProtocol.Request(method: request.httpMethod ?? "GET", url: request.url!,
                                          headers: request.allHTTPHeaderFields ?? [:],
                                          body: String(decoding: request.httpBody ?? Data(), as: UTF8.self))
        lock.locked { recorded.append(req) }
        guard let reply = handler(req) else {
            throw HTTPError.transport("Network is down", code: URLError.notConnectedToInternet.rawValue)
        }
        if let failure = reply.failure { throw HTTPError.transport("échec simulé", code: failure.rawValue) }
        let response = HTTPURLResponse(url: req.url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: reply.headers)!
        return (reply.body, response)
    }
}

extension StubURLProtocol {
    /// Client dont les requêtes normales passent par le stub et les requêtes
    /// liées à la Wi-Fi par `bound`.
    static func client(bound: BoundTransport, maxRedirects: Int = 10) -> HTTPClient {
        HTTPClient(options: HTTPClientOptions(maxRedirects: maxRedirects, protocolClasses: [StubURLProtocol.self],
                                              boundTransport: bound))
    }
}
