import XCTest
@testable import CaptiveKit

/// Portails qui coupent le DNS avant authentification : la sonde par nom
/// échoue, la sonde de secours par IP littérale + en-tête Host voit le portail.
final class FallbackProbeTests: XCTestCase {
    override func tearDown() { StubURLProtocol.reset() }

    func testDNSBlockedPortalIsSeenThroughTheIPFallback() async {
        StubURLProtocol.reset { r in
            switch r.url.host {
            case "captive.apple.com": return .fail(.cannotFindHost)
            case Prober.fallbackIP: return .redirect("http://portal.example.net/portal")
            default: return .html("<form><input name=email></form>")
            }
        }
        let client = StubURLProtocol.client()
        defer { client.close() }
        guard case .captive(let r) = await Prober().probe(using: client) else { return XCTFail("attendu captif") }
        XCTAssertEqual(r.url.host, "portal.example.net")
        let fallback = StubURLProtocol.requests.first { $0.url.host == Prober.fallbackIP }
        XCTAssertEqual(fallback?.headers["Host"], "captive.apple.com")
    }

    func testFallbackSuccessStaysOfflineWithTheOriginalReason() async {
        StubURLProtocol.reset { r in
            r.url.host == Prober.fallbackIP ? .html(BnB.successPage) : .fail(.cannotFindHost)
        }
        let client = StubURLProtocol.client()
        defer { client.close() }
        guard case .offline = await Prober().probe(using: client) else { return XCTFail("attendu hors ligne") }
    }

    func testNoFallbackWhenTheMachineIsNotConnected() async {
        StubURLProtocol.reset(nil)
        let client = StubURLProtocol.client()
        defer { client.close() }
        guard case .offline = await Prober().probe(using: client) else { return XCTFail("attendu hors ligne") }
        XCTAssertFalse(StubURLProtocol.requests.contains { $0.url.host == Prober.fallbackIP })
    }

    func testCustomProbeURLHasNoFallback() async {
        StubURLProtocol.reset { r in r.url.host == Prober.fallbackIP ? .redirect("http://portal.example.net/") : .fail(.cannotFindHost) }
        let client = StubURLProtocol.client()
        defer { client.close() }
        let prober = Prober(url: URL(string: "http://probe.example.com/ok")!)
        guard case .offline = await prober.probe(using: client) else { return XCTFail("attendu hors ligne") }
    }

    func testOfflineReasonChangesAreLogged() async throws {
        let root = try TempDir.make()
        let logURL = root.appendingPathComponent("w.log")
        var config = Config()
        config.email = BnB.email
        let clock = TestClock()
        let engine = WatchdogEngine(paths: Paths(root: root), config: config, logger: Logger(url: logURL),
                                    environment: .init(makeClient: { _ in StubURLProtocol.client() },
                                                       sleep: { _ in }, now: { clock.tick() },
                                                       ssid: { nil }, notifier: RecordingNotifier()))
        engine.reloadsConfig = false
        StubURLProtocol.reset(nil)
        _ = await engine.runOnce()
        _ = await engine.runOnce()
        StubURLProtocol.reset { _ in .fail(.timedOut) }
        _ = await engine.runOnce()
        let log = try String(contentsOf: logURL, encoding: .utf8)
        let lines = log.split(separator: "\n")
        XCTAssertEqual(lines.filter { $0.contains("→ offline") }.count, 1, log)
        XCTAssertEqual(lines.filter { $0.contains("hors ligne : ") }.count, 1, log)
    }
}
