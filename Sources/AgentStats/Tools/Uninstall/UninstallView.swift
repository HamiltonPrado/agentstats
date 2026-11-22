import SwiftUI
import AppKit

struct UninstallView: View {
    @ObservedObject var store: UninstallStore
    @StateObject private var search = Box("")

    var body: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            if let plan = store.plan {
                planView(plan)
            } else {
                list
            }
        }
        .cardStyle()
        .task { await store.refresh() }
    }

    @ViewBuilder private var list: some View {
        HStack(spacing: DS.sm) {
            Text("Apps").font(DS.body.weight(.medium))
            Spacer(minLength: DS.sm)
            if store.loaded { Text("\(store.apps.count)").font(DS.meta.monospacedDigit()).foregroundStyle(Color.text3) }
        }
        if store.apps.count > 5 {
            TextField("Procurar app", text: $search.value).textFieldStyle(.roundedBorder).font(DS.body)
        }
        if let message = store.message { note(message, color: .text2) }
        if !store.loaded { note("A ler as apps…") }
        let found = store.apps.filter { search.value.isEmpty || $0.name.localizedStandardContains(search.value) }
        LazyVStack(spacing: 0) {
            ForEach(found) { app in
                Button { store.choose(app) } label: {
                    HStack(spacing: DS.sm) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 16, height: 16)
                        Text(app.name).font(DS.body).lineLimit(1)
                        Spacer(minLength: DS.sm)
                        Image(systemName: "chevron.right").font(DS.meta).foregroundStyle(Color.text3)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        note("Vai tudo para o Lixo. As apps da Apple e o próprio AgentStats não aparecem.")
    }

    @ViewBuilder private func planView(_ plan: UninstallPlan) -> some View {
        HStack(spacing: DS.sm) {
            IconButton(systemName: "chevron.left", help: "Voltar às apps") { store.cancel() }
            VStack(alignment: .leading, spacing: 2) {
                Text(plan.app.name).font(DS.body.weight(.medium)).lineLimit(1)
                Text(plan.app.bundleID).font(DS.meta).foregroundStyle(Color.text3).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        HStack(spacing: DS.sm) {
            Image(systemName: "checkmark.square.fill").foregroundStyle(Color.text2).frame(width: 16)
            Text(store.shortPath(plan.app.path)).lineLimit(1).truncationMode(.middle)
        }
        .font(DS.body)

        if plan.sharedWithCopy {
            note("Há outra cópia desta app no Mac, por isso os dados ficam: também são dela.")
        } else if plan.leftovers.isEmpty {
            note("Não encontrei restos com o identificador desta app.")
        } else {
            HStack(spacing: DS.sm) {
                Text("Restos, escolhe o que vai").font(DS.meta).foregroundStyle(Color.text2)
                Spacer(minLength: DS.sm)
                let everything = Set(plan.leftovers.map(\.path))
                textLink(store.selected == everything ? "Nenhum" : "Todos") {
                    store.selected = store.selected == everything ? [] : everything
                    store.confirming = false
                }
            }
            ForEach(plan.leftovers) { entry in leftover(entry) }
            if plan.leftovers.contains(where: { $0.path.contains("/Library/Containers/") }) {
                note("A pasta em Containers pode ter documentos teus.", color: .waitingText)
            }
        }

        if let message = store.message { note(message, color: .waitingText) }
        if store.confirming {
            ConfirmBar(text: "Mover \(plan.app.name)\(selectionText) para o Lixo?", confirm: "Mover para o Lixo",
                       cancel: { store.confirming = false }, action: { store.moveToTrash() })
        } else {
            Button("Mover para o Lixo…") { store.confirming = true }.controlSize(.small)
        }
    }

    private var selectionText: String {
        switch store.selected.count {
        case 0: ", sem os restos,"
        case 1: " e 1 resto"
        case let n: " e \(n) restos"
        }
    }

    private func leftover(_ entry: UninstallPlan.Entry) -> some View {
        let on = store.selected.contains(entry.path)
        return Button {
            if on { store.selected.remove(entry.path) } else { store.selected.insert(entry.path) }
            store.confirming = false   // muda o que se ia confirmar
        } label: {
            HStack(spacing: DS.sm) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.text2)).frame(width: 16)
                Text(store.shortPath(entry.path)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .font(DS.meta)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(entry.path)
        .accessibilityValue(on ? "Selecionado" : "Não selecionado")
    }
}
