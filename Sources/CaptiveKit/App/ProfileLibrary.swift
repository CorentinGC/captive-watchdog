import Foundation

public struct ProfileEntry: Equatable, Identifiable, Sendable {
    public enum Origin: String, Sendable {
        case builtin, user, override
    }

    public var profile: Profile
    public var origin: Origin
    /// Fichier utilisateur ; nil pour un profil intégré.
    public var file: URL?
    /// Texte présenté dans l'éditeur (le fichier tel quel pour un profil utilisateur).
    public var json: String

    public var id: String { profile.id }
    public var isEditable: Bool { origin != .builtin }

    public var originLabel: String {
        switch origin {
        case .builtin: return "intégré"
        case .user: return "utilisateur"
        case .override: return "remplace l'intégré"
        }
    }
}

public enum ProfileLibraryError: Error, CustomStringConvertible {
    case notEditable(String)

    public var description: String {
        switch self {
        case .notEditable(let id): return "« \(id) » est un profil intégré : il ne peut pas être supprimé"
        }
    }
}

/// Profils vus par l'éditeur de l'app : les intégrés en lecture seule, les
/// fichiers utilisateur de `profiles/` modifiables. Même règle de surcharge
/// que `ProfileStore` : un fichier utilisateur remplace l'intégré de même id.
public struct ProfileLibrary: Sendable {
    public let directory: URL
    /// L'id devient un nom de fichier : pas de séparateur ni de chemin relatif.
    static let idPattern = "^[A-Za-z0-9][A-Za-z0-9._-]*$"

    public init(directory: URL) { self.directory = directory }

    public static let template = #"""
    {
      "id": "mon-portail",
      "name": "Mon portail",
      "match": { "portalHost": "(^|\\.)portail\\.example\\.com$" },
      "form": {
        "checkboxes": { "check": [], "skip": [] }
      },
      "chain": { "maxHops": 4 }
    }
    """#

    public func load() -> (entries: [ProfileEntry], errors: [ProfileLoadError]) {
        var user: [ProfileEntry] = []
        var errors: [ProfileLoadError] = []
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names.sorted() where name.hasSuffix(".json") {
            let url = directory.appendingPathComponent(name)
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                let profile = try Self.parse(text)
                if let k = user.firstIndex(where: { $0.id == profile.id }) {
                    errors.append(ProfileLoadError(file: user[k].file?.lastPathComponent ?? "?",
                                                   message: "id « \(profile.id) » en double, remplacé par \(name)"))
                    user.remove(at: k)
                }
                user.append(ProfileEntry(profile: profile, origin: .user, file: url, json: text))
            } catch {
                errors.append(ProfileLoadError(file: name, message: String(describing: error)))
            }
        }
        var entries: [ProfileEntry] = []
        for builtin in BuiltinProfiles.all {
            if var mine = user.first(where: { $0.id == builtin.id }) {
                mine.origin = .override
                entries.append(mine)
            } else {
                entries.append(ProfileEntry(profile: builtin, origin: .builtin, file: nil, json: Self.encode(builtin)))
            }
        }
        entries += user.filter { entry in !BuiltinProfiles.all.contains { $0.id == entry.id } }
        return (entries, errors)
    }

    public static func parse(_ text: String) throws -> Profile {
        let profile: Profile
        do {
            profile = try JSONDecoder().decode(Profile.self, from: Data(text.utf8))
        } catch let error as DecodingError {
            throw ProfileValidationError(description: describe(error))
        }
        guard Pattern.matches(idPattern, profile.id) else {
            throw ProfileValidationError(description: "id invalide « \(profile.id) » : lettres, chiffres, « . », « _ » et « - » uniquement")
        }
        try profile.validate()
        return profile
    }

    /// Valide puis écrit le texte tel quel ; un id déjà présent réécrit son fichier.
    @discardableResult
    public func save(_ text: String) throws -> Profile {
        let profile = try Self.parse(text)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = load().entries.first { $0.id == profile.id && $0.file != nil }?.file
        let url = existing ?? directory.appendingPathComponent("\(profile.id).json")
        let body = text.hasSuffix("\n") ? text : text + "\n"
        try Data(body.utf8).write(to: url, options: .atomic)
        return profile
    }

    public func delete(_ entry: ProfileEntry) throws {
        guard entry.isEditable, let file = entry.file else { throw ProfileLibraryError.notEditable(entry.id) }
        try FileManager.default.removeItem(at: file)
    }

    @discardableResult
    public func importFile(_ url: URL) throws -> Profile {
        try save(try String(contentsOf: url, encoding: .utf8))
    }

    public func export(_ entry: ProfileEntry, to url: URL) throws {
        try Data(entry.json.utf8).write(to: url, options: .atomic)
    }

    /// Test à blanc du profil en cours d'édition contre une page sauvegardée.
    public static func test(_ profile: Profile, html: String, pageURL: URL?, identity: Identity,
                            skipCheckbox: String) -> String {
        let store = ProfileStore(builtin: [.generic, profile], userDirectory: nil)
        var report = ProfileLearner.dryRun(html: html, pageURL: pageURL, profiles: store,
                                           identity: identity, skipCheckbox: skipCheckbox)
        let applied = report.split(separator: "\n").contains { $0 == "profil : \(profile.id)" }
        if !applied {
            report += "\n⚠︎ « \(profile.id) » ne correspond pas à cet hôte : c'est le profil générique qui s'appliquerait."
        }
        return report
    }

    static func encode(_ profile: Profile) -> String {
        guard let data = try? JSONCoding.encoder().encode(profile) else { return "{}" }
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    static func describe(_ error: DecodingError) -> String {
        switch error {
        case .dataCorrupted(let context):
            return "JSON invalide : \(context.debugDescription)"
        case .keyNotFound(let key, _):
            return "clé manquante : \(key.stringValue)"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return "type inattendu pour « \(path) »"
        @unknown default:
            return "JSON invalide : \(error)"
        }
    }
}
