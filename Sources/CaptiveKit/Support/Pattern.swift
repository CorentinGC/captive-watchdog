import Foundation

/// Regex insensibles à la casse, utilisées par les profils et l'heuristique.
enum Pattern {
    static func matches(_ pattern: String, _ s: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    static func isValid(_ pattern: String) -> Bool {
        (try? NSRegularExpression(pattern: pattern)) != nil
    }
}
