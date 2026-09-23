enum HTMLToken: Equatable {
    case start(name: String, attributes: [String: String])
    case end(name: String)
    case text(String)
}

/// Tokeniseur tolérant : ne lève jamais d'erreur, se comporte comme un
/// navigateur sur les cas utiles (attributs sans guillemets, `<` isolé,
/// contenu brut de script/style/title/textarea, balises non fermées).
struct HTMLTokenizer {
    static let rawTextElements: Set<String> = ["script", "style", "title", "textarea"]

    private let s: [Unicode.Scalar]
    private var i = 0
    private var rawTextEnd: String?

    init(_ html: String) { s = Array(html.unicodeScalars) }

    mutating func next() -> HTMLToken? {
        if let name = rawTextEnd {
            rawTextEnd = nil
            return rawText(until: name)
        }
        guard i < s.count else { return nil }
        if s[i] == "<", let token = tag() { return token }
        let start = i
        i += 1 // un « < » qui n'ouvre pas de balise est du texte
        while i < s.count, s[i] != "<" { i += 1 }
        return .text(string(start, i))
    }

    private mutating func tag() -> HTMLToken? {
        let n = i + 1
        guard n < s.count else { return nil }
        if s[n] == "!" {
            if matches("<!--", at: i) {
                i = find("-->", from: i + 4).map { $0 + 3 } ?? s.count
            } else {
                skipPastClosingBracket(from: n)
            }
            return .text("")
        }
        if s[n] == "?" {
            skipPastClosingBracket(from: n)
            return .text("")
        }
        if s[n] == "/" {
            let nameStart = n + 1
            guard nameStart < s.count, isLetter(s[nameStart]) else {
                skipPastClosingBracket(from: n)
                return .text("")
            }
            var j = nameStart
            while j < s.count, isNameChar(s[j]) { j += 1 }
            let name = string(nameStart, j).lowercased()
            skipPastClosingBracket(from: j)
            return .end(name: name)
        }
        guard isLetter(s[n]) else { return nil }
        var j = n
        while j < s.count, isNameChar(s[j]) { j += 1 }
        let name = string(n, j).lowercased()
        i = j
        var attributes: [String: String] = [:]
        while i < s.count {
            skipWhitespace()
            guard i < s.count else { break }
            if s[i] == ">" { i += 1; break }
            if s[i] == "/" { i += 1; continue }
            let nameStart = i
            while i < s.count, !isWhitespace(s[i]), s[i] != "=", s[i] != ">",
                  !(s[i] == "/" && i + 1 < s.count && s[i + 1] == ">") {
                i += 1
            }
            if i == nameStart { i += 1; continue }
            let attributeName = string(nameStart, i).lowercased()
            skipWhitespace()
            var value = ""
            if i < s.count, s[i] == "=" {
                i += 1
                skipWhitespace()
                if i < s.count, s[i] == "\"" || s[i] == "'" {
                    let quote = s[i]
                    let valueStart = i + 1
                    var k = valueStart
                    while k < s.count, s[k] != quote { k += 1 }
                    value = string(valueStart, k)
                    i = min(k + 1, s.count)
                } else {
                    let valueStart = i
                    while i < s.count, !isWhitespace(s[i]), s[i] != ">" { i += 1 }
                    value = string(valueStart, i)
                }
            }
            if attributes[attributeName] == nil {
                attributes[attributeName] = HTMLEntities.decode(value)
            }
        }
        if Self.rawTextElements.contains(name) { rawTextEnd = name }
        return .start(name: name, attributes: attributes)
    }

    private mutating func rawText(until name: String) -> HTMLToken {
        let start = i
        let closing = Array("</\(name)".unicodeScalars)
        var j = i
        while j < s.count, !(s[j] == "<" && matches(closing, at: j)) { j += 1 }
        i = j
        let raw = string(start, j)
        return .text(name == "title" || name == "textarea" ? HTMLEntities.decode(raw) : raw)
    }

    private mutating func skipPastClosingBracket(from j: Int) {
        i = find(">", from: j).map { $0 + 1 } ?? s.count
    }

    private mutating func skipWhitespace() {
        while i < s.count, isWhitespace(s[i]) { i += 1 }
    }

    private func matches(_ pattern: String, at j: Int) -> Bool {
        matches(Array(pattern.unicodeScalars), at: j)
    }

    private func matches(_ pattern: [Unicode.Scalar], at j: Int) -> Bool {
        guard j + pattern.count <= s.count else { return false }
        for k in 0..<pattern.count where lower(s[j + k]) != lower(pattern[k]) { return false }
        return true
    }

    private func find(_ pattern: String, from j: Int) -> Int? {
        let p = Array(pattern.unicodeScalars)
        var k = j
        while k + p.count <= s.count {
            if matches(p, at: k) { return k }
            k += 1
        }
        return nil
    }

    private func lower(_ c: Unicode.Scalar) -> Unicode.Scalar {
        (65...90).contains(c.value) ? Unicode.Scalar(c.value + 32)! : c
    }

    private func isWhitespace(_ c: Unicode.Scalar) -> Bool {
        c == " " || c == "\n" || c == "\t" || c == "\r" || c == "\u{0C}"
    }

    private func isLetter(_ c: Unicode.Scalar) -> Bool {
        (97...122).contains(c.value | 0x20)
    }

    private func isNameChar(_ c: Unicode.Scalar) -> Bool {
        isLetter(c) || (48...57).contains(c.value) || c == "-" || c == ":"
    }

    private func string(_ a: Int, _ b: Int) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: s[a..<b])
        return String(view)
    }
}
