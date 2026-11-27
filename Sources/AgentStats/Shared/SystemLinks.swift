import AppKit
import ApplicationServices

/// Os painéis das Definições do Sistema que a app abre (os endereços ficam num só sítio).
enum SystemSettings {
    enum Pane: String {
        case screenCapture = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case pasteboard = "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard"
        case location = "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"
        case loginItems = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
    }

    static func open(_ pane: Pane) {
        if let url = URL(string: pane.rawValue) { NSWorkspace.shared.open(url) }
    }
}

enum Finder {
    /// Abre o Finder com estes ficheiros selecionados.
    static func reveal(_ urls: [URL]) { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    static func reveal(path: String) { reveal([URL(fileURLWithPath: path)]) }
}

/// A permissão de Acessibilidade (mover janelas, ler menus, bloquear o teclado).
enum AX {
    /// Sem permissão e com `prompt`, o macOS mostra o pedido (uma vez por arranque, por decisão dele).
    @discardableResult
    static func ensureTrusted(prompt: Bool = true) -> Bool {
        guard !AXIsProcessTrusted() else { return true }
        // A constante kAXTrustedCheckOptionPrompt é uma var global, que o Swift 6 não deixa usar.
        if prompt { _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) }
        return false
    }
}
