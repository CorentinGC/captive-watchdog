import XCTest
@testable import CaptiveKit

final class FormFillerTests: XCTestCase {
    let identity = Identity(email: BnB.email, password: "")
    var bnb: Profile { BuiltinProfiles.all.first { $0.id == "bnb-hotels" }! }

    func fill(_ html: String, pageURL: URL, profile: Profile = .generic) throws -> FilledForm {
        let page = HTMLScanner.scan(html)
        let picked = try XCTUnwrap(FormFiller.pickLoginForm(page, profile: profile))
        return FormFiller.fill(picked.form, page: page, pageURL: pageURL, identity: identity, profile: profile)
    }

    func testBnBFrenchPayloadMatchesWhatTheRealPortalAccepted() throws {
        let filled = try fill(try Fixture.string("bnb/portal-fr.html"), pageURL: BnB.portalURL, profile: bnb)
        XCTAssertEqual(filled.payload, [
            FormPair(name: "csrf_token", value: "CSRF_TOKEN_PLACEHOLDER"),
            FormPair(name: "email", value: BnB.email),
            FormPair(name: "chartConsent", value: "true"),
            FormPair(name: "connect", value: "Se connecter"),
        ])
        XCTAssertEqual(filled.method, "post")
        XCTAssertEqual(filled.actionURL.absoluteString, BnB.loginAction)
    }

    func testBnBEnglishPageSendsEnglishSubmitValue() throws {
        let filled = try fill(try Fixture.string("bnb/portal-en.html"), pageURL: BnB.portalURL, profile: bnb)
        XCTAssertEqual(filled.payload.last, FormPair(name: "connect", value: "Connect"))
    }

    func testGenericHeuristicAloneHandlesBnB() throws {
        for fixture in ["bnb/portal-fr.html", "bnb/portal-en.html"] {
            let filled = try fill(try Fixture.string(fixture), pageURL: BnB.portalURL)
            XCTAssertEqual(filled.payload.map(\.name), ["csrf_token", "email", "chartConsent", "connect"], fixture)
        }
    }

    func testMarketingOptInAndOutOfFormSubscribeAreNeverSent() throws {
        for profile in [Profile.generic, bnb] {
            let filled = try fill(try Fixture.string("bnb/portal-fr.html"), pageURL: BnB.portalURL, profile: profile)
            let names = filled.payload.map(\.name)
            XCTAssertFalse(names.contains("optinEmail"))
            XCTAssertFalse(names.contains("subscribe"))
            XCTAssertEqual(names.filter { $0 == "connect" }.count, 1)
        }
    }

    func testStage2IsDetectedAsAutoFormAndReplayedVerbatim() throws {
        let page = HTMLScanner.scan(try Fixture.string("bnb/stage2.html"))
        let form = try XCTUnwrap(page.forms.first(where: FormFiller.isAutoForm))
        let replay = FormFiller.replay(form, page: page, pageURL: URL(string: BnB.loginAction)!)
        XCTAssertEqual(replay.payload, [
            FormPair(name: "username", value: "000000000000_1700000000"),
            FormPair(name: "password", value: "000000000000"),
            FormPair(name: "autherr", value: "0"),
        ])
        XCTAssertEqual(replay.actionURL.absoluteString, BnB.stage2Action)
        XCTAssertFalse(FormFiller.isAutoForm(HTMLScanner.scan(try Fixture.string("bnb/portal-fr.html")).forms[0]))
    }

    func testFormWithoutActionPostsToDocumentURL() throws {
        let pageURL = URL(string: "https://portal.example.com/login?session=42")!
        let html = #"<base href="https://other.example.com/"><form method="post"><input type="email" name="mail"></form>"#
        let filled = try fill(html, pageURL: pageURL)
        XCTAssertEqual(filled.actionURL, pageURL)
        XCTAssertEqual(filled.payload, [FormPair(name: "mail", value: BnB.email)])
    }

    func testRelativeActionHonoursBaseHref() throws {
        let html = #"<head><base href="https://portal.example.com/auth/"></head><form action="go.php" method="post"><input type="email" name="e"></form>"#
        let filled = try fill(html, pageURL: URL(string: "http://captive.apple.com/hotspot-detect.html")!)
        XCTAssertEqual(filled.actionURL.absoluteString, "https://portal.example.com/auth/go.php")
    }

    func testFallsBackToFirstTextFieldWhenNoHint() throws {
        let html = #"<form action="/a" method="post"><input type="text" name="f1"><input type="checkbox" name="c1" value="yes"><input type="submit" value="OK"></form>"#
        let filled = try fill(html, pageURL: URL(string: "https://portal.example.com/")!)
        XCTAssertEqual(filled.payload, [FormPair(name: "f1", value: BnB.email), FormPair(name: "c1", value: "yes")])
    }

    func testSendsOnlyThePreferredSubmit() throws {
        let html = """
        <form action="/a" method="post"><input type="email" name="e">
        <input type="submit" name="signup" value="Sign up"><input type="submit" name="login" value="Log in"></form>
        """
        let filled = try fill(html, pageURL: URL(string: "https://portal.example.com/")!)
        XCTAssertEqual(filled.payload.map(\.name), ["e", "login"])
    }

    func testSkipsSearchAndNewsletterForms() throws {
        let html = """
        <form class="newsletter" action="/nl"><input type="email" name="nl_email"><input type="submit"></form>
        <form action="/search"><input type="text" name="q"></form>
        <form action="/login" method="post"><input type="text" name="user_email"></form>
        """
        let filled = try fill(html, pageURL: URL(string: "https://portal.example.com/")!)
        XCTAssertEqual(filled.actionURL.path, "/login")
    }

    func testRadioGroupSendsOneValue() throws {
        let html = """
        <form action="/a" method="post"><input type="email" name="e">
        <input type="radio" name="plan" value="free"><input type="radio" name="plan" value="premium" checked>
        <input type="radio" name="plan" value="x"></form>
        """
        let filled = try fill(html, pageURL: URL(string: "https://portal.example.com/")!)
        XCTAssertEqual(filled.payload.filter { $0.name == "plan" }, [FormPair(name: "plan", value: "premium")])
    }

    func testProfileCheckListOverridesMarketingPattern() throws {
        let html = #"<form action="/a" method="post"><input type="email" name="e"><input type="checkbox" name="optin_terms" value="ok"></form>"#
        let url = URL(string: "https://portal.example.com/")!
        XCTAssertFalse(try fill(html, pageURL: url).payload.contains { $0.name == "optin_terms" })
        let profile = try JSONDecoder().decode(Profile.self, from: Data(#"{"id":"t","form":{"checkboxes":{"check":["optin_terms"]}}}"#.utf8))
        XCTAssertTrue(try fill(html, pageURL: url, profile: profile).payload.contains(FormPair(name: "optin_terms", value: "ok")))
    }

    func testEncodeIsFormURLEncoded() {
        let data = FormFiller.encode([FormPair(name: "a b", value: "é&=+"), FormPair(name: "t", value: "x==")])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "a+b=%C3%A9%26%3D%2B&t=x%3D%3D")
    }
}
