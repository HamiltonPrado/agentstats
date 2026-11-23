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
    static var handler: (() -> Void)? {
        get { handlers[1] }
        set { handlers[1] = newValue }
    }
    /// Uma ação por id: 1 é o atalho principal; os dos separadores começam em `TabHotKeys.firstID`.
    static var handlers: [UInt32: () -> Void] = [:]
    static let signature = OSType(0x4147_5354)   // "AGST"

    private let id: UInt32
    private var ref: EventHotKeyRef?
    private(set) var current: Combo?
    private static var handlerInstalled = false

    init(id: UInt32 = 1) {
        self.id = id
    }

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
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var key = EventHotKeyID()
                let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                               nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
                guard status == noErr, key.signature == GlobalHotKey.signature else { return OSStatus(eventNotHandledErr) }
                let id = key.id
                DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotKey.handlers[id]?() } }
                return noErr
            }, 1, &spec, nil, nil)
            Self.handlerInstalled = true
        }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else {
            Log.readers.error("Não foi possível registar o atalho \(combo.label, privacy: .public): \(status)")
            ref = nil
            return false
        }
        current = combo
        return true
    }
}

/// ⌥⌘1, ⌥⌘2… abrem o painel no separador com esse número, pela ordem da barra. Desligados por omissão:
/// são atalhos globais e podiam tirar combinações a outras apps.
@MainActor
final class TabHotKeys {
    static let firstID: UInt32 = 10
    /// Os números do teclado não têm códigos seguidos.
    static let digits: [UInt32] = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7,
                                   kVK_ANSI_8, kVK_ANSI_9].map { UInt32($0) }

    static func combo(_ number: Int) -> GlobalHotKey.Combo {
        GlobalHotKey.Combo(keyCode: digits[number - 1], modifiers: UInt32(optionKey | cmdKey), label: "⌥⌘\(number)")
    }

    private var keys: [GlobalHotKey] = []

    /// `count` atalhos (0 desliga todos). Só mexe nos que mudam.
    func update(count: Int) {
        let wanted = min(max(count, 0), Self.digits.count)
        while keys.count < Self.digits.count { keys.append(GlobalHotKey(id: Self.firstID + UInt32(keys.count + 1))) }
        for (i, key) in keys.enumerated() {
            key.register(i < wanted ? Self.combo(i + 1) : nil)
        }
    }

    /// `open` recebe o número do atalho premido.
    static func install(_ open: @escaping (Int) -> Void) {
        for n in 1...digits.count {
            GlobalHotKey.handlers[firstID + UInt32(n)] = { open(n) }
        }
    }
}
