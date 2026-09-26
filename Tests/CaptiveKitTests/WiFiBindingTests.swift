import XCTest
@testable import CaptiveKit

/// Nouvelle association à un réseau captif : tant que la fenêtre de connexion
/// macOS est ouverte, la Wi-Fi a le rang « Never » et toute requête non liée
/// échoue en -1009. Seules les requêtes liées explicitement à la Wi-Fi passent
/// (observé au B&B le 2026-09-27).
final class WiFiBindingTests: XCTestCase {
    override func tearDown() { StubURLProtocol.reset() }

    func testPortalHeldByTheSystemWindowIsSeenThroughTheWiFi() async {
        StubURLProtocol.reset(nil)
        let bound = StubBoundTransport(BnbScenario().reply)
        let client = StubURLProtocol.client(bound: bound)
        defer { client.close() }
        guard case .captive(let r) = await Prober().probe(using: client) else { return XCTFail("attendu captif") }
        XCTAssertEqual(r.url.host, "wifi.moveon-hotelbb.com")
        XCTAssertTrue(client.isBoundToInterface)
    }

    func testWiFiDownToo_staysOfflineWithoutIPFallback() async {
        StubURLProtocol.reset(nil)
        let bound = StubBoundTransport { _ in nil }
        let client = StubURLProtocol.client(bound: bound)
        defer { client.close() }
        guard case .offline = await Prober().probe(using: client) else { return XCTFail("attendu hors ligne") }
        XCTAssertEqual(bound.requests.count, 1)
        XCTAssertFalse(bound.requests.contains { $0.url.host == Prober.fallbackIP })
        XCTAssertFalse(StubURLProtocol.requests.contains { $0.url.host == Prober.fallbackIP })
    }

    func testReachableNetworkNeverBindsToTheWiFi() async {
        StubURLProtocol.reset { _ in .html(BnB.successPage) }
        let bound = StubBoundTransport { _ in XCTFail("transport lié inutile"); return nil }
        let client = StubURLProtocol.client(bound: bound)
        defer { client.close() }
        guard case .online = await Prober().probe(using: client) else { return XCTFail("attendu en ligne") }
        XCTAssertFalse(client.isBoundToInterface)
    }

    func testEngineRenewsWhileTheSystemWindowHoldsTheWiFi() async throws {
        StubURLProtocol.reset(nil)
        let scenario = BnbScenario()
        let bound = StubBoundTransport(scenario.reply)
        let root = try TempDir.make()
        var config = Config()
        config.email = BnB.email
        let clock = TestClock()
        let engine = WatchdogEngine(paths: Paths(root: root), config: config,
                                    logger: Logger(url: root.appendingPathComponent("w.log")),
                                    environment: .init(makeClient: { _ in StubURLProtocol.client(bound: bound) },
                                                       sleep: { _ in }, now: { clock.tick() },
                                                       ssid: { nil }, notifier: RecordingNotifier()))
        engine.reloadsConfig = false
        let result = await engine.runOnce()
        XCTAssertEqual(result, .renewed)
        XCTAssertTrue(scenario.authed)
        XCTAssertTrue(bound.requests.contains { $0.method == "POST" && $0.url.path == "/reg.php" })
    }

    // MARK: redirections suivies par le client en mode lié

    func testBoundRedirectsConvertPostToGetAndCarryCookies() async throws {
        let bound = StubBoundTransport { r in
            switch r.url.path {
            case "/login": return .redirect("/welcome", status: 302, headers: ["Set-Cookie": "s=1; Path=/"])
            case "/welcome": return .html("ok \(r.method) [\(r.cookie)] [\(r.body)]")
            default: return .html("introuvable", status: 404)
            }
        }
        let client = StubURLProtocol.client(bound: bound)
        defer { client.close() }
        client.bindToInterface()
        let r = try await client.post(URL(string: "http://p.example.com/login")!, form: [FormPair(name: "a", value: "b")])
        XCTAssertEqual(r.body, "ok GET [s=1] []")
        XCTAssertEqual(r.url.absoluteString, "http://p.example.com/welcome")
        XCTAssertEqual(r.redirects.map(\.code), [302])
        XCTAssertNil(bound.requests.last?.headers["Content-Type"])
    }

    func testBound307KeepsPostBody() async throws {
        let bound = StubBoundTransport { r in
            r.url.path == "/a" ? .redirect("/b", status: 307) : .html("\(r.method) \(r.body)")
        }
        let client = StubURLProtocol.client(bound: bound)
        defer { client.close() }
        client.bindToInterface()
        let r = try await client.post(URL(string: "http://p.example.com/a")!, form: [FormPair(name: "x", value: "1")])
        XCTAssertEqual(r.body, "POST x=1")
    }

    func testBoundHostOverrideIsDroppedOnRedirect() async throws {
        let bound = StubBoundTransport { r in
            r.url.host == Prober.fallbackIP ? .redirect("http://portal.example.net/p") : .html("portail")
        }
        let client = StubURLProtocol.client(bound: bound)
        defer { client.close() }
        client.bindToInterface()
        _ = try await client.get(URL(string: "http://\(Prober.fallbackIP)/hotspot-detect.html")!, host: "captive.apple.com")
        XCTAssertEqual(bound.requests.first?.headers["Host"], "captive.apple.com")
        XCTAssertNil(bound.requests.last?.headers["Host"])
    }

    func testBoundRedirectCapReturnsLastRedirectResponse() async throws {
        let bound = StubBoundTransport { r in .redirect(r.url.absoluteString) }
        let client = StubURLProtocol.client(bound: bound, maxRedirects: 3)
        defer { client.close() }
        client.bindToInterface()
        let r = try await client.get(URL(string: "http://p.example.com/loop")!)
        XCTAssertEqual(r.status, 302)
        XCTAssertEqual(r.redirects.count, 3)
    }
}
