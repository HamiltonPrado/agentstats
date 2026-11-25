import AppKit
import CryptoKit
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
        static let images = "clipboard.images"
    }

    @Published private(set) var enabled: Bool
    /// Guardar também imagens (desligado por defeito: as capturas de ecrã podem ter coisas sensíveis).
    @Published private(set) var imagesEnabled: Bool
    /// Pausado pelo modo apresentação: não guarda nada enquanto estiver.
    @Published var paused = false
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
    private var demo = false
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
        imagesEnabled = defaults?.bool(forKey: Key.images) ?? false
        requested = defaults?.bool(forKey: Key.requested) ?? false
        lastChange = pasteboard.changeCount
        load()
        refreshAccess()
    }

    private var historyFile: URL? { directory?.appendingPathComponent("clipboard.json") }
    private var imagesDirectory: URL? { directory?.appendingPathComponent("clipboard-images") }

    func setImagesEnabled(_ on: Bool) {
        imagesEnabled = on
        defaults?.set(on, forKey: Key.images)
    }

    func imageURL(_ item: ClipItem) -> URL? {
        guard let name = item.image else { return nil }
        return imagesDirectory?.appendingPathComponent(name)
    }
    private var snippetsFile: URL? { directory?.appendingPathComponent("snippets.json") }

    // MARK: Vigiar

    func start() {
        guard !demo else { return }
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
        if paused {
            lastChange = pasteboard.changeCount   // o que se copiar durante a pausa não entra depois
            return
        }
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
        if imagesEnabled, ClipboardRules.isImageCopy(types: types), ClipboardRules.shouldRead(types: types, apps: apps) {
            keepImage(change: change, now: now)
            return
        }
        guard types.contains(NSPasteboard.PasteboardType.string.rawValue),
              ClipboardRules.shouldRead(types: types, apps: apps),
              let text = pasteboard.string(forType: .string) else { return }
        // Mudou entre ver os tipos e ler: o texto podia ser de uma cópia confidencial.
        guard pasteboard.changeCount == change, ClipboardRules.shouldKeep(text) else { return }
        items = ClipboardRules.adding(text, to: items, now: now)
        saveHistory()
    }

    /// Guarda a imagem como PNG, com o hash do conteúdo como nome (a mesma imagem não se duplica).
    private func keepImage(change: Int, now: Date) {
        let raw = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)
        guard pasteboard.changeCount == change, let raw, raw.count <= ClipboardRules.maxImageBytes,
              let rep = NSBitmapImageRep(data: raw), let png = rep.representation(using: .png, properties: [:]),
              png.count <= ClipboardRules.maxImageBytes, let dir = imagesDirectory else { return }
        let name = SHA256.hash(data: png).prefix(12).map { String(format: "%02x", $0) }.joined() + ".png"
        let url = dir.appendingPathComponent(name)
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: png, attributes: [.posixPermissions: 0o600]) else { return }
        }
        items = ClipboardRules.addingImage(name, size: "\(rep.pixelsWide)×\(rep.pixelsHigh)", to: items, now: now)
        saveHistory()
        removeOrphanImages()
    }

    func copyImage(_ item: ClipItem) {
        guard let url = imageURL(item), let data = try? Data(contentsOf: url) else { return }
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
        lastChange = pasteboard.changeCount
    }

    /// Copia o que o item tiver: texto ou imagem.
    func copyItem(_ item: ClipItem) {
        if item.image != nil { copyImage(item) } else { copy(item.text) }
    }

    private func removeOrphanImages() {
        guard let dir = imagesDirectory, let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in ClipboardRules.orphanImages(files: files, items: items) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    // MARK: Permissão

    func refreshAccess() {
        guard !demo else { return }
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
        removeOrphanImages()
    }

    func clearHistory() {
        items.removeAll()
        historyWritable = true   // apagar também serve para recomeçar depois de um ficheiro ilegível
        storageError = nil
        saveHistory()
        removeOrphanImages()
    }

    func prune(now: Date = Date()) {
        let kept = ClipboardRules.pruned(items, now: now)
        guard kept != items else { return }
        items = kept
        saveHistory()
        removeOrphanImages()
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
        demo = true
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
