import AppKit
import Carbon.HIToolbox

/// Silenciar o microfone com um atalho global, para chamadas. Com botão de silenciar no aparelho usa-o;
/// sem ele (como no microfone do MacBook), põe o volume de entrada a 0 e repõe o de antes.
enum MicMute {
    static let hotkeyKey = "mic.hotkey"
    static let defaultPreset = "ctrloptM"
    static let hotkeyID: UInt32 = 3
    static let presets: [(key: String, combo: GlobalHotKey.Combo)] = [
        ("ctrloptM", .init(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(controlKey | optionKey), label: "⌃⌥M")),
        ("ctrlcmdM", .init(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(controlKey | cmdKey), label: "⌃⌘M")),
        ("ctrloptcmdM", .init(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(controlKey | optionKey | cmdKey), label: "⌃⌥⌘M")),
    ]

    static var configured: GlobalHotKey.Combo? {
        let key = UserDefaults.standard.string(forKey: hotkeyKey) ?? defaultPreset
        return presets.first { $0.key == key }?.combo
    }
}

@MainActor
final class MicMuteStore: ObservableObject {
    static let shared = MicMuteStore()

    @Published private(set) var muted = false
    var onChange: (() -> Void)?
    private let audio = AudioControlStore()
    /// Volume a repor, quando o aparelho não tem botão de silenciar.
    private var savedVolume: Double?
    private let hotKey = GlobalHotKey(id: MicMute.hotkeyID)

    func start() {
        GlobalHotKey.handlers[MicMute.hotkeyID] = { MicMuteStore.shared.toggle() }
        registerHotKey()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MicMuteStore.shared.set(false) }   // não deixa o microfone calado depois de sair
        }
    }

    func registerHotKey() { _ = hotKey.register(MicMute.configured) }

    func toggle() { set(!muted) }

    func set(_ on: Bool) {
        guard on != muted else { return }
        audio.refresh()
        if audio.canMuteInput {
            audio.setInputMuted(on)
        } else if audio.canSetInputVolume {
            if on {
                savedVolume = audio.inputVolume
                audio.setInputVolume(0)
            } else {
                audio.setInputVolume(savedVolume ?? 0.75)
                savedVolume = nil
            }
        } else {
            return   // este microfone não deixa nem silenciar nem baixar o volume
        }
        muted = on
        NSSound(named: on ? "Bottle" : "Pop")?.play()
        onChange?()
    }
}
