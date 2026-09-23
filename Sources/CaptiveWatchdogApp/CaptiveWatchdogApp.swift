import CaptiveKit
import SwiftUI

@main
struct CaptiveWatchdogApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: model.snapshot.symbol)
        }
        Window("Historique", id: "history") {
            HistoryView(model: model)
        }
        .defaultSize(width: 820, height: 420)
        Window("Profils", id: "profiles") {
            ProfilesView(paths: model.paths)
        }
        .defaultSize(width: 920, height: 580)
        Window("E-mail", id: "setup") {
            SetupView(model: model)
        }
        .windowResizability(.contentSize)
    }
}
