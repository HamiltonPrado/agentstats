import AppKit
import SwiftUI

struct DisksView: View {
    @ObservedObject var store: DisksStore

    var body: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            HStack(spacing: DS.sm) {
                Text("Discos externos").font(DS.body.weight(.medium))
                Spacer(minLength: DS.sm)
                if store.volumes.count > 1 {
                    textLink("Ejetar todos") { Task { await store.ejectAll() } }
                        .disabled(!store.ejecting.isEmpty)
                }
            }
            if store.volumes.isEmpty { note("Nenhum disco para ejetar.") }
            ForEach(store.volumes) { v in row(v) }
            note("Discos externos, imagens de disco e volumes de rede. Se algum estiver em uso, mostra o que o está a usar.")
        }
        .cardStyle()
        .onAppear { store.start() }
    }

    @ViewBuilder private func row(_ v: Volume) -> some View {
        VStack(alignment: .leading, spacing: DS.xs) {
            HStack(spacing: DS.sm) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: v.path)).resizable().frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L(v.name)).font(DS.body).lineLimit(1).truncationMode(.middle)
                    Text(L(detail(v))).font(DS.meta.monospacedDigit()).foregroundStyle(Color.text3).lineLimit(1)
                }
                Spacer(minLength: DS.sm)
                if store.ejecting.contains(v.path) {
                    ProgressView().controlSize(.small)
                } else {
                    IconButton(systemName: "eject", help: String(localized: "Ejetar \(v.name)")) { Task { await store.eject(v) } }
                }
            }
            if let m = store.messages[v.path] { note(m, color: .attentionText) }
        }
        .padding(.vertical, DS.xs)
        .contextMenu {
            Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: v.path)]) }
        }
    }

    private func detail(_ v: Volume) -> String {
        var parts: [String] = []
        if let free = v.free, let total = v.total, total > 0 { parts.append(String(localized: "\(Fmt.disk(free)) livres de \(Fmt.disk(total))")) }
        if v.network { parts.append("rede") }
        return parts.isEmpty ? v.path : parts.joined(separator: " · ")
    }
}
