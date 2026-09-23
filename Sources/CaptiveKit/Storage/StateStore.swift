import Foundation

public enum NetworkStatus: String, Codable, Sendable {
    case unknown, online, captive, offline
}

public struct WatchdogState: Codable, Equatable, Sendable {
    public var status: NetworkStatus = .unknown
    public var since: Date?
    public var lastCheck: Date?
    public var lastRenew: Date?
    public var lastRenewDuration: Double?
    public var lastRenewNetwork: String?
    public var lastFailure: Date?
    public var lastFailureReason: String?
    public var lastIncident: String?
    public var consecutiveFailures = 0
    public var pid: Int32?

    public init() {}
}

/// Un événement par tentative de reconnexion (spec §7, source de la vue Historique).
public struct HistoryEvent: Codable, Equatable, Sendable {
    public enum Verdict: String, Codable, Sendable { case success, failure }

    public var network: String
    public var profile: String
    public var start: Date
    public var end: Date
    public var duration: Double
    public var verdict: Verdict
    public var attempts: Int
    public var incident: String?
    public var reason: String?
}

public struct StateStore: Sendable {
    public let paths: Paths

    public init(paths: Paths) { self.paths = paths }

    public func load() -> WatchdogState {
        guard let data = try? Data(contentsOf: paths.state),
              let state = try? JSONCoding.decoder().decode(WatchdogState.self, from: data) else { return WatchdogState() }
        return state
    }

    public func save(_ state: WatchdogState) throws {
        try FileManager.default.createDirectory(at: paths.support, withIntermediateDirectories: true)
        try JSONCoding.encoder().encode(state).write(to: paths.state, options: .atomic)
    }

    public func append(_ event: HistoryEvent) throws {
        try FileManager.default.createDirectory(at: paths.support, withIntermediateDirectories: true)
        var line = try JSONCoding.encoder(pretty: false).encode(event)
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: paths.history) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(line)
        } else {
            try line.write(to: paths.history)
        }
    }

    public func history(limit: Int? = nil) -> [HistoryEvent] {
        guard let text = try? String(contentsOf: paths.history, encoding: .utf8) else { return [] }
        let decoder = JSONCoding.decoder()
        let events = text.split(separator: "\n").compactMap { try? decoder.decode(HistoryEvent.self, from: Data($0.utf8)) }
        guard let limit else { return events }
        return Array(events.suffix(limit))
    }
}
