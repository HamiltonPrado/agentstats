import Foundation
import Darwin
import IOKit

enum BatteryReader {
    /// `SystemLoad` vem em miliwatts. Zero ou valores impossíveis num portátil contam como "sem leitura".
    static func systemWatts(telemetry: [String: Any]?) -> Double? {
        guard let mw = (telemetry?["SystemLoad"] as? NSNumber)?.doubleValue, mw > 0, mw < 500_000 else { return nil }
        return mw / 1000
    }

    /// 0...1. Até ao M4 as capacidades vêm no nível de cima; no M5 vêm dentro de `BatteryData`, e aí
    /// a nominal é a que se aproxima da "Capacidade máxima" das Definições do Sistema.
    static func health(properties: [String: Any]) -> Double? {
        func ratio(_ dict: [String: Any], _ keys: [String]) -> Double? {
            guard let design = (dict["DesignCapacity"] as? NSNumber)?.doubleValue, design > 0,
                  let full = keys.lazy.compactMap({ (dict[$0] as? NSNumber)?.doubleValue }).first, full > 0 else { return nil }
            return Swift.min(full / design, 1)
        }
        if let top = ratio(properties, ["AppleRawMaxCapacity", "NominalChargeCapacity"]) { return top }
        guard let nested = properties["BatteryData"] as? [String: Any] else { return nil }
        return ratio(nested, ["NominalChargeCapacity", "AppleRawMaxCapacity"])
    }

    static func read() -> BatterySample? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }

        var b = BatterySample()
        let cur = (dict["CurrentCapacity"] as? NSNumber)?.doubleValue ?? 0
        let max = (dict["MaxCapacity"] as? NSNumber)?.doubleValue ?? 100
        b.percent = max > 0 ? min(cur / max, 1) : 0
        b.isCharging = (dict["IsCharging"] as? Bool) ?? false
        b.externalPower = (dict["ExternalConnected"] as? Bool) ?? false
        if let t = (dict["TimeRemaining"] as? NSNumber)?.intValue, t > 0, t < 65535 { b.minutesRemaining = t }
        b.cycles = (dict["CycleCount"] as? NSNumber)?.intValue ?? 0
        b.health = health(properties: dict)
        if let t = (dict["Temperature"] as? NSNumber)?.doubleValue { b.temperature = t / 100 }
        if let mv = (dict["Voltage"] as? NSNumber)?.int64Value, let ma = (dict["Amperage"] as? NSNumber)?.int64Value {
            let amps = Double(Int32(truncatingIfNeeded: ma)) / 1000
            b.watts = abs(Double(mv) / 1000 * amps)
        }
        b.systemWatts = systemWatts(telemetry: dict["PowerTelemetryData"] as? [String: Any])
        return b
    }
}
