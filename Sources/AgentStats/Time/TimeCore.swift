import Foundation

/// Temporizador simples ou Pomodoro (trabalho, pausa, e uma pausa longa a cada 4).
struct TimerPlan: Equatable, Sendable {
    enum Phase: String, Sendable { case timer, focus, shortBreak, longBreak }

    var phase: Phase
    var duration: TimeInterval
    /// Pomodoros de trabalho já terminados nesta série.
    var completedFocus = 0

    static let focus: TimeInterval = 25 * 60
    static let shortBreak: TimeInterval = 5 * 60
    static let longBreak: TimeInterval = 15 * 60
    static let focusPerLongBreak = 4

    var title: String {
        switch phase {
        case .timer: "Temporizador"
        case .focus: "Foco"
        case .shortBreak: "Pausa"
        case .longBreak: "Pausa longa"
        }
    }

    /// A fase seguinte do Pomodoro (nil num temporizador simples, que acaba aí).
    func next() -> TimerPlan? {
        switch phase {
        case .timer: return nil
        case .focus:
            let done = completedFocus + 1
            return done % Self.focusPerLongBreak == 0
                ? TimerPlan(phase: .longBreak, duration: Self.longBreak, completedFocus: done)
                : TimerPlan(phase: .shortBreak, duration: Self.shortBreak, completedFocus: done)
        case .shortBreak, .longBreak:
            return TimerPlan(phase: .focus, duration: Self.focus, completedFocus: completedFocus)
        }
    }

}

/// Fusos horários escolhidos e como mostrar cada um em relação à hora local.
enum WorldClock {
    static let key = "clock.zones"

    static func zones(_ raw: String?) -> [TimeZone] {
        (raw ?? "").split(separator: ",").compactMap { TimeZone(identifier: String($0)) }
    }

    static func encode(_ zones: [TimeZone]) -> String { zones.map(\.identifier).joined(separator: ",") }

    /// "Europe/Lisbon" → "Lisbon"; "America/Sao_Paulo" → "Sao Paulo".
    static func city(_ z: TimeZone) -> String {
        (z.identifier.split(separator: "/").last.map(String.init) ?? z.identifier).replacingOccurrences(of: "_", with: " ")
    }

    /// "+1 h", "−3 h 30", "mesma hora".
    static func offset(_ z: TimeZone, from local: TimeZone, at date: Date) -> String {
        let diff = z.secondsFromGMT(for: date) - local.secondsFromGMT(for: date)
        guard diff != 0 else { return "mesma hora" }
        let sign = diff > 0 ? "+" : "−"
        let h = abs(diff) / 3600, m = abs(diff) / 60 % 60
        return m == 0 ? "\(sign)\(h) h" : "\(sign)\(h) h \(String(format: "%02d", m))"
    }

    /// "ontem", "amanhã" ou nada, comparando o dia lá com o dia cá.
    static func dayNote(_ z: TimeZone, local: TimeZone, at date: Date) -> String? {
        var there = Calendar(identifier: .gregorian), here = Calendar(identifier: .gregorian)
        there.timeZone = z
        here.timeZone = local
        let a = there.dateComponents([.year, .month, .day], from: date), b = here.dateComponents([.year, .month, .day], from: date)
        guard let da = there.date(from: a), let db = there.date(from: b) else { return nil }
        let days = there.dateComponents([.day], from: db, to: da).day ?? 0
        return days > 0 ? "amanhã" : days < 0 ? "ontem" : nil
    }

    static func time(_ z: TimeZone, at date: Date) -> String { Fmt.hm(date, timeZone: z) }

    /// Procura por cidade ou identificador.
    static func search(_ text: String, in all: [String] = TimeZone.knownTimeZoneIdentifiers, limit: Int = 8) -> [TimeZone] {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }
        return all.filter { $0.replacingOccurrences(of: "_", with: " ").localizedStandardContains(q) }
            .prefix(limit).compactMap(TimeZone.init(identifier:))
    }
}
