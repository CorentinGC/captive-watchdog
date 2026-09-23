import Foundation

/// `profile learn` : squelette de profil depuis une page capturée.
/// `profile test` : payload qui serait envoyé, sans rien émettre.
public enum ProfileLearner {
    public struct Learned {
        public var profile: Profile
        public var report: String
    }

    static let placeholderEmail = "guest@example.com"
    static let placeholderURL = URL(string: "http://portal.invalid/")!

    public static func learn(html: String, pageURL: URL?) -> Learned {
        let page = HTMLScanner.scan(html)
        let host = pageURL.map { LoginSession.portalHost(page, pageURL: $0) }
            ?? page.baseHref.flatMap { URL(string: $0)?.host?.lowercased() }
        let match = host.map { Profile.Match(portalHost: hostPattern($0), ssid: nil) }
        var notes: [String] = []
        if host == nil { notes.append("hôte inconnu : relancez avec --url ou complétez match.portalHost") }

        guard let picked = FormFiller.pickLoginForm(page, profile: .generic) else {
            notes.append("aucun formulaire exploitable : profil minimal")
            return Learned(profile: Profile(id: slug(host), name: host ?? "Nouveau portail", match: match, form: nil, chain: nil),
                           report: notes.joined(separator: "\n"))
        }
        let filled = FormFiller.fill(picked.form, page: page, pageURL: pageURL ?? placeholderURL,
                                     identity: Identity(email: placeholderEmail), profile: .generic)
        let email = filled.payload.first { $0.value == placeholderEmail }?.name
        let boxes = picked.form.fields.filter { $0.type == "checkbox" }.compactMap(\.name)
        let checked = boxes.filter { name in filled.payload.contains { $0.name == name } }
        let skipped = boxes.filter { !checked.contains($0) }
        let action = picked.form.action.flatMap { raw -> String? in
            let path = raw.split(separator: "?").first.map(String.init) ?? raw
            let last = (path as NSString).lastPathComponent
            return last.isEmpty || last == "/" ? nil : NSRegularExpression.escapedPattern(for: last)
        }
        let form = Profile.FormRules(
            action: action,
            fields: email.map { Profile.FormRules.Fields(email: $0, password: nil) },
            checkboxes: boxes.isEmpty ? nil : Profile.FormRules.Checkboxes(check: checked.isEmpty ? nil : checked,
                                                                           skip: skipped.isEmpty ? nil : skipped),
            submit: FormFiller.chooseSubmit(picked.form, preferred: nil)?.name)
        let profile = Profile(id: slug(host), name: host ?? "Nouveau portail", match: match, form: form,
                              chain: Profile.ChainRules(maxHops: 4, expectHosts: nil))
        notes.append("formulaire retenu : \(picked.form.action ?? "(sans action)") (score \(FormFiller.score(picked.form)))")
        notes.append("payload : " + filled.payload.map { "\($0.name)=\($0.value == placeholderEmail ? "<email>" : $0.value)" }
            .joined(separator: "&"))
        return Learned(profile: profile, report: notes.joined(separator: "\n"))
    }

    public static func dryRun(html: String, pageURL: URL?, profiles: ProfileStore, identity: Identity,
                              skipCheckbox: String) -> String {
        let page = HTMLScanner.scan(html)
        let url = pageURL ?? placeholderURL
        let host = LoginSession.portalHost(page, pageURL: url)
        let profile = profiles.resolve(portalHost: host, ssid: nil)
        var lines = ["hôte : \(host)", "profil : \(profile.id)"]
        guard let picked = FormFiller.pickLoginForm(page, profile: profile) else {
            return (lines + ["aucun formulaire exploitable"]).joined(separator: "\n")
        }
        let filled = FormFiller.fill(picked.form, page: page, pageURL: url, identity: identity,
                                     profile: profile, skipCheckbox: skipCheckbox)
        lines.append("\(filled.method.uppercased()) \(filled.actionURL.absoluteString)")
        lines += filled.payload.map { "  \($0.name) = \($0.value == identity.email ? "<email>" : $0.value)" }
        lines += filled.notes.map { "  · \($0)" }
        if FormFiller.isAutoForm(picked.form) { lines.append("  (formulaire auto-soumis : rejoué tel quel)") }
        return lines.joined(separator: "\n")
    }

    static func hostPattern(_ host: String) -> String {
        "^" + NSRegularExpression.escapedPattern(for: host) + "$"
    }

    static func slug(_ host: String?) -> String {
        guard let host else { return "nouveau-portail" }
        let chars = host.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(chars).split(separator: "-").joined(separator: "-")
    }
}
