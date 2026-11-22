import AppKit
import CoreAudio
import Darwin

/// Leituras do Core Audio de que o mixer precisa. Nada aqui altera som nem pede permissões.
enum CoreAudioRead {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func value<T: BitwiseCopyable>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T? {
        var address = address(selector)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0) }
        return status == noErr ? value : nil
    }

    static func objects(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var address = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func defaultOutputUID() -> String? {
        guard let id = value(system, kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0)), id != 0 else { return nil }
        return string(id, kAudioDevicePropertyDeviceUID)
    }
}

/// Uma app com som, que pode ter vários processos (os browsers tocam num processo auxiliar).
struct MixerSource: Sendable, Equatable {
    let key: String
    let name: String
    /// De onde tirar o ícone (nil: processo sem .app).
    let appPath: String?
    var objects: [AudioObjectID]
    var playing: Bool
}

struct AudioProcessInfo: Sendable {
    let object: AudioObjectID
    let pid: pid_t
    /// O processo responsável: o Safari, para o som que sai do WebKit.
    let owner: pid_t
    let executable: String
    let ownerExecutable: String
    let playing: Bool
}

enum MixerDiscovery {
    private typealias ResponsibleFunction = @convention(c) (pid_t) -> pid_t
    /// Função privada do sistema. Se um dia desaparecer, cada processo fica por si e o resto funciona.
    private static let responsible: ResponsibleFunction? = {
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)   // RTLD_DEFAULT
        guard let symbol = dlsym(defaultHandle, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsibleFunction.self)
    }()

    static func owner(of pid: pid_t) -> pid_t {
        let answer = responsible?(pid) ?? pid
        return answer > 0 ? answer : pid
    }

    static func executable(_ pid: pid_t) -> String {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(decoding: buffer.prefix(Int(length)), as: UTF8.self) : ""
    }

    static func processes() -> [AudioProcessInfo] {
        CoreAudioRead.objects(CoreAudioRead.system, kAudioHardwarePropertyProcessObjectList).compactMap { object in
            guard let pid = CoreAudioRead.value(object, kAudioProcessPropertyPID, pid_t(0)), pid > 0 else { return nil }
            let owner = owner(of: pid)
            let path = executable(pid)
            return AudioProcessInfo(
                object: object, pid: pid, owner: owner, executable: path,
                ownerExecutable: owner == pid ? path : executable(owner),
                playing: (CoreAudioRead.value(object, kAudioProcessPropertyIsRunningOutput, UInt32(0)) ?? 0) != 0)
        }
    }

    /// Junta os processos por app. O próprio AgentStats fica sempre de fora (seria realimentação).
    static func group(_ processes: [AudioProcessInfo], ownPID: pid_t,
                      displayName: (String) -> String) -> [MixerSource] {
        var out: [String: MixerSource] = [:]
        for p in processes where p.pid != ownPID && p.owner != ownPID {
            let app = MixerMath.appPath(executable: p.ownerExecutable) ?? MixerMath.appPath(executable: p.executable)
            let key = app ?? p.executable
            guard !key.isEmpty else { continue }
            if var existing = out[key] {
                existing.objects.append(p.object)
                existing.playing = existing.playing || p.playing
                out[key] = existing
            } else {
                let name = app.map(displayName) ?? (key as NSString).lastPathComponent
                out[key] = MixerSource(key: key, name: name, appPath: app, objects: [p.object], playing: p.playing)
            }
        }
        return out.values
            .map { source in
                var sorted = source
                sorted.objects.sort()
                return sorted
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func sources() -> [MixerSource] {
        group(processes(), ownPID: getpid()) { path in
            let name = FileManager.default.displayName(atPath: path)
            return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        }
    }
}
