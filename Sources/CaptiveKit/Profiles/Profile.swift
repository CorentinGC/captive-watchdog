import Foundation

/// Décrit comment un réseau dévie du comportement générique.
/// Toutes les clés sont optionnelles : ce qui manque est déduit.
public struct Profile: Codable, Equatable, Sendable {
    public var id: String
    public var name: String?
    public var match: Match?
    public var form: FormRules?
    public var chain: ChainRules?

    public struct Match: Codable, Equatable, Sendable {
        public var portalHost: String?
        public var ssid: String?
    }

    public struct FormRules: Codable, Equatable, Sendable {
        public var action: String?
        public var fields: Fields?
        public var checkboxes: Checkboxes?
        public var submit: String?

        public struct Fields: Codable, Equatable, Sendable {
            public var email: String?
            public var password: String?
        }

        public struct Checkboxes: Codable, Equatable, Sendable {
            public var check: [String]?
            public var skip: [String]?
        }
    }

    public struct ChainRules: Codable, Equatable, Sendable {
        public var maxHops: Int?
        public var expectHosts: [String]?
    }

    public static let generic = Profile(id: "generic", name: "Générique", match: nil, form: nil, chain: nil)
}

public struct ProfileValidationError: Error, CustomStringConvertible {
    public var description: String
}

extension Profile {
    /// nil : le profil ne s'applique pas. Sinon, nombre de critères satisfaits.
    /// Le SSID n'est évalué que s'il est lisible (macOS 26 le masque sans
    /// autorisation de Localisation).
    func specificity(portalHost: String, ssid: String?) -> Int? {
        guard let match else { return nil }
        var score = 0
        if let pattern = match.portalHost {
            guard Pattern.matches(pattern, portalHost) else { return nil }
            score += 1
        }
        if let pattern = match.ssid, let ssid {
            guard Pattern.matches(pattern, ssid) else { return nil }
            score += 1
        }
        return score > 0 ? score : nil
    }

    func validate() throws {
        guard !id.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ProfileValidationError(description: "id vide")
        }
        let patterns: [(String, String?)] = [
            ("match.portalHost", match?.portalHost),
            ("match.ssid", match?.ssid),
            ("form.action", form?.action),
        ]
        for (label, pattern) in patterns {
            if let pattern, !Pattern.isValid(pattern) {
                throw ProfileValidationError(description: "\(label) : regex invalide « \(pattern) »")
            }
        }
        if let hops = chain?.maxHops, !(0...20).contains(hops) {
            throw ProfileValidationError(description: "chain.maxHops hors de 0…20 : \(hops)")
        }
    }
}
