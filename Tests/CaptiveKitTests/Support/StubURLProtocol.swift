import Foundation
@testable import CaptiveKit

/// Remplace le réseau : chaque requête passe par `handler`. nil = hors ligne.
/// État statique : les tests XCTest s'exécutent en série.
final class StubURLProtocol: URLProtocol {
    struct Request {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: String
        var cookie: String { headers["Cookie"] ?? "" }
    }

    struct Reply {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        var failure: URLError.Code?

        /// Échec réseau précis (ex. DNS : `.cannotFindHost`).
        static func fail(_ code: URLError.Code) -> Reply { Reply(failure: code) }

        static func html(_ s: String, status: Int = 200, headers: [String: String] = [:]) -> Reply {
            var h = headers
            h["Content-Type"] = h["Content-Type"] ?? "text/html; charset=UTF-8"
            return Reply(status: status, headers: h, body: Data(s.utf8))
        }

        static func bytes(_ data: Data, contentType: String) -> Reply {
            Reply(status: 200, headers: ["Content-Type": contentType], body: data)
        }

        static func redirect(_ to: String, status: Int = 302, headers: [String: String] = [:]) -> Reply {
            var h = headers
            h["Location"] = to
            return Reply(status: status, headers: h)
        }
    }

    static var handler: ((Request) -> Reply?)?
    private static let lock = NSLock()
    private static var recorded: [Request] = []
    static var requests: [Request] { lock.locked { recorded } }

    static func reset(_ handler: ((Request) -> Reply?)? = nil) {
        lock.locked { recorded = [] }
        self.handler = handler
    }

    static func client(maxRedirects: Int = 10) -> HTTPClient {
        HTTPClient(options: HTTPClientOptions(maxRedirects: maxRedirects, protocolClasses: [StubURLProtocol.self]))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let req = Request(method: request.httpMethod ?? "GET", url: request.url!,
                          headers: request.allHTTPHeaderFields ?? [:], body: Self.body(of: request))
        Self.lock.locked { Self.recorded.append(req) }
        guard let reply = Self.handler?(req) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        if let failure = reply.failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }
        let response = HTTPURLResponse(url: req.url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        if (300..<400).contains(reply.status), let location = reply.headers["Location"],
           let target = URL(string: location, relativeTo: req.url)?.absoluteURL {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    static func body(of request: URLRequest) -> String {
        if let body = request.httpBody { return String(decoding: body, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
