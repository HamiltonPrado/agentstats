import Foundation
import Darwin
import IOKit

enum MemoryReader {
    private static let pageSize = UInt64(sysconf(_SC_PAGESIZE))

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
            let pages = Pages(anonymous: UInt64(stats.internal_page_count), purgeable: UInt64(stats.purgeable_count),
                              wired: UInt64(stats.wire_count), compressor: UInt64(stats.compressor_page_count),
                              external: UInt64(stats.external_page_count), free: UInt64(stats.free_count))
            Self.apply(pages, pageSize: Self.pageSize, to: &s)
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

    /// Contagens de páginas, tal como o `host_statistics64` as dá.
    struct Pages {
        var anonymous: UInt64
        var purgeable: UInt64
        var wired: UInt64
        var compressor: UInt64
        var external: UInt64
        var free: UInt64
    }

    /// As purgáveis saem das apps e contam em cache: o sistema pode tirá-las quando quiser.
    static func apply(_ p: Pages, pageSize page: UInt64, to s: inout MemorySample) {
        s.app = (p.anonymous > p.purgeable ? p.anonymous - p.purgeable : 0) * page
        s.wired = p.wired * page
        s.compressed = p.compressor * page
        s.cached = (p.external + p.purgeable) * page
        s.free = p.free * page
    }
}
