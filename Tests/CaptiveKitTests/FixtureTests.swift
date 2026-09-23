import XCTest

final class FixtureTests: XCTestCase {
    func testBnBFixturesAreScrubbed() throws {
        for name in ["bnb/portal-fr.html", "bnb/portal-en.html", "bnb/stage2.html"] {
            let html = try Fixture.string(name)
            XCTAssertTrue(html.contains("<form"), name)
            XCTAssertFalse(html.contains("go-mpuls" + "e"), "\(name) contient encore le script analytics")
        }
        XCTAssertTrue(try Fixture.string("bnb/portal-fr.html").contains("CSRF_TOKEN_PLACEHOLDER"))
        XCTAssertTrue(try Fixture.string("bnb/portal-en.html").contains("CSRF_TOKEN_PLACEHOLDER"))
        XCTAssertTrue(try Fixture.string("bnb/stage2.html").contains("000000000000_1700000000"))
    }
}
