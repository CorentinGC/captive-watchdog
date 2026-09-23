import XCTest
@testable import CaptiveKit

final class LoginSessionTests: XCTestCase {
    override func tearDown() { StubURLProtocol.reset() }

    func session(client: HTTPClient, recorder: IncidentRecorder? = nil, maxChainHops: Int = 4) -> LoginSession {
        var config = Config()
        config.email = BnB.email
        config.maxChainHops = maxChainHops
        return LoginSession(client: client, prober: Prober(), profiles: ProfileStore(userDirectory: nil),
                            identity: Identity(email: BnB.email), config: config, ssid: nil,
                            recorder: recorder, logger: Logger(url: nil), sleep: { _ in })
    }

    func captive(_ client: HTTPClient) async throws -> HTTPResponse {
        guard case .captive(let r) = await Prober().probe(using: client) else {
            throw XCTSkip("la sonde aurait dû être captive")
        }
        return r
    }

    func posts() -> [StubURLProtocol.Request] { StubURLProtocol.requests.filter { $0.method == "POST" } }

    func testBnBTwoStageLoginEndToEnd() async throws {
        let scenario = BnbScenario()
        scenario.install()
        let client = StubURLProtocol.client()
        defer { client.close() }
        let recorder = IncidentRecorder(directory: try TempDir.make(), keep: 5)

        let outcome = await session(client: client, recorder: recorder).run(captive: try await captive(client))

        XCTAssertEqual(outcome.verdict, .success, outcome.reason ?? "")
        XCTAssertEqual(outcome.host, "wifi.moveon-hotelbb.com")
        XCTAssertEqual(outcome.profile, "bnb-hotels")
        let posts = posts()
        XCTAssertEqual(posts.map(\.url.absoluteString), [BnB.loginAction, BnB.stage2Action])
        XCTAssertEqual(posts[0].body, "csrf_token=CSRF_TOKEN_PLACEHOLDER&email=guest%40example.com&chartConsent=true&connect=Se+connecter")
        XCTAssertEqual(posts[1].body, "username=000000000000_1700000000&password=000000000000&autherr=0")
        XCTAssertTrue(posts[0].cookie.contains("SESSIONID=abc123"), "cookie du GET rejoué au POST 1")
        XCTAssertTrue(posts[1].cookie.contains("wf=1"), "cookie de domaine rejoué au POST 2")
        XCTAssertFalse(posts[1].cookie.contains("SESSIONID"), "cookie d'hôte non envoyé à un autre hôte")
        XCTAssertFalse(StubURLProtocol.requests.contains { $0.body.contains("subscribe") || $0.body.contains("optinEmail") })

        let meta = try String(contentsOf: recorder.list()[0].appendingPathComponent("meta.json"), encoding: .utf8)
        XCTAssertTrue(meta.contains(#""verdict" : "success""#))
        XCTAssertTrue(meta.contains("<email>"))
        XCTAssertFalse(meta.contains(BnB.email))
    }

    func testStoppingAfterFirstPostWouldBeAFalseSuccess() async throws {
        let scenario = BnbScenario()
        scenario.grantAccess = false
        scenario.install()
        let client = StubURLProtocol.client()
        defer { client.close() }
        let outcome = await session(client: client).run(captive: try await captive(client))
        XCTAssertEqual(outcome.verdict, .failure)
        XCTAssertEqual(outcome.reason, "toujours captif après le login")
    }

    func testGenericPortalReachedThroughMetaRefresh() async throws {
        var authed = false
        StubURLProtocol.reset { r in
            switch (r.method, r.url.host ?? "", r.url.path) {
            case ("GET", "captive.apple.com", _):
                return .html(authed ? BnB.successPage
                                    : #"<html><head><meta http-equiv="refresh" content="0;url=http://portal.example.com/login"></head></html>"#)
            case ("GET", "portal.example.com", "/login"):
                return .html(#"<form method="post" action="/auth"><input type="email" name="mail"><input type="checkbox" name="terms" value="1"><button type="submit" name="go" value="1">Go</button></form>"#)
            case ("POST", "portal.example.com", "/auth"):
                authed = true
                return .html("<html>ok</html>")
            default:
                return .html("introuvable", status: 404)
            }
        }
        let client = StubURLProtocol.client()
        defer { client.close() }
        let outcome = await session(client: client).run(captive: try await captive(client))
        XCTAssertEqual(outcome.verdict, .success, outcome.reason ?? "")
        XCTAssertEqual(outcome.profile, "generic")
        XCTAssertEqual(outcome.host, "portal.example.com")
        XCTAssertEqual(posts().map(\.body), ["mail=guest%40example.com&terms=1&go=1"])
    }

    func testJavaScriptOnlyPortalFailsWithExplicitReason() async throws {
        StubURLProtocol.reset { r in
            r.url.host == "captive.apple.com"
                ? .redirect("https://portal.example.com/app")
                : .html("<html><div id=app></div><script>render()</script></html>")
        }
        let client = StubURLProtocol.client()
        defer { client.close() }
        let outcome = await session(client: client).run(captive: try await captive(client))
        XCTAssertEqual(outcome.verdict, .failure)
        XCTAssertTrue(outcome.reason?.contains("JavaScript") == true, outcome.reason ?? "")
        XCTAssertTrue(posts().isEmpty)
    }

    func testBounceLoopStopsAtHopCeiling() async throws {
        StubURLProtocol.reset { r in
            switch (r.method, r.url.host ?? "") {
            case ("GET", "captive.apple.com"): return .redirect("https://portal.example.com/login")
            case ("GET", _): return .html(#"<form method="post" action="/auth"><input type="email" name="mail"></form>"#)
            default: return .html(#"<form method="post" action="/auth"><input type="hidden" name="t" value="1"></form>"#)
            }
        }
        let client = StubURLProtocol.client()
        defer { client.close() }
        let outcome = await session(client: client, maxChainHops: 3).run(captive: try await captive(client))
        XCTAssertEqual(outcome.verdict, .failure)
        XCTAssertEqual(posts().count, 1 + 3)
        XCTAssertTrue(outcome.notes.contains("plafond de 3 rebonds atteint"))
    }
}
