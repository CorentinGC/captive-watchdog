import CaptiveKit
import SwiftUI

struct HistoryView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Table(model.history) {
            TableColumn("Début") { (row: HistoryRow) in Text(Format.timestamp(row.event.start)) }
            TableColumn("Réseau") { (row: HistoryRow) in Text(row.event.network) }
            TableColumn("Profil") { (row: HistoryRow) in Text(row.event.profile) }
            TableColumn("Durée") { (row: HistoryRow) in Text(Format.duration(row.event.duration)) }
            TableColumn("Résultat") { (row: HistoryRow) in
                Text(row.event.verdict == .success ? "OK" : "Échec")
                    .foregroundColor(row.event.verdict == .success ? .green : .red)
            }
            TableColumn("Tentatives") { (row: HistoryRow) in Text("\(row.event.attempts)") }
            TableColumn("Détail") { (row: HistoryRow) in Text(row.event.reason ?? "") }
        }
        .overlay {
            if model.history.isEmpty {
                Text("Aucune tentative enregistrée.").foregroundColor(.secondary)
            }
        }
        .toolbar {
            Button("Actualiser") { model.loadHistory() }
        }
        .onAppear { model.loadHistory() }
    }
}
