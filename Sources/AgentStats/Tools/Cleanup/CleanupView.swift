import SwiftUI
import AppKit

struct CleanupView: View {
    @ObservedObject var store: CleanupStore

    var body: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            HStack(spacing: DS.sm) {
                Text("Caches conhecidas").font(DS.body.weight(.medium))
                Spacer(minLength: DS.sm)
                IconButton(systemName: "arrow.clockwise", help: "Procurar outra vez") { Task { await store.refresh() } }
                    .disabled(store.busy)
            }
            if !store.loaded {
                note("A medir e a ver o que está em uso…")
            } else if store.entries.isEmpty {
                note("Não há nada que valha a pena limpar.")
            }
            group("Seguras", store.entries.filter(\.target.recommended))
            group("Opcionais, escolhe tu", store.entries.filter { !$0.target.recommended })
            result
            action
            note("Só toca nesta lista e só move para o Lixo. O espaço fica livre quando o esvaziares.")
        }
        .cardStyle()
        .task { await store.refresh() }
    }

    @ViewBuilder private func group(_ title: String, _ entries: [CleanupEntry]) -> some View {
        if !entries.isEmpty {
            Text(L(title)).font(DS.meta.weight(.medium)).foregroundStyle(Color.text2).padding(.top, DS.xs)
            ForEach(entries) { entry in row(entry) }
        }
    }

    private func row(_ entry: CleanupEntry) -> some View {
        let on = store.isSelected(entry)
        return Button { store.toggle(entry) } label: {
            HStack(alignment: .top, spacing: DS.sm) {
                box(entry, on: on).font(DS.body).frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: DS.sm) {
                        Text(L(entry.target.name)).font(DS.body).foregroundStyle(entry.block == nil ? Color.primary : Color.text2)
                        Spacer(minLength: DS.sm)
                        Text(L((entry.complete ? "" : "pelo menos ") + Fmt.disk(entry.bytes)))
                            .font(DS.body.monospacedDigit()).foregroundStyle(Color.text2).lineLimit(1)
                    }
                    Text(L(entry.block?.text ?? entry.target.detail))
                        .font(DS.meta)
                        .foregroundStyle(entry.block == nil ? Color.text3 : Color.waitingText)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Sem .disabled: esbatia o motivo, que é o que se precisa de ler.
        .allowsHitTesting(entry.block == nil && !store.busy)
        .help(L(store.shortPath(entry)))
        .accessibilityValue(entry.block != nil ? "Não disponível" : on ? "Selecionado" : "Não selecionado")
    }

    @ViewBuilder private func box(_ entry: CleanupEntry, on: Bool) -> some View {
        if entry.block != nil {
            Image(systemName: "minus.square").foregroundStyle(Color.text3)
        } else if on {
            Image(systemName: "checkmark.square.fill").foregroundStyle(.tint)
        } else {
            Image(systemName: "square").foregroundStyle(Color.text2)
        }
    }

    @ViewBuilder private var result: some View {
        if let message = store.message { note(message, color: .text2) }
        ForEach(store.problems, id: \.self) { problem in note(problem, color: .waitingText) }
    }

    @ViewBuilder private var action: some View {
        if store.moving {
            note("A mover para o Lixo…")
        } else if store.scanning && !store.entries.isEmpty {
            note("A confirmar tamanhos e o que está em uso…")
        } else if let pending = store.pending {
            ConfirmBar(text: String(localized: "Mover \(size(pending)) para o Lixo? \(pending.map(\.target.name).joined(separator: ", ")). Nada é apagado de vez."),
                       confirm: "Mover para o Lixo",
                       cancel: { store.cancel() },
                       action: { Task { await store.moveToTrash() } })
        } else if !store.selected.isEmpty {
            Button("Mover \(size(store.selected)) para o Lixo…") { store.askToConfirm() }.controlSize(.small)
        }
    }

    private func size(_ entries: [CleanupEntry]) -> String {
        Fmt.disk(entries.reduce(UInt64(0)) { $0 + $1.bytes })
    }
}
