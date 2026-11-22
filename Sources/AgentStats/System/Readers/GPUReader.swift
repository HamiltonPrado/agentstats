import Foundation
import Darwin
import IOKit

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
