import Foundation

public struct Paths: Sendable {
    public let support: URL
    public let logs: URL

    public init(support: URL, logs: URL) {
        self.support = support
        self.logs = logs
    }

    /// Racine unique (tests, `CAPTIVE_WATCHDOG_HOME`) : `support/` et `logs/`.
    public init(root: URL) {
        self.init(support: root.appendingPathComponent("support", isDirectory: true),
                  logs: root.appendingPathComponent("logs", isDirectory: true))
    }

    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> Paths {
        if let root = environment["CAPTIVE_WATCHDOG_HOME"], !root.isEmpty {
            return Paths(root: URL(fileURLWithPath: root, isDirectory: true))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return Paths(support: home.appendingPathComponent("Library/Application Support/CaptiveWatchdog", isDirectory: true),
                     logs: home.appendingPathComponent("Library/Logs/CaptiveWatchdog", isDirectory: true))
    }

    public var config: URL { support.appendingPathComponent("config.json") }
    public var state: URL { support.appendingPathComponent("state.json") }
    public var history: URL { support.appendingPathComponent("history.jsonl") }
    public var profiles: URL { support.appendingPathComponent("profiles", isDirectory: true) }
    public var incidents: URL { support.appendingPathComponent("incidents", isDirectory: true) }
    public var lock: URL { support.appendingPathComponent("watchdog.lock") }
    public var log: URL { logs.appendingPathComponent("watchdog.log") }

    public func ensure() throws {
        for dir in [support, profiles, incidents, logs] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
