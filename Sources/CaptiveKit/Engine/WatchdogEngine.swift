import Foundation

public protocol Notifier: Sendable {
    func notify(title: String, body: String)
}

public struct SilentNotifier: Notifier {
    public init() {}
    public func notify(title: String, body: String) {}
}

/// Notification système sans entitlement : `osascript` (Phase 1, CLI).
public struct OSAScriptNotifier: Notifier {
    public init() {}

    public func notify(title: String, body: String) {
        func quoted(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "display notification \(quoted(body)) with title \(quoted(title))"]
        try? process.run()
    }
}

public enum CycleResult: Equatable, Sendable {
    case online, offline, renewed
    case failed(String)
}

public final class WatchdogEngine: @unchecked Sendable {
    public struct Environment {
        public var makeClient: (Config) -> HTTPClient
        public var sleep: (Double) async -> Void
        public var now: () -> Date
        /// nil en Phase 1 : sans autorisation de Localisation, macOS masque le SSID.
        public var ssid: () -> String?
        public var notifier: Notifier

        public init(makeClient: @escaping (Config) -> HTTPClient, sleep: @escaping (Double) async -> Void,
                    now: @escaping () -> Date, ssid: @escaping () -> String?, notifier: Notifier) {
            self.makeClient = makeClient
            self.sleep = sleep
            self.now = now
            self.ssid = ssid
            self.notifier = notifier
        }

        public static func live(notifier: Notifier) -> Environment {
            Environment(
                makeClient: { HTTPClient(options: HTTPClientOptions(verifyTLS: $0.verifyTLS)) },
                sleep: { try? await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) },
                now: Date.init,
                ssid: { nil },
                notifier: notifier)
        }
    }

    public let paths: Paths
    public private(set) var config: Config
    /// Relit config.json à chaque cycle : `config set` prend effet sans redémarrage.
    public var reloadsConfig = true
    let environment: Environment
    let logger: Logger
    let store: StateStore
    private let lock = NSLock()
    private var wakeRequested = false

    public init(paths: Paths, config: Config, logger: Logger, environment: Environment) {
        self.paths = paths
        self.config = config
        self.logger = logger
        self.environment = environment
        store = StateStore(paths: paths)
    }

    public func requestImmediateCycle() { lock.locked { wakeRequested = true } }

    func takeWake() -> Bool {
        lock.locked {
            defer { wakeRequested = false }
            return wakeRequested
        }
    }

    public func loop() async {
        logger.info("démarrage du watchdog (pid \(getpid()), sonde toutes les \(Int(config.interval)) s)")
        while !Task.isCancelled {
            let result = await runOnce()
            if case .failed = result {
                await nap(config.failBackoff)
            } else {
                await nap(config.interval)
            }
        }
    }

    /// Sommeil découpé en tranches de 0,5 s pour réagir vite à « reconnecter ».
    public func nap(_ seconds: Double) async {
        var left = seconds
        while left > 0 {
            if takeWake() {
                logger.info("cycle immédiat demandé")
                return
            }
            let step = min(0.5, left)
            await environment.sleep(step)
            left -= step
        }
    }

    public func runOnce() async -> CycleResult {
        if reloadsConfig, let fresh = try? Config.load(from: paths.config), !fresh.email.isEmpty { config = fresh }
        var state = store.load()
        state.pid = getpid()
        state.lastCheck = environment.now()
        let client = environment.makeClient(config)
        defer { client.close() }
        let prober = Prober(url: URL(string: config.probeURL) ?? Prober.defaultURL)
        let result: CycleResult
        switch await prober.probe(using: client) {
        case .online:
            transition(&state, to: .online, detail: nil)
            result = .online
        case .offline(let why):
            transition(&state, to: .offline, detail: why)
            result = .offline
        case .captive(let response):
            transition(&state, to: .captive, detail: response.url.host)
            result = await handleCaptive(response, client: client, prober: prober, state: &state)
        }
        // Surveillance suspendue en plein cycle : le réseau a échoué parce que la
        // tâche est annulée, pas parce que le Wi-Fi est coupé. Rien à enregistrer.
        guard !Task.isCancelled else { return result }
        try? store.save(state)
        return result
    }

    func transition(_ state: inout WatchdogState, to status: NetworkStatus, detail: String?) {
        guard state.status != status else { return }
        logger.info("statut : \(state.status.rawValue) → \(status.rawValue)" + (detail.map { " (\($0))" } ?? ""))
        state.status = status
        state.since = environment.now()
    }

    func handleCaptive(_ first: HTTPResponse, client: HTTPClient, prober: Prober,
                       state: inout WatchdogState) async -> CycleResult {
        let start = environment.now()
        let profiles = ProfileStore(userDirectory: paths.profiles)
        for error in profiles.errors { logger.warn("profil ignoré \(error.file) : \(error.message)") }
        let recorder = IncidentRecorder(directory: paths.incidents, keep: config.keepIncidents)
        let identity = Identity(email: config.email, password: config.password)
        logger.warn("portail captif détecté : \(first.url.host ?? "?")")

        var captive = first
        var activeClient = client
        var extraClients: [HTTPClient] = []
        defer { extraClients.forEach { $0.close() } }
        var outcome: LoginOutcome?
        var attempts = 0
        var recoveredAlone = false
        let retries = max(1, config.retries)

        attemptLoop: for attempt in 1...retries {
            attempts = attempt
            let session = LoginSession(client: activeClient, prober: prober, profiles: profiles, identity: identity,
                                       config: config, ssid: environment.ssid(), recorder: recorder, logger: logger,
                                       sleep: environment.sleep)
            let o = await session.run(captive: captive)
            outcome = o
            if o.verdict == .success { break }
            logger.warn("tentative \(attempt)/\(retries) échouée : \(o.reason ?? "?") (incident \(o.incident ?? "-"))")
            guard attempt < retries else { break }
            await environment.sleep(config.retryDelay)
            activeClient = environment.makeClient(config)
            extraClients.append(activeClient)
            switch await prober.probe(using: activeClient) {
            case .online:
                recoveredAlone = true
                break attemptLoop
            case .offline:
                break attemptLoop
            case .captive(let r):
                captive = r
            }
        }

        guard !Task.isCancelled else {
            logger.info("cycle interrompu (surveillance suspendue)")
            return .failed("interrompu")
        }
        let end = environment.now()
        let host = outcome?.host ?? first.url.host ?? "inconnu"
        let ok = outcome?.verdict == .success || recoveredAlone
        let event = HistoryEvent(network: host, profile: outcome?.profile ?? Profile.generic.id, start: start, end: end,
                                 duration: end.timeIntervalSince(start), verdict: ok ? .success : .failure,
                                 attempts: attempts, incident: outcome?.incident, reason: ok ? nil : outcome?.reason)
        try? store.append(event)
        state.lastIncident = outcome?.incident ?? state.lastIncident

        if ok {
            state.lastRenew = end
            state.lastRenewDuration = event.duration
            state.lastRenewNetwork = host
            state.consecutiveFailures = 0
            transition(&state, to: .online, detail: host)
            logger.info("reconnecté à \(host) en \(Format.duration(event.duration)) (\(attempts) tentative(s))")
            if config.notify { environment.notifier.notify(title: "Wi-Fi reconnecté", body: "\(host) — \(Format.duration(event.duration))") }
            return .renewed
        }
        let reason = outcome?.reason ?? "échec"
        let previousReason = state.lastFailureReason
        state.lastFailure = end
        state.lastFailureReason = reason
        state.consecutiveFailures += 1
        logger.error("échec de reconnexion à \(host) : \(reason) (\(state.consecutiveFailures) échec(s) d'affilée)")
        // Une notification par panne, pas une par cycle : seulement au premier
        // échec d'une série ou quand la cause change.
        if config.notify, state.consecutiveFailures == 1 || previousReason != reason {
            environment.notifier.notify(title: "Wi-Fi : reconnexion impossible", body: "\(host) — \(reason)")
        }
        return .failed(reason)
    }
}
