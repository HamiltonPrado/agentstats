import Foundation
import Darwin
import IOKit

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
    var temperature: Double? = nil // °C
    var watts: Double? = nil       // a entrar ou a sair da bateria
    var systemWatts: Double? = nil // o Mac inteiro
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
