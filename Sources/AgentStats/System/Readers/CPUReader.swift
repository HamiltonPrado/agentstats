import Foundation
import Darwin
import IOKit

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

        var s = Self.sample(current: cur, previous: prev)
        prev = cur
        var l = [Double](repeating: 0, count: 3)
        getloadavg(&l, 3)
        s.load = (l[0], l[1], l[2])
        return s
    }

    /// Utilização entre duas leituras dos contadores de cada núcleo (user, system, idle, nice).
    /// Sem leitura anterior compatível, tudo a zero. A carga média fica de fora.
    static func sample(current cur: [[UInt64]], previous prev: [[UInt64]]) -> CPUSample {
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
        if tAll > 0 {
            s.user = tUser / tAll
            s.system = tSys / tAll
            s.total = s.user + s.system
        }
        return s
    }
}
