import AppKit

/// O que se pode fazer a partir de uma sessão. As vistas dos agentes só chamam isto: não falam com o sistema.
@MainActor
enum AgentActions {
    static func openFolder(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    static func openInTerminal(_ path: String) {
        NSWorkspace.shared.open([URL(fileURLWithPath: path)],
                                withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    static func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    /// O ficheiro do transcript da sessão, se houver. O OpenCode guarda tudo numa base de dados, e as sessões
    /// vistas só pelo processo (Gemini CLI, Aider sem histórico…) não têm ficheiro: o id não é um caminho.
    nonisolated static func transcriptPath(_ id: String, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        id.hasPrefix("/") && exists(id) ? id : nil
    }

    static func revealTranscript(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
