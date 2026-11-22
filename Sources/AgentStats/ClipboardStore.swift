import AppKit
import SwiftUI

enum ClipboardAccess: Equatable {
    case allowed
    case notRequested   // o macOS ainda não perguntou
    case asks           // pergunta a cada leitura: um histórico automático seria um alerta por cópia
    case denied
}

/// Histórico do clipboard e snippets. Está desligado até o utilizador o ligar, e só `start()`, chamado
/// pela app a sério, o põe a vigiar: capturas, `--dump` e testes nunca leem o clipboard real.
/// O conteúdo nunca vai para logs nem para a rede.
@MainActor
final class ClipboardStore: ObservableObject {
    static let shared = ClipboardStore(
        pasteboard: .general,
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentStats"),
        defaults: .standard)

    private enum Key {
        static let enabled = "clipboard.enabled"
        static let requested = "clipboard.accessRequested"
    }

    @Published private(set) var enabled: Bool
    @Published private(set) var access: ClipboardAccess = .notRequested
    @Published private(set) var items: [ClipItem] = []
    @Published private(set) var snippets: [Snippet] = []
    @Published private(set) var storageError: String?
    /// Vive aqui e não na vista: o painel fecha-se ao clicar noutra app e o rascunho perdia-se.
    @Published var draft: Snippet?

    private let pasteboard: NSPasteboard
    private var directory: URL?
    private let defaults: UserDefaults?
    private let accessOverride: ClipboardAccess?
    private let frontApp: () -> String?

    private var requested: Bool
    private var lastChange: Int
    private var previousApp: String?
    private var watching = false
    private var timer: Timer?
    private var historyWritable = true
    private var snippetsWritable = true

    /// `directory` e `defaults` nil: só em memória. `accessOverride` e `frontApp` existem para os testes.
    init(pasteboard: NSPasteboard, directory: URL?, defaults: UserDefaults?, accessOverride: ClipboardAccess? = nil,
         frontApp: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }) {
        self.pasteboard = pasteboard
        self.directory = directory
        self.defaults = defaults
        self.accessOverride = accessOverride
        self.frontApp = frontApp
        enabled = defaults?.bool(forKey: Key.enabled) ?? false
        requested = defaults?.bool(forKey: Key.requested) ?? false
        lastChange = pasteboard.changeCount
        load()
        refreshAccess()
    }

    private var historyFile: URL? { directory?.appendingPathComponent("clipboard.json") }
    private var snippetsFile: URL? { directory?.appendingPathComponent("snippets.json") }

    // MARK: Vigiar

    func start() {
        watching = true
        prune()
        updateTimer()
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        defaults?.set(on, forKey: Key.enabled)
        // O que já lá estava antes de ligar não entra.
        lastChange = pasteboard.changeCount
        previousApp = nil
        refreshAccess()
        updateTimer()
    }

    private func updateTimer() {
        timer?.invalidate()
        timer = nil
        guard watching, enabled else { return }
        lastChange = pasteboard.changeCount
        let t = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func poll(now: Date = Date()) {
        guard enabled else { return }
        let app = frontApp()
        // A da volta anterior também conta: copia-se no gestor de passwords e muda-se logo de app.
        let apps = [app, previousApp].compactMap { $0 }
        previousApp = app

        let change = pasteboard.changeCount
        guard change != lastChange else {
            refreshAccess()
            return
        }
        lastChange = change
        refreshAccess()
        guard access == .allowed else { return }

        let types = (pasteboard.types ?? []).map(\.rawValue)
        guard types.contains(NSPasteboard.PasteboardType.string.rawValue),
              ClipboardRules.shouldRead(types: types, apps: apps),
              let text = pasteboard.string(forType: .string) else { return }
        // Mudou entre ver os tipos e ler: o texto podia ser de uma cópia confidencial.
        guard pasteboard.changeCount == change, ClipboardRules.shouldKeep(text) else { return }
        items = ClipboardRules.adding(text, to: items, now: now)
        saveHistory()
    }

    // MARK: Permissão

    func refreshAccess() {
        let new = accessOverride ?? systemAccess()
        if new != access { access = new }
    }

    private func systemAccess() -> ClipboardAccess {
        guard #available(macOS 15.4, *) else { return .allowed }
        switch pasteboard.accessBehavior {
        case .alwaysAllow: return .allowed
        case .alwaysDeny: return .denied
        case .ask: return .asks
        // Depois do pedido, continuar em `.default` quer dizer que este macOS não faz a pergunta.
        case .default: return requested ? .allowed : .notRequested
        @unknown default: return .asks
        }
    }

    /// Só por clique. Uma leitura é a única forma de a app aparecer nas Definições do Sistema;
    /// o que se lê é deitado fora.
    func requestAccess() {
        _ = pasteboard.string(forType: .string)
        requested = true
        defaults?.set(true, forKey: Key.requested)
        lastChange = pasteboard.changeCount
        refreshAccess()
    }

    // MARK: Histórico

    /// Escrever não precisa de permissão.
    func copy(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastChange = pasteboard.changeCount   // a nossa cópia não é uma entrada nova
    }

    func togglePin(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].pinned.toggle()
        saveHistory()
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        saveHistory()
    }

    func clearHistory() {
        items.removeAll()
        historyWritable = true   // apagar também serve para recomeçar depois de um ficheiro ilegível
        storageError = nil
        saveHistory()
    }

    func prune(now: Date = Date()) {
        let kept = ClipboardRules.pruned(items, now: now)
        guard kept != items else { return }
        items = kept
        saveHistory()
    }

    // MARK: Snippets

    func saveDraft() {
        guard var snippet = draft, !snippet.text.isEmpty else { return }
        snippet.name = snippet.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if snippet.name.isEmpty { snippet.name = String(ClipboardRules.preview(snippet.text).prefix(40)) }
        if let i = snippets.firstIndex(where: { $0.id == snippet.id }) {
            snippets[i] = snippet
        } else {
            snippets.append(snippet)
        }
        draft = nil
        saveSnippets()
    }

    func removeSnippet(_ id: UUID) {
        snippets.removeAll { $0.id == id }
        saveSnippets()
    }

    // MARK: Disco

    private func load() {
        if let url = historyFile {
            switch PrivateFile.load([ClipItem].self, from: url) {
            case .missing: break
            case .value(let saved): items = saved
            case .unreadable:
                historyWritable = false
                storageError = "Não consegui ler o histórico guardado. Não lhe mexi."
            }
        }
        if let url = snippetsFile {
            switch PrivateFile.load([Snippet].self, from: url) {
            case .missing: break
            case .value(let saved): snippets = saved
            case .unreadable:
                snippetsWritable = false
                storageError = "Não consegui ler os snippets guardados. Não lhes mexi, e os novos não ficam guardados."
            }
        }
    }

    private func saveHistory() {
        guard historyWritable, let url = historyFile else { return }
        if !PrivateFile.save(items, to: url, backup: false) { storageError = "Não consegui guardar o histórico." }
    }

    private func saveSnippets() {
        guard snippetsWritable, let url = snippetsFile else { return }
        // Os snippets são escritos por ti: esses entram nas cópias de segurança.
        if !PrivateFile.save(snippets, to: url, backup: true) { storageError = "Não consegui guardar os snippets." }
    }

    /// Para as capturas, que acabam no README e no site: nunca mostram o clipboard real, e nada é gravado.
    func loadDemo(now: Date = Date()) {
        directory = nil
        enabled = true
        access = .allowed
        storageError = nil
        draft = nil
        items = [
            ClipItem(text: "git switch -c feat/painel", date: now.addingTimeInterval(-40)),
            ClipItem(text: "https://example.com/docs/instalar", date: now.addingTimeInterval(-900), pinned: true),
            ClipItem(text: "Reunião passada para as 15:00, sala 2.", date: now.addingTimeInterval(-7200)),
        ]
        snippets = [
            Snippet(name: "Assinatura", text: "Obrigado,\nAna"),
            Snippet(name: "Testes", text: "./test.sh && ./build.sh"),
        ]
    }
}

/// Uma app só de barra de menus não tem menu principal, e sem o menu Editar ⌘V, ⌘C, ⌘A e ⌘Z não
/// funcionam nos campos de texto do painel. O menu nunca se vê.
enum EditMenu {
    @MainActor static func make() -> NSMenu {
        let main = NSMenu()
        let holder = NSMenuItem()
        let edit = NSMenu(title: "Editar")
        edit.addItem(withTitle: "Desfazer", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Refazer", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(withTitle: "Cortar", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Colar", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Selecionar tudo", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        holder.submenu = edit
        main.addItem(holder)
        return main
    }
}
