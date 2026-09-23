import XCTest
@testable import CaptiveKit

final class ProfileLearnerTests: XCTestCase {
    func testLearnedProfileCapturesTheBnBForm() throws {
        let learned = ProfileLearner.learn(html: try Fixture.string("bnb/portal-en.html"), pageURL: BnB.portalURL)
        let p = learned.profile
        XCTAssertEqual(p.id, "wifi-moveon-hotelbb-com")
        XCTAssertEqual(p.match?.portalHost, #"^wifi\.moveon-hotelbb\.com$"#)
        XCTAssertEqual(p.form?.action, #"wifi-access\.php"#)
        XCTAssertEqual(p.form?.fields?.email, "email")
        XCTAssertEqual(p.form?.checkboxes?.check, ["chartConsent"])
        XCTAssertEqual(p.form?.checkboxes?.skip, ["optinEmail"])
        XCTAssertEqual(p.form?.submit, "connect")
        XCTAssertNoThrow(try p.validate())
        XCTAssertTrue(learned.report.contains("<email>"))
        XCTAssertFalse(learned.report.contains("guest@example.com"))
    }

    func testLearnedProfileReproducesThePayloadOnTheOtherLanguage() throws {
        let learned = ProfileLearner.learn(html: try Fixture.string("bnb/portal-en.html"), pageURL: BnB.portalURL)
        let store = ProfileStore(builtin: [.generic, learned.profile], userDirectory: nil)
        let report = ProfileLearner.dryRun(html: try Fixture.string("bnb/portal-fr.html"), pageURL: BnB.portalURL,
                                           profiles: store, identity: Identity(email: BnB.email),
                                           skipCheckbox: FormFiller.defaultSkipCheckbox)
        XCTAssertTrue(report.contains("profil : wifi-moveon-hotelbb-com"))
        XCTAssertTrue(report.contains("POST \(BnB.loginAction)"))
        XCTAssertTrue(report.contains("  email = <email>"))
        XCTAssertTrue(report.contains("  connect = Se connecter"))
        XCTAssertFalse(report.contains("optinEmail ="))
    }

    func testLearnWithoutURLOrFormStillProducesAValidProfile() throws {
        let learned = ProfileLearner.learn(html: "<html><script>app()</script></html>", pageURL: nil)
        XCTAssertEqual(learned.profile.id, "nouveau-portail")
        XCTAssertNil(learned.profile.match)
        XCTAssertNoThrow(try learned.profile.validate())
        XCTAssertTrue(learned.report.contains("aucun formulaire"))
    }
}
