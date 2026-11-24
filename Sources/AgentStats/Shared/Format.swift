import Foundation
import SwiftUI
import AppKit
import UserNotifications

enum Fmt {
    /// Bytes com vírgula decimal (pt-PT), igual ao resto da app: 10,24 GB
    static func bytes(_ b: UInt64) -> String {
        decimal(ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .memory))
    }
    /// Versão curta para espaços pequenos: 193 GB, 10 GB, 512 MB
    static func bytesShort(_ b: UInt64) -> String {
        let gb = Double(b) / 1_073_741_824
        if gb >= 1 { return num(gb, gb < 10 ? 1 : 0) + " GB" }
        return num(Double(b) / 1_048_576, 0) + " MB"
    }
    /// Espaço em disco, em múltiplos de 1000 como as Definições e o Finder: 250,79 GB
    /// (a RAM fica em múltiplos de 1024, também como no macOS).
    static func disk(_ b: UInt64) -> String {
        decimal(ByteCountFormatter.string(fromByteCount: Int64(clamping: b), countStyle: .file))
    }
    /// Versão curta do espaço em disco: 1,5 TB, 198 GB, 4,1 GB, 512 MB
    static func diskShort(_ b: UInt64) -> String {
        let gb: Double = Double(b) / 1_000_000_000
        if gb >= 999.5 { return num(gb / 1000, 1) + " TB" }
        if gb >= 1 { return num(gb, gb < 10 ? 1 : 0) + " GB" }
        return num(Double(b) / 1_000_000, 0) + " MB"
    }
    static func rate(_ bps: Double, short: Bool = false) -> String {
        let units = short ? ["B", "K", "M", "G"] : ["B/s", "KB/s", "MB/s", "GB/s"]
        var v = bps, i = 0
        while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
        let n = v >= 100 || i == 0 ? Fmt.num(v, 0) : Fmt.num(v, 1)
        return n + (short ? units[i] : " " + units[i])
    }
    /// Número com vírgula decimal (pt-PT), igual em todo o lado: 46,9 · 1,2 · 0,85
    static func num(_ v: Double, _ digits: Int) -> String {
        decimal(String(format: "%.\(digits)f", v))
    }
    /// Vírgula decimal em português, ponto em inglês.
    static func decimal(_ s: String) -> String { appIsEnglish ? s : s.replacingOccurrences(of: ".", with: ",") }
    /// Temperatura com o símbolo de grau correto: 46,9 °C
    static func temp(_ c: Double, _ digits: Int = 1) -> String { num(c, digits) + " °C" }
    static func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }
    /// 950 → "950"; 12 300 → "12,3k"; 4 560 000 → "4,6M"
    /// Dólares com vírgula decimal: "$0,42", "$12,40", "$1 234".
    static func usd(_ v: Double) -> String {
        if v < 0.01 { return decimal("<$0.01") }
        let f = NumberFormatter()
        f.locale = Locale(identifier: appIsEnglish ? "en_US" : "pt_PT")
        f.numberStyle = .decimal
        f.minimumFractionDigits = v < 100 ? 2 : 0
        f.maximumFractionDigits = v < 100 ? 2 : 0
        return "$" + (f.string(from: NSNumber(value: v)) ?? String(format: "%.2f", v))
    }

    static func tokens(_ n: Int) -> String {
        let d = Double(n)
        let s: String
        switch d {
        case ..<1000: return "\(n)"
        case ..<1_000_000: s = String(format: d < 10_000 ? "%.1fk" : "%.0fk", d / 1000)
        case ..<1_000_000_000: s = String(format: d < 10_000_000 ? "%.1fM" : "%.0fM", d / 1_000_000)
        default: s = String(format: "%.1fB", d / 1_000_000_000)
        }
        return decimal(s)
    }
    static func duration(_ t: TimeInterval) -> String {
        let s = Int(t)
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
    static func ago(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 5 { return "agora" }
        if s < 60 { return String(localized: "há \(s)s") }
        if s < 3600 { return String(localized: "há \(s / 60) min") }
        return String(localized: "há \(s / 3600)h")
    }
    /// "claude-opus-5-5" → "Opus 5.5"; "claude-sonnet-4-5-20250929" → "Sonnet 4.5"
    static func model(_ m: String?) -> String? {
        guard let m else { return nil }
        let parts = m.replacingOccurrences(of: "claude-", with: "").components(separatedBy: "-")
            .filter { !($0.count >= 8 && $0.allSatisfy(\.isNumber)) }
        let words = parts.filter { !$0.allSatisfy(\.isNumber) }.map { $0.capitalized }
        let version = parts.filter { $0.allSatisfy(\.isNumber) }.joined(separator: ".")
        return (words + (version.isEmpty ? [] : [version])).joined(separator: " ")
    }
    static func minutes(_ m: Int) -> String { m >= 60 ? String(localized: "\(m / 60)h \(m % 60)min") : String(localized: "\(m) min") }
    /// "02-22:16:01" (formato etime do ps) → "2d 22h"
    static func etime(_ e: String) -> String {
        var days = 0, rest = Substring(e)
        if let dash = e.firstIndex(of: "-") { days = Int(e[..<dash]) ?? 0; rest = e[e.index(after: dash)...] }
        let f = rest.split(separator: ":").compactMap { Int($0) }
        let (h, m, s) = f.count == 3 ? (f[0], f[1], f[2]) : (0, f.first ?? 0, f.count > 1 ? f[1] : 0)
        if days > 0 { return "\(days)d \(h)h" }
        if h > 0 { return String(localized: "\(h)h \(m)min") }
        if m > 0 { return "\(m)min" }
        return "\(s)s"
    }
}
