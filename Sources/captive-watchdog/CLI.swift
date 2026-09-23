import CaptiveKit
import Foundation

enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case message(String)

    var description: String {
        switch self {
        case .usage(let text): return "usage : captive-watchdog \(text)"
        case .message(let text): return text
        }
    }
}

struct Args {
    var positionals: [String] = []
    var flags: Set<String> = []
    var options: [String: String] = [:]

    init(_ raw: [String], valued: Set<String> = [], allowed: Set<String> = []) throws {
        var i = 0
        while i < raw.count {
            let arg = raw[i]
            if arg.hasPrefix("-"), arg.count > 1 {
                if valued.contains(arg) {
                    guard i + 1 < raw.count else { throw CLIError.message("valeur manquante après \(arg)") }
                    options[arg] = raw[i + 1]
                    i += 2
                    continue
                }
                guard allowed.contains(arg) else { throw CLIError.message("option inconnue : \(arg)") }
                flags.insert(arg)
            } else {
                positionals.append(arg)
            }
            i += 1
        }
    }
}

struct CLI {
    let arguments: [String]
    let paths: Paths

    static let usage = """
    captive-watchdog — reconnexion automatique aux portails captifs Wi-Fi

    Usage :
      captive-watchdog run [--once] [--force] [--verbose]    surveille et reconnecte
      captive-watchdog status [--json]                       état, dernier renouvellement
      captive-watchdog reconnect                             force un cycle immédiat
      captive-watchdog history [-n N]                        tentatives récentes
      captive-watchdog logs [-n N] [-f]                      journal
      captive-watchdog incidents [--reveal]                  dossiers de post-mortem
      captive-watchdog profile list                          profils disponibles
      captive-watchdog profile learn <page.html> [--url URL] [--save]
      captive-watchdog profile test <page.html> [--url URL]  payload qui serait envoyé
      captive-watchdog config show | path | set <clé> <valeur>
      captive-watchdog install-agent [--disable-legacy LABEL]
      captive-watchdog uninstall-agent
      captive-watchdog --version
    """

    func run() async -> Int32 {
        guard let command = arguments.first else {
            print(Self.usage)
            return 0
        }
        let rest = Array(arguments.dropFirst())
        do {
            switch command {
            case "run": return try await runCommand(rest)
            case "status": return try status(rest)
            case "reconnect": return try await reconnect()
            case "history": return try history(rest)
            case "logs": return try logs(rest)
            case "incidents": return try incidents(rest)
            case "profile": return try profile(rest)
            case "config": return try config(rest)
            case "install-agent": return try installAgent(rest)
            case "uninstall-agent": return uninstallAgent()
            case "--version", "version":
                print(BuildInfo.version)
                return 0
            case "help", "-h", "--help":
                print(Self.usage)
                return 0
            default:
                fputs("commande inconnue : \(command)\n\n\(Self.usage)\n", stderr)
                return 64
            }
        } catch {
            fputs("erreur : \(error)\n", stderr)
            return 1
        }
    }

    // MARK: run / reconnect

    func runCommand(_ raw: [String]) async throws -> Int32 {
        let args = try Args(raw, allowed: ["--once", "--force", "--verbose"])
        try paths.ensure()
        let config = try Config.load(from: paths.config)
        guard !config.email.isEmpty else {
            throw CLIError.message("aucune adresse e-mail configurée. Lancez : captive-watchdog config set email vous@example.com")
        }
        let lock = InstanceLock(url: paths.lock)
        let acquired = try lock.acquire()
        if !acquired && !args.flags.contains("--force") {
            let pid = InstanceLock.holderPID(at: paths.lock).map(String.init) ?? "?"
            throw CLIError.message("une instance tourne déjà (pid \(pid)). --force pour passer outre.")
        }
        defer { lock.release() }
        let logger = Logger(url: paths.log, echo: args.flags.contains("--verbose") || isatty(STDERR_FILENO) != 0)
        let engine = WatchdogEngine(paths: paths, config: config, logger: logger,
                                    environment: .live(notifier: OSAScriptNotifier()))
        if args.flags.contains("--once") {
            switch await engine.runOnce() {
            case .online: print("en ligne"); return 0
            case .renewed: print("reconnecté"); return 0
            case .offline: print("hors ligne"); return 2
            case .failed(let why): print("échec : \(why)"); return 1
            }
        }
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .global())
        source.setEventHandler { engine.requestImmediateCycle() }
        source.resume()
        await engine.loop()
        source.cancel()
        return 0
    }

    func reconnect() async throws -> Int32 {
        if let pid = InstanceLock.holderPID(at: paths.lock) {
            kill(pid, SIGUSR1)
            print("cycle immédiat demandé au démon (pid \(pid)) — suivi : captive-watchdog logs -f")
            return 0
        }
        return try await runCommand(["--once"])
    }

    // MARK: lecture

    func status(_ raw: [String]) throws -> Int32 {
        let args = try Args(raw, allowed: ["--json"])
        let state = StateStore(paths: paths).load()
        if args.flags.contains("--json") {
            print(String(decoding: try JSONCoding.encoder().encode(state), as: UTF8.self))
            return 0
        }
        let now = Date()
        let label: [NetworkStatus: String] = [.online: "en ligne", .captive: "portail captif",
                                              .offline: "hors ligne", .unknown: "inconnu"]
        var lines = ["Statut : \(label[state.status] ?? state.status.rawValue)"
                     + (state.since.map { " (depuis \(Format.timestamp($0)))" } ?? "")]
        if let check = state.lastCheck { lines.append("Dernière vérification : \(Format.ago(check, now: now))") }
        if let renew = state.lastRenew {
            lines.append("Dernier renouvellement : \(Format.timestamp(renew)) (\(Format.ago(renew, now: now)))"
                         + (state.lastRenewNetwork.map { " — \($0)" } ?? "")
                         + (state.lastRenewDuration.map { ", \(Format.duration($0))" } ?? ""))
        } else {
            lines.append("Dernier renouvellement : jamais")
        }
        if state.consecutiveFailures > 0 {
            lines.append("Échecs consécutifs : \(state.consecutiveFailures)" + (state.lastFailureReason.map { " — \($0)" } ?? ""))
        }
        lines.append(InstanceLock.holderPID(at: paths.lock).map { "Démon : actif (pid \($0))" } ?? "Démon : inactif")
        if let incident = state.lastIncident {
            lines.append("Dernier incident : \(paths.incidents.appendingPathComponent(incident).path)")
        }
        print(lines.joined(separator: "\n"))
        return 0
    }

    func history(_ raw: [String]) throws -> Int32 {
        let args = try Args(raw, valued: ["-n"])
        let events = StateStore(paths: paths).history(limit: Int(args.options["-n"] ?? "20") ?? 20)
        guard !events.isEmpty else {
            print("Aucune tentative enregistrée.")
            return 0
        }
        for e in events.reversed() {
            let verdict = e.verdict == .success ? "OK   " : "ÉCHEC"
            let duration = Format.duration(e.duration).padding(toLength: 8, withPad: " ", startingAt: 0)
            print("\(Format.timestamp(e.start))  \(verdict)  \(duration)  \(e.network)  [\(e.profile), \(e.attempts) tent.]"
                  + (e.reason.map { "  — \($0)" } ?? ""))
        }
        return 0
    }

    func logs(_ raw: [String]) throws -> Int32 {
        let args = try Args(raw, valued: ["-n"], allowed: ["-f"])
        guard FileManager.default.fileExists(atPath: paths.log.path) else {
            print("pas encore de journal (\(paths.log.path))")
            return 0
        }
        var tailArgs = ["-n", args.options["-n"] ?? "50"]
        if args.flags.contains("-f") { tailArgs.append("-f") }
        return tool("/usr/bin/tail", tailArgs + [paths.log.path])
    }

    func incidents(_ raw: [String]) throws -> Int32 {
        let args = try Args(raw, allowed: ["--reveal"])
        let dirs = IncidentRecorder(directory: paths.incidents, keep: .max).list()
        guard !dirs.isEmpty else {
            print("Aucun incident.")
            return 0
        }
        if args.flags.contains("--reveal") { return tool("/usr/bin/open", ["-R", dirs[0].path]) }
        for dir in dirs {
            let meta = try? JSONCoding.decoder().decode(IncidentMeta.self,
                                                        from: Data(contentsOf: dir.appendingPathComponent("meta.json")))
            print("\(dir.lastPathComponent)  \(meta?.verdict ?? "?")  \(meta?.steps.count ?? 0) étapes"
                  + (meta?.reason.map { "  — \($0)" } ?? ""))
        }
        print("\nDossier : \(paths.incidents.path)")
        return 0
    }

    // MARK: profils

    func profile(_ raw: [String]) throws -> Int32 {
        guard let sub = raw.first else { throw CLIError.usage("profile list | learn <page.html> | test <page.html>") }
        let args = try Args(Array(raw.dropFirst()), valued: ["--url"], allowed: ["--save"])
        let store = ProfileStore(userDirectory: paths.profiles)
        switch sub {
        case "list":
            let builtin = Set(BuiltinProfiles.all.map(\.id))
            let user = Set(ProfileStore.loadUserProfiles(from: paths.profiles).0.map(\.id))
            for p in store.profiles {
                let origin = user.contains(p.id) ? (builtin.contains(p.id) ? "utilisateur, remplace l'intégré" : "utilisateur") : "intégré"
                print("\(p.id.padding(toLength: 24, withPad: " ", startingAt: 0)) \(p.name ?? "")  [\(origin)]"
                      + (p.match?.portalHost.map { "  hôte ~ \($0)" } ?? ""))
            }
            for e in store.errors { print("⚠︎ \(e.file) ignoré : \(e.message)") }
            print("\nProfils utilisateur : \(paths.profiles.path)")
            return 0
        case "learn", "test":
            guard let file = args.positionals.first else { throw CLIError.usage("profile \(sub) <page.html> [--url URL]") }
            let html = HTTPClient.decodeBody(try Data(contentsOf: URL(fileURLWithPath: file)), contentType: nil)
            let url = args.options["--url"].flatMap(URL.init(string:))
            if sub == "learn" {
                let learned = ProfileLearner.learn(html: html, pageURL: url)
                let json = String(decoding: try JSONCoding.encoder().encode(learned.profile), as: UTF8.self)
                print(json)
                fputs(learned.report + "\n", stderr)
                if args.flags.contains("--save") {
                    try paths.ensure()
                    let destination = paths.profiles.appendingPathComponent("\(learned.profile.id).json")
                    try Data(json.utf8).write(to: destination)
                    fputs("enregistré : \(destination.path)\n", stderr)
                }
                return 0
            }
            let config = try Config.load(from: paths.config)
            let identity = Identity(email: config.email.isEmpty ? "guest@example.com" : config.email, password: config.password)
            print(ProfileLearner.dryRun(html: html, pageURL: url, profiles: store, identity: identity,
                                        skipCheckbox: config.skipCheckbox))
            return 0
        default:
            throw CLIError.usage("profile list | learn <page.html> | test <page.html>")
        }
    }

    // MARK: config

    func config(_ raw: [String]) throws -> Int32 {
        switch raw.first ?? "show" {
        case "show":
            var config = try Config.load(from: paths.config)
            if !config.password.isEmpty { config.password = "••••" }
            print(String(decoding: try JSONCoding.encoder().encode(config), as: UTF8.self))
            return 0
        case "path":
            print(paths.config.path)
            return 0
        case "set":
            guard raw.count == 3 else {
                throw CLIError.usage("config set <clé> <valeur>  (clés : \(Config.keys.joined(separator: ", ")))")
            }
            try paths.ensure()
            var config = try Config.load(from: paths.config)
            try config.set(raw[1], raw[2])
            try config.save(to: paths.config)
            print("\(raw[1]) mis à jour")
            return 0
        default:
            throw CLIError.usage("config show | path | set <clé> <valeur>")
        }
    }

    // MARK: agent

    func installAgent(_ raw: [String]) throws -> Int32 {
        let args = try Args(raw, valued: ["--disable-legacy"])
        let config = try Config.load(from: paths.config)
        guard !config.email.isEmpty else {
            throw CLIError.message("configurez d'abord l'e-mail : captive-watchdog config set email vous@example.com")
        }
        try paths.ensure()
        let agent = LaunchAgent()
        if let legacy = args.options["--disable-legacy"] {
            _ = tool("/bin/launchctl", ["bootout", "\(LaunchAgent.domain)/\(legacy)"], quiet: true)
            if let moved = try LaunchAgent.disableLegacy(label: legacy, directory: agent.directory) {
                print("ancien agent arrêté et désactivé : \(moved.path)")
            } else {
                print("aucun plist \(legacy) trouvé (déjà désactivé ?)")
            }
        }
        let executable = Self.invokedExecutablePath()
        if executable.contains("/.build/") {
            fputs("attention : binaire de build (\(executable)) ; l'agent cassera si .build est nettoyé.\n", stderr)
        }
        try agent.write(executable: executable, logs: paths.logs)
        _ = tool("/bin/launchctl", ["bootout", "\(LaunchAgent.domain)/\(agent.label)"], quiet: true)
        let rc = tool("/bin/launchctl", ["bootstrap", LaunchAgent.domain, agent.plistURL.path])
        guard rc == 0 else { throw CLIError.message("launchctl bootstrap a échoué (code \(rc))") }
        print("agent installé : \(agent.plistURL.path)\nexécutable : \(executable)\nsuivi : captive-watchdog status")
        return 0
    }

    func uninstallAgent() -> Int32 {
        let agent = LaunchAgent()
        _ = tool("/bin/launchctl", ["bootout", "\(LaunchAgent.domain)/\(agent.label)"], quiet: true)
        try? FileManager.default.removeItem(at: agent.plistURL)
        print("agent désinstallé (\(agent.plistURL.lastPathComponent))")
        return 0
    }

    /// Chemin tel qu'invoqué, symlinks non résolus : sous Homebrew,
    /// /opt/homebrew/bin/captive-watchdog survit aux mises à jour, pas la cible du lien.
    static func invokedExecutablePath() -> String {
        let arg0 = CommandLine.arguments[0]
        if arg0.hasPrefix("/") { return arg0 }
        if arg0.contains("/") {
            return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(arg0).standardized.path
        }
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let candidate = "\(dir)/\(arg0)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return Bundle.main.executablePath ?? arg0
    }

    func tool(_ path: String, _ arguments: [String], quiet: Bool = false) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if quiet {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        do { try process.run() } catch { return 127 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
