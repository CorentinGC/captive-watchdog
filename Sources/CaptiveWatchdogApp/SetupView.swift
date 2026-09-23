import CaptiveKit
import SwiftUI

struct SetupView: View {
    @ObservedObject var model: AppModel
    @State private var email = ""
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Adresse e-mail envoyée aux portails").font(.headline)
            Text("Elle est transmise à chaque portail captif rencontré : une adresse jetable convient.")
                .font(.callout)
                .foregroundColor(.secondary)
            TextField("vous@example.com", text: $email)
                .textFieldStyle(.roundedBorder)
                .frame(width: 340)
                .onSubmit(save)
            if let error { Text(error).font(.callout).foregroundColor(.red) }
            HStack {
                Spacer()
                Button("Enregistrer", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .onAppear { email = (try? Config.load(from: model.paths.config))?.email ?? "" }
    }

    private func save() {
        do {
            try model.setEmail(email)
            error = nil
            dismiss()
        } catch {
            self.error = "\(error)"
        }
    }
}
