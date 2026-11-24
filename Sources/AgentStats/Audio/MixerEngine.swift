import CoreAudio
import Foundation
import os

// Volume por app com audio taps (macOS 14.2+):
//
//   app ──tap──▶ aparelho agregado privado ──ganho──▶ saída predefinida
//
// Regras de segurança:
// 1. A 100% não há tap: o som segue o caminho normal.
// 2. Sem permissão o tap entrega silêncio, sem erro. Por isso começa em `.unmuted` com a saída a zero
//    e só cala o original (`.mutedWhenTapped`) depois de ter recebido som a sério.
// 3. `.mutedWhenTapped` e objetos privados: se o AgentStats parar ou rebentar, o som original volta.
// 4. O microfone do aparelho de saída nunca é aberto: só o stream do tap fica ligado.

private let mixerLog = Logger(subsystem: "local.agentstats", category: "mixer")

enum MixerStatus: Sendable, Equatable {
    case normal        // a 100%, sem tap
    case checking      // a confirmar que chega áudio
    case noSignal      // a app toca mas só chega silêncio: quase sempre falta de permissão
    case active
    case failed(String)
}

struct MixerFailure: Error {
    let step: String
    let status: OSStatus
}

private func check(_ status: OSStatus, _ step: String) throws {
    guard status == noErr else { throw MixerFailure(step: step, status: status) }
}

/// Um tap, o seu aparelho agregado e o callback. Só é usado na fila do `MixerEngine`.
@available(macOS 14.2, *)
private final class TapSession {
    let deviceUID: String
    let renderer: MixerRenderer
    let createdAt = Date()
    private(set) var objects: [AudioObjectID]
    private(set) var muting: Bool

    private let uuid = UUID()
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    /// `verified`: já se recebeu som desta app, por isso pode calar o original logo (evita um salto de
    /// volume ao trocar de auscultadores).
    init(objects: [AudioObjectID], deviceUID: String, gain: Float, verified: Bool) throws {
        self.objects = objects
        self.deviceUID = deviceUID
        muting = verified
        renderer = MixerRenderer(target: gain, live: verified)
        do { try start() } catch {
            stop()
            throw error
        }
    }

    deinit { stop() }

    private func tapDescription(objects: [AudioObjectID], muting: Bool) -> CATapDescription {
        let d = CATapDescription(stereoMixdownOfProcesses: objects)
        d.uuid = uuid
        d.name = "AgentStats Mixer"
        d.isPrivate = true
        d.muteBehavior = muting ? .mutedWhenTapped : .unmuted
        return d
    }

    private func start() throws {
        try check(AudioHardwareCreateProcessTap(tapDescription(objects: objects, muting: muting), &tap), "criar o tap")

        guard let format = CoreAudioRead.value(tap, kAudioTapPropertyFormat, AudioStreamBasicDescription()),
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32,
              format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0 else {
            throw MixerFailure(step: "formato de áudio", status: kAudioHardwareUnspecifiedError)
        }

        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AgentStats Mixer",
            kAudioAggregateDeviceUIDKey: "local.agentstats.mixer.\(uuid.uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: deviceUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: uuid.uuidString,
                                               kAudioSubTapDriftCompensationKey: true]],
        ]
        try check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate), "criar o aparelho")
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, nil, renderer.makeIOBlock()), "ligar o áudio")
        guard let procID else { throw MixerFailure(step: "ligar o áudio", status: kAudioHardwareUnspecifiedError) }
        try disableDeviceInputs(procID)
        try check(AudioDeviceStart(aggregate, procID), "arrancar o áudio")
    }

    /// Deixa ligado só o último stream de entrada (o tap). Sem isto, um aparelho com entrada e saída
    /// abria o microfone: indicador aceso e, em Bluetooth, qualidade de chamada.
    private func disableDeviceInputs(_ procID: AudioDeviceIOProcID) throws {
        let count = CoreAudioRead.objects(aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput).count
        guard count > 1 else { return }
        guard let offset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn) else {
            throw MixerFailure(step: "desligar o microfone", status: kAudioHardwareUnspecifiedError)
        }
        let size = offset + count * MemoryLayout<UInt32>.size
        let memory = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { memory.deallocate() }
        memset(memory, 0, size)
        memory.storeBytes(of: unsafeBitCast(procID, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
        memory.storeBytes(of: UInt32(count), toByteOffset: offset - MemoryLayout<UInt32>.size, as: UInt32.self)
        memory.storeBytes(of: UInt32(1), toByteOffset: offset + (count - 1) * MemoryLayout<UInt32>.size, as: UInt32.self)
        var address = CoreAudioRead.address(kAudioDevicePropertyIOProcStreamUsage, scope: kAudioObjectPropertyScopeInput)
        try check(AudioObjectSetPropertyData(aggregate, &address, 0, nil, UInt32(size), memory), "desligar o microfone")
    }

    /// Muda processos ou silenciamento no tap que já existe, sem corte no som.
    func update(objects newObjects: [AudioObjectID], muting newMuting: Bool) -> Bool {
        var description = tapDescription(objects: newObjects, muting: newMuting)
        var address = CoreAudioRead.address(kAudioTapPropertyDescription)
        let status = withUnsafePointer(to: &description) {
            AudioObjectSetPropertyData(tap, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
        }
        guard status == noErr else { return false }
        objects = newObjects
        muting = newMuting
        return true
    }

    var running: Bool {
        (CoreAudioRead.value(aggregate, kAudioDevicePropertyDeviceIsRunning, UInt32(0)) ?? 0) != 0
    }

    func stop() {
        if let procID {
            AudioDeviceStop(aggregate, procID)
            AudioDeviceDestroyIOProcID(aggregate, procID)
        }
        procID = nil
        if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate) }
        aggregate = AudioObjectID(kAudioObjectUnknown)
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        tap = AudioObjectID(kAudioObjectUnknown)
    }
}

struct MixerSnapshot: Sendable {
    var sources: [MixerSource] = []
    var status: [String: MixerStatus] = [:]
}

/// Todo o estado vive numa fila própria: criar um aparelho demora, e o primeiro arranque pode ficar
/// à espera do pedido de permissão. O main thread nunca pode esperar por isso.
@available(macOS 14.2, *)
final class MixerEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.agentstats.mixer", qos: .userInitiated)
    private let publish: @Sendable (MixerSnapshot) -> Void

    private var targets: [String: Float] = [:]
    private var sessions: [String: TapSession] = [:]
    private var verified = Set<String>()
    private var waitingSince: [String: Date] = [:]
    private var neutralSince: [String: Date] = [:]
    private var failures: [String: (message: String, retry: Date)] = [:]
    private var timer: DispatchSourceTimer?
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init(publish: @escaping @Sendable (MixerSnapshot) -> Void) {
        self.publish = publish
    }

    func refresh() {
        queue.async { self.reconcile() }
    }

    func set(_ key: String, gain: Float) {
        queue.async {
            let isNew = self.targets[key] == nil
            if isNew && gain == 1 { return }
            self.targets[key] = gain
            if gain != 1 {
                self.neutralSince[key] = nil
            } else if self.neutralSince[key] == nil {
                self.neutralSince[key] = Date()
            }
            self.sessions[key]?.renderer.setTarget(gain)
            // Arrastar o slider só muda o ganho; criar ou remover taps fica para a reconciliação.
            if isNew { self.reconcile() }
        }
    }

    private func watch(_ active: Bool) {
        guard active != (timer != nil) else { return }
        if active {
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 0.25, repeating: 0.5, leeway: .milliseconds(100))
            t.setEventHandler { [weak self] in self?.reconcile() }
            t.resume()
            timer = t
            // Trocar de auscultadores ou abrir um processo novo não espera pelo temporizador.
            for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyProcessObjectList] {
                var address = CoreAudioRead.address(selector)
                let block: AudioObjectPropertyListenerBlock = { @Sendable [weak self] _, _ in self?.reconcile() }
                if AudioObjectAddPropertyListenerBlock(CoreAudioRead.system, &address, queue, block) == noErr {
                    listeners.append((address, block))
                }
            }
        } else {
            timer?.cancel()
            timer = nil
            for (stored, block) in listeners {
                var address = stored
                AudioObjectRemovePropertyListenerBlock(CoreAudioRead.system, &address, queue, block)
            }
            listeners.removeAll()
        }
    }

    private func reconcile() {
        let now = Date()
        // 100% durante 1 s: devolve o som ao caminho normal (passar pelo 100% a arrastar não conta).
        for (key, since) in neutralSince where now.timeIntervalSince(since) >= 1 {
            sessions.removeValue(forKey: key)?.stop()
            targets[key] = nil
            neutralSince[key] = nil
            waitingSince[key] = nil
            failures[key] = nil
        }
        watch(!targets.isEmpty)

        let sources = MixerDiscovery.sources()
        let byKey = Dictionary(sources.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let device = targets.isEmpty ? nil : CoreAudioRead.defaultOutputUID()
        var status: [String: MixerStatus] = [:]
        for (key, gain) in targets {
            status[key] = step(key, gain: gain, source: byKey[key], device: device, now: now)
        }
        publish(MixerSnapshot(sources: sources, status: status))
    }

    private func step(_ key: String, gain: Float, source: MixerSource?, device: String?, now: Date) -> MixerStatus {
        guard let source, let device else {
            sessions.removeValue(forKey: key)?.stop()
            waitingSince[key] = nil
            return .checking
        }
        if let session = sessions[key] {
            let deviceChanged = session.deviceUID != device
            let died = now.timeIntervalSince(session.createdAt) > 2 && !session.running
            let processesFailed = !deviceChanged && session.objects != source.objects
                && !session.update(objects: source.objects, muting: session.muting)
            // À espera de permissão: um tap criado antes de a dares pode continuar mudo, por isso recria-se.
            let staleProbe = !session.muting && source.playing
                && now.timeIntervalSince(session.createdAt) > 10 && !session.renderer.heard
            if deviceChanged || died || processesFailed || staleProbe {
                sessions.removeValue(forKey: key)?.stop()
            }
        }
        if sessions[key] == nil {
            if let failure = failures[key], now < failure.retry { return .failed(failure.message) }
            do {
                sessions[key] = try TapSession(objects: source.objects, deviceUID: device, gain: gain,
                                               verified: verified.contains(key))
                failures[key] = nil
            } catch {
                let failure = error as? MixerFailure
                let message = String(localized: "Não deu para \(failure?.step ?? "ligar") (erro \(failure?.status ?? 0))")
                mixerLog.error("\(message, privacy: .public)")
                failures[key] = (message, now.addingTimeInterval(3))
                return .failed(message)
            }
        }
        guard let session = sessions[key] else { return .checking }
        if session.muting { return .active }

        if session.renderer.heard {
            // Há áudio de verdade: só agora se cala o original.
            verified.insert(key)
            waitingSince[key] = nil
            if session.update(objects: session.objects, muting: true) {
                session.renderer.goLive()
                return .active
            }
            sessions.removeValue(forKey: key)?.stop()   // recria já verificado na próxima volta
            return .checking
        }
        guard source.playing else {
            waitingSince[key] = nil
            return .checking
        }
        let since = waitingSince[key] ?? now
        waitingSince[key] = since
        return now.timeIntervalSince(since) >= 4 ? .noSignal : .checking
    }
}
