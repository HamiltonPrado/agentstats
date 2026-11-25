import SwiftUI

/// Um bloco de notas no painel. Fica num ficheiro só teu (0600), gravado pouco depois de parares de escrever.
@MainActor
final class QuickNotesStore: ObservableObject {
    static let shared = QuickNotesStore(file: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AgentStats/notes.json"))

    @Published var text: String { didSet { scheduleSave() } }
    private let file: URL?
    private var pending: Task<Void, Never>?
    private var demo = false

    struct Saved: Codable { var text: String }

    init(file: URL?) {
        self.file = file
        if let file, case .value(let saved) = PrivateFile.load(Saved.self, from: file) { text = saved.text } else { text = "" }
    }

    private func scheduleSave() {
        guard !demo else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        guard !demo, let file else { return }
        _ = PrivateFile.save(Saved(text: text), to: file, backup: true)
    }

    func loadDemo() {
        demo = true
        text = "Ligar ao contabilista\nRever o PR da loja antes das 18h"
    }
}

struct QuickNotesCard: View {
    @ObservedObject var store: QuickNotesStore

    var body: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            HStack {
                Text("Notas").font(DS.body.weight(.medium))
                Spacer()
                if !store.text.isEmpty {
                    textLink("Copiar") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(store.text, forType: .string)
                    }
                }
            }
            TextEditor(text: $store.text)
                .font(DS.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 90, maxHeight: 180)
                .padding(DS.xs)
                .background(RoundedRectangle(cornerRadius: DS.rSmall, style: .continuous).fill(DS.raised))
            note("Guardadas só neste Mac, enquanto escreves.")
        }
        .cardStyle()
        .onDisappear { store.saveNow() }
    }
}
