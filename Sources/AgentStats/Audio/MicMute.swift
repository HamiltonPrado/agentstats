import AppKit
import Carbon.HIToolbox
import CoreAudio

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
    /// O aparelho que foi silenciado: é esse que volta a ligar, mesmo que entretanto se tenham ligado os AirPods.
    private var mutedDevice: AudioDeviceID?
    /// Volume a repor, quando o aparelho não tem botão de silenciar.
    private var savedVolume: Double?
    private let hotKey = GlobalHotKey(id: MicMute.hotkeyID)
    private var watching: AudioDeviceID?

    private static let restoreVolumeKey = "mic.restoreVolume"
    private static let unmuteKey = "mic.unmuteOnLaunch"
    private static let deviceKey = "mic.mutedDevice"

    func start() {
        // A app fechou de repente com o microfone calado: volta a ligá-lo (o mesmo aparelho, se ainda existir).
        let d = UserDefaults.standard
        audio.refresh()
        let saved = (d.object(forKey: Self.deviceKey) as? Int).map { AudioDeviceID($0) }
        let device = saved.flatMap { audio.inputExists($0) ? $0 : nil } ?? audio.inputID
        if let v = d.object(forKey: Self.restoreVolumeKey) as? Double {
            audio.setInput(volume: v, on: device)
            d.removeObject(forKey: Self.restoreVolumeKey)
        }
        if d.bool(forKey: Self.unmuteKey) {
            if audio.inputMuteSettable(device) { audio.setInput(muted: false, on: device) }
            d.removeObject(forKey: Self.unmuteKey)
        }
        d.removeObject(forKey: Self.deviceKey)
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
        let d = UserDefaults.standard
        let device = on ? audio.inputID : (mutedDevice.flatMap { audio.inputExists($0) ? $0 : nil } ?? audio.inputID)
        if audio.inputMuteSettable(device) {
            audio.setInput(muted: on, on: device)
            if on { d.set(true, forKey: Self.unmuteKey) } else { d.removeObject(forKey: Self.unmuteKey) }
        } else if audio.inputVolumeSettable(device) {
            if on {
                let v = audio.inputVolume(of: device) ?? 0.75
                savedVolume = v
                d.set(v, forKey: Self.restoreVolumeKey)
                audio.setInput(volume: 0, on: device)
            } else {
                audio.setInput(volume: savedVolume ?? 0.75, on: device)
                savedVolume = nil
                d.removeObject(forKey: Self.restoreVolumeKey)
            }
        } else if on {
            return   // este microfone não deixa nem silenciar nem baixar o volume
        }
        if on { d.set(Int(device), forKey: Self.deviceKey) } else { d.removeObject(forKey: Self.deviceKey) }
        mutedDevice = on ? device : nil
        muted = on
        watch(on ? device : nil)
        NSSound(named: on ? "Bottle" : "Pop")?.play()
        onChange?()
    }

    // MARK: Mudanças feitas fora da app (Definições do Sistema, o botão do próprio aparelho)

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
    }

    /// Os blocos registados, para os tirar outra vez (o Core Audio identifica-os pelo próprio bloco).
    private var listener: AudioObjectPropertyListenerBlock?

    private func watch(_ device: AudioDeviceID?) {
        if let old = watching, let listener {
            for sel in [kAudioDevicePropertyMute, kAudioDevicePropertyVolumeScalar] {
                var a = Self.address(sel)
                AudioObjectRemovePropertyListenerBlock(old, &a, .main, listener)
            }
        }
        watching = nil
        listener = nil
        guard let device else { return }
        let block: AudioObjectPropertyListenerBlock = { @Sendable _, _ in
            MainActor.assumeIsolated { MicMuteStore.shared.deviceChanged() }   // fila .main
        }
        for sel in [kAudioDevicePropertyMute, kAudioDevicePropertyVolumeScalar] {
            var a = Self.address(sel)
            AudioObjectAddPropertyListenerBlock(device, &a, .main, block)
        }
        watching = device
        listener = block
    }

    /// Alguém voltou a ligar o microfone por outro lado: o indicador na barra de menus deixa de mentir.
    private func deviceChanged() {
        guard muted, let device = mutedDevice else { return }
        let stillMuted = savedVolume == nil ? (audio.inputIsMuted(device) ?? false) : ((audio.inputVolume(of: device) ?? 1) < 0.01)
        guard !stillMuted else { return }
        muted = false
        mutedDevice = nil
        savedVolume = nil
        let d = UserDefaults.standard
        for k in [Self.unmuteKey, Self.restoreVolumeKey, Self.deviceKey] { d.removeObject(forKey: k) }
        watch(nil)
        onChange?()
    }
}
