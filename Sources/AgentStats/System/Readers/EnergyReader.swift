import Darwin
import Foundation

struct AppEnergy: Sendable, Equatable, Identifiable {
    var id: String
    var name: String
    var watts: Double
}

/// Energia gasta por app, pelo contador que o macOS mantém em cada processo (`ri_energy_nj`).
/// Sem sudo só se leem os processos do utilizador, e o ecrã não conta: é uma comparação entre apps,
/// não o consumo do Mac.
final class EnergyReader {
    /// O pid sozinho não chega: o sistema reutiliza-os.
    struct ProcessKey: Hashable {
        let pid: pid_t
        let start: UInt64
    }

    private var previous: [ProcessKey: UInt64] = [:]
    private var previousTime: ContinuousClock.Instant?
    private var apps: [ProcessKey: (id: String, name: String)] = [:]

    /// As apps que mais gastaram desde a leitura anterior (nil na primeira, que só serve de referência).
    func read(limit: Int = 5) -> [AppEnergy]? {
        let counters = Self.counters()
        // ContinuousClock: o intervalo conta também o tempo em suspensão.
        let now = ContinuousClock.now
        defer {
            previous = counters
            previousTime = now
            apps = apps.filter { counters[$0.key] != nil }
        }
        guard let previousTime else { return nil }
        let seconds = previousTime.duration(to: now) / .seconds(1)
        return Self.rank(previous: previous, current: counters, seconds: seconds, limit: limit) { key in
            if let known = apps[key] { return known }
            let app = Self.app(pid: key.pid)
            apps[key] = app
            return app
        }
    }

    static func rank(previous: [ProcessKey: UInt64], current: [ProcessKey: UInt64], seconds: Double, limit: Int,
                     app: (ProcessKey) -> (id: String, name: String)) -> [AppEnergy] {
        guard seconds > 0 else { return [] }
        var totals: [String: AppEnergy] = [:]
        for (key, energy) in current {
            guard let old = previous[key], energy > old else { continue }
            let (id, name) = app(key)
            totals[id, default: AppEnergy(id: id, name: name, watts: 0)].watts += Double(energy - old) / 1e9 / seconds
        }
        let visible = totals.values.filter { $0.watts >= 0.01 }
        return Array(visible.sorted { $0.watts > $1.watts }.prefix(limit))
    }

    private static func counters() -> [ProcessKey: UInt64] {
        let expected = proc_listallpids(nil, 0)
        guard expected > 0 else { return [:] }
        var pids = [pid_t](repeating: 0, count: Int(expected) + 64)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var out: [ProcessKey: UInt64] = [:]
        for pid in pids.prefix(max(count, 0)) where pid > 0 {
            var usage = rusage_info_v6()
            let status = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
            }
            if status == 0 { out[ProcessKey(pid: pid, start: usage.ri_proc_start_abstime)] = usage.ri_energy_nj }
        }
        return out
    }

    /// Os processos auxiliares contam para a app responsável por eles (como no mixer).
    private static func app(pid: pid_t) -> (id: String, name: String) {
        let own = MixerDiscovery.executable(pid)
        let owner = MixerDiscovery.executable(MixerDiscovery.owner(of: pid))
        if let path = MixerMath.appPath(executable: owner) ?? MixerMath.appPath(executable: own) {
            let name = FileManager.default.displayName(atPath: path)
            return (path, name.hasSuffix(".app") ? String(name.dropLast(4)) : name)
        }
        guard !own.isEmpty else { return ("pid:\(pid)", "Processo \(pid)") }
        return (own, (own as NSString).lastPathComponent)
    }
}
