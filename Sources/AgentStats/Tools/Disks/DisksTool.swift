import AppKit
import Foundation

/// Um disco que se pode ejetar: externo, imagem de disco ou volume de rede.
struct Volume: Identifiable, Equatable, Sendable {
    var id: String { path }
    let name: String
    let path: String
    var total: UInt64?
    var free: UInt64?
    var network = false
}

enum DiskRules {
    /// Fica de fora o disco do Mac e os volumes do sistema; entra o que o Finder deixaria ejetar.
    static func isEjectable(path: String, ejectable: Bool, removable: Bool, onInternalDisk: Bool, local: Bool) -> Bool {
        guard path != "/", !path.hasPrefix("/System/Volumes") else { return false }
        return ejectable || removable || !onInternalDisk || !local
    }

    /// Saída de `lsof -F pc`: os nomes das apps com ficheiros abertos no disco, sem repetidos.
    static func blockers(lsofOutput: String) -> [String] {
        var names = Set<String>()
        for line in lsofOutput.split(separator: "\n") where line.first == "c" {
            let name = line.dropFirst().replacingOccurrences(of: "\\x20", with: " ")
            if !name.isEmpty { names.insert(name) }
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func blockedMessage(_ names: [String]) -> String {
        names.isEmpty ? "O disco está em uso. Fecha o que estiver a usá-lo e tenta outra vez."
            : String(localized: "Em uso por \(names.prefix(4).joined(separator: ", "))\(names.count > 4 ? " e mais \(names.count - 4)" : ""). Fecha e tenta outra vez.")
    }
}

@MainActor
final class DisksStore: ObservableObject {
    static let shared = DisksStore()

    @Published private(set) var volumes: [Volume] = []
    @Published private(set) var ejecting: Set<String> = []
    @Published private(set) var messages: [String: String] = [:]
    private var observing = false
    private var demo = false

    func start() {
        guard !demo else { return }
        refresh()
        guard !observing else { return }
        observing = true
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { DisksStore.shared.refresh() }
            }
        }
    }

    /// Um volume de rede pendurado pode demorar segundos a responder: lê-se fora do main thread.
    func refresh() {
        guard !demo else { return }
        Task {
            let found = await Blocking.run { DisksStore.readVolumes() }
            volumes = found
            messages = messages.filter { key, _ in found.contains { $0.path == key } }
        }
    }

    nonisolated static func readVolumes() -> [Volume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey,
                                      .volumeIsLocalKey, .volumeIsBrowsableKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable != false,
                  DiskRules.isEjectable(path: url.path, ejectable: v.volumeIsEjectable ?? false, removable: v.volumeIsRemovable ?? false,
                                        onInternalDisk: v.volumeIsInternal ?? true, local: v.volumeIsLocal ?? true) else { return nil }
            return Volume(name: v.volumeName ?? url.lastPathComponent, path: url.path,
                          total: v.volumeTotalCapacity.map { UInt64(max(0, $0)) },
                          free: v.volumeAvailableCapacity.map { UInt64(max(0, $0)) },
                          network: v.volumeIsLocal == false)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func eject(_ v: Volume) async {
        guard !demo, !ejecting.contains(v.path) else { return }
        ejecting.insert(v.path)
        messages[v.path] = nil
        let url = URL(fileURLWithPath: v.path)
        let error: String? = await Blocking.run {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        if error != nil {
            // Quem está a usá-lo: é o que se quer saber quando o macOS só diz "em uso".
            let found = await ToolRunner.run("/usr/sbin/lsof", ["-F", "pc", v.path], timeout: 20)
            messages[v.path] = DiskRules.blockedMessage(DiskRules.blockers(lsofOutput: found.out))
        }
        ejecting.remove(v.path)
        refresh()
    }

    func ejectAll() async {
        for v in volumes { await eject(v) }
    }

    func loadDemo() {
        demo = true
        volumes = [Volume(name: "Cópias", path: "/Volumes/Cópias", total: 2_000_000_000_000, free: 1_240_000_000_000),
                   Volume(name: "PEN", path: "/Volumes/PEN", total: 64_000_000_000, free: 51_000_000_000)]
        messages = ["/Volumes/Cópias": DiskRules.blockedMessage(["Pré-visualização"])]
    }
}
