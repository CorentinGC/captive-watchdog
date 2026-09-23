enum HTMLEntities {
    static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "eacute": "é", "egrave": "è", "ecirc": "ê", "euml": "ë", "agrave": "à", "acirc": "â",
        "auml": "ä", "icirc": "î", "iuml": "ï", "ocirc": "ô", "ouml": "ö", "ugrave": "ù",
        "ucirc": "û", "uuml": "ü", "ccedil": "ç", "Eacute": "É", "Egrave": "È", "Ecirc": "Ê",
        "Agrave": "À", "Ccedil": "Ç", "oelig": "œ", "laquo": "«", "raquo": "»", "rsquo": "’",
        "lsquo": "‘", "ldquo": "“", "rdquo": "”", "hellip": "…", "euro": "€", "copy": "©",
        "reg": "®", "ndash": "–", "mdash": "—", "szlig": "ß", "ntilde": "ñ", "aacute": "á",
        "iacute": "í", "oacute": "ó", "uacute": "ú",
    ]

    static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].prefix(12).firstIndex(of: ";"),
               let replacement = resolve(String(s[s.index(after: i)..<semi])) {
                out += replacement
                i = s.index(after: semi)
                continue
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }

    static func resolve(_ name: String) -> String? {
        if name.hasPrefix("#x") || name.hasPrefix("#X") {
            return UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        if name.hasPrefix("#") {
            return UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        return named[name]
    }
}
