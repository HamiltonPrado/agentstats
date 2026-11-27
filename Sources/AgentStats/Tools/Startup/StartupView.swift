import AppKit
import SwiftUI

struct StartupView: View {
    @ObservedObject var store: StartupStore

    var body: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            HStack(spacing: DS.sm) {
                Text("Arranca sozinho").font(DS.body.weight(.medium))
                Spacer(minLength: DS.sm)
                IconButton(systemName: "arrow.clockwise", help: "Atualizar") { Task { await store.refresh() } }
            }
            if !store.loaded {
                note("A ler…")
            } else if store.items.isEmpty {
                note("Nenhum serviço de terceiros arranca sozinho.")
            }
            ForEach(Array(store.items.enumerated()), id: \.element.id) { i, item in
                if i == 0 || store.items[i - 1].scope != item.scope {
                    Text(L(heading(item.scope))).font(DS.meta.weight(.medium)).foregroundStyle(Color.text2).padding(.top, DS.xs)
                }
                row(item)
            }
            if let m = store.message { note(m, color: .attentionText) }
            note("Os do Mac e de outros utilizadores só se gerem nas Definições do Sistema. Desligar é reversível.")
            textLink("Abrir Itens de início nas Definições…") { store.openLoginItems() }
        }
        .cardStyle()
        .task { await store.refresh() }
    }

    private func heading(_ scope: LaunchItem.Scope) -> String {
        switch scope {
        case .user: "Teus"
        case .agent: "Para todos os utilizadores"
        case .daemon: "Do sistema (em segundo plano)"
        }
    }

    @ViewBuilder private func row(_ item: LaunchItem) -> some View {
        VStack(alignment: .leading, spacing: DS.xs) {
            HStack(spacing: DS.sm) {
                StatusDot(item.running && !item.disabled ? .working : .idle)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L(item.title)).font(DS.body).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(item.disabled ? Color.text2 : Color.primary)
                    Text(L(detail(item))).font(DS.meta).foregroundStyle(Color.text3).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: DS.sm)
                if store.busy.contains(item.id) {
                    ProgressView().controlSize(.small)
                } else if item.canToggle {
                    textLink(item.disabled ? "Ligar" : "Desligar", color: item.disabled ? .accentColor : .text2) {
                        if item.disabled { Task { await store.set(item, enabled: true) } } else { store.confirming = item.id }
                    }
                }
            }
            if store.confirming == item.id {
                ConfirmBar(text: String(localized: "Desligar \(item.title)? Para agora e deixa de arrancar sozinho. Podes voltar a ligá-lo aqui."),
                           confirm: "Desligar", cancel: { store.confirming = nil },
                           action: { Task { await store.set(item, enabled: false) } })
            }
        }
        .padding(.vertical, 2)
        .help(L(item.program ?? item.label))
        .contextMenu {
            Button("Mostrar no Finder") { store.reveal(item) }
            Button("Copiar label") { ClipboardStore.shared.copy(item.label) }
        }
    }

    private func detail(_ item: LaunchItem) -> String {
        var parts: [String] = []
        if item.disabled { parts.append("desligado") } else if item.running { parts.append("a correr") }
        if item.keepAlive { parts.append("sempre ativo") } else if item.runAtLoad { parts.append("ao arrancar") }
        if item.appName != nil { parts.append(item.label) }
        return parts.map { L($0) }.joined(separator: " · ")
    }
}
