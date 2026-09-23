import Foundation

/// Cookies gérés à la main : le même jar doit servir au GET, aux POST et à
/// chaque saut de redirection, sans dépendre du stockage partagé du système.
public final class CookieJar: @unchecked Sendable {
    private var cookies: [HTTPCookie] = []
    private let lock = NSLock()

    public init() {}

    public func ingest(_ response: HTTPURLResponse, for url: URL) {
        var fields: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String { fields[key] = value }
        }
        let fresh = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        guard !fresh.isEmpty else { return }
        let now = Date()
        lock.locked {
            for cookie in fresh {
                cookies.removeAll { $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path }
                if let expiry = cookie.expiresDate, expiry < now { continue }
                cookies.append(cookie)
            }
        }
    }

    public func header(for url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let path = url.path.isEmpty ? "/" : url.path
        let secure = url.scheme?.lowercased() == "https"
        let now = Date()
        let matching = lock.locked {
            cookies.filter { c in
                if let expiry = c.expiresDate, expiry < now { return false }
                if c.isSecure && !secure { return false }
                let domain = c.domain.lowercased()
                let domainOK = domain.hasPrefix(".")
                    ? host == String(domain.dropFirst()) || host.hasSuffix(domain)
                    : host == domain
                return domainOK && path.hasPrefix(c.path)
            }
        }
        guard !matching.isEmpty else { return nil }
        return matching.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
}
