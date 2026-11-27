import AppKit
import UniformTypeIdentifiers

/// Os painéis de abrir e gravar, sem `runModal()`: esse corre um ciclo de eventos encaixado e, a meio de uma
/// função async do main actor, deixava correr amostras e avisos no meio dela.
@MainActor
enum FilePanels {
    static func save(name: String, types: [UTType]) async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = types
        return await run(panel) ? panel.url : nil
    }

    static func open(types: [UTType], multiple: Bool = false) async -> [URL] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = multiple
        panel.canChooseDirectories = false
        return await run(panel) ? panel.urls : []
    }

    /// Gravar não falha em silêncio: diz que não deu.
    static func reportSaveFailure() {
        let alert = NSAlert()
        alert.messageText = L("Não consegui guardar o ficheiro.")
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func run(_ panel: NSSavePanel) async -> Bool {
        NSApp.activate()
        return await withCheckedContinuation { c in
            panel.begin { c.resume(returning: $0 == .OK) }
        }
    }
}
