import Foundation

public enum ConfigError: Error, Equatable, CustomStringConvertible {
    case unknownKey(String)
    case invalidValue(String, String)

    public var description: String {
        switch self {
        case .unknownKey(let key): return "clé inconnue « \(key) » (clés : \(Config.keys.joined(separator: ", ")))"
        case .invalidValue(let key, let value): return "valeur invalide pour \(key) : « \(value) »"
        }
    }
}

public struct Config: Codable, Equatable, Sendable {
    public var email = ""
    public var password = ""
    public var interval: Double = 20
    public var retries = 3
    public var retryDelay: Double = 4
    public var failBackoff: Double = 300
    /// Désactivé par défaut : les portails captifs servent souvent des
    /// certificats invalides, et seul l'e-mail transite.
    public var verifyTLS = false
    public var notify = true
    public var keepIncidents = 10
    public var maxChainHops = 4
    public var skipCheckbox = FormFiller.defaultSkipCheckbox
    public var probeURL = Prober.defaultURL.absoluteString

    public static let keys = ["email", "password", "interval", "retries", "retryDelay", "failBackoff",
                              "verifyTLS", "notify", "keepIncidents", "maxChainHops", "skipCheckbox", "probeURL"]

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? d.email
        password = try c.decodeIfPresent(String.self, forKey: .password) ?? d.password
        interval = try c.decodeIfPresent(Double.self, forKey: .interval) ?? d.interval
        retries = try c.decodeIfPresent(Int.self, forKey: .retries) ?? d.retries
        retryDelay = try c.decodeIfPresent(Double.self, forKey: .retryDelay) ?? d.retryDelay
        failBackoff = try c.decodeIfPresent(Double.self, forKey: .failBackoff) ?? d.failBackoff
        verifyTLS = try c.decodeIfPresent(Bool.self, forKey: .verifyTLS) ?? d.verifyTLS
        notify = try c.decodeIfPresent(Bool.self, forKey: .notify) ?? d.notify
        keepIncidents = try c.decodeIfPresent(Int.self, forKey: .keepIncidents) ?? d.keepIncidents
        maxChainHops = try c.decodeIfPresent(Int.self, forKey: .maxChainHops) ?? d.maxChainHops
        skipCheckbox = try c.decodeIfPresent(String.self, forKey: .skipCheckbox) ?? d.skipCheckbox
        probeURL = try c.decodeIfPresent(String.self, forKey: .probeURL) ?? d.probeURL
        sanitize()
    }

    /// config.json peut être édité à la main et il est relu à chaque cycle :
    /// une valeur dangereuse (boucle serrée, filtre marketing inopérant) est
    /// ramenée à une valeur sûre plutôt que suivie.
    mutating func sanitize() {
        interval = max(5, interval)
        retries = max(1, retries)
        retryDelay = max(1, retryDelay)
        failBackoff = max(30, failBackoff)
        keepIncidents = max(1, keepIncidents)
        maxChainHops = min(20, max(0, maxChainHops))
        if !Pattern.isValid(skipCheckbox) { skipCheckbox = FormFiller.defaultSkipCheckbox }
    }

    public static func load(from url: URL) throws -> Config {
        guard FileManager.default.fileExists(atPath: url.path) else { return Config() }
        return try JSONCoding.decoder().decode(Config.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONCoding.encoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public mutating func set(_ key: String, _ raw: String) throws {
        func number() throws -> Double {
            guard let v = Double(raw), v >= 0 else { throw ConfigError.invalidValue(key, raw) }
            return v
        }
        func integer() throws -> Int {
            guard let v = Int(raw), v >= 0 else { throw ConfigError.invalidValue(key, raw) }
            return v
        }
        func flag() throws -> Bool {
            switch raw.lowercased() {
            case "1", "true", "yes", "oui", "on": return true
            case "0", "false", "no", "non", "off": return false
            default: throw ConfigError.invalidValue(key, raw)
            }
        }
        switch key {
        case "email": email = raw
        case "password": password = raw
        case "interval": interval = try max(5, number())
        case "retries": retries = try max(1, integer())
        case "retryDelay": retryDelay = try max(1, number())
        case "failBackoff": failBackoff = try max(30, number())
        case "verifyTLS": verifyTLS = try flag()
        case "notify": notify = try flag()
        case "keepIncidents": keepIncidents = try max(1, integer())
        case "maxChainHops": maxChainHops = try min(20, integer())
        case "skipCheckbox":
            guard Pattern.isValid(raw) else { throw ConfigError.invalidValue(key, raw) }
            skipCheckbox = raw
        case "probeURL":
            guard URL(string: raw)?.scheme != nil else { throw ConfigError.invalidValue(key, raw) }
            probeURL = raw
        default:
            throw ConfigError.unknownKey(key)
        }
    }
}
