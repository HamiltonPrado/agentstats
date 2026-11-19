import AppKit
import Carbon.HIToolbox

/// Atalho de teclado global para abrir e fechar o painel.
/// Usa a API de atalhos do sistema (Carbon), que não precisa de permissões de acessibilidade.
@MainActor
final class GlobalHotKey {
    struct Combo: Equatable, Sendable {
        let keyCode: UInt32
        let modifiers: UInt32
        let label: String
    }

    /// Atalhos disponíveis nas Definições (chave guardada em UserDefaults → combinação).
    static let presets: [(key: String, combo: Combo)] = [
        ("optcmdA", Combo(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey | cmdKey), label: "⌥⌘A")),
        ("ctrloptA", Combo(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(controlKey | optionKey), label: "⌃⌥A")),
        ("optcmdS", Combo(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(optionKey | cmdKey), label: "⌥⌘S")),
    ]
    static let defaultsKey = "hotkey"
    static let defaultPreset = "optcmdA"

    /// A combinação escolhida nas Definições, ou nil se o atalho estiver desligado.
    static var configured: Combo? {
        let key = UserDefaults.standard.string(forKey: defaultsKey) ?? defaultPreset
        return presets.first { $0.key == key }?.combo
    }

    /// O que fazer quando o atalho é premido (o StatusController abre/fecha o painel).
    static var handler: (() -> Void)?

    private var ref: EventHotKeyRef?
    private(set) var current: Combo?
    private static var handlerInstalled = false

    /// Regista a combinação (substituindo a anterior). Devolve false se o sistema recusar,
    /// por exemplo porque outra app já usa o mesmo atalho.
    @discardableResult
    func register(_ combo: Combo?) -> Bool {
        guard combo != current else { return true }
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        current = nil
        guard let combo else { return true }

        if !Self.handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            // Função C: não pode capturar contexto, por isso chama o handler estático no main actor.
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotKey.handler?() } }
                return noErr
            }, 1, &spec, nil, nil)
            Self.handlerInstalled = true
        }

        let id = EventHotKeyID(signature: OSType(0x4147_5354), id: 1)   // "AGST"
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else {
            Log.readers.error("Não foi possível registar o atalho \(combo.label, privacy: .public): \(status)")
            ref = nil
            return false
        }
        current = combo
        return true
    }
}
