import SwiftUI
import AppKit

/// Tokens de hoje (Claude + Codex). Clicar abre os últimos 7 dias e os projetos que mais gastaram.
struct TodayUsage: View {
    let usage: UsageSnapshot
    @AppStorage("usage.expanded") private var expanded = false

    var body: some View {
        let t = usage.todayTotal
        VStack(alignment: .leading, spacing: DS.md) {
            Button { withAnimation(Motion.ease(0.2)) { expanded.toggle() } } label: {
                HStack(alignment: .firstTextBaseline, spacing: DS.sm) {
                    Text("Hoje").font(DS.body).foregroundStyle(Color.text2)
                    Text("\(Fmt.tokens(t.total)) tokens").font(DS.title.monospacedDigit())
                    if usage.todayCost >= 0.01 {
                        Text("~" + Fmt.usd(usage.todayCost)).font(DS.meta.monospacedDigit()).foregroundStyle(Color.text2)
                            .help("Quanto custaria na API, a preços públicos. Com um plano Pro/Max/Plus não é o que pagas.")
                    } else {
                        Text("\(Fmt.tokens(t.output)) de saída").font(DS.meta.monospacedDigit()).foregroundStyle(Color.text3)
                    }
                    Spacer(minLength: DS.xs)
                    Image(systemName: "chevron.right")
                        .font(DS.meta).foregroundStyle(Color.text3)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hoje, \(Fmt.tokens(t.total)) tokens" + (usage.todayCost >= 0.01 ? ", cerca de \(Fmt.usd(usage.todayCost)) em API" : ""))
            .accessibilityHint(expanded ? "Esconde a semana" : "Mostra os últimos 7 dias e os projetos")

            if expanded {
                week
                if !usage.projects.isEmpty { projects }
            }
        }
        .cardStyle(padding: DS.md)
        .help("Inclui leituras de cache (\(Fmt.tokens(t.cacheRead))), que são a maior parte e custam muito menos do que tokens novos. Entrada nova \(Fmt.tokens(t.input)) · cache escrita \(Fmt.tokens(t.cacheWrite)) · saída \(Fmt.tokens(t.output))")
    }

    /// Barras dos últimos 7 dias; hoje com a cor de destaque, os outros em neutro.
    private var week: some View {
        let maxTotal = max(usage.week.map(\.total.total).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: DS.sm) {
            HStack {
                Text("Últimos 7 dias").font(DS.meta).foregroundStyle(Color.text2)
                Spacer()
                Text(Fmt.tokens(usage.weekTotal.total) + " tokens" + (usage.weekCost >= 0.01 ? " · ~" + Fmt.usd(usage.weekCost) : ""))
                    .font(DS.meta.monospacedDigit()).foregroundStyle(Color.text3)
            }
            HStack(alignment: .bottom, spacing: DS.sm) {
                ForEach(Array(usage.week.enumerated()), id: \.offset) { i, d in
                    let isToday = i == usage.week.count - 1
                    VStack(spacing: DS.xs) {
                        Text(d.total.isEmpty ? "" : Fmt.tokens(d.total.total))
                            .font(.system(size: 9).monospacedDigit()).foregroundStyle(Color.text3)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(isToday ? Color.accentColor : Color.secondary.opacity(0.45))
                            .frame(height: max(2, 40 * Double(d.total.total) / Double(maxTotal)))
                        Text(Self.weekday(d.day)).font(DS.meta).foregroundStyle(isToday ? Color.primary : Color.text3)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(Self.weekday(d.day)): \(Fmt.tokens(d.total.total)) tokens")
                }
            }
            .frame(height: 72, alignment: .bottom)
        }
    }

    /// Projetos que mais gastaram na semana: lista com barras finas (não um segundo gráfico).
    private var projects: some View {
        let top = Array(usage.projects.prefix(5))
        let maxTotal = max(top.first?.usage.total ?? 1, 1)
        return VStack(alignment: .leading, spacing: DS.sm) {
            Text("Projetos esta semana").font(DS.meta).foregroundStyle(Color.text2)
            ForEach(top, id: \.name) { p in
                VStack(alignment: .leading, spacing: DS.xs) {
                    HStack {
                        Text(p.name.trimmingCharacters(in: .whitespaces)).font(DS.body).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: DS.sm)
                        Text(Fmt.tokens(p.usage.total)).font(DS.body.monospacedDigit()).foregroundStyle(Color.text2)
                        if p.cost >= 0.01 {
                            Text("~" + Fmt.usd(p.cost)).font(DS.body.monospacedDigit()).foregroundStyle(Color.text3)
                                .frame(minWidth: 56, alignment: .trailing)
                        }
                    }
                    Bar(value: Double(p.usage.total) / Double(maxTotal), color: .secondary.opacity(0.5), height: 2)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// "2026-11-19" → "qui" (abreviatura fixa de 3 letras, para as barras ficarem alinhadas)
    nonisolated static func weekday(_ day: String) -> String {
        let parse = DateFormatter()
        parse.dateFormat = "yyyy-MM-dd"
        guard let d = parse.date(from: day) else { return "" }
        let names = ["dom", "seg", "ter", "qua", "qui", "sex", "sáb"]
        return names[Calendar.current.component(.weekday, from: d) - 1]
    }
}
