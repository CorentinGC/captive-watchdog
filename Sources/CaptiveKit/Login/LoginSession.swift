import Foundation

public struct LoginOutcome: Sendable {
    public enum Verdict: String, Codable, Sendable { case success, failure }

    public var verdict: Verdict
    public var host: String
    public var profile: String
    public var reason: String?
    public var notes: [String]
    public var incident: String?
}

/// Une passe de login complète sur un portail (spec §6, étapes 2 à 7 hors
/// tentatives) : page → formulaire → POST → rebonds → re-sonde.
public final class LoginSession {
    let client: HTTPClient
    let prober: Prober
    let profiles: ProfileStore
    let identity: Identity
    let config: Config
    let ssid: String?
    let recorder: IncidentRecorder?
    let logger: Logger
    let sleep: (Double) async -> Void
    /// La passerelle met parfois une seconde à ouvrir l'accès après le POST.
    public var verifyAttempts = 3
    public var verifyDelay: Double = 1.5

    public init(client: HTTPClient, prober: Prober, profiles: ProfileStore, identity: Identity, config: Config,
                ssid: String?, recorder: IncidentRecorder?, logger: Logger,
                sleep: @escaping (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1e9)) }) {
        self.client = client
        self.prober = prober
        self.profiles = profiles
        self.identity = identity
        self.config = config
        self.ssid = ssid
        self.recorder = recorder
        self.logger = logger
        self.sleep = sleep
    }

    public func run(captive probe: HTTPResponse) async -> LoginOutcome {
        var host = probe.url.host ?? "inconnu"
        var profileID = Profile.generic.id
        var notes: [String] = []
        let incident: Incident?
        do {
            incident = try recorder?.open(host: host, redacting: identity)
        } catch {
            logger.warn("incident non enregistré : \(error)")
            incident = nil
        }

        func note(_ text: String) {
            notes.append(text)
            incident?.note(text)
            logger.info(text)
        }

        func finish(_ verdict: LoginOutcome.Verdict, _ reason: String?) -> LoginOutcome {
            incident?.finish(verdict: verdict.rawValue, reason: reason)
            return LoginOutcome(verdict: verdict, host: host, profile: profileID, reason: reason,
                                notes: notes, incident: incident?.name)
        }

        incident?.record("portal", probe)
        do {
            var page = probe
            var scanned = HTMLScanner.scan(page.body)
            var refreshes = 0
            while scanned.forms.isEmpty, let target = scanned.metaRefresh, refreshes < config.maxChainHops {
                refreshes += 1
                page = try await client.get(FormFiller.resolve(target, page: scanned, pageURL: page.url))
                incident?.record("refresh\(refreshes)", page)
                scanned = HTMLScanner.scan(page.body)
            }

            host = Self.portalHost(scanned, pageURL: page.url)
            let profile = profiles.resolve(portalHost: host, ssid: ssid)
            profileID = profile.id
            incident?.setContext(host: host, profile: profile.id)
            note("profil « \(profile.id) » pour \(host)")

            guard let picked = FormFiller.pickLoginForm(scanned, profile: profile) else {
                let hasScript = page.body.range(of: "<script", options: .caseInsensitive) != nil
                return finish(.failure, hasScript ? "aucun formulaire HTML exploitable (portail JavaScript ?)"
                                                  : "aucun formulaire HTML exploitable")
            }
            incident?.setCandidates(picked.candidates)
            let filled = FormFiller.fill(picked.form, page: scanned, pageURL: page.url, identity: identity,
                                         profile: profile, skipCheckbox: config.skipCheckbox)
            filled.notes.forEach(note)
            var response = try await submit(filled)
            incident?.record("login", response, request: RequestRecord(filled))

            let maxHops = profile.chain?.maxHops ?? config.maxChainHops
            let expected = Set((profile.chain?.expectHosts ?? []).map { $0.lowercased() })
            var hops = 0
            while true {
                let scannedResponse = HTMLScanner.scan(response.body)
                let replay = scannedResponse.forms.first(where: FormFiller.isAutoForm)
                    .map { FormFiller.replay($0, page: scannedResponse, pageURL: response.url) }
                let refresh = (replay == nil && scannedResponse.forms.isEmpty) ? scannedResponse.metaRefresh : nil
                guard replay != nil || refresh != nil else { break }
                guard hops < maxHops else {
                    note("plafond de \(maxHops) rebonds atteint")
                    break
                }
                hops += 1
                if let replay {
                    if !expected.isEmpty, let target = replay.actionURL.host?.lowercased(), !expected.contains(target) {
                        note("rebond vers un hôte inattendu : \(target)")
                    }
                    note("rebond \(hops) : formulaire caché vers \(replay.actionURL.host ?? "?")")
                    response = try await submit(replay)
                    incident?.record("chain\(hops)", response, request: RequestRecord(replay))
                } else if let refresh {
                    note("rebond \(hops) : meta refresh")
                    response = try await client.get(FormFiller.resolve(refresh, page: scannedResponse, pageURL: response.url))
                    incident?.record("chain\(hops)", response)
                }
            }

            let attempts = max(1, verifyAttempts)
            for attempt in 1...attempts {
                switch await prober.probe(using: client) {
                case .online:
                    note("vérification : en ligne")
                    return finish(.success, nil)
                case .captive(let r):
                    if attempt == attempts {
                        incident?.record("verify", r)
                        return finish(.failure, "toujours captif après le login")
                    }
                case .offline(let why):
                    if attempt == attempts { return finish(.failure, "hors ligne après le login : \(why)") }
                }
                await sleep(verifyDelay)
            }
            return finish(.failure, "vérification impossible")
        } catch {
            return finish(.failure, "réseau : \(error)")
        }
    }

    func submit(_ filled: FilledForm) async throws -> HTTPResponse {
        if filled.method == "post" { return try await client.post(filled.actionURL, form: filled.payload) }
        var components = URLComponents(url: filled.actionURL, resolvingAgainstBaseURL: true)!
        let query = String(decoding: FormFiller.encode(filled.payload), as: UTF8.self)
        components.percentEncodedQuery = query.isEmpty ? nil : query
        return try await client.get(components.url ?? filled.actionURL)
    }

    /// Hôte servant à choisir le profil : celui de <base href> s'il existe
    /// (portail servi en ligne sous captive.apple.com), sinon celui de la page.
    public static func portalHost(_ page: ScannedPage, pageURL: URL) -> String {
        if let base = page.baseHref, let host = URL(string: base, relativeTo: pageURL)?.host {
            return host.lowercased()
        }
        return pageURL.host?.lowercased() ?? "inconnu"
    }
}
