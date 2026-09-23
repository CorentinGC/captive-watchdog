import Foundation

public struct HTMLField: Equatable, Sendable {
    public var tag: String
    public var type: String
    public var name: String?
    public var value: String?
    public var id: String?
    public var placeholder: String?
    public var checked: Bool
    public var required: Bool
    public var options: [String]
    /// Attribut `form="…"` : rattache le champ à un formulaire par son id.
    public var formOwner: String?
    /// Texte du <label> associé (for= ou englobant), espaces normalisés.
    public var label: String?

    init(tag: String, type: String, attributes a: [String: String]) {
        self.tag = tag
        self.type = type
        name = a["name"]
        value = a["value"]
        id = a["id"]
        placeholder = a["placeholder"]
        checked = a["checked"] != nil
        required = a["required"] != nil
        options = []
        formOwner = a["form"]
    }
}

public struct HTMLForm: Equatable, Sendable {
    public var action: String?
    public var method: String
    public var id: String?
    public var name: String?
    public var cssClass: String?
    public var fields: [HTMLField]
}

public struct ScannedPage: Equatable, Sendable {
    public var title: String?
    public var baseHref: String?
    public var metaRefresh: String?
    public var forms: [HTMLForm]

    public init(title: String? = nil, baseHref: String? = nil, metaRefresh: String? = nil, forms: [HTMLForm] = []) {
        self.title = title
        self.baseHref = baseHref
        self.metaRefresh = metaRefresh
        self.forms = forms
    }
}

public enum HTMLScanner {
    public static func scan(_ html: String) -> ScannedPage {
        var tokenizer = HTMLTokenizer(html)
        var page = ScannedPage()
        var form: HTMLForm?
        var detached: [(owner: String, field: HTMLField)] = []
        var select: HTMLField?
        var selected: String?
        var optionPending = false
        var optionSelected = false
        var textarea: HTMLField?
        var rawOwner: String?
        // <label> : texte accumulé, cible for=, et index du premier champ englobé.
        var label: (target: String?, text: String, start: Int?)?
        var labelsByID: [String: String] = [:]

        func add(_ field: HTMLField) {
            if let owner = field.formOwner {
                detached.append((owner, field))
            } else {
                form?.fields.append(field)
            }
        }

        func closeSelect() {
            guard var field = select else { return }
            field.value = selected ?? field.options.first
            add(field)
            select = nil
        }

        while let token = tokenizer.next() {
            switch token {
            case let .start(name, a):
                switch name {
                case "form":
                    // Comme un navigateur : un <form> imbriqué est ignoré.
                    if form == nil {
                        form = HTMLForm(action: a["action"], method: (a["method"] ?? "get").lowercased(),
                                        id: a["id"], name: a["name"], cssClass: a["class"], fields: [])
                    }
                case "input":
                    add(HTMLField(tag: "input", type: (a["type"] ?? "text").lowercased(), attributes: a))
                case "button":
                    add(HTMLField(tag: "button", type: (a["type"] ?? "submit").lowercased(), attributes: a))
                case "select":
                    closeSelect()
                    select = HTMLField(tag: "select", type: "select", attributes: a)
                    selected = nil
                case "option":
                    guard select != nil else { break }
                    optionPending = false
                    if let value = a["value"] {
                        select?.options.append(value)
                        if a["selected"] != nil { selected = value }
                    } else {
                        optionPending = true
                        optionSelected = a["selected"] != nil
                    }
                case "textarea":
                    textarea = HTMLField(tag: "textarea", type: "textarea", attributes: a)
                    rawOwner = "textarea"
                case "title":
                    rawOwner = "title"
                case "label":
                    label = (a["for"], "", form?.fields.count)
                case "base":
                    if page.baseHref == nil, let href = a["href"], !href.isEmpty { page.baseHref = href }
                case "meta":
                    if page.metaRefresh == nil, a["http-equiv"]?.lowercased() == "refresh", let content = a["content"] {
                        page.metaRefresh = refreshURL(content)
                    }
                default:
                    break
                }
            case let .end(name):
                switch name {
                case "form":
                    if let f = form { page.forms.append(f) }
                    form = nil
                case "select":
                    closeSelect()
                case "label":
                    guard let open = label else { break }
                    label = nil
                    let text = open.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    guard !text.isEmpty else { break }
                    if let target = open.target, !target.isEmpty {
                        if labelsByID[target] == nil { labelsByID[target] = text }
                    } else if let start = open.start, let count = form?.fields.count, start < count {
                        for k in start..<count where form?.fields[k].label == nil { form?.fields[k].label = text }
                    }
                default:
                    break
                }
            case let .text(text):
                if rawOwner == nil, label != nil { label?.text += HTMLEntities.decode(text) }
                if let owner = rawOwner {
                    rawOwner = nil
                    if owner == "title", page.title == nil {
                        page.title = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    } else if owner == "textarea", var field = textarea {
                        field.value = text
                        add(field)
                        textarea = nil
                    }
                } else if optionPending {
                    let value = HTMLEntities.decode(text).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty {
                        select?.options.append(value)
                        if optionSelected { selected = value }
                        optionPending = false
                    }
                }
            }
        }
        closeSelect()
        if let f = form { page.forms.append(f) }
        for (owner, field) in detached {
            if let k = page.forms.firstIndex(where: { $0.id == owner }) {
                page.forms[k].fields.append(field)
            }
        }
        for f in page.forms.indices {
            for k in page.forms[f].fields.indices where page.forms[f].fields[k].label == nil {
                if let id = page.forms[f].fields[k].id, let text = labelsByID[id] { page.forms[f].fields[k].label = text }
            }
        }
        return page
    }

    /// `0; url='next.php'` → `next.php` ; un rafraîchissement sans URL → nil.
    static func refreshURL(_ content: String) -> String? {
        guard let r = content.range(of: "url", options: .caseInsensitive) else { return nil }
        var rest = content[r.upperBound...].drop(while: { $0 == " " })
        guard rest.first == "=" else { return nil }
        rest = rest.dropFirst().drop(while: { $0 == " " })
        let url = rest.trimmingCharacters(in: CharacterSet(charactersIn: "'\" "))
        return url.isEmpty ? nil : url
    }
}
