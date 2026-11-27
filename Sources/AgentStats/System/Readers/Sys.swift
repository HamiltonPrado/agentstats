import Foundation
import Darwin
import IOKit

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
        return string(buf)
    }

    /// Texto de um buffer C terminado em nulo (sem ler para além do array).
    static func string(_ chars: [CChar]) -> String {
        String(decoding: chars.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static var uptime: TimeInterval {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0 else { return 0 }
        return Date().timeIntervalSince1970 - Double(tv.tv_sec)
    }

    /// Corre na amostragem: com tempo limite, para um `ps` encravado nunca parar as métricas todas.
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 5) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        guard let r = ProcessRun.sync(p, timeout: timeout) else {
            Log.readers.error("Falha a lançar \(path, privacy: .public)")
            return ""
        }
        if r.timedOut { Log.readers.error("\(path, privacy: .public) não respondeu a tempo") }
        return String(decoding: r.out, as: UTF8.self)
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

    /// Texto de um array C de tamanho fixo. O kernel não garante o terminador nulo quando o nome
    /// ocupa o array todo, por isso lê no máximo o tamanho do array (nunca para além dele).
    static func fixedCString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self) }
    }
}
