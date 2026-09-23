import XCTest
@testable import CaptiveKit

final class LaunchAgentTests: XCTestCase {
    func testPlistRunsTheInvokedExecutable() throws {
        let dir = try TempDir.make()
        let agent = LaunchAgent(directory: dir)
        let logs = URL(fileURLWithPath: "/tmp/cw-logs")
        try agent.write(executable: "/opt/homebrew/bin/captive-watchdog", logs: logs)
        let data = try Data(contentsOf: agent.plistURL)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["Label"] as? String, "io.github.corentingc.captive-watchdog")
        XCTAssertEqual(plist["ProgramArguments"] as? [String], ["/opt/homebrew/bin/captive-watchdog", "run"])
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["KeepAlive"] as? Bool, true)
        XCTAssertEqual(plist["StandardErrorPath"] as? String, "/tmp/cw-logs/launchd.err.log")
        XCTAssertEqual(agent.plistURL.lastPathComponent, "io.github.corentingc.captive-watchdog.plist")
    }

    func testDisableLegacyRenamesThePlist() throws {
        let dir = try TempDir.make()
        let legacy = dir.appendingPathComponent("org.example.old-watchdog.plist")
        try Data("x".utf8).write(to: legacy)
        let moved = try XCTUnwrap(try LaunchAgent.disableLegacy(label: "org.example.old-watchdog", directory: dir))
        XCTAssertEqual(moved.lastPathComponent, "org.example.old-watchdog.plist.disabled")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertNil(try LaunchAgent.disableLegacy(label: "org.example.absent", directory: dir))
    }
}
