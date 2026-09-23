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

    public func plist(executable: String, arguments: [String] = ["run"], logs: URL) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [executable] + arguments,
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 30,
            "ProcessType": "Background",
            "StandardOutPath": logs.appendingPathComponent("launchd.out.log").path,
            "StandardErrorPath": logs.appendingPathComponent("launchd.err.log").path,
        ]
    }

    public func write(executable: String, logs: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist(executable: executable, logs: logs),
                                                      format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
    }

    /// Renomme le plist d'un ancien agent en `.disabled` (réversible).
    public static func disableLegacy(label: String, directory: URL) throws -> URL? {
        let source = directory.appendingPathComponent("\(label).plist")
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        let destination = source.appendingPathExtension("disabled")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
    }
}
