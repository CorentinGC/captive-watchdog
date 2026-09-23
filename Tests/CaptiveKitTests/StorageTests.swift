import XCTest
@testable import CaptiveKit

final class StorageTests: XCTestCase {
    func response(_ url: String, _ body: String) -> HTTPResponse {
        HTTPResponse(url: URL(string: url)!, status: 200, headers: [:], body: body, redirects: [])
    }

    func testConfigDefaultsFillMissingKeys() throws {
        let c = try JSONCoding.decoder().decode(Config.self, from: Data(#"{"email":"guest@example.com"}"#.utf8))
        XCTAssertEqual(c.email, "guest@example.com")
        XCTAssertEqual(c.interval, 20)
        XCTAssertEqual(c.retries, 3)
        XCTAssertEqual(c.maxChainHops, 4)
        XCTAssertFalse(c.verifyTLS)
        XCTAssertEqual(c.skipCheckbox, FormFiller.defaultSkipCheckbox)
    }

    func testConfigSetValidatesAndSaveIsPrivate() throws {
        let root = try TempDir.make()
        let url = root.appendingPathComponent("config.json")
        var c = Config()
        try c.set("email", "guest@example.com")
        try c.set("interval", "30")
        try c.set("notify", "non")
        XCTAssertThrowsError(try c.set("bogus", "1"))
        XCTAssertThrowsError(try c.set("retries", "abc"))
        XCTAssertThrowsError(try c.set("skipCheckbox", "("))
        XCTAssertEqual(c.interval, 30)
        XCTAssertFalse(c.notify)
        try c.save(to: url)
        XCTAssertEqual(try Config.load(from: url), c)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        XCTAssertEqual(try Config.load(from: root.appendingPathComponent("absent.json")), Config())
    }

    func testStateRoundTripAndHistoryTail() throws {
        let store = StateStore(paths: Paths(root: try TempDir.make()))
        XCTAssertEqual(store.load(), WatchdogState())
        var state = WatchdogState()
        state.status = .online
        state.lastRenew = Date(timeIntervalSince1970: 1_700_000_000)
        state.consecutiveFailures = 2
        try store.save(state)
        XCTAssertEqual(store.load(), state)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for k in 0..<3 {
            try store.append(HistoryEvent(network: "n\(k)", profile: "generic", start: start, end: start.addingTimeInterval(6),
                                          duration: 6, verdict: .success, attempts: 1, incident: nil, reason: nil))
        }
        XCTAssertEqual(store.history().count, 3)
        XCTAssertEqual(store.history(limit: 2).map(\.network), ["n1", "n2"])
    }

    func testHistorySkipsCorruptLines() throws {
        let paths = Paths(root: try TempDir.make())
        try paths.ensure()
        try "pas du json\n".write(to: paths.history, atomically: true, encoding: .utf8)
        let store = StateStore(paths: paths)
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        try store.append(HistoryEvent(network: "ok", profile: "generic", start: t, end: t, duration: 0,
                                      verdict: .failure, attempts: 3, incident: nil, reason: "x"))
        XCTAssertEqual(store.history().map(\.network), ["ok"])
    }

    func testIncidentPruneKeepsNewestAndNeverTheOpenOne() throws {
        let recorder = IncidentRecorder(directory: try TempDir.make(), keep: 2)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var last: Incident?
        for k in 0..<3 {
            last = try recorder.open(host: "portal.example.com", redacting: nil, now: base.addingTimeInterval(Double(k)))
        }
        let open = try XCTUnwrap(last)
        open.record("probe", response("https://portal.example.com/", "<html></html>"))
        let names = recorder.list().map(\.lastPathComponent)
        XCTAssertEqual(names.count, 2)
        XCTAssertEqual(names.first, open.name)
        XCTAssertTrue(FileManager.default.fileExists(atPath: open.directory.appendingPathComponent("00-probe.html").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: open.directory.appendingPathComponent("meta.json").path))
    }

    func testIncidentRedactsIdentity() throws {
        let recorder = IncidentRecorder(directory: try TempDir.make(), keep: 5)
        let incident = try recorder.open(host: "portal.example.com",
                                         redacting: Identity(email: BnB.email, password: "s3cret-pass"))
        incident.record("login",
                        response("https://portal.example.com/ok?u=guest%40example.com", "Bienvenue guest@example.com"),
                        request: RequestRecord(method: "post", url: "https://portal.example.com/auth",
                                               payload: [FormPair(name: "email", value: BnB.email),
                                                         FormPair(name: "pw", value: "s3cret-pass")]))
        incident.note("e-mail guest@example.com placé")
        incident.finish(verdict: "success", reason: nil)
        let everything = try FileManager.default.contentsOfDirectory(at: incident.directory, includingPropertiesForKeys: nil)
            .map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        XCTAssertFalse(everything.contains("guest@example.com"))
        XCTAssertFalse(everything.contains("guest%40example.com"))
        XCTAssertFalse(everything.contains("s3cret-pass"))
        XCTAssertTrue(everything.contains("<email>"))
        XCTAssertTrue(everything.contains("<password>"))
    }

    func testLoggerAppendsAndRotates() throws {
        let url = try TempDir.make().appendingPathComponent("watchdog.log")
        let logger = Logger(url: url, maxBytes: 200)
        for k in 0..<10 { logger.info("ligne \(k) " + String(repeating: "x", count: 30)) }
        let current = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(current.contains("ligne 9"))
        XCTAssertTrue(current.contains("[INFO]"))
        XCTAssertLessThanOrEqual(current.utf8.count, 200)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("1").path))
    }

    func testFormatDurations() {
        XCTAssertEqual(Format.duration(6.1), "6 s")
        XCTAssertEqual(Format.duration(60), "1 min")
        XCTAssertEqual(Format.duration(3 * 3600 + 12 * 60), "3 h 12 min")
        XCTAssertEqual(Format.duration(7200), "2 h")
        XCTAssertEqual(Format.duration(90_000), "1 j 1 h")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(Format.ago(now.addingTimeInterval(-300), now: now), "il y a 5 min")
    }

    func testPathsHonourOverride() {
        let paths = Paths.standard(environment: ["CAPTIVE_WATCHDOG_HOME": "/tmp/cw-root"])
        XCTAssertEqual(paths.config.path, "/tmp/cw-root/support/config.json")
        XCTAssertEqual(paths.log.path, "/tmp/cw-root/logs/watchdog.log")
        XCTAssertTrue(Paths.standard(environment: [:]).support.path.hasSuffix("Library/Application Support/CaptiveWatchdog"))
    }
}
