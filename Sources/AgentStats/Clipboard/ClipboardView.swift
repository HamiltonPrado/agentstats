import SwiftUI
import AppKit

struct ClipboardView: View {
    @ObservedObject var store: ClipboardStore
    @StateObject private var search = Box("")
    @StateObject private var copied = Box<UUID?>(nil)
    @StateObject private var showAll = Box(false)
    @StateObject private var confirmClear = Box(false)
    @StateObject private var confirmDelete = Box<UUID?>(nil)
    @StateObject private var selected = Box<Int?>(nil)
    @StateObject private var pasteNote = Box<String?>(nil)

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
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.return) {
            guard let i = selected.value, visibleItems.indices.contains(i) else { return .ignored }
            paste(visibleItems[i].text)
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "123456789")) { press in
            guard let n = Int(press.characters), visibleItems.indices.contains(n - 1) else { return .ignored }
            paste(visibleItems[n - 1].text)
            return .handled
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

    /// A lista que se vê, pela mesma ordem: as teclas apontam para estes.
    private var visibleItems: [ClipItem] {
        let found = store.items.filter { matches($0.text) }
        let ordered = found.filter(\.pinned) + found.filter { !$0.pinned }
        return showAll.value || !search.value.isEmpty ? ordered : Array(ordered.prefix(Self.shortList))
    }

    private func move(_ by: Int) -> KeyPress.Result {
        let count = visibleItems.count
        guard count > 0 else { return .ignored }
        selected.value = min(max((selected.value ?? (by > 0 ? -1 : count)) + by, 0), count - 1)
        return .handled
    }

    private func paste(_ text: String) {
        if QuickPaste.paste(text, store: store) == .copiedOnly {
            pasteNote.value = "Copiado. Para colar logo na app onde estavas, dá ao AgentStats acesso à Acessibilidade."
        }
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
        let visible = visibleItems
        if !visible.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { i, item in
                    historyRow(item, number: i < 9 ? i + 1 : nil)
                        .background(RoundedRectangle(cornerRadius: DS.rSmall).fill(selected.value == i ? DS.raised : .clear))
                }
            }
            if let n = pasteNote.value { note(n, color: .text2) }
            note("1–9 ou ↑↓ e Enter colam na app onde estavas.")
            HStack(spacing: DS.sm) {
                if ordered.count > Self.shortList && search.value.isEmpty {
                    textLink(showAll.value ? "Mostrar menos" : "Mostrar os \(ordered.count)") { showAll.value.toggle() }
                }
                Spacer(minLength: 0)
                if confirmClear.value {
                    Text("Apagar o histórico todo?").font(DS.meta).foregroundStyle(Color.text2).lineLimit(1)
                    textLink("Apagar", color: .attentionText) {
                        store.clearHistory()
                        confirmClear.value = false
                    }
                    textLink("Não") { confirmClear.value = false }
                } else {
                    textLink("Limpar") { confirmClear.value = true }
                }
            }
        } else if !search.value.isEmpty {
            note("Nada no histórico com esse texto.")
        }
    }

    private func historyRow(_ item: ClipItem, number: Int?) -> some View {
        HStack(spacing: 0) {
            Text(number.map(String.init) ?? "").font(DS.meta.monospacedDigit()).foregroundStyle(Color.text3)
                .frame(width: 14, alignment: .leading)
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
                textLink("Apagar", color: .attentionText) {
                    store.removeSnippet(snippet.id)
                    confirmDelete.value = nil
                }
                .padding(.horizontal, DS.xs)
                textLink("Não") { confirmDelete.value = nil }
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
}
