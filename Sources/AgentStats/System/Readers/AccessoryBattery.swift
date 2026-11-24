import Foundation
import IOKit

/// Bateria de um acessório Bluetooth. Os AirPods têm várias (esquerdo, direito, estojo).
struct AccessoryBattery: Identifiable, Equatable, Sendable {
    var id: String { name + "|" + parts.map(\.label).joined(separator: ",") }
    let name: String
    let kind: String?          // "Headphones", "Mouse", "Keyboard"…
    let parts: [Part]

    struct Part: Equatable, Sendable {
        let label: String      // "" quando é só uma
        let percent: Int
    }

    var lowest: Int { parts.map(\.percent).min() ?? 100 }

    var symbol: String {
        switch kind?.lowercased() {
        case "headphones", "headset": "airpods"
        case "mouse": "computermouse"
        case "keyboard": "keyboard"
        case "trackpad": "rectangle.and.hand.point.up.left"
        case "gamepad": "gamecontroller"
        default: "dot.radiowaves.left.and.right"
        }
    }
}

enum AccessoryBatteryReader {
    /// `system_profiler SPBluetoothDataType -json`: só os ligados e com nível de bateria.
    static func parse(profiler data: Data) -> [AccessoryBattery] {
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sections = j["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        var out: [AccessoryBattery] = []
        for section in sections {
            for device in (section["device_connected"] as? [[String: Any]]) ?? [] {
                for (name, value) in device {
                    guard let info = value as? [String: Any] else { continue }
                    let fields: [(String, String)] = [("device_batteryLevelMain", ""), ("device_batteryLevel", ""),
                                                      ("device_batteryLevelLeft", "E"), ("device_batteryLevelRight", "D"),
                                                      ("device_batteryLevelCase", "Estojo")]
                    var parts: [AccessoryBattery.Part] = []
                    for (key, label) in fields {
                        if let p = percent(info[key]), !parts.contains(where: { $0.label == label }) { parts.append(.init(label: label, percent: p)) }
                    }
                    if !parts.isEmpty { out.append(AccessoryBattery(name: name, kind: info["device_minorType"] as? String, parts: parts)) }
                }
            }
        }
        return out
    }

    /// "80%" ou 80.
    static func percent(_ v: Any?) -> Int? {
        if let n = v as? NSNumber { return (0...100).contains(n.intValue) ? n.intValue : nil }
        guard let s = v as? String, let n = Int(s.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) else { return nil }
        return (0...100).contains(n) ? n : nil
    }

    /// Acessórios Apple (Magic Mouse, Keyboard, Trackpad): o IOKit tem a percentagem sem lançar processos.
    static func appleHID() -> [AccessoryBattery] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var out: [AccessoryBattery] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func prop(_ key: String) -> Any? { IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
            guard let p = percent(prop("BatteryPercent")), let name = prop("Product") as? String else { continue }
            let lower = name.lowercased()
            let kind = lower.contains("mouse") ? "Mouse" : lower.contains("trackpad") ? "Trackpad" : lower.contains("keyboard") ? "Keyboard" : nil
            out.append(AccessoryBattery(name: name, kind: kind, parts: [.init(label: "", percent: p)]))
        }
        return out
    }

    /// Junta as duas fontes; o mesmo nome só aparece uma vez.
    static func merged(_ a: [AccessoryBattery], _ b: [AccessoryBattery]) -> [AccessoryBattery] {
        var seen = Set<String>()
        return (a + b).filter { seen.insert($0.name.lowercased()).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

@MainActor
final class AccessoryBatteryStore: ObservableObject {
    static let shared = AccessoryBatteryStore()
    @Published private(set) var accessories: [AccessoryBattery] = []
    @Published private(set) var loaded = false
    private var demo = false

    func refresh() async {
        guard !demo else { return }
        let profiler = await ToolRunner.run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"], timeout: 20)
        let fromProfiler = AccessoryBatteryReader.parse(profiler: Data(profiler.out.utf8))
        let fromHID = await Task.detached { AccessoryBatteryReader.appleHID() }.value
        accessories = AccessoryBatteryReader.merged(fromProfiler, fromHID)
        loaded = true
    }

    func loadDemo() {
        demo = true
        loaded = true
        accessories = [
            AccessoryBattery(name: "AirPods Pro", kind: "Headphones", parts: [.init(label: "E", percent: 82), .init(label: "D", percent: 79), .init(label: "Estojo", percent: 45)]),
            AccessoryBattery(name: "Magic Mouse", kind: "Mouse", parts: [.init(label: "", percent: 18)]),
        ]
    }
}
