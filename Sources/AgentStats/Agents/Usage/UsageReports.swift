import Foundation

/// Orçamento de custo estimado: aviso aos 80% e aos 100%, uma vez por período.
enum Budget {
    static let enabledKey = "budget.enabled"
    static let amountKey = "budget.amount"
    static let periodKey = "budget.period"
    static let notifiedKey = "budget.notified"
    static let levels: [Double] = [80, 100]

    enum Period: String, CaseIterable, Identifiable {
        case day, week
        var id: String { rawValue }
        var title: String { self == .day ? "por dia" : "por semana" }
        var short: String { self == .day ? "hoje" : "esta semana" }
    }

    /// O dia de hoje, ou a semana do calendário (de segunda até hoje).
    static func spent(_ week: [DayUsage], period: Period, now: Date, calendar: Calendar = .current) -> Double {
        let today = day(now, calendar)
        switch period {
        case .day: return week.first { $0.day == today }?.cost ?? 0
        case .week:
            var cal = calendar
            cal.firstWeekday = 2
            guard let start = cal.dateInterval(of: .weekOfYear, for: now)?.start else { return 0 }
            let first = day(start, calendar)
            return week.filter { $0.day >= first && $0.day <= today }.reduce(0) { $0 + $1.cost }
        }
    }

    static func periodID(_ period: Period, now: Date, calendar: Calendar = .current) -> String {
        switch period {
        case .day: return "d" + day(now, calendar)
        case .week:
            var cal = calendar
            cal.firstWeekday = 2
            let c = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
            return "w\(c.yearForWeekOfYear ?? 0)-\(c.weekOfYear ?? 0)"
        }
    }

    /// O nível a avisar agora (nil se nenhum novo) e o que fica guardado ("período|nível").
    static func evaluate(spent: Double, amount: Double, period: String, notified: String?) -> (level: Double?, notified: String?) {
        guard amount > 0 else { return (nil, notified) }
        let pct = spent / amount * 100
        let parts = notified?.split(separator: "|")
        let last = parts?.count == 2 && String(parts![0]) == period ? Double(parts![1]) ?? -1 : -1
        guard let level = levels.last(where: { pct >= $0 }), level > last else { return (nil, notified) }
        return (level, "\(period)|\(Int(level))")
    }

    static func day(_ d: Date, _ calendar: Calendar) -> String { DayKey.string(d, timeZone: calendar.timeZone) }
}

/// Resumo da semana, por notificação, na primeira vez que a app corre numa semana nova (a partir das 9 h).
enum WeeklySummary {
    static let enabledKey = "summary.weekly"
    static let lastKey = "summary.lastWeek"

    static func due(now: Date, last: String?, calendar: Calendar = .current) -> String? {
        guard calendar.component(.hour, from: now) >= 9 else { return nil }
        let id = Budget.periodID(.week, now: now, calendar: calendar)
        return id == last ? nil : id
    }

    /// nil se a semana não teve uso: não vale a pena avisar.
    static func text(_ u: UsageSnapshot) -> (title: String, body: String)? {
        let total = u.weekTotal.total
        guard total > 0 else { return nil }
        var parts = [String(localized: "\(Fmt.tokens(total)) tokens")]
        if u.weekCost >= 0.01 { parts.append("~" + Fmt.usd(u.weekCost) + " em API") }
        if let top = u.projects.first, top.usage.total > 0 {
            parts.append(String(localized: "mais em \(top.name) (\(Int((Double(top.usage.total) / Double(total) * 100).rounded()))%)"))
        }
        if let busiest = u.week.max(by: { $0.total.total < $1.total.total }), busiest.total.total > 0 {
            parts.append(String(localized: "dia mais ativo: \(TodayUsage.weekday(busiest.day))"))
        }
        return ("A tua semana com os agentes", parts.joined(separator: " · "))
    }
}

/// Os últimos 7 dias e os projetos em CSV, para folhas de cálculo. Números com ponto decimal.
enum UsageCSV {
    static func make(_ u: UsageSnapshot) -> String {
        var lines = ["dia,claude_tokens,codex_tokens,outros_tokens,total_tokens,custo_usd"]
        for d in u.week {
            lines.append([d.day, "\(d.claude.total)", "\(d.codex.total)", "\(d.other.total)", "\(d.total.total)", money(d.cost)].joined(separator: ","))
        }
        lines.append("")
        lines.append("projeto,tokens,custo_usd")
        for p in u.projects { lines.append([field(p.name), "\(p.usage.total)", money(p.cost)].joined(separator: ",")) }
        return lines.joined(separator: "\n") + "\n"
    }

    static func money(_ v: Double) -> String { String(format: "%.4f", v) }

    /// Aspas à volta de quem tem vírgulas, aspas ou quebras; e nada que uma folha leia como fórmula.
    static func field(_ s: String) -> String {
        var v = s
        if let first = v.first, "=+-@".contains(first) { v = "'" + v }
        guard v.contains(where: { ",\"\n\r".contains($0) }) else { return v }
        return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// Exportar e importar as definições (não o histórico nem o estado dos avisos).
enum SettingsTransfer {
    static let prefixes = ["agents.", "alert.", "appearance.", "bar.", "budget.", "capture.", "cleaning.", "clock.", "files.",
                           "hotkey", "notify", "panel.", "power.", "proc.", "profiles.", "refreshInterval", "screen.",
                           "settings.", "summary.weekly", "system.", "tools.", "ui.", "updates.check", "usage."]
    static let excluded: Set<String> = ["alert.limits.notified", "budget.notified", "panel.tab2", "updates.lastCheck",
                                        "updates.notified", "welcome.shown", "summary.lastWeek",
                                        // Estado de uma gravação em curso neste Mac, não uma definição.
                                        "capture.recording.pid", "capture.recording.file"]

    static func filtered(_ all: [String: Any]) -> [String: Any] {
        all.filter { key, value in
            !excluded.contains(key) && prefixes.contains { key.hasPrefix($0) }
                && (value is String || value is NSNumber || value is Data || value is [String: Any] || value is [Any])
        }
    }

    static func data(_ all: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: filtered(all), format: .xml, options: 0)
    }

    static func read(_ data: Data) -> [String: Any]? {
        (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}
