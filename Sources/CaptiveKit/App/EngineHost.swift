import Foundation

/// Fait tourner le moteur dans l'app si le verrou d'instance est libre ;
/// sinon observe l'instance qui le tient (démon CLI) et lui relaie
/// « reconnecter » par SIGUSR1. Méthodes à appeler depuis un seul fil (l'UI).
public final class EngineHost: @unchecked Sendable {
    public let paths: Paths
    let makeEngine: (Config) -> WatchdogEngine
    let sendSignal: (pid_t, Int32) -> Int32
    private let lock: InstanceLock
    private let guardLock = NSLock()
    private var runningEngine: WatchdogEngine?
    private var task: Task<Void, Never>?
    private var signalSource: DispatchSourceSignal?
    private var activity: NSObjectProtocol?
    private var suspended = false
    /// Moteur annulé dont la tâche n'est pas encore sortie : il garde le verrou.
    private var draining = false
    public private(set) var mode: EngineMode = .stopped

    var engine: WatchdogEngine? { guardLock.locked { runningEngine } }

    public init(paths: Paths, makeEngine: @escaping (Config) -> WatchdogEngine,
                sendSignal: @escaping (pid_t, Int32) -> Int32 = { kill($0, $1) }) {
        self.paths = paths
        self.makeEngine = makeEngine
        self.sendSignal = sendSignal
        lock = InstanceLock(url: paths.lock)
        // `captive-watchdog reconnect` signale quiconque tient le verrou, y
        // compris l'app pendant un bref acquire : l'action par défaut la tuerait.
        signal(SIGUSR1, SIG_IGN)
    }

    deinit { stop() }

    public static func live(paths: Paths, logger: Logger, notifier: Notifier) -> EngineHost {
        EngineHost(paths: paths, makeEngine: {
            WatchdogEngine(paths: paths, config: $0, logger: logger, environment: .live(notifier: notifier))
        })
    }

    /// Démarre ou reprend la surveillance.
    @discardableResult
    public func start() -> EngineMode {
        suspended = false
        return refresh()
    }

    /// À appeler périodiquement : prend le relais quand l'instance observée
    /// s'arrête, et démarre dès qu'un e-mail est configuré.
    @discardableResult
    public func refresh() -> EngineMode {
        if suspended {
            mode = .stopped
            return mode
        }
        if mode == .hosting { return mode }
        if guardLock.locked({ draining }) {
            mode = .stopped
            return mode
        }
        try? paths.ensure()
        if (try? lock.acquire()) == true {
            let config: Config
            do {
                config = try Config.load(from: paths.config)
            } catch {
                lock.release()
                mode = .configError("config.json illisible (\(error.localizedDescription))")
                return mode
            }
            guard !config.email.isEmpty else {
                lock.release()
                mode = .needsEmail
                return mode
            }
            launch(config)
            mode = .hosting
        } else if let pid = InstanceLock.holderPID(at: paths.lock) {
            mode = .observing(pid)
        }
        return mode
    }

    public func stop() {
        suspended = true
        if let task {
            // Le verrou est rendu par la tâche elle-même, une fois sortie :
            // un « Reprendre » immédiat ne lance pas un second moteur.
            guardLock.locked { draining = true }
            task.cancel()
        } else {
            lock.release()
        }
        task = nil
        guardLock.locked { runningEngine = nil }
        signalSource?.cancel()
        signalSource = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        mode = .stopped
    }

    public func reconnect() {
        switch mode {
        case .hosting: engine?.requestImmediateCycle()
        case .observing(let pid): _ = sendSignal(pid, SIGUSR1)
        case .needsEmail, .stopped, .configError: break
        }
    }

    @discardableResult
    public func setEmail(_ raw: String) throws -> EngineMode {
        let email = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.contains("@"), !email.hasPrefix("@"), !email.hasSuffix("@") else {
            throw ConfigError.invalidValue("email", email)
        }
        try paths.ensure()
        var config = try Config.load(from: paths.config)
        try config.set("email", email)
        try config.save(to: paths.config)
        return mode == .needsEmail ? refresh() : mode
    }

    private func launch(_ config: Config) {
        let engine = makeEngine(config)
        guardLock.locked { runningEngine = engine }
        installSignalHandler()
        // Une app LSUIElement en arrière-plan subit App Nap : ses minuteries
        // seraient espacées de plusieurs minutes, la sonde aussi.
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                         reason: "Surveillance du portail captif")
        task = Task.detached { [lock, guardLock, weak self] in
            await engine.loop()
            lock.release()
            guardLock.locked { self?.draining = false }
        }
    }

    /// `captive-watchdog reconnect` envoie SIGUSR1 au détenteur du verrou :
    /// sans gestionnaire, l'action par défaut tuerait l'app.
    private func installSignalHandler() {
        guard signalSource == nil else { return }
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .global())
        source.setEventHandler { [weak self] in self?.engine?.requestImmediateCycle() }
        source.resume()
        signalSource = source
    }
}
