import SwiftUI
import AppKit

/// Limites do plano de cada agente: % gasta de cada janela e quando renova.
struct PlanLimitsCard: View {
    let limits: [PlanLimits]
    var hint: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: DS.md) {
            ForEach(Array(limits.enumerated()), id: \.offset) { i, l in
                if i > 0 { Divider().opacity(0.5) }
                VStack(alignment: .leading, spacing: DS.sm) {
                    HStack(spacing: DS.xs) {
                        Text(L(l.provider.rawValue)).font(DS.body.weight(.medium))
                        if let plan = l.plan { Text("· " + plan).font(DS.body).foregroundStyle(Color.text2) }
                        Spacer(minLength: DS.xs)
                        Text(L(Fmt.ago(l.observedAt))).font(DS.meta).foregroundStyle(Color.text3)
                            .help("Última leitura dos limites")
                    }
                    ForEach(l.windows) { w in row(w) }
                }
            }
            if let hint {
                if !limits.isEmpty { Divider().opacity(0.5) }
                Label(L(hint), systemImage: "info.circle").font(DS.meta).foregroundStyle(Color.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .cardStyle(padding: DS.md)
    }

    private func row(_ w: LimitWindow) -> some View {
        let fraction = w.usedPercent / 100
        let textColor: Color = fraction >= 0.9 ? .attentionText : fraction >= 0.75 ? .waitingText : .primary
        let color: Color = fraction >= 0.9 ? Palette.attention : fraction >= 0.75 ? Palette.waiting : .accentColor
        let now = Date()
        let runsOut: Date? = LimitForecast.runsOut(w, now: now)
        return VStack(alignment: .leading, spacing: DS.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DS.xs) {
                Text(L(w.label)).font(DS.body)
                if let r = w.resetsAt {
                    Text(String(localized: "· renova \(Self.resetText(r, now: Date()))")).font(DS.meta).foregroundStyle(Color.text3).lineLimit(1)
                }
                Spacer(minLength: DS.sm)
                Text(L(Fmt.num(w.usedPercent, 0) + "%")).font(DS.body.monospacedDigit())
                    .foregroundStyle(textColor)
            }
            Bar(value: fraction, color: color, height: 4)
            if let end = runsOut {
                Text(String(localized: "A este ritmo acaba \(Self.resetText(end, now: now)), antes de renovar"))
                    .font(DS.meta).foregroundStyle(Color.waitingText).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L(Self.spoken(w, runsOut: runsOut, now: now)))
    }

    private static func spoken(_ w: LimitWindow, runsOut: Date?, now: Date) -> String {
        var text = String(localized: "\(w.label): \(Fmt.num(w.usedPercent, 0))% usado")
        if let r = w.resetsAt { text += String(localized: ", renova \(resetText(r, now: now))") }
        if let end = runsOut { text += String(localized: ", a este ritmo acaba \(resetText(end, now: now))") }
        return text
    }

    /// "às 14:30" hoje, "amanhã às 09:00", "qui 09:00" nesta semana, "2 dez" mais longe.
    nonisolated static func resetText(_ d: Date, now: Date) -> String {
        let cal = Calendar.current
        let hm = DateFormatter()
        hm.dateFormat = "HH:mm"
        let time = hm.string(from: d)
        if cal.isDate(d, inSameDayAs: now) { return String(localized: "às \(time)") }
        if let t = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(d, inSameDayAs: t) { return String(localized: "amanhã às \(time)") }
        if d.timeIntervalSince(now) < 6 * 86_400 {
            let names = ["dom", "seg", "ter", "qua", "qui", "sex", "sáb"]
            return L(names[cal.component(.weekday, from: d) - 1]) + " " + time
        }
        let months = ["jan", "fev", "mar", "abr", "mai", "jun", "jul", "ago", "set", "out", "nov", "dez"]
        return "\(cal.component(.day, from: d)) \(L(months[cal.component(.month, from: d) - 1]))"
    }
}
