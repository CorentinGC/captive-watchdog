import Foundation

/// Rôle de l'app vis-à-vis du moteur (spec §4 : un seul moteur actif).
public enum EngineMode: Equatable, Sendable {
    /// L'app tient le verrou et fait tourner le moteur.
    case hosting
    /// Une autre instance (démon CLI) tient le verrou : l'app affiche son état.
    case observing(pid_t)
    /// Aucune adresse e-mail configurée : le moteur ne démarre pas.
    case needsEmail
    /// Surveillance suspendue par l'utilisateur.
    case stopped
    /// config.json existe mais ne se lit pas : le moteur ne démarre pas.
    case configError(String)

    public var isObserving: Bool {
        if case .observing = self { return true }
        return false
    }
}

/// Ce que le menu affiche, calculé depuis state.json : aucune logique dans les vues.
/// Symboles « bouclier » : un glyphe Wi-Fi se confondrait avec celui du système.
public struct StatusSnapshot: Equatable, Sendable {
    public var symbol: String
    public var headline: String
    public var lastRenew: String
    public var lastRenewDetail: String?
    public var lastCheck: String?
    public var failure: String?
    public var engine: String
    public var lastIncident: String?

    public static func make(state: WatchdogState, mode: EngineMode, now: Date = Date()) -> StatusSnapshot {
        var symbol: String
        let headline: String
        switch state.status {
        case .online: headline = "En ligne"; symbol = "checkmark.shield"
        case .captive: headline = "Portail captif"; symbol = "exclamationmark.shield"
        case .offline: headline = "Hors ligne"; symbol = "xmark.shield"
        case .unknown: headline = "État inconnu"; symbol = "shield"
        }
        if state.consecutiveFailures > 0 { symbol = "exclamationmark.shield" }

        let engine: String
        switch mode {
        case .hosting:
            engine = "Surveillance : active"
        case .observing(let pid):
            engine = "Surveillance : démon en ligne de commande (pid \(pid))"
        case .needsEmail:
            engine = "Surveillance : e-mail à configurer"
            symbol = "exclamationmark.shield"
        case .stopped:
            engine = "Surveillance : suspendue"
            symbol = "shield.slash"
        case .configError(let message):
            engine = "Surveillance : \(message)"
            symbol = "exclamationmark.shield"
        }

        let detail = state.lastRenew.map { date -> String in
            var text = Format.timestamp(date)
            if let network = state.lastRenewNetwork { text += " — \(network)" }
            if let duration = state.lastRenewDuration { text += " (\(Format.duration(duration)))" }
            return text
        }
        let failure = state.consecutiveFailures > 0
            ? "\(state.consecutiveFailures) échec(s) d'affilée" + (state.lastFailureReason.map { " — \($0)" } ?? "")
            : nil
        return StatusSnapshot(
            symbol: symbol,
            headline: headline,
            lastRenew: "Dernier renouvellement : " + (state.lastRenew.map { Format.ago($0, now: now) } ?? "jamais"),
            lastRenewDetail: detail,
            lastCheck: state.lastCheck.map { "Vérifié \(Format.ago($0, now: now))" },
            failure: failure,
            engine: engine,
            lastIncident: state.lastIncident)
    }
}
