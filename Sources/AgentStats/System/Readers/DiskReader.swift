import Foundation
import Darwin
import IOKit

final class DiskReader {
    private var prevRead: UInt64 = 0
    private var prevWrite: UInt64 = 0
    private var lastTime = Date()
    private var space: (total: UInt64, free: UInt64, at: Date) = (0, 0, .distantPast)

    func read() -> DiskSample {
        var s = DiskSample()
        // O espaço livre "importante" passa pelo serviço CacheDelete do macOS, que é caro: lê de 30 em 30 s.
        if Date().timeIntervalSince(space.at) > 30 {
            let url = URL(fileURLWithPath: "/")
            if let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) {
                space = (UInt64(v.volumeTotalCapacity ?? 0), UInt64(v.volumeAvailableCapacityForImportantUsage ?? 0), Date())
            }
        }
        s.total = space.total
        s.free = space.free

        var rd: UInt64 = 0, wr: UInt64 = 0
        var iter: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iter) == KERN_SUCCESS {
            var svc = IOIteratorNext(iter)
            while svc != 0 {
                if let stats = IORegistryEntryCreateCFProperty(svc, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any] {
                    rd += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                    wr += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
                }
                IOObjectRelease(svc)
                svc = IOIteratorNext(iter)
            }
            IOObjectRelease(iter)
        }
        let now = Date()
        let dt = max(now.timeIntervalSince(lastTime), 0.001)
        if prevRead > 0 {
            s.readPerSec = Self.rate(now: rd, before: prevRead, seconds: dt)
            s.writePerSec = Self.rate(now: wr, before: prevWrite, seconds: dt)
        }
        prevRead = rd; prevWrite = wr; lastTime = now
        return s
    }

    /// Bytes por segundo entre duas leituras. Um contador que recua (disco desligado) dá zero.
    static func rate(now: UInt64, before: UInt64, seconds: Double) -> Double {
        now >= before ? Double(now - before) / seconds : 0
    }
}
