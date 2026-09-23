import AppKit
import CaptiveKit
import SwiftUI

struct HistoryRow: Identifiable {
    let id: Int
    let event: HistoryEvent
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot: StatusSnapshot
    @Published private(set) var mode: EngineMode = .stopped
    @Published private(set) var history: [HistoryRow] = []
    let paths: Paths
    private let host: EngineHost
    private let store: StateStore
    private var timer: Timer?

    init(paths: Paths = .standard()) {
        self.paths = paths
        store = StateStore(paths: paths)
        host = EngineHost.live(paths: paths, logger: Logger(url: paths.log), notifier: OSAScriptNotifier())
        snapshot = StatusSnapshot.make(state: WatchdogState(), mode: .stopped)
        host.start()
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    var canReconnect: Bool { mode == .hosting || mode.isObserving }

    func tick() {
        mode = host.refresh()
        snapshot = StatusSnapshot.make(state: store.load(), mode: mode)
    }

    func loadHistory() {
        history = store.history(limit: 500).reversed().enumerated().map { HistoryRow(id: $0.offset, event: $0.element) }
    }

    func reconnect() {
        host.reconnect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.tick() }
    }

    func toggleSuspend() {
        if mode == .stopped { host.start() } else { host.stop() }
        tick()
    }

    func setEmail(_ email: String) throws {
        try host.setEmail(email)
        tick()
    }

    func openLog() {
        if !FileManager.default.fileExists(atPath: paths.log.path) {
            try? paths.ensure()
            FileManager.default.createFile(atPath: paths.log.path, contents: nil)
        }
        NSWorkspace.shared.open(paths.log)
    }

    func revealLastIncident() {
        if let name = store.load().lastIncident {
            NSWorkspace.shared.activateFileViewerSelecting([paths.incidents.appendingPathComponent(name)])
        } else {
            NSWorkspace.shared.open(paths.incidents)
        }
    }

    func openDataFolder() {
        try? paths.ensure()
        NSWorkspace.shared.open(paths.support)
    }

    func quit() {
        host.stop()
        NSApp.terminate(nil)
    }
}
