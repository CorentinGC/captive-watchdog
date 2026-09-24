import Foundation

public struct Redirect: Codable, Equatable, Sendable {
    public var code: Int
    public var from: String
    public var to: String
}

public struct HTTPResponse: Sendable {
    public var url: URL
    public var status: Int
    public var headers: [String: String]
    public var body: String
    public var redirects: [Redirect]

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public enum HTTPError: Error, CustomStringConvertible {
    /// `code` : code URLError d'origine (ex. -1009 = machine non connectée).
    case transport(String, code: Int? = nil)
    case notHTTP

    public var description: String {
        switch self {
        case .transport(let message, _): return message
        case .notHTTP: return "réponse non HTTP"
        }
    }
}

public struct HTTPClientOptions {
    public static let safariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    public var verifyTLS: Bool
    public var timeout: TimeInterval
    public var maxRedirects: Int
    public var maxBodyBytes: Int
    public var userAgent: String
    public var acceptLanguage: String
    public var protocolClasses: [AnyClass]

    public init(verifyTLS: Bool = true, timeout: TimeInterval = 15, maxRedirects: Int = 10,
                maxBodyBytes: Int = 2_000_000, userAgent: String = HTTPClientOptions.safariUserAgent,
                acceptLanguage: String = "fr-FR,fr;q=0.9,en;q=0.8", protocolClasses: [AnyClass] = []) {
        self.verifyTLS = verifyTLS
        self.timeout = timeout
        self.maxRedirects = maxRedirects
        self.maxBodyBytes = maxBodyBytes
        self.userAgent = userAgent
        self.acceptLanguage = acceptLanguage
        self.protocolClasses = protocolClasses
    }
}

/// Une instance = une « session navigateur » : jar de cookies propre,
/// redirections tracées. Requêtes séquentielles uniquement.
public final class HTTPClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public let jar = CookieJar()
    let options: HTTPClientOptions
    private var session: URLSession!
    private let lock = NSLock()
    private var redirects: [Redirect] = []

    public init(options: HTTPClientOptions = HTTPClientOptions()) {
        self.options = options
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = options.timeout
        configuration.timeoutIntervalForResource = options.timeout * 2
        configuration.waitsForConnectivity = false
        if !options.protocolClasses.isEmpty { configuration.protocolClasses = options.protocolClasses }
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// La session retient son délégué : à appeler quand le client ne sert plus.
    public func close() { session.invalidateAndCancel() }

    /// `referer` : page d'où part la requête, comme un navigateur. Les portails
    /// à middleware CSRF rejettent un POST sans Referer/Origin de même origine.
    /// `host` : remplace l'en-tête Host (URL à IP littérale, DNS contourné).
    public func get(_ url: URL, referer: URL? = nil, host: String? = nil) async throws -> HTTPResponse {
        try await send(method: "GET", url: url, body: nil, referer: referer, host: host)
    }

    public func post(_ url: URL, form: [FormPair], referer: URL? = nil) async throws -> HTTPResponse {
        try await send(method: "POST", url: url, body: FormFiller.encode(form), referer: referer)
    }

    static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        return url.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
    }

    func send(method: String, url: URL, body: Data?, referer: URL? = nil, host: String? = nil) async throws -> HTTPResponse {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: options.timeout)
        request.httpMethod = method
        request.setValue(options.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(options.acceptLanguage, forHTTPHeaderField: "Accept-Language")
        request.setValue("text/html,application/xhtml+xml,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if let host { request.setValue(host, forHTTPHeaderField: "Host") }
        if let body {
            request.httpBody = body
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        if let cookie = jar.header(for: url) { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        if let referer {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
            if method == "POST", let origin = Self.origin(of: referer) { request.setValue(origin, forHTTPHeaderField: "Origin") }
        }
        lock.locked { redirects = [] }

        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch {
            throw HTTPError.transport(error.localizedDescription, code: (error as? URLError)?.errorCode)
        }
        guard let http = result.1 as? HTTPURLResponse else { throw HTTPError.notHTTP }
        let finalURL = http.url ?? url
        jar.ingest(http, for: finalURL)
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields { headers[String(describing: key)] = String(describing: value) }
        let data = result.0.count > options.maxBodyBytes ? result.0.prefix(options.maxBodyBytes) : result.0
        let contentType = headers.first { $0.key.lowercased() == "content-type" }?.value
        return HTTPResponse(url: finalURL, status: http.statusCode, headers: headers,
                            body: Self.decodeBody(data, contentType: contentType),
                            redirects: lock.locked { redirects })
    }

    public static func decodeBody(_ data: Data, contentType: String?) -> String {
        switch charset(of: contentType) ?? "" {
        case "iso-8859-1", "iso8859-1", "latin1", "latin-1":
            return String(data: data, encoding: .isoLatin1) ?? ""
        case "windows-1252", "cp1252":
            return String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1) ?? ""
        default:
            if let text = String(data: data, encoding: .utf8) { return text }
            return String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1) ?? ""
        }
    }

    static func charset(of contentType: String?) -> String? {
        guard let ct = contentType?.lowercased(), let r = ct.range(of: "charset=") else { return nil }
        let value = ct[r.upperBound...].split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) {
        let from = response.url ?? task.currentRequest?.url
        if let from { jar.ingest(response, for: from) }
        let accepted: Bool = lock.locked {
            guard redirects.count < options.maxRedirects else { return false }
            redirects.append(Redirect(code: response.statusCode, from: from?.absoluteString ?? "",
                                      to: request.url?.absoluteString ?? ""))
            return true
        }
        guard accepted, let to = request.url else { return completionHandler(nil) }
        var next = request
        next.setValue(jar.header(for: to), forHTTPHeaderField: "Cookie")
        next.setValue(options.userAgent, forHTTPHeaderField: "User-Agent")
        next.setValue(options.acceptLanguage, forHTTPHeaderField: "Accept-Language")
        completionHandler(next)
    }

    /// Les portails captifs servent souvent des certificats invalides :
    /// la vérification TLS est configurable (spec §7, `verifyTLS`).
    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if !options.verifyTLS,
           challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
