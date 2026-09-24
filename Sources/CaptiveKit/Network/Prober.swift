import Foundation

public enum ProbeResult: Sendable {
    case online
    case captive(HTTPResponse)
    case offline(String)
}

public struct Prober: Sendable {
    public static let defaultURL = URL(string: "http://captive.apple.com/hotspot-detect.html")!
    public static let fallbackIP = "17.253.29.137"
    public var url: URL

    public init(url: URL = Prober.defaultURL) { self.url = url }

    /// `Success` sans redirection → en ligne ; erreur réseau → hors ligne ;
    /// toute autre réponse → captif (la réponse sert de page de portail).
    /// Certains portails coupent le DNS avant authentification : la sonde par
    /// nom échoue alors comme si le Wi-Fi était coupé. On retente sur l'IP
    /// d'Apple avec l'en-tête Host d'origine ; si le réseau répond autre chose
    /// que `Success`, c'est le portail.
    public func probe(using client: HTTPClient) async -> ProbeResult {
        do {
            return classify(try await client.get(url))
        } catch {
            let reason = String(describing: error)
            guard let fallback = fallbackURL, !Self.isNotConnected(error),
                  let r = try? await client.get(fallback, host: url.host) else { return .offline(reason) }
            if case .online = classify(r) { return .offline(reason) }
            return .captive(r)
        }
    }

    /// Seulement pour la sonde Apple : une URL de sonde personnalisée n'a pas d'IP connue.
    var fallbackURL: URL? {
        guard url.host == Self.defaultURL.host else { return nil }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.host = Self.fallbackIP
        return parts?.url
    }

    func classify(_ r: HTTPResponse) -> ProbeResult {
        if r.status == 200, r.redirects.isEmpty,
           r.body.range(of: "<TITLE>Success</TITLE>", options: .caseInsensitive) != nil {
            return .online
        }
        return .captive(r)
    }

    /// Pas d'interface réseau : inutile de retenter par IP.
    static func isNotConnected(_ error: Error) -> Bool {
        if case HTTPError.transport(_, let code?) = error { return code == URLError.notConnectedToInternet.rawValue }
        return false
    }
}
