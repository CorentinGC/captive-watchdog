import Foundation

public struct ProfileLoadError: Equatable, Sendable {
    public var file: String
    public var message: String
}

public struct ProfileStore: Sendable {
    public private(set) var profiles: [Profile]
    public private(set) var errors: [ProfileLoadError]

    public init(builtin: [Profile] = BuiltinProfiles.all, userDirectory: URL?) {
        var byID: [String: Profile] = [:]
        var order: [String] = []
        func insert(_ p: Profile) {
            if byID[p.id] == nil { order.append(p.id) }
            byID[p.id] = p
        }
        builtin.forEach(insert)
        var errors: [ProfileLoadError] = []
        if let userDirectory {
            let (user, loadErrors) = Self.loadUserProfiles(from: userDirectory)
            user.forEach(insert)
            errors = loadErrors
        }
        profiles = order.compactMap { byID[$0] }
        self.errors = errors
    }

    public static func loadUserProfiles(from directory: URL) -> ([Profile], [ProfileLoadError]) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return ([], []) }
        var profiles: [Profile] = []
        var errors: [ProfileLoadError] = []
        for name in names.sorted() where name.hasSuffix(".json") {
            do {
                let data = try Data(contentsOf: directory.appendingPathComponent(name))
                let profile = try JSONDecoder().decode(Profile.self, from: data)
                try profile.validate()
                profiles.append(profile)
            } catch {
                errors.append(ProfileLoadError(file: name, message: String(describing: error)))
            }
        }
        return (profiles, errors)
    }

    /// Le profil le plus spécifique gagne ; à égalité, le premier chargé.
    /// Aucun ne correspond → le générique : c'est le cas nominal.
    public func resolve(portalHost: String, ssid: String?) -> Profile {
        var best: (profile: Profile, score: Int)?
        for profile in profiles {
            if let score = profile.specificity(portalHost: portalHost, ssid: ssid), score > (best?.score ?? 0) {
                best = (profile, score)
            }
        }
        return best?.profile ?? profiles.first { $0.id == "generic" } ?? .generic
    }
}
