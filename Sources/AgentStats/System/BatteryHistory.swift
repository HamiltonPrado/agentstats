import Foundation

/// Energia de cada app desde que o Mac saiu da corrente. Ligado à corrente fica como estava;
/// ao voltar à bateria recomeça. Só conta enquanto o AgentStats está aberto.
struct EnergySinceUnplug: Equatable {
    private(set) var since: Date?
    private(set) var onBattery = false
    private(set) var apps: [String: AppEnergy] = [:]

    mutating func add(_ readings: [AppEnergy], onBattery battery: Bool, now: Date) {
        defer { onBattery = battery }
        guard battery else { return }
        if !onBattery {
            since = now
            apps = [:]
        }
        for r in readings where r.joules > 0 {
            apps[r.id, default: AppEnergy(id: r.id, name: r.name, watts: 0)].joules += r.joules
        }
    }

    func top(_ limit: Int = 5) -> [AppEnergy] {
        Array(apps.values.filter { $0.joules >= 36 }.sorted { $0.joules > $1.joules }.prefix(limit))   // ≥ 0,01 Wh
    }

    static func demo(since: Date, apps: [AppEnergy], onBattery: Bool = true) -> EnergySinceUnplug {
        var e = EnergySinceUnplug()
        e.since = since
        e.onBattery = onBattery
        e.apps = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })
        return e
    }
}

/// Saúde e ciclos da bateria, uma leitura por dia.
struct BatteryDay: Codable, Equatable {
    var day: String      // yyyy-MM-dd (hora local)
    var health: Double?  // 0...1
    var cycles: Int
}

enum BatteryHistory {
    static let keepDays = 400
    /// Abaixo disto a comparação diz pouco.
    static let minimumSpan = 7

    static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentStats/battery-history.json")
    }

    static func dayString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f.string(from: d)
    }

    static func date(_ day: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f.date(from: day)
    }

    /// Junta a leitura de hoje (substitui a de hoje, se já houver). Os dias mais antigos saem.
    static func recording(_ days: [BatteryDay], health: Double?, cycles: Int, now: Date) -> [BatteryDay] {
        let today = dayString(now)
        var out = days.filter { $0.day != today }
        out.append(BatteryDay(day: today, health: health, cycles: cycles))
        out.sort { $0.day < $1.day }
        return Array(out.suffix(keepDays))
    }

    /// A leitura mais antiga e a mais recente, se distarem pelo menos `minimumSpan` dias.
    static func change(_ days: [BatteryDay]) -> (from: BatteryDay, to: BatteryDay, days: Int)? {
        guard let first = days.first, let last = days.last, let a = date(first.day), let b = date(last.day) else { return nil }
        let span = Calendar.current.dateComponents([.day], from: a, to: b).day ?? 0
        return span >= minimumSpan ? (first, last, span) : nil
    }

    static func load(from url: URL = file) -> [BatteryDay] {
        guard let data = try? Data(contentsOf: url), let days = try? JSONDecoder().decode([BatteryDay].self, from: data) else { return [] }
        return days.sorted { $0.day < $1.day }
    }

    static func save(_ days: [BatteryDay], to url: URL = file) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(days).write(to: url, options: .atomic)
        } catch {
            Log.readers.error("Não foi possível gravar o histórico da bateria: \(error.localizedDescription, privacy: .public)")
        }
    }
}
