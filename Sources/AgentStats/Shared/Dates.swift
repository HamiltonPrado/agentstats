import Foundation

/// A chave de um dia, "2026-11-26", igual em toda a app: o uso, o orçamento, a bateria e o tempo por app
/// comparam estas chaves como texto, por isso têm de vir todas do mesmo sítio.
/// Calendário gregoriano e algarismos ASCII sempre (o calendário do utilizador pode ser outro),
/// no fuso horário atual de cada vez (depois de uma viagem, "hoje" muda com o Mac).
enum DayKey {
    private static func calendar(_ zone: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal
    }

    static func string(_ date: Date, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let c = calendar(timeZone).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// O início desse dia.
    static func date(_ key: String, timeZone: TimeZone = .autoupdatingCurrent) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, key.count == 10 else { return nil }
        return calendar(timeZone).date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

/// Datas ISO 8601 dos ficheiros dos agentes, com ou sem frações de segundo (cada agente escreve à sua maneira).
/// O `ISO8601DateFormatter` é seguro entre threads (documentado pela Apple); a classe só o embrulha.
final class ISODate: @unchecked Sendable {
    static let shared = ISODate()

    private let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    func parse(_ s: String) -> Date? {
        fractional.date(from: s) ?? plain.date(from: s)
    }
}

extension Fmt {
    /// "14:05" no fuso dado, sem criar um DateFormatter a cada chamada (isto corre dentro de `body`).
    static func hm(_ date: Date, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// "4:05" ou "1:02:03": a contagem dos temporizadores, das gravações e da partilha.
    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}
