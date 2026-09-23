import Foundation

public struct Identity: Equatable, Sendable {
    public var email: String
    public var password: String

    public init(email: String, password: String = "") {
        self.email = email
        self.password = password
    }
}

public struct FormPair: Codable, Equatable, Sendable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct FilledForm: Sendable {
    public var form: HTMLForm
    public var actionURL: URL
    public var method: String
    public var payload: [FormPair]
    public var notes: [String]
}

public struct FormCandidate: Codable, Equatable, Sendable {
    public var index: Int
    public var id: String?
    public var action: String?
    public var score: Int
}

/// Heuristique générique éprouvée en v1, pilotable par un profil.
public enum FormFiller {
    public static let defaultSkipCheckbox = "optin|newsletter|marketing|offre|promo|publicit|advert|subscribe|loyalty"
    static let emailHint = "e-?mail|courriel|adresse|user(name)?|login|identifiant|guest|client|nom"
    static let submitPrefer = "connect|log[-_ ]?in|continu|acce(s|d)|valider|entrer|start|submit"
    static let submitAvoid = "subscribe|join|adh[eé]r|register|inscri|sign[-_ ]?up|newsletter"
    static let skipFormHint = "search|recherche|newsletter"

    static func hint(_ f: HTMLField) -> String {
        [f.name, f.id, f.placeholder].compactMap { $0 }.joined(separator: " ")
    }

    static func isSubmit(_ f: HTMLField) -> Bool {
        (f.tag == "input" && (f.type == "submit" || f.type == "image")) || (f.tag == "button" && f.type == "submit")
    }

    static func isEmailish(_ f: HTMLField) -> Bool {
        f.type == "email" || (f.tag == "input" && f.type == "text" && Pattern.matches(emailHint, hint(f)))
    }

    public static func score(_ form: HTMLForm) -> Int {
        form.fields.reduce(0) { total, f in
            if isEmailish(f) { return total + 5 }
            switch f.type {
            case "checkbox": return total + 2
            case "hidden", "password": return total + 1
            default: return isSubmit(f) ? total + 2 : total
            }
        }
    }

    public static func pickLoginForm(_ page: ScannedPage, profile: Profile) -> (form: HTMLForm, candidates: [FormCandidate])? {
        let candidates = page.forms.enumerated().map {
            FormCandidate(index: $0.offset, id: $0.element.id, action: $0.element.action, score: score($0.element))
        }
        if let pattern = profile.form?.action,
           let k = page.forms.firstIndex(where: { Pattern.matches(pattern, $0.action ?? "") }) {
            return (page.forms[k], candidates)
        }
        let eligible = page.forms.indices.filter { k in
            let f = page.forms[k]
            let label = [f.id, f.name, f.cssClass, f.action].compactMap { $0 }.joined(separator: " ")
            return candidates[k].score > 0 && !Pattern.matches(skipFormHint, label)
        }
        guard let best = eligible.max(by: { candidates[$0].score < candidates[$1].score }) else { return nil }
        return (page.forms[best], candidates)
    }

    /// Formulaire sans saisie (champs cachés + boutons) : un rebond que le
    /// portail auto-soumet en JavaScript.
    public static func isAutoForm(_ form: HTMLForm) -> Bool {
        let data = form.fields.filter { !isSubmit($0) && $0.type != "button" && $0.type != "reset" }
        return !data.isEmpty && data.allSatisfy { $0.type == "hidden" }
    }

    public static func fill(_ form: HTMLForm, page: ScannedPage, pageURL: URL, identity: Identity,
                            profile: Profile, skipCheckbox: String = defaultSkipCheckbox) -> FilledForm {
        build(form, page: page, pageURL: pageURL, identity: identity, rules: profile.form, skipCheckbox: skipCheckbox)
    }

    /// Rejeu d'un rebond : valeurs telles quelles, rien n'est injecté.
    public static func replay(_ form: HTMLForm, page: ScannedPage, pageURL: URL) -> FilledForm {
        build(form, page: page, pageURL: pageURL, identity: nil, rules: nil, skipCheckbox: defaultSkipCheckbox)
    }

    static func build(_ form: HTMLForm, page: ScannedPage, pageURL: URL, identity: Identity?,
                      rules: Profile.FormRules?, skipCheckbox: String) -> FilledForm {
        var pairs: [FormPair] = []
        var notes: [String] = []
        let emailName: String? = identity == nil ? nil : (rules?.fields?.email
            ?? form.fields.first(where: isEmailish)?.name
            ?? form.fields.first(where: { $0.tag == "input" && $0.type == "text" && $0.name != nil })?.name)
        let passwordName = identity == nil ? nil : (rules?.fields?.password ?? form.fields.first { $0.type == "password" }?.name)
        let check = Set(rules?.checkboxes?.check ?? [])
        let skip = Set(rules?.checkboxes?.skip ?? [])
        var radios = Set<String>()
        var emailPlaced = false

        for f in form.fields {
            guard let name = f.name, !name.isEmpty, !isSubmit(f) else { continue }
            switch f.type {
            case "button", "reset", "file":
                continue
            case "checkbox":
                let tick: Bool
                if skip.contains(name) {
                    tick = false
                    notes.append("case « \(name) » laissée décochée (profil)")
                } else if check.contains(name) {
                    tick = true
                } else if identity == nil {
                    tick = f.checked
                } else if Pattern.matches(skipCheckbox, hint(f)) {
                    tick = false
                    notes.append("case « \(name) » laissée décochée (motif marketing)")
                } else {
                    tick = true
                }
                if tick {
                    pairs.append(FormPair(name: name, value: f.value ?? "on"))
                    notes.append("case « \(name) » cochée")
                }
            case "radio":
                guard radios.insert(name).inserted else { continue }
                let group = form.fields.filter { $0.type == "radio" && $0.name == name }
                let pick = group.first(where: \.checked) ?? group[0]
                pairs.append(FormPair(name: name, value: pick.value ?? "on"))
            case "password":
                pairs.append(FormPair(name: name, value: name == passwordName ? identity?.password ?? "" : f.value ?? ""))
            default:
                if let identity, name == emailName, f.type != "hidden", !emailPlaced {
                    pairs.append(FormPair(name: name, value: identity.email))
                    emailPlaced = true
                    notes.append("e-mail placé dans « \(name) »")
                } else {
                    pairs.append(FormPair(name: name, value: f.value ?? ""))
                }
            }
        }
        if identity != nil && !emailPlaced { notes.append("aucun champ e-mail trouvé") }
        if let submit = chooseSubmit(form, preferred: rules?.submit), let name = submit.name, !name.isEmpty {
            if submit.type == "image" {
                pairs += [FormPair(name: "\(name).x", value: "1"), FormPair(name: "\(name).y", value: "1")]
            } else {
                pairs.append(FormPair(name: name, value: submit.value ?? ""))
            }
            notes.append("bouton « \(name) » envoyé")
        }
        return FilledForm(form: form, actionURL: resolve(form.action, page: page, pageURL: pageURL),
                          method: form.method == "post" ? "post" : "get", payload: pairs, notes: notes)
    }

    /// Un navigateur n'envoie qu'un bouton : celui du profil, sinon le premier
    /// qui ressemble à « se connecter », en évitant inscription et newsletter.
    static func chooseSubmit(_ form: HTMLForm, preferred: String?) -> HTMLField? {
        let submits = form.fields.filter(isSubmit)
        if let preferred, let s = submits.first(where: { $0.name == preferred }) { return s }
        func label(_ f: HTMLField) -> String { [f.name, f.id, f.value].compactMap { $0 }.joined(separator: " ") }
        let acceptable = submits.filter { !Pattern.matches(submitAvoid, label($0)) }
        return acceptable.first { Pattern.matches(submitPrefer, label($0)) } ?? acceptable.first ?? submits.first
    }

    /// Action vide → URL du document (spec HTML) ; relative → contre <base href>.
    public static func resolve(_ target: String?, page: ScannedPage, pageURL: URL) -> URL {
        guard let target = target?.trimmingCharacters(in: .whitespacesAndNewlines), !target.isEmpty else { return pageURL }
        let base = page.baseHref.flatMap { URL(string: $0, relativeTo: pageURL)?.absoluteURL } ?? pageURL
        return URL(string: target, relativeTo: base)?.absoluteURL ?? base
    }

    static let formUnreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._* ")

    static func formEscape(_ s: String) -> String {
        (s.addingPercentEncoding(withAllowedCharacters: formUnreserved) ?? s).replacingOccurrences(of: " ", with: "+")
    }

    public static func encode(_ pairs: [FormPair]) -> Data {
        Data(pairs.map { "\(formEscape($0.name))=\(formEscape($0.value))" }.joined(separator: "&").utf8)
    }
}
