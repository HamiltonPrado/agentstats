import SwiftUI
import AppKit

/// Atividade dos agentes nas últimas 24 h, em blocos de 10 minutos.
struct ActivityStrip: View {
    @Environment(\.agentAccentColor) private var agentAccentColor
    let day: [MinuteSample]

    var body: some View {
        let now = Date()
        let cutoff = now.timeIntervalSince1970 - History24h.activityWindow
        let recent = day.filter { $0.t >= cutoff }
        let buckets = History24h.buckets(recent, now: now)
        let active = History24h.activeMinutes(recent, now: now)
        VStack(alignment: .leading, spacing: DS.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("Últimas 24 h").font(DS.body).foregroundStyle(Color.text2)
                Spacer()
                Text(active > 0 ? String(localized: "agentes ativos \(Fmt.minutes(active))") : L("sem atividade"))
                    .font(DS.meta.monospacedDigit()).foregroundStyle(Color.text3)
            }
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(Array(buckets.enumerated()), id: \.offset) { _, b in
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 1)
                            .fill(b.attention ? Palette.attention.opacity(0.8) : (b.working > 0 ? agentAccentColor : DS.raised))
                            .frame(height: b.working > 0 ? max(3, 20 * b.working) : 2)
                    }
                }
            }
            .frame(height: 20)
            .accessibilityHidden(true)
            HStack {
                Text(L(DayChart.hour(buckets.first?.start ?? Date().timeIntervalSince1970))).font(DS.meta.monospacedDigit())
                Spacer()
                Text("agora").font(DS.meta)
            }
            .foregroundStyle(Color.text3)
            .accessibilityHidden(true)
        }
        .cardStyle()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(active > 0 ? String(localized: "Atividade dos agentes nas últimas 24 horas: \(Fmt.minutes(active)) com agentes a trabalhar")
                                : L("Atividade dos agentes nas últimas 24 horas: sem atividade"))
    }
}
