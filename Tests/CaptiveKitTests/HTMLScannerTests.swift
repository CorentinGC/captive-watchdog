import XCTest
@testable import CaptiveKit

final class HTMLScannerTests: XCTestCase {
    func testBnBPortalFormIncludingOutOfFormSubmit() throws {
        let page = HTMLScanner.scan(try Fixture.string("bnb/portal-fr.html"))
        XCTAssertEqual(page.title, "B&B HOTELS WIFI Portal")
        XCTAssertEqual(page.forms.count, 1)
        let form = page.forms[0]
        XCTAssertEqual(form.id, "access-wifi")
        XCTAssertEqual(form.action, "wifi-access.php")
        XCTAssertEqual(form.method, "post")
        XCTAssertEqual(form.fields.map(\.name), ["csrf_token", "email", "chartConsent", "optinEmail", "connect", "subscribe"])
        XCTAssertEqual(form.fields.first { $0.name == "subscribe" }?.value, "Adhérer gratuitement")
        XCTAssertEqual(form.fields.first { $0.name == "csrf_token" }?.value, "CSRF_TOKEN_PLACEHOLDER")
        XCTAssertEqual(form.fields.first { $0.name == "email" }?.placeholder, "Adresse e-mail")
    }

    func testBnBStage2HiddenForm() throws {
        let page = HTMLScanner.scan(try Fixture.string("bnb/stage2.html"))
        let form = try XCTUnwrap(page.forms.first { $0.id == "authsubmit" })
        XCTAssertEqual(form.action, "https://redirect-wifi.moveon-hotelbb.com/reg.php")
        XCTAssertEqual(form.fields.filter { $0.type == "hidden" }.map(\.name), ["username", "password", "autherr"])
        XCTAssertEqual(form.fields.last?.tag, "button")
        XCTAssertEqual(form.fields.last?.type, "submit")
        XCTAssertNil(form.fields.last?.name)
    }

    func testMalformedMarkupIsParsedLikeABrowser() {
        let html = """
        <form action=/login method=POST>
          <input name=email type=email>
          <input type=checkbox name=cgu checked>
          3 < 5
          <!-- <form action=/bad><input name=ghost> -->
          <input name=x value='a>b'>
          <input name=first name=second>
        """
        let page = HTMLScanner.scan(html)
        XCTAssertEqual(page.forms.count, 1)
        let form = page.forms[0]
        XCTAssertEqual(form.action, "/login")
        XCTAssertEqual(form.method, "post")
        XCTAssertEqual(form.fields.map(\.name), ["email", "cgu", "x", "first"])
        XCTAssertEqual(form.fields[0].type, "email")
        XCTAssertTrue(form.fields[1].checked)
        XCTAssertEqual(form.fields[2].value, "a>b")
    }

    func testScriptContentIsNotMarkup() {
        let html = #"<script>var s = "<form action='/js'>";</SCRIPT><form action="/real"><input name="a"></form>"#
        let page = HTMLScanner.scan(html)
        XCTAssertEqual(page.forms.map(\.action), ["/real"])
    }

    func testBaseHrefMetaRefreshAndTitleEntities() {
        let html = """
        <head><title>B&amp;B &eacute;t&eacute;</title>
        <base href="https://portal.example.com/sub/">
        <meta http-equiv="Refresh" content="0; url='next.php?a=1&amp;b=2'"></head>
        """
        let page = HTMLScanner.scan(html)
        XCTAssertEqual(page.title, "B&B été")
        XCTAssertEqual(page.baseHref, "https://portal.example.com/sub/")
        XCTAssertEqual(page.metaRefresh, "next.php?a=1&b=2")
        XCTAssertTrue(page.forms.isEmpty)
    }

    func testSelectAndTextarea() {
        let html = """
        <form><select name=room><option value=1>A<option value=2 selected>B<option>Deluxe</option></select>
        <textarea name=msg>hi &amp; bye</textarea></form>
        """
        let fields = HTMLScanner.scan(html).forms[0].fields
        XCTAssertEqual(fields[0].name, "room")
        XCTAssertEqual(fields[0].options, ["1", "2", "Deluxe"])
        XCTAssertEqual(fields[0].value, "2")
        XCTAssertEqual(fields[1].value, "hi & bye")
    }

    func testFieldsAttachedByFormAttribute() {
        let html = #"<form id="f" action="/a"><input name="in"></form><input name="out" form="f"><input name="orphan">"#
        XCTAssertEqual(HTMLScanner.scan(html).forms[0].fields.map(\.name), ["in", "out"])
    }

    func testEntities() {
        XCTAssertEqual(HTMLEntities.decode("&eacute;&#233;&#xE9;&amp;&unknown; & x"), "ééé&&unknown; & x")
    }
}
