import Foundation

/// Profils livrés avec l'application. Littéraux JSON plutôt que ressources :
/// un binaire installé seul (Homebrew) n'emporte pas de bundle.
public enum BuiltinProfiles {
    public static let all: [Profile] = sources.map {
        try! JSONDecoder().decode(Profile.self, from: Data($0.utf8))
    }

    static let sources = [generic, bnbHotels]

    static let generic = #"{ "id": "generic", "name": "Générique" }"#

    static let bnbHotels = #"""
    {
      "id": "bnb-hotels",
      "name": "B&B Hotels (Wifirst)",
      "match": { "portalHost": "(^|\\.)moveon-hotelbb\\.com$", "ssid": "^(BB|B&B)" },
      "form": {
        "action": "wifi-access\\.php",
        "fields": { "email": "email" },
        "checkboxes": { "check": ["chartConsent"], "skip": ["optinEmail"] },
        "submit": "connect"
      },
      "chain": { "maxHops": 4, "expectHosts": ["redirect-wifi.moveon-hotelbb.com"] }
    }
    """#
}
