import AppKit
import CaptiveKit
import SwiftUI
import UniformTypeIdentifiers

struct ProfilesView: View {
    let paths: Paths
    let library: ProfileLibrary
    @State private var entries: [ProfileEntry] = []
    @State private var loadErrors: [ProfileLoadError] = []
    @State private var selection: String?
    @State private var text = ""
    @State private var message: String?
    @State private var pageURL = ""
    @State private var report = ""

    init(paths: Paths) {
        self.paths = paths
        library = ProfileLibrary(directory: paths.profiles)
    }

    private var selected: ProfileEntry? { entries.first { $0.id == selection } }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                List(entries, selection: $selection) { entry in
                    VStack(alignment: .leading) {
                        Text(entry.profile.name ?? entry.id)
                        Text("\(entry.id) · \(entry.originLabel)").font(.caption).foregroundColor(.secondary)
                    }
                    .tag(entry.id)
                }
                ForEach(loadErrors, id: \.file) { error in
                    Text("⚠︎ \(error.file) : \(error.message)").font(.caption).foregroundColor(.orange)
                }
                HStack {
                    Button("Nouveau") { newProfile() }
                    Button("Importer…") { importProfile() }
                }
            }
            .padding(8)
            .frame(minWidth: 240)

            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 240)
                if let message { Text(message).font(.callout) }
                HStack {
                    Button("Enregistrer") { save() }.keyboardShortcut("s")
                    Button("Supprimer") { delete() }.disabled(!(selected?.isEditable ?? false))
                    Button("Exporter…") { export() }.disabled(selected == nil)
                }
                Divider()
                HStack {
                    TextField("URL de la page testée (facultatif)", text: $pageURL)
                        .textFieldStyle(.roundedBorder)
                    Button("Tester sur une page…") { test() }
                }
                if !report.isEmpty {
                    ScrollView {
                        Text(report)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 140)
                }
            }
            .padding(8)
            .frame(minWidth: 460)
        }
        .onAppear(perform: reload)
        .onChange(of: selection) { _ in showSelection() }
    }

    private func reload() {
        (entries, loadErrors) = library.load()
    }

    private func showSelection() {
        report = ""
        guard let entry = selected else { return }
        text = entry.json
        message = entry.isEditable ? nil : "Profil intégré : l'enregistrer crée une copie utilisateur qui le remplace."
    }

    private func newProfile() {
        selection = nil
        text = ProfileLibrary.template
        message = "Nouveau profil : adaptez l'id et le motif d'hôte, puis enregistrez."
        report = ""
    }

    private func save() {
        do {
            let profile = try library.save(text)
            reload()
            selection = profile.id
            message = "Enregistré : « \(profile.id) », pris en compte au prochain cycle."
        } catch {
            message = "Erreur : \(error)"
        }
    }

    private func delete() {
        guard let entry = selected else { return }
        do {
            try library.delete(entry)
            reload()
            message = entry.origin == .override ? "Copie supprimée : le profil intégré s'applique de nouveau." : "Profil supprimé."
            if let restored = selected { text = restored.json } else { selection = nil; text = "" }
        } catch {
            message = "Erreur : \(error)"
        }
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let profile = try library.importFile(url)
            reload()
            selection = profile.id
            message = "Importé : « \(profile.id) »."
        } catch {
            message = "Import refusé : \(error)"
        }
    }

    private func export() {
        guard let entry = selected else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(entry.id).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try library.export(entry, to: url)
            message = "Exporté vers \(url.path)."
        } catch {
            message = "Export impossible : \(error)"
        }
    }

    private func test() {
        let profile: Profile
        do {
            profile = try ProfileLibrary.parse(text)
        } catch {
            message = "Profil invalide : \(error)"
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html, .plainText]
        panel.directoryURL = paths.incidents
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        let config = (try? Config.load(from: paths.config)) ?? Config()
        let identity = Identity(email: config.email.isEmpty ? "guest@example.com" : config.email, password: config.password)
        let trimmed = pageURL.trimmingCharacters(in: .whitespaces)
        report = ProfileLibrary.test(profile, html: HTTPClient.decodeBody(data, contentType: nil),
                                     pageURL: trimmed.isEmpty ? nil : URL(string: trimmed),
                                     identity: identity, skipCheckbox: config.skipCheckbox)
        message = "Test à blanc sur \(url.lastPathComponent) : rien n'a été envoyé."
    }
}
