import XCTest
@testable import CaptiveKit

/// Régressions relevées par la revue finale de la phase 1.
final class ReviewFixTests: XCTestCase {
    override func tearDown() { StubURLProtocol.reset() }

    let url = URL(string: "https://portal.example.com/")!

    func fill(_ html: String) throws -> FilledForm {
        let page = HTMLScanner.scan(html)
        let picked = try XCTUnwrap(FormFiller.pickLoginForm(page, profile: .generic))
        return FormFiller.fill(picked.form, page: page, pageURL: url, identity: Identity(email: BnB.email), profile: .generic)
    }

    func testEmailGoesToEmailFieldNotToNameFields() throws {
        let filled = try fill(#"<form action="/a" method="post"><input name="nom"><input name="prenom"><input type="email" name="email"></form>"#)
        XCTAssertEqual(filled.payload, [
            FormPair(name: "nom", value: ""),
            FormPair(name: "prenom", value: ""),
            FormPair(name: "email", value: BnB.email),
        ])
    }

    func testStrongTextHintBeatsWeakHint() throws {
        let filled = try fill(#"<form action="/a" method="post"><input name="client_id"><input name="user_mail"></form>"#)
        XCTAssertEqual(filled.payload.first { $0.value == BnB.email }?.name, "user_mail")
    }

    func testScannerCapturesLabelText() {
        let html = #"<form><label for="c1">Offres <b>partenaires</b></label><input type="checkbox" id="c1" name="c1"><label><input type="checkbox" name="c2"> J&apos;accepte les CGU</label></form>"#
        let fields = HTMLScanner.scan(html).forms[0].fields
        XCTAssertEqual(fields.map(\.label), ["Offres partenaires", "J'accepte les CGU"])
    }

    func testMarketingCheckboxesAreDetectedByNameValueAndLabel() throws {
        let html = """
        <form action="/a" method="post"><input type="email" name="e">
        <input type="checkbox" name="opt_in_x">
        <input type="checkbox" name="cb2" value="newsletter">
        <input type="checkbox" name="accept_partner_offers_sms">
        <label for="c4">Je souhaite recevoir les bons plans</label><input type="checkbox" id="c4" name="c4">
        <label><input type="checkbox" name="c5"> J'accepte les offres partenaires</label>
        <label><input type="checkbox" name="cgu" value="1"> J'accepte les conditions générales</label>
        </form>
        """
        let names = try fill(html).payload.map(\.name)
        XCTAssertEqual(names, ["e", "cgu"])
    }

    func testInvalidOrUnsafeConfigValuesAreRepairedOnLoad() throws {
        let json = #"{"email":"guest@example.com","skipCheckbox":"news(letter","interval":0,"failBackoff":0,"retryDelay":0,"retries":0,"maxChainHops":99}"#
        let c = try JSONCoding.decoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertEqual(c.skipCheckbox, FormFiller.defaultSkipCheckbox)
        XCTAssertEqual(c.interval, 5)
        XCTAssertEqual(c.failBackoff, 30)
        XCTAssertEqual(c.retryDelay, 1)
        XCTAssertEqual(c.retries, 1)
        XCTAssertEqual(c.maxChainHops, 20)
        var d = Config()
        try d.set("failBackoff", "0")
        try d.set("retryDelay", "0")
        XCTAssertEqual(d.failBackoff, 30)
        XCTAssertEqual(d.retryDelay, 1)
    }

    func testFormSubmissionsCarryRefererAndOrigin() async throws {
        let scenario = BnbScenario()
        scenario.install()
        let client = StubURLProtocol.client()
        defer { client.close() }
        guard case .captive(let probe) = await Prober().probe(using: client) else { return XCTFail("attendu captif") }
        var config = Config()
        config.email = BnB.email
        let outcome = await LoginSession(client: client, prober: Prober(), profiles: ProfileStore(userDirectory: nil),
                                         identity: Identity(email: BnB.email), config: config, ssid: nil,
                                         recorder: nil, logger: Logger(url: nil), sleep: { _ in }).run(captive: probe)
        XCTAssertEqual(outcome.verdict, .success)
        let posts = StubURLProtocol.requests.filter { $0.method == "POST" }
        XCTAssertEqual(posts[0].headers["Referer"], BnB.probeRedirect)
        XCTAssertEqual(posts[0].headers["Origin"], "https://wifi.moveon-hotelbb.com")
        XCTAssertEqual(posts[1].headers["Referer"], BnB.loginAction)
        XCTAssertEqual(posts[1].headers["Origin"], "https://wifi.moveon-hotelbb.com")
    }

    func testRepeatedFailuresNotifyOnlyOnce() async throws {
        let scenario = BnbScenario()
        scenario.grantAccess = false
        scenario.install()
        let root = try TempDir.make()
        let notifier = RecordingNotifier()
        var config = Config()
        config.email = BnB.email
        config.retries = 1
        let clock = TestClock()
        let engine = WatchdogEngine(paths: Paths(root: root), config: config, logger: Logger(url: nil),
                                    environment: .init(makeClient: { _ in StubURLProtocol.client() }, sleep: { _ in },
                                                       now: { clock.tick() }, ssid: { nil }, notifier: notifier))
        engine.reloadsConfig = false
        _ = await engine.runOnce()
        _ = await engine.runOnce()
        _ = await engine.runOnce()
        XCTAssertEqual(notifier.titles, ["Wi-Fi : reconnexion impossible"])
        XCTAssertEqual(StateStore(paths: Paths(root: root)).load().consecutiveFailures, 3)
        scenario.grantAccess = true
        _ = await engine.runOnce()
        XCTAssertEqual(notifier.titles, ["Wi-Fi : reconnexion impossible", "Wi-Fi reconnecté"])
    }
}
