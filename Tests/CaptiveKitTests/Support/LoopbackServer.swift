import Foundation
import Network
@testable import CaptiveKit

/// Mini serveur HTTP sur 127.0.0.1 : une connexion = une requête, réponse
/// brute fournie par le test, puis fermeture. Sert à éprouver le vrai
/// transport Network.framework (lié à l'interface loopback).
final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "loopback-server")
    private let lock = NSLock()
    private var received: [String] = []
    private let respond: (String) -> Data

    /// `respond` reçoit la requête brute (en-têtes + corps) et renvoie les octets à écrire.
    init(respond: @escaping (String) -> Data) throws {
        self.respond = respond
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        listener = try NWListener(using: params, on: .any)
        listener.newConnectionHandler = { [weak self] c in self?.serve(c) }
    }

    var requests: [String] { lock.locked { received } }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { [listener] state in
                guard !resumed else { return }
                switch state {
                case .ready: resumed = true; cont.resume(returning: listener.port!.rawValue)
                case .failed(let e): resumed = true; cont.resume(throwing: e)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        read(c, buffer: Data())
    }

    private func read(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, eof, error in
            var acc = buffer
            if let data { acc.append(data) }
            if let text = Self.complete(acc) {
                lock.locked { received.append(text) }
                c.send(content: respond(text), completion: .contentProcessed { _ in c.cancel() })
            } else if eof || error != nil {
                c.cancel()
            } else {
                read(c, buffer: acc)
            }
        }
    }

    /// Requête complète : en-têtes terminés et corps de Content-Length reçu.
    private static func complete(_ data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        guard let end = text.range(of: "\r\n\r\n") else { return nil }
        let head = text[..<end.lowerBound].lowercased()
        let length = head.split(separator: "\r\n")
            .first { $0.hasPrefix("content-length:") }
            .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
        return text[end.upperBound...].utf8.count >= length ? text : nil
    }
}
