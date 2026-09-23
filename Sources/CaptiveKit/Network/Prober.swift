import Foundation

public enum ProbeResult: Sendable {
    case online
    case captive(HTTPResponse)
    case offline(String)
}

public struct Prober: Sendable {
    public static let defaultURL = URL(string: "http://captive.apple.com/hotspot-detect.html")!
    public var url: URL

    public init(url: URL = Prober.defaultURL) { self.url = url }

    /// `Success` sans redirection → en ligne ; erreur réseau → hors ligne ;
    /// toute autre réponse → captif (la réponse sert de page de portail).
    public func probe(using client: HTTPClient) async -> ProbeResult {
        do {
            let r = try await client.get(url)
            if r.status == 200, r.redirects.isEmpty,
               r.body.range(of: "<TITLE>Success</TITLE>", options: .caseInsensitive) != nil {
                return .online
            }
            return .captive(r)
        } catch {
            return .offline(String(describing: error))
        }
    }
}
