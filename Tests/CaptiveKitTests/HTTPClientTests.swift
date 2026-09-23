import XCTest
@testable import CaptiveKit

final class HTTPClientTests: XCTestCase {
    override func tearDown() { StubURLProtocol.reset() }

    func testCookiesFollowRedirectsAndLaterRequests() async throws {
        StubURLProtocol.reset { r in
            switch r.url.path {
            case "/a": return .redirect("https://p.example.com/b", headers: ["Set-Cookie": "SID=1; Path=/"])
            case "/b": return .html(r.cookie == "SID=1" ? "cookie ok" : "cookie manquant")
            default: return .html("posted")
            }
        }
        let client = StubURLProtocol.client()
        defer { client.close() }
        let first = try await client.get(URL(string: "https://p.example.com/a")!)
        XCTAssertEqual(first.body, "cookie ok")
        XCTAssertEqual(first.url.path, "/b")
        XCTAssertEqual(first.redirects, [Redirect(code: 302, from: "https://p.example.com/a", to: "https://p.example.com/b")])
        _ = try await client.post(URL(string: "https://p.example.com/c")!, form: [FormPair(name: "k", value: "v w")])
        let post = try XCTUnwrap(StubURLProtocol.requests.last)
        XCTAssertEqual(post.method, "POST")
        XCTAssertEqual(post.cookie, "SID=1")
        XCTAssertEqual(post.body, "k=v+w")
        XCTAssertEqual(post.headers["Content-Type"], "application/x-www-form-urlencoded")
    }

    func testHostOnlyCookieStaysOnItsHostDomainCookieIsShared() async throws {
        StubURLProtocol.reset { r in
            switch r.url.host {
            case "a.example.com": return .html("a", headers: ["Set-Cookie": "host=1; Path=/"])
            case "b.example.com": return .html("b", headers: ["Set-Cookie": "dom=2; Domain=example.com; Path=/"])
            default: return .html("c")
            }
        }
        let client = StubURLProtocol.client()
        defer { client.close() }
        _ = try await client.get(URL(string: "https://a.example.com/")!)
        _ = try await client.get(URL(string: "https://b.example.com/")!)
        _ = try await client.get(URL(string: "https://c.example.com/")!)
        XCTAssertEqual(StubURLProtocol.requests.last?.cookie, "dom=2")
    }

    func testRedirectCapReturnsLastRedirectResponse() async throws {
        StubURLProtocol.reset { r in .redirect(r.url.absoluteString) }
        let client = StubURLProtocol.client(maxRedirects: 3)
        defer { client.close() }
        let r = try await client.get(URL(string: "https://p.example.com/loop")!)
        XCTAssertEqual(r.status, 302)
        XCTAssertEqual(r.redirects.count, 3)
    }

    func testDecodesLatin1WithAndWithoutCharset() async throws {
        let html = #"<form action="/go" method="post"><input name="email" placeholder="Adresse électronique"></form>"#
        let bytes = try XCTUnwrap(html.data(using: .isoLatin1))
        StubURLProtocol.reset { r in
            r.url.path == "/declared"
                ? .bytes(bytes, contentType: "text/html; charset=ISO-8859-1")
                : .bytes(bytes, contentType: "text/html")
        }
        let client = StubURLProtocol.client()
        defer { client.close() }
        for path in ["/declared", "/undeclared"] {
            let r = try await client.get(URL(string: "https://p.example.com\(path)")!)
            XCTAssertEqual(HTMLScanner.scan(r.body).forms.first?.fields.first?.placeholder, "Adresse électronique", path)
        }
    }

    func testTransportFailureThrows() async {
        StubURLProtocol.reset(nil)
        let client = StubURLProtocol.client()
        defer { client.close() }
        do {
            _ = try await client.get(URL(string: "https://p.example.com/")!)
            XCTFail("aurait dû échouer")
        } catch {
            XCTAssertTrue(error is HTTPError)
        }
    }

    func testProberClassifiesOnlineCaptiveOffline() async {
        let prober = Prober()
        let client = StubURLProtocol.client()
        defer { client.close() }

        StubURLProtocol.reset { _ in .html(BnB.successPage) }
        guard case .online = await prober.probe(using: client) else { return XCTFail("attendu en ligne") }

        StubURLProtocol.reset { r in r.url.host == "captive.apple.com" ? .redirect(BnB.probeRedirect) : .html("portail") }
        guard case .captive(let r) = await prober.probe(using: client) else { return XCTFail("attendu captif") }
        XCTAssertEqual(r.url.host, "wifi.moveon-hotelbb.com")

        StubURLProtocol.reset(nil)
        guard case .offline = await prober.probe(using: client) else { return XCTFail("attendu hors ligne") }
    }
}
