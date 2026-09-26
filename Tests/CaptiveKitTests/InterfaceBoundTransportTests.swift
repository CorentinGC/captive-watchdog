import XCTest
import Network
@testable import CaptiveKit

/// Vrai transport Network.framework, lié à l'interface loopback pour le test.
final class InterfaceBoundTransportTests: XCTestCase {
    private func client() -> HTTPClient {
        let c = HTTPClient(options: HTTPClientOptions(boundTransport: InterfaceBoundTransport(interface: .loopback)))
        c.bindToInterface()
        return c
    }

    private func reply(_ lines: [String], body: String = "") -> Data {
        Data((lines.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8)
    }

    func testGetDecodesChunkedBodyAndMergesCookies() async throws {
        let server = try LoopbackServer { _ in
            self.reply(["HTTP/1.1 200 OK", "Content-Type: text/html; charset=utf-8", "Transfer-Encoding: chunked",
                        "Set-Cookie: a=1; Path=/", "Set-Cookie: b=2; Path=/"],
                       body: "5\r\nPorta\r\n5\r\nil é\r\n0\r\n\r\n")
        }
        let port = try await server.start()
        defer { server.stop() }
        let c = client()
        defer { c.close() }
        let url = URL(string: "http://127.0.0.1:\(port)/p?x=1%202")!
        let r = try await c.get(url)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.body, "Portail é")
        XCTAssertEqual(c.jar.header(for: url), "a=1; b=2")
        let head = try XCTUnwrap(server.requests.first)
        XCTAssertTrue(head.hasPrefix("GET /p?x=1%202 HTTP/1.1\r\n"), head)
        XCTAssertTrue(head.contains("\r\nHost: 127.0.0.1:\(port)\r\n"), head)
        XCTAssertTrue(head.contains("\r\nConnection: close\r\n"), head)
    }

    func testPostSendsBodyAndFollowsRedirectOnTheSameInterface() async throws {
        let server = try LoopbackServer { raw in
            raw.hasPrefix("POST ")
                ? self.reply(["HTTP/1.1 302 Found", "Location: /done", "Content-Length: 0"])
                : self.reply(["HTTP/1.1 200 OK", "Content-Length: 2"], body: "ok")
        }
        let port = try await server.start()
        defer { server.stop() }
        let c = client()
        defer { c.close() }
        let r = try await c.post(URL(string: "http://127.0.0.1:\(port)/login")!,
                                 form: [FormPair(name: "email", value: "a@b.c")])
        XCTAssertEqual(r.body, "ok")
        XCTAssertEqual(r.redirects.count, 1)
        XCTAssertTrue(server.requests.first?.hasSuffix("\r\n\r\nemail=a%40b.c") ?? false, server.requests.first ?? "")
        XCTAssertTrue(server.requests.last?.hasPrefix("GET /done HTTP/1.1") ?? false)
    }

    func testBodyWithoutLengthIsReadUntilClose() async throws {
        let server = try LoopbackServer { _ in self.reply(["HTTP/1.0 200 OK"], body: "fin") }
        let port = try await server.start()
        defer { server.stop() }
        let c = client()
        defer { c.close() }
        let r = try await c.get(URL(string: "http://127.0.0.1:\(port)/")!)
        XCTAssertEqual(r.body, "fin")
    }

    func testRefusedConnectionThrowsTransportError() async throws {
        let server = try LoopbackServer { _ in Data() }
        let port = try await server.start()
        server.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        let c = client()
        defer { c.close() }
        do {
            _ = try await c.get(URL(string: "http://127.0.0.1:\(port)/")!)
            XCTFail("attendu une erreur")
        } catch let error as HTTPError {
            guard case .transport = error else { return XCTFail("attendu transport, reçu \(error)") }
        }
    }
}
