import Foundation
import Combine
import IOKit.pwr_mgt
import CoreAudio

@MainActor
final class KeepAwakeController {
    private var assertion: IOPMAssertionID = 0
    private var timeout: Timer?
    var onTimeout: (() -> Void)?

    func setEnabled(_ enabled: Bool, minutes: Double) {
        timeout?.invalidate()
        timeout = nil
        if enabled {
            guard assertion == 0 else {
                if minutes > 0 { schedule(minutes: minutes) }
                return
            }
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "AgentStats: manter o Mac acordado" as CFString,
                &assertion)
            if result != kIOReturnSuccess { assertion = 0; return }
            if minutes > 0 { schedule(minutes: minutes) }
        } else if assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }

    private func schedule(minutes: Double) {
        timeout = Timer.scheduledTimer(withTimeInterval: minutes * 60, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.setEnabled(false, minutes: 0)
                self?.onTimeout?()
            }
        }
    }

}

struct SystemAudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
}

@MainActor
final class AudioControlStore: ObservableObject {
    @Published var outputs: [SystemAudioDevice] = []
    @Published var inputs: [SystemAudioDevice] = []
    @Published var outputID: AudioDeviceID = 0
    @Published var inputID: AudioDeviceID = 0
    @Published var outputVolume: Double = 0.5
    @Published var inputVolume: Double = 0.5
    @Published var outputMuted = false
    @Published var inputMuted = false
    @Published var canSetOutputVolume = false
    @Published var canSetInputVolume = false
    @Published var canMuteOutput = false
    @Published var canMuteInput = false

    /// Os nomes dos aparelhos trazem muitas vezes o nome do dono: nas capturas são inventados.
    static var demo = false

    init() { refresh() }

    func refresh() {
        guard !Self.demo else { return loadDemo() }
        outputs = Self.devices(scope: kAudioDevicePropertyScopeOutput)
        inputs = Self.devices(scope: kAudioDevicePropertyScopeInput)
        outputID = Self.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        inputID = Self.defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        readControls()
    }

    func selectOutput(_ id: AudioDeviceID) {
        Self.setDefaultDevice(id, selector: kAudioHardwarePropertyDefaultOutputDevice)
        refresh()
    }

    func selectInput(_ id: AudioDeviceID) {
        Self.setDefaultDevice(id, selector: kAudioHardwarePropertyDefaultInputDevice)
        refresh()
    }

    func setOutputVolume(_ value: Double) { setScalar(outputID, scope: kAudioDevicePropertyScopeOutput, value: Float(value)); readControls() }
    func setInputVolume(_ value: Double) { setScalar(inputID, scope: kAudioDevicePropertyScopeInput, value: Float(value)); readControls() }
    func setOutputMuted(_ value: Bool) { setMute(outputID, scope: kAudioDevicePropertyScopeOutput, value: value); readControls() }
    func setInputMuted(_ value: Bool) { setMute(inputID, scope: kAudioDevicePropertyScopeInput, value: value); readControls() }

    private func loadDemo() {
        outputs = [SystemAudioDevice(id: 1, name: "Colunas do MacBook")]
        inputs = [SystemAudioDevice(id: 2, name: "Microfone do MacBook")]
        outputID = 1
        inputID = 2
        outputVolume = 0.65
        inputVolume = 0.8
        canSetOutputVolume = true
        canSetInputVolume = true
        canMuteOutput = true
        canMuteInput = true
    }

    private func readControls() {
        guard !Self.demo else { return }
        outputVolume = scalar(outputID, scope: kAudioDevicePropertyScopeOutput) ?? 0.5
        inputVolume = scalar(inputID, scope: kAudioDevicePropertyScopeInput) ?? 0.5
        outputMuted = mute(outputID, scope: kAudioDevicePropertyScopeOutput) ?? false
        inputMuted = mute(inputID, scope: kAudioDevicePropertyScopeInput) ?? false
        canSetOutputVolume = hasSettableScalar(outputID, scope: kAudioDevicePropertyScopeOutput)
        canSetInputVolume = hasSettableScalar(inputID, scope: kAudioDevicePropertyScopeInput)
        canMuteOutput = hasSettableMute(outputID, scope: kAudioDevicePropertyScopeOutput)
        canMuteInput = hasSettableMute(inputID, scope: kAudioDevicePropertyScopeInput)
    }

    private static func devices(scope: AudioObjectPropertyScope) -> [SystemAudioDevice] {
        var listAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioDeviceID>.size) else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard hasStreams(id, scope: scope), let name = deviceName(id) else { return nil }
            return SystemAudioDevice(id: id, name: name)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func hasStreams(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size >= UInt32(MemoryLayout<AudioStreamID>.size)
    }

    private static func deviceName(_ id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        // O Core Audio devolve uma CFString já retida (+1): recebe-se como Unmanaged e liberta-se uma vez.
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    private static func setDefaultDevice(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = id
        _ = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &value)
    }

    private func scalar(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Double? {
        guard id != 0, let value = readScalar(id, scope: scope, element: kAudioObjectPropertyElementMain) else { return nil }
        return Double(value)
    }

    private func readScalar(_ id: AudioDeviceID, scope: AudioObjectPropertyScope, element: AudioObjectPropertyElement) -> Float? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: scope, mElement: element)
        var value: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private func mute(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool? {
        guard id != 0 else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    private func setScalar(_ id: AudioDeviceID, scope: AudioObjectPropertyScope, value: Float) {
        guard id != 0 else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(id, &address) else { return }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(id, &address, &settable) == noErr, settable.boolValue else { return }
        var v = min(max(value, 0), 1)
        _ = AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Float>.size), &v)
    }

    private func setMute(_ id: AudioDeviceID, scope: AudioObjectPropertyScope, value: Bool) {
        guard id != 0 else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(id, &address), AudioObjectIsPropertySettable(id, &address, &settable) == noErr, settable.boolValue else { return }
        var v: UInt32 = value ? 1 : 0
        _ = AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
    }

    private func hasSettableScalar(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        guard id != 0 else { return false }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(id, &address) && AudioObjectIsPropertySettable(id, &address, &settable) == noErr && settable.boolValue
    }

    private func hasSettableMute(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        guard id != 0 else { return false }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(id, &address) && AudioObjectIsPropertySettable(id, &address, &settable) == noErr && settable.boolValue
    }
}
