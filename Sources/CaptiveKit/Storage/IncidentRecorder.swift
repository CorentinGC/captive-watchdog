import Foundation

public struct RequestRecord: Codable, Sendable {
    public var method: String
    public var url: String
    public var payload: [FormPair]

    init(method: String, url: String, payload: [FormPair]) {
        self.method = method
        self.url = url
        self.payload = payload
    }

    public init(_ filled: FilledForm) {
        self.init(method: filled.method, url: filled.actionURL.absoluteString, payload: filled.payload)
    }
}

public struct IncidentStep: Codable, Sendable {
    public var n: Int
    public var label: String
    public var url: String
    public var status: Int
    public var redirects: [Redirect]
    public var headers: [String: String]
    public var request: RequestRecord?
}

public struct IncidentMeta: Codable, Sendable {
    public var started: Date
    public var finished: Date?
    public var host: String
    public var profile: String?
    public var verdict: String
    public var reason: String?
    public var steps: [IncidentStep] = []
    public var candidates: [FormCandidate] = []
    public var notes: [String] = []
}

/// Remplace l'identité par des marqueurs : un incident doit pouvoir être partagé.
struct Redactor: Sendable {
    let secrets: [(String, String)]

    init(identity: Identity?) {
        var secrets: [(String, String)] = []
        if let identity, !identity.email.isEmpty {
            secrets.append((FormFiller.formEscape(identity.email), "<email>"))
            secrets.append((identity.email, "<email>"))
        }
        if let identity, identity.password.count >= 4 {
            secrets.append((FormFiller.formEscape(identity.password), "<password>"))
            secrets.append((identity.password, "<password>"))
        }
        self.secrets = secrets
    }

    func scrub(_ text: String) -> String {
        secrets.reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1, options: .caseInsensitive) }
    }

    func scrub(_ request: RequestRecord) -> RequestRecord {
        RequestRecord(method: request.method, url: scrub(request.url),
                      payload: request.payload.map { FormPair(name: $0.name, value: scrub($0.value)) })
    }
}

public final class Incident: @unchecked Sendable {
    public let directory: URL
    public var name: String { directory.lastPathComponent }
    private var meta: IncidentMeta
    private let redactor: Redactor
    private var counter = 0

    init(directory: URL, meta: IncidentMeta, redactor: Redactor) {
        self.directory = directory
        self.meta = meta
        self.redactor = redactor
        flush()
    }

    public func record(_ label: String, _ response: HTTPResponse, request: RequestRecord? = nil) {
        let n = counter
        counter += 1
        let base = String(format: "%02d-%@", n, label)
        try? Data(redactor.scrub(response.body).utf8).write(to: directory.appendingPathComponent(base + ".html"))
        let step = IncidentStep(
            n: n, label: label, url: redactor.scrub(response.url.absoluteString), status: response.status,
            redirects: response.redirects.map { Redirect(code: $0.code, from: redactor.scrub($0.from), to: redactor.scrub($0.to)) },
            headers: response.headers.mapValues { redactor.scrub($0) },
            request: request.map { redactor.scrub($0) })
        try? JSONCoding.encoder().encode(step).write(to: directory.appendingPathComponent(base + ".json"))
        meta.steps.append(step)
        flush()
    }

    public func note(_ text: String) {
        meta.notes.append(redactor.scrub(text))
        flush()
    }

    public func setContext(host: String, profile: String) {
        meta.host = host
        meta.profile = profile
        flush()
    }

    public func setCandidates(_ candidates: [FormCandidate]) {
        meta.candidates = candidates
        flush()
    }

    public func finish(verdict: String, reason: String?) {
        meta.verdict = verdict
        meta.reason = reason.map { redactor.scrub($0) }
        meta.finished = Date()
        flush()
    }

    private func flush() {
        try? JSONCoding.encoder().encode(meta).write(to: directory.appendingPathComponent("meta.json"), options: .atomic)
    }
}

public struct IncidentRecorder: Sendable {
    public let directory: URL
    public let keep: Int

    public init(directory: URL, keep: Int) {
        self.directory = directory
        self.keep = keep
    }

    /// La purge précède l'ouverture : l'incident en cours n'est jamais évincé.
    public func open(host: String, redacting identity: Identity?, now: Date = Date()) throws -> Incident {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        prune(keeping: max(0, keep - 1))
        let safeHost = String(host.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" ? Character($0) : "_"
        })
        let base = "\(Self.stamp(now))-\(safeHost)"
        var url = directory.appendingPathComponent(base, isDirectory: true)
        var k = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base)-\(k)", isDirectory: true)
            k += 1
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return Incident(directory: url, meta: IncidentMeta(started: now, host: host, verdict: "en cours"),
                        redactor: Redactor(identity: identity))
    }

    public func list() -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    public func prune(keeping n: Int) {
        for old in list().dropFirst(n) { try? FileManager.default.removeItem(at: old) }
    }

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }
}
