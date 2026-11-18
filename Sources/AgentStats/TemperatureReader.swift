import Foundation

/// Temperaturas lidas dos sensores HID do Apple Silicon (APIs privadas do IOKit, carregadas com dlsym).
struct TemperatureSample {
    var cpuAvg: Double?
    var cpuMax: Double?
    var chipAvg: Double?       // sensores "tdev" do SoC
    var ssd: Double?
    var battery: Double?
    var sensors: [(name: String, value: Double)] = []
}

final class TemperatureReader {
    private typealias Create = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatching = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias CopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyProperty = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    private typealias CopyEvent = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias GetFloat = @convention(c) (AnyObject, Int32) -> Double

    private static let temperatureType: Int64 = 15  // kIOHIDEventTypeTemperature

    private var copyServices: CopyServices?
    private var copyProperty: CopyProperty?
    private var copyEvent: CopyEvent?
    private var getFloat: GetFloat?
    private var client: AnyObject?
    private var services: [(service: AnyObject, name: String)] = []
    private var essential: [Int] = []
    private var reads = 0
    private var extraCache: [(name: String, value: Double)] = []

    init() {
        guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return }
        func sym<T>(_ n: String, _ t: T.Type) -> T? { dlsym(h, n).map { unsafeBitCast($0, to: t) } }
        guard let create = sym("IOHIDEventSystemClientCreate", Create.self),
              let setMatching = sym("IOHIDEventSystemClientSetMatching", SetMatching.self) else { return }
        copyServices = sym("IOHIDEventSystemClientCopyServices", CopyServices.self)
        copyProperty = sym("IOHIDServiceClientCopyProperty", CopyProperty.self)
        copyEvent = sym("IOHIDServiceClientCopyEvent", CopyEvent.self)
        getFloat = sym("IOHIDEventGetFloatValue", GetFloat.self)
        guard let c = create(kCFAllocatorDefault)?.takeRetainedValue() else { return }
        // PrimaryUsagePage 0xff00 / PrimaryUsage 5 = sensores de temperatura da Apple
        _ = setMatching(c, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        client = c
        refreshServices()
    }

    private func refreshServices() {
        guard let client, let copyServices, let copyProperty,
              let arr = copyServices(client)?.takeRetainedValue() as? [AnyObject] else { return }
        services = arr.compactMap { s in
            let name = (copyProperty(s, "Product" as CFString)?.takeRetainedValue() as? String) ?? "Sensor"
            // só os sensores mostrados (die, dispositivo, SSD, bateria); ignora calibração
            let useful = name.contains("tdie") || name.contains("tdev") || name.hasPrefix("NAND") || name.contains("battery")
            return useful ? (s, name) : nil
        }
        // Cada leitura custa ~1 ms por sensor. Essenciais: dies da CPU + 1 SSD + 1 bateria.
        // Os restantes (tdev, baterias duplicadas) só são lidos de vez em quando.
        var seen = Set<String>()
        essential = services.indices.filter { i in
            let n = services[i].name
            if n.contains("tdie") { return true }
            if n.hasPrefix("NAND") || n.contains("battery") { return seen.insert(n).inserted }
            return false
        }
    }

    var isAvailable: Bool { !services.isEmpty }

    func read() -> TemperatureSample? {
        guard let copyEvent, let getFloat, !services.isEmpty else { return nil }
        var s = TemperatureSample()
        var cpu: [Double] = [], chip: [Double] = [], ssd: [Double] = [], bat: [Double] = []
        reads += 1
        let full = reads % 5 == 1   // leitura completa (com sensores secundários) 1 vez em 5
        let indices = full ? Array(services.indices) : essential
        if !full {
            for x in extraCache { s.sensors.append(x); if x.name.contains("tdev") { chip.append(x.value) } }
        } else { extraCache = [] }
        for i in indices {
            let (svc, name) = services[i]
            guard let e = copyEvent(svc, Self.temperatureType, 0, 0)?.takeRetainedValue() else { continue }
            let v = getFloat(e, Int32(Self.temperatureType << 16))
            guard v > 0, v < 130, !name.contains("tcal") else { continue } // ignora calibração e leituras inválidas
            s.sensors.append((name, v))
            if full && !essential.contains(i) { extraCache.append((name, v)) }
            if name.contains("tdie") { cpu.append(v) }
            else if name.contains("tdev") { chip.append(v) }
            else if name.hasPrefix("NAND") { ssd.append(v) }
            else if name.contains("battery") { bat.append(v) }
        }
        func avg(_ a: [Double]) -> Double? { a.isEmpty ? nil : a.reduce(0, +) / Double(a.count) }
        s.cpuAvg = avg(cpu)
        s.cpuMax = cpu.max()
        s.chipAvg = avg(chip)
        s.ssd = ssd.max()
        s.battery = avg(bat)
        s.sensors.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return s
    }
}
