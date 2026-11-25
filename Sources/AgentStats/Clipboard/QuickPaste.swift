import AppKit
import ApplicationServices

/// Cola um texto na app que estava à frente antes de abrir o painel: copia, devolve-lhe o foco e carrega ⌘V.
/// Carregar teclas noutra app precisa da Acessibilidade; sem ela, fica só copiado.
@MainActor
enum QuickPaste {
    /// A app da frente quando o painel abriu (nunca o próprio AgentStats).
    static var previousApp: NSRunningApplication?

    static func rememberFrontApp() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
    }

    enum Outcome: Equatable { case pasted, copiedOnly }

    @discardableResult
    static func paste(_ text: String, store: ClipboardStore) -> Outcome {
        paste(ClipItem(text: text, date: Date()), store: store)
    }

    /// Texto ou imagem.
    @discardableResult
    static func paste(_ item: ClipItem, store: ClipboardStore) -> Outcome {
        store.copyItem(item)
        guard AXIsProcessTrusted(), let app = previousApp, !app.isTerminated else { return .copiedOnly }
        AppState.controller?.closePanel()
        app.activate()
        // Dá tempo à app de voltar à frente antes do ⌘V.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { sendCommandV() }
        return .pasted
    }

    private static func sendCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let v: CGKeyCode = 9   // a tecla V em qualquer disposição ANSI/ISO
        let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
