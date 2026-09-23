import AppKit
import CaptiveKit
import SwiftUI

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let s = model.snapshot
        Text(s.headline)
        Text(s.lastRenew)
        if let detail = s.lastRenewDetail { Text(detail) }
        if let check = s.lastCheck { Text(check) }
        if let failure = s.failure { Text(failure) }
        Text(s.engine)
        Divider()
        Button("Reconnecter maintenant") { model.reconnect() }
            .keyboardShortcut("r")
            .disabled(!model.canReconnect)
        Button(model.mode == .needsEmail ? "Configurer l'e-mail…" : "Modifier l'e-mail…") { show("setup") }
        Divider()
        Button("Historique…") { show("history") }
            .keyboardShortcut("h")
        Button("Profils…") { show("profiles") }
            .keyboardShortcut("p")
        Button("Ouvrir le journal") { model.openLog() }
            .keyboardShortcut("l")
        Button("Révéler le dernier incident") { model.revealLastIncident() }
            .disabled(s.lastIncident == nil)
        Button("Ouvrir le dossier des données") { model.openDataFolder() }
        Divider()
        Button(model.mode == .stopped ? "Reprendre la surveillance" : "Suspendre la surveillance") { model.toggleSuspend() }
            .disabled(model.mode.isObserving)
        Button("Quitter") { model.quit() }
            .keyboardShortcut("q")
    }

    private func show(_ id: String) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: id)
    }
}
