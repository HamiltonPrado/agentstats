import Foundation
import Darwin
import IOKit

// MARK: - Models

struct CPUSample {
    var total: Double = 0      // 0...1
    var user: Double = 0
    var system: Double = 0
    var cores: [Double] = []
    var load: (Double, Double, Double) = (0, 0, 0)
}

struct MemorySample {
    var total: UInt64 = ProcessInfo.processInfo.physicalMemory
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0
    var free: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    var pressure: Int = 1      // 1 normal, 2 aviso, 4 crítico
    var used: UInt64 { app + wired + compressed }
    var usage: Double { total == 0 ? 0 : Double(used) / Double(total) }
}

struct NetworkSample {
    var downPerSec: Double = 0
    var upPerSec: Double = 0
    var totalDown: UInt64 = 0
    var totalUp: UInt64 = 0
    var localIP: String = "—"
    var interface: String = "—"
}

struct DiskSample {
    var total: UInt64 = 0
    var free: UInt64 = 0
    var readPerSec: Double = 0
    var writePerSec: Double = 0
    var used: UInt64 { total > free ? total - free : 0 }
    var usage: Double { total == 0 ? 0 : Double(used) / Double(total) }
}

struct BatterySample {
    var percent: Double = 0
    var isCharging = false
    var externalPower = false
    var minutesRemaining: Int? = nil
    var cycles: Int = 0
    var health: Double? = nil      // 0...1
    var temperature: Double? = nil // ºC
    var watts: Double? = nil
}

struct ProcSample: Identifiable {
    var id: Int { pid }
    let pid: Int
    let ppid: Int
    let cpu: Double
    let rssKB: UInt64
    let elapsed: String
    let name: String
    let args: String
}

// MARK: - Helpers

enum Sys {
    static func sysctlInt<T: FixedWidthInteger>(_ name: String, _ type: T.Type) -> T? {
        var value: T = 0
        var size = MemoryLayout<T>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    static var uptime: TimeInterval {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0 else { return 0 }
        return Date().timeIntervalSince1970 - Double(tv.tv_sec)
    }

    static func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Diretório de trabalho atual de um processo (via libproc).
    static func cwd(of pid: Int) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let r = proc_pidinfo(Int32(pid), PROC_PIDVNODEPATHINFO, 0, &info, size)
        guard r == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    static func number(_ any: Any?) -> NSNumber? { any as? NSNumber }
}

// MARK: - CPU

final class CPUReader {
    private var prev: [[UInt64]] = []

    func read() -> CPUSample {
        var numCPU: natural_t = 0
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPU, &info, &count) == KERN_SUCCESS,
              let info else { return CPUSample() }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(count) * MemoryLayout<integer_t>.stride))
        }

        var cur: [[UInt64]] = []
        for i in 0..<Int(numCPU) {
            let b = Int(CPU_STATE_MAX) * i
            cur.append([
                UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_USER)])),
                UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_SYSTEM)])),
                UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_IDLE)])),
                UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_NICE)])),
            ])
        }

        var s = CPUSample()
        var tUser = 0.0, tSys = 0.0, tAll = 0.0
        if prev.count == cur.count {
            for (c, p) in zip(cur, prev) {
                let d = zip(c, p).map { $0 >= $1 ? Double($0 - $1) : 0 }
                let all = d.reduce(0, +)
                let busy = d[0] + d[1] + d[3]
                s.cores.append(all > 0 ? busy / all : 0)
                tUser += d[0] + d[3]; tSys += d[1]; tAll += all
            }
        } else {
            s.cores = Array(repeating: 0, count: cur.count)
        }
        prev = cur
        if tAll > 0 {
            s.user = tUser / tAll
            s.system = tSys / tAll
            s.total = s.user + s.system
        }
        var l = [Double](repeating: 0, count: 3)
        getloadavg(&l, 3)
        s.load = (l[0], l[1], l[2])
        return s
    }
}

// MARK: - Memória

enum MemoryReader {
    static func read() -> MemorySample {
        var s = MemorySample()
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if r == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            let internalPages = UInt64(stats.internal_page_count)
            let purgeable = UInt64(stats.purgeable_count)
            s.app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
            s.wired = UInt64(stats.wire_count) * page
            s.compressed = UInt64(stats.compressor_page_count) * page
            s.cached = (UInt64(stats.external_page_count) + purgeable) * page
            s.free = UInt64(stats.free_count) * page
        }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            s.swapUsed = swap.xsu_used
            s.swapTotal = swap.xsu_total
        }
        s.pressure = Int(Sys.sysctlInt("kern.memorystatus_vm_pressure_level", Int32.self) ?? 1)
        return s
    }
}

// MARK: - Rede

final class NetworkReader {
    private var prev: [String: (UInt32, UInt32)] = [:]
    private var lastTime = Date()
    private var accDown: UInt64 = 0
    private var accUp: UInt64 = 0

    private func isPhysical(_ name: String) -> Bool {
        name.hasPrefix("en") || name.hasPrefix("pdp_ip")
    }

    func read() -> NetworkSample {
        var s = NetworkSample()
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return s }
        defer { freeifaddrs(ifaddr) }

        var cur: [String: (UInt32, UInt32)] = [:]
        var p = ifaddr
        while let a = p {
            let ifa = a.pointee
            let name = String(cString: ifa.ifa_name)
            if let addr = ifa.ifa_addr, isPhysical(name) {
                let family = Int32(addr.pointee.sa_family)
                if family == AF_LINK, let data = ifa.ifa_data {
                    let d = data.assumingMemoryBound(to: if_data.self).pointee
                    cur[name] = (d.ifi_ibytes, d.ifi_obytes)
                } else if family == AF_INET, s.localIP == "—", (ifa.ifa_flags & UInt32(IFF_UP)) != 0 {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        s.localIP = String(cString: host)
                        s.interface = name
                    }
                }
            }
            p = ifa.ifa_next
        }

        let now = Date()
        let dt = max(now.timeIntervalSince(lastTime), 0.001)
        var down: UInt64 = 0, up: UInt64 = 0
        for (name, c) in cur {
            guard let pv = prev[name] else { continue }
            // contadores de 32 bits podem dar a volta
            down += UInt64(c.0 &- pv.0)
            up += UInt64(c.1 &- pv.1)
        }
        if !prev.isEmpty {
            s.downPerSec = Double(down) / dt
            s.upPerSec = Double(up) / dt
            accDown += down; accUp += up
        }
        s.totalDown = accDown
        s.totalUp = accUp
        prev = cur
        lastTime = now
        return s
    }
}

// MARK: - Disco

final class DiskReader {
    private var prevRead: UInt64 = 0
    private var prevWrite: UInt64 = 0
    private var lastTime = Date()

    func read() -> DiskSample {
        var s = DiskSample()
        let url = URL(fileURLWithPath: "/")
        if let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) {
            s.total = UInt64(v.volumeTotalCapacity ?? 0)
            s.free = UInt64(v.volumeAvailableCapacityForImportantUsage ?? 0)
        }

        var rd: UInt64 = 0, wr: UInt64 = 0
        var iter: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iter) == KERN_SUCCESS {
            var svc = IOIteratorNext(iter)
            while svc != 0 {
                if let stats = IORegistryEntryCreateCFProperty(svc, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any] {
                    rd += Sys.number(stats["Bytes (Read)"])?.uint64Value ?? 0
                    wr += Sys.number(stats["Bytes (Write)"])?.uint64Value ?? 0
                }
                IOObjectRelease(svc)
                svc = IOIteratorNext(iter)
            }
            IOObjectRelease(iter)
        }
        let now = Date()
        let dt = max(now.timeIntervalSince(lastTime), 0.001)
        if prevRead > 0 {
            s.readPerSec = rd >= prevRead ? Double(rd - prevRead) / dt : 0
            s.writePerSec = wr >= prevWrite ? Double(wr - prevWrite) / dt : 0
        }
        prevRead = rd; prevWrite = wr; lastTime = now
        return s
    }
}

// MARK: - GPU

enum GPUReader {
    static func read() -> Double? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }
        var best: Double?
        var svc = IOIteratorNext(iter)
        while svc != 0 {
            if let perf = IORegistryEntryCreateCFProperty(svc, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
               let u = Sys.number(perf["Device Utilization %"])?.doubleValue {
                best = max(best ?? 0, u / 100)
            }
            IOObjectRelease(svc)
            svc = IOIteratorNext(iter)
        }
        return best
    }
}

// MARK: - Bateria

enum BatteryReader {
    static func read() -> BatterySample? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }

        var b = BatterySample()
        let cur = Sys.number(dict["CurrentCapacity"])?.doubleValue ?? 0
        let max = Sys.number(dict["MaxCapacity"])?.doubleValue ?? 100
        b.percent = max > 0 ? min(cur / max, 1) : 0
        b.isCharging = (dict["IsCharging"] as? Bool) ?? false
        b.externalPower = (dict["ExternalConnected"] as? Bool) ?? false
        if let t = Sys.number(dict["TimeRemaining"])?.intValue, t > 0, t < 65535 { b.minutesRemaining = t }
        b.cycles = Sys.number(dict["CycleCount"])?.intValue ?? 0
        if let raw = Sys.number(dict["AppleRawMaxCapacity"])?.doubleValue ?? Sys.number(dict["NominalChargeCapacity"])?.doubleValue,
           let design = Sys.number(dict["DesignCapacity"])?.doubleValue, design > 0 {
            b.health = min(raw / design, 1)
        }
        if let t = Sys.number(dict["Temperature"])?.doubleValue { b.temperature = t / 100 }
        if let mv = Sys.number(dict["Voltage"])?.int64Value, let ma = Sys.number(dict["Amperage"])?.int64Value {
            let amps = Double(Int32(truncatingIfNeeded: ma)) / 1000
            b.watts = abs(Double(mv) / 1000 * amps)
        }
        return b
    }
}

// MARK: - Processos

enum ProcessReader {
    /// Lista de processos (pid, ppid, %cpu, rss, tempo, nome, argumentos).
    static func read() -> [ProcSample] {
        // comm e args são lidos em chamadas separadas porque ambos podem ter espaços.
        let main = Sys.run("/bin/ps", ["-axo", "pid=,ppid=,pcpu=,rss=,etime=,comm="])
        let argsOut = Sys.run("/bin/ps", ["-axww", "-o", "pid=,args="])

        var argsByPid: [Int: String] = [:]
        for line in argsOut.split(separator: "\n") {
            let t = line.drop(while: { $0 == " " })
            guard let sp = t.firstIndex(of: " "), let pid = Int(t[..<sp]) else { continue }
            argsByPid[pid] = String(t[t.index(after: sp)...])
        }

        var out: [ProcSample] = []
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
            out.append(ProcSample(
                pid: pid,
                ppid: Int(fields[1]) ?? 0,
                cpu: Double(fields[2].replacingOccurrences(of: ",", with: ".")) ?? 0,
                rssKB: UInt64(fields[3]) ?? 0,
                elapsed: String(fields[4]),
                name: (comm as NSString).lastPathComponent,
                args: argsByPid[pid] ?? comm
            ))
        }
        return out
    }
}
