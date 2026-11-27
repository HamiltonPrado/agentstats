import AppKit
import ApplicationServices
import Carbon

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
        waitForFront(app, tries: 0)
        return .pasted
    }

    /// Só carrega ⌘V quando a app certa está mesmo à frente: se outra ganhar o foco entretanto,
    /// o texto (que pode ser um snippet sensível) não vai parar lá. Desiste ao fim de cerca de 1 s.
    private static func waitForFront(_ app: NSRunningApplication, tries: Int) {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
            // Um instante para a janela dela receber o foco do teclado.
            Task { try? await Task.sleep(for: .milliseconds(60)); sendCommandV() }
            return
        }
        guard tries < 30, !app.isTerminated else { return }
        Task { try? await Task.sleep(for: .milliseconds(35)); waitForFront(app, tries: tries + 1) }
    }

    private static func sendCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let v = KeyLayout.keyCode(for: "v") ?? 9
        let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

/// A tecla que dá uma letra com ⌘ na disposição de teclado atual (em Dvorak o "V" não está onde está em QWERTY;
/// nas disposições "QWERTY ⌘" volta a estar, e é isso que o ⌘ no estado dos modificadores trata).
enum KeyLayout {
    static func keyCode(for character: Character) -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        let target = String(character).lowercased()
        return data.withUnsafeBytes { buffer -> CGKeyCode? in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            for code in 0..<128 {
                var dead: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), UInt32((cmdKey >> 8) & 0xFF),
                                            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                            &dead, chars.count, &length, &chars)
                if status == noErr, length > 0, String(utf16CodeUnits: chars, count: length).lowercased() == target {
                    return CGKeyCode(code)
                }
            }
            return nil
        }
    }
}
