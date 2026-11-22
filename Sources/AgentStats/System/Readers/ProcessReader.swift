import Foundation
import Darwin
import IOKit

enum ProcessReader {
    /// Nomes cujos argumentos interessam (para identificar agentes que correm em node/python, e o papel do Codex).
    static let argsWanted: Set<String> = ["node", "bun", "deno", "codex", "claude", "gemini", "gemini-cli", "agy", "antigravity", "python", "python3", "Python"]

    /// Lista de processos (pid, ppid, %cpu, rss, tempo, nome). Uma única chamada ao `ps` (que tem privilégios
    /// para ler processos de sistema); os argumentos só são lidos via sysctl para os poucos processos que importam.
    static func read() -> [ProcSample] {
        let main = Sys.run("/bin/ps", ["-axo", "pid=,ppid=,pcpu=,rss=,etime=,comm="])
        var out: [ProcSample] = []
        out.reserveCapacity(900)
        for line in main.split(separator: "\n") {
            var rest = Substring(line)
            var fields: [Substring] = []
            for _ in 0..<5 {
                rest = rest.drop(while: { $0 == " " })
                guard let sp = rest.firstIndex(of: " ") else { break }
                fields.append(rest[..<sp])
                rest = rest[sp...]
            }
            guard fields.count == 5, let pid = Int(fields[0]) else { continue }
            let comm = rest.trimmingCharacters(in: .whitespaces)
            let name = (comm as NSString).lastPathComponent
            let wantsArgs = argsWanted.contains(name) || name.hasPrefix("python")
            out.append(ProcSample(
                pid: pid,
                ppid: Int(fields[1]) ?? 0,
                cpu: Double(fields[2].replacingOccurrences(of: ",", with: ".")) ?? 0,
                rssKB: UInt64(fields[3]) ?? 0,
                elapsed: String(fields[4]),
                name: name,
                args: wantsArgs ? (arguments(of: pid) ?? comm) : comm
            ))
        }
        return out
    }

    /// Linha de comandos de um processo via sysctl KERN_PROCARGS2 (sem lançar processos).
    static func arguments(of pid: Int) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return nil }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = 4
        while i < size && buf[i] != 0 { i += 1 }   // caminho do executável
        while i < size && buf[i] == 0 { i += 1 }   // padding
        var args: [String] = []
        var start = i
        while i < size && args.count < argc {
            if buf[i] == 0 {
                args.append(String(decoding: buf[start..<i], as: UTF8.self))
                start = i + 1
            }
            i += 1
        }
        return args.isEmpty ? nil : args.joined(separator: " ")
    }
}

/// Os processos do utilizador (onde vivem os agentes) são lidos a cada amostra via libproc, sem lançar
/// processos. Os de sistema (root), que a libproc não deixa ler, vêm do `ps` só de 3 em 3 amostras.
final class ProcessSampler {
    private var prevTimes: [Int32: UInt64] = [:]
    private var prevWall: UInt64 = 0
    private var psCache: [ProcSample] = []
    private var argsCache: [Int32: (start: UInt64, args: String)] = [:]
    private var tick = 0

    func read() -> [ProcSample] {
        tick += 1
        if tick % 5 == 1 || psCache.isEmpty { psCache = ProcessReader.read() }  // ps de 10 em 10 s

        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return psCache }
        var pids = [Int32](repeating: 0, count: Int(n) + 64)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size)))
        let alive = Set(pids.prefix(count).filter { $0 > 0 })

        let now = mach_absolute_time()
        let dWall = prevWall > 0 ? Double(now - prevWall) : 0
        var times: [Int32: UInt64] = [:]
        var fresh: [Int: ProcSample] = [:]
        let nowSec = UInt64(Date().timeIntervalSince1970)

        for pid in alive {
            // uma só chamada devolve bsdinfo + taskinfo
            var all = proc_taskallinfo()
            guard proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &all, Int32(MemoryLayout<proc_taskallinfo>.size)) > 0 else { continue }
            let bi = all.pbsd, ti = all.ptinfo
            // Em Apple Silicon os tempos da tarefa vêm em unidades mach, tal como mach_absolute_time.
            let total = ti.pti_total_user + ti.pti_total_system
            times[pid] = total
            var cpu = 0.0
            if dWall > 0, let p = prevTimes[pid], total >= p { cpu = Double(total - p) / dWall * 100 }

            var name = Self.fixedCString(bi.pbi_name)
            if name.isEmpty { name = Self.fixedCString(bi.pbi_comm) }
            var args = name
            if ProcessReader.argsWanted.contains(name) || name.hasPrefix("python") {
                if let c = argsCache[pid], c.start == bi.pbi_start_tvsec { args = c.args }
                else if let a = ProcessReader.arguments(of: Int(pid)) {
                    args = a; argsCache[pid] = (bi.pbi_start_tvsec, a)
                }
            }
            fresh[Int(pid)] = ProcSample(
                pid: Int(pid), ppid: Int(bi.pbi_ppid), cpu: cpu,
                rssKB: ti.pti_resident_size / 1024,
                elapsed: Self.etime(nowSec > bi.pbi_start_tvsec ? nowSec - bi.pbi_start_tvsec : 0),
                name: name, args: args)
        }
        prevTimes = times
        prevWall = now
        argsCache = argsCache.filter { alive.contains($0.key) }

        // Junta: dados frescos da libproc por cima do último `ps`; descarta processos que já terminaram.
        var out = psCache.compactMap { p -> ProcSample? in
            guard alive.contains(Int32(p.pid)) else { return nil }
            if let f = fresh.removeValue(forKey: p.pid) {
                // na primeira amostra a libproc ainda não tem %CPU: mantém o do ps
                return dWall > 0 ? f : ProcSample(pid: f.pid, ppid: f.ppid, cpu: p.cpu, rssKB: f.rssKB, elapsed: f.elapsed, name: p.name, args: f.args)
            }
            return p
        }
        out.append(contentsOf: fresh.values)
        return out
    }

    /// Texto de um array C de tamanho fixo. O kernel não garante o terminador nulo quando o nome
    /// ocupa o array todo, por isso lê no máximo o tamanho do array (nunca para além dele).
    static func fixedCString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self) }
    }

    /// Formato igual ao `etime` do ps: [DD-]HH:MM:SS
    static func etime(_ s: UInt64) -> String {
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60, sec = s % 60
        let hms = String(format: "%02d:%02d:%02d", h, m, sec)
        return d > 0 ? String(format: "%02d-", d) + hms : hms
    }
}
