import Foundation

public struct LaunchAgent {
    public static let defaultLabel = "io.github.corentingc.captive-watchdog"
    public static var domain: String { "gui/\(getuid())" }

    public let label: String
    public let directory: URL
    public var plistURL: URL { directory.appendingPathComponent("\(label).plist") }

    public init(label: String = LaunchAgent.defaultLabel,
                directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")) {
        self.label = label
        self.directory = directory
    }

    public enum Kind: Sendable {
        /// `captive-watchdog run`, relancé en permanence.
        case daemon
        /// L'app menubar : « Quitter » la laisse quittée jusqu'au prochain login.
        case app
    }

    public func plist(executable: String, kind: Kind = .daemon, logs: URL) -> [String: Any] {
        let keepAlive: Any = kind == .daemon ? true : ["SuccessfulExit": false]
        return [
            "Label": label,
            "ProgramArguments": kind == .daemon ? [executable, "run"] : [executable],
            "RunAtLoad": true,
            "KeepAlive": keepAlive,
            "ThrottleInterval": 30,
            "ProcessType": kind == .daemon ? "Background" : "Interactive",
            "StandardOutPath": logs.appendingPathComponent("launchd.out.log").path,
            "StandardErrorPath": logs.appendingPathComponent("launchd.err.log").path,
        ]
    }

    public func write(executable: String, kind: Kind = .daemon, logs: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist(executable: executable, kind: kind, logs: logs),
                                                      format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
    }
}
