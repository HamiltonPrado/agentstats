import SwiftUI
import AppKit

struct ClipboardView: View {
    @ObservedObject var store: ClipboardStore
    @StateObject private var search = Box("")
    @StateObject private var copied = Box<UUID?>(nil)
    @StateObject private var showAll = Box(false)
    @StateObject private var confirmClear = Box(false)
    @StateObject private var confirmDelete = Box<UUID?>(nil)

    private static let shortList = 8

    var body: some View {
        VStack(alignment: .leading, spacing: DS.md) {
            if store.items.count + store.snippets.count > 5 || !search.value.isEmpty { searchField }
            if let error = store.storageError {
                Text(error).font(DS.meta).foregroundStyle(Color.waitingText).fixedSize(horizontal: false, vertical: true)
            }
            historyCard
            snippetsCard
        }
        .onAppear {
            store.refreshAccess()
            store.prune()
        }
    }

    private var searchField: some View {
        TextField("Procurar", text: $search.value)
            .textFieldStyle(.roundedBorder).font(DS.body)
            .accessibilityLabel("Procurar no histórico e nos snippets")
    }

    private func matches(_ text: String) -> Bool {
        search.value.isEmpty || text.localizedStandardContains(search.value)
    }

    // MARK: Histórico

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            HStack(spacing: DS.sm) {
                Text("Histórico").font(DS.body.weight(.medium))
                Spacer(minLength: DS.sm)
                Toggle("Guardar o que copio", isOn: Binding(get: { store.enabled }, set: { store.setEnabled($0) }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .help("Guardar o que copio")
            }
            if store.enabled {
                accessNotice
            } else {
                note("Desligado. Se ligares, guarda o texto que copiares, só neste Mac e por 7 dias. Ignora o que os gestores de passwords copiam e as chaves de API conhecidas.")
            }
            historyList
        }
        .cardStyle()
    }

    @ViewBuilder private var accessNotice: some View {
        switch store.access {
        case .allowed:
            if store.items.isEmpty { note("Copia algum texto e aparece aqui.") }
        case .notRequested:
            note("O macOS tem de te perguntar primeiro. Depois escolhe “Permitir sempre” nas Definições, senão pergunta a cada cópia.")
            Button("Pedir acesso") { store.requestAccess() }.controlSize(.small)
        case .asks, .denied:
            note(store.access == .denied
                 ? "O macOS não deixa o AgentStats ler o clipboard, por isso nada está a ser guardado."
                 : "Falta um passo: escolhe “Permitir sempre” para o AgentStats em Privacidade e Segurança → Colar de outras apps. Até lá não leio nada, para não veres um alerta por cópia.")
            Button("Abrir Definições do Sistema") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard") {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder private var historyList: some View {
        let found = store.items.filter { matches($0.text) }
        let ordered = found.filter(\.pinned) + found.filter { !$0.pinned }
        let visible = showAll.value || !search.value.isEmpty ? ordered : Array(ordered.prefix(Self.shortList))
        if !visible.isEmpty {
            VStack(spacing: 0) {
                ForEach(visible) { item in historyRow(item) }
            }
            HStack(spacing: DS.sm) {
                if ordered.count > Self.shortList && search.value.isEmpty {
                    link(showAll.value ? "Mostrar menos" : "Mostrar os \(ordered.count)") { showAll.value.toggle() }
                }
                Spacer(minLength: 0)
                if confirmClear.value {
                    Text("Apagar o histórico todo?").font(DS.meta).foregroundStyle(Color.text2).lineLimit(1)
                    link("Apagar", color: .attentionText) {
                        store.clearHistory()
                        confirmClear.value = false
                    }
                    link("Não") { confirmClear.value = false }
                } else {
                    link("Limpar") { confirmClear.value = true }
                }
            }
        } else if !search.value.isEmpty {
            note("Nada no histórico com esse texto.")
        }
    }

    private func historyRow(_ item: ClipItem) -> some View {
        HStack(spacing: 0) {
            copyButton(id: item.id, text: item.text) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ClipboardRules.preview(item.text)).font(DS.body).lineLimit(1).truncationMode(.tail)
                    Text(copied.value == item.id ? "Copiado" : Fmt.ago(item.date))
                        .font(DS.meta)
                        .foregroundStyle(copied.value == item.id ? AnyShapeStyle(Color.workingText) : AnyShapeStyle(Color.text3))
                }
            }
            IconButton(systemName: item.pinned ? "pin.fill" : "pin", help: item.pinned ? "Desafixar" : "Afixar") {
                store.togglePin(item.id)
            }
            IconButton(systemName: "xmark", help: "Apagar do histórico") { store.remove(item.id) }
        }
        .padding(.vertical, DS.xs)
    }

    // MARK: Snippets

    private var snippetsCard: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            HStack(spacing: DS.sm) {
                Text("Snippets").font(DS.body.weight(.medium))
                Spacer(minLength: DS.sm)
                if store.draft == nil {
                    IconButton(systemName: "plus", help: "Novo snippet") { store.draft = Snippet(name: "", text: "") }
                }
            }
            if store.draft != nil { editor }

            let found = store.snippets.filter { matches($0.name + "\n" + $0.text) }
            if found.isEmpty && store.draft == nil {
                note(search.value.isEmpty
                     ? "Textos que usas muito. Um clique copia; não precisam do histórico ligado."
                     : "Nenhum snippet com esse texto.")
            }
            VStack(spacing: 0) {
                ForEach(found) { snippet in snippetRow(snippet) }
            }
        }
        .cardStyle()
    }

    private func snippetRow(_ snippet: Snippet) -> some View {
        HStack(spacing: 0) {
            copyButton(id: snippet.id, text: snippet.text) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(snippet.name).font(DS.body).lineLimit(1)
                    Text(copied.value == snippet.id ? "Copiado" : ClipboardRules.preview(snippet.text))
                        .font(DS.meta).lineLimit(1)
                        .foregroundStyle(copied.value == snippet.id ? AnyShapeStyle(Color.workingText) : AnyShapeStyle(Color.text3))
                }
            }
            if confirmDelete.value == snippet.id {
                link("Apagar", color: .attentionText) {
                    store.removeSnippet(snippet.id)
                    confirmDelete.value = nil
                }
                .padding(.horizontal, DS.xs)
                link("Não") { confirmDelete.value = nil }
            } else {
                IconButton(systemName: "pencil", help: "Editar") { store.draft = snippet }
                IconButton(systemName: "trash", help: "Apagar snippet") { confirmDelete.value = snippet.id }
            }
        }
        .padding(.vertical, DS.xs)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            TextField("Nome (opcional)", text: Binding(get: { store.draft?.name ?? "" }, set: { store.draft?.name = $0 }))
                .textFieldStyle(.roundedBorder).font(DS.body)
            TextEditor(text: Binding(get: { store.draft?.text ?? "" }, set: { store.draft?.text = $0 }))
                .font(DS.body).scrollContentBackground(.hidden)
                .frame(height: 72).padding(DS.xs)
                .background(RoundedRectangle(cornerRadius: DS.rSmall, style: .continuous).fill(DS.raised))
                .accessibilityLabel("Texto do snippet")
            HStack(spacing: DS.sm) {
                Spacer()
                Button("Cancelar") { store.draft = nil }
                Button("Guardar") { store.saveDraft() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(store.draft?.text.isEmpty ?? true)
            }
            .controlSize(.small)
        }
    }

    // MARK: Peças

    private func copyButton<Label: View>(id: UUID, text: String, @ViewBuilder label: () -> Label) -> some View {
        Button {
            store.copy(text)
            copied.value = id
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                if copied.value == id { copied.value = nil }
            }
        } label: {
            label().frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copiar")
        .accessibilityHint("Copia para o clipboard")
    }

    private func link(_ title: String, color: Color = .text2, action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(.plain).font(DS.meta).foregroundStyle(color).fixedSize()
    }

    private func note(_ text: String) -> some View {
        Text(text).font(DS.meta).foregroundStyle(Color.text3).fixedSize(horizontal: false, vertical: true)
    }
}
