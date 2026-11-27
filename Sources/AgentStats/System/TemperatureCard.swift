import SwiftUI

struct TemperatureCard: View {
    @Environment(\.agentAccentColor) private var agentAccentColor
    let t: TemperatureSample
    let history: [Double]
    let thermal: String
    var day: [MinuteSample] = []
    @StateObject private var expanded = Box(false)

    private func color(_ c: Double) -> Color { Palette.tempText(c) }

    var body: some View {
        Card(title: "Temperaturas", icon: "thermometer.medium", trailing: t.cpuMax.map { Fmt.temp($0, 0) }) {
            if history.count > 1 {
                Sparkline(values: history, maxValue: 110).frame(height: 48)
            }
            if let a = t.cpuAvg, let mx = t.cpuMax {
                StatRow(label: "CPU, média e máximo", value: Fmt.num(a, 1) + " · " + Fmt.temp(mx), valueColor: color(mx))
            }
            if let c = t.chipAvg { StatRow(label: "Chip", value: Fmt.temp(c), valueColor: color(c)) }
            if let s = t.ssd { StatRow(label: "SSD", value: Fmt.temp(s), valueColor: color(s)) }
            if let b = t.battery { StatRow(label: "Bateria", value: Fmt.temp(b), valueColor: color(b)) }
            StatRow(label: "Estado térmico", value: thermal.prefix(1).uppercased() + thermal.dropFirst())
            Divider().opacity(0.5)
            DayChart(samples: day, value: { $0.temp }, maxValue: 110, title: "Temperatura da CPU", format: { Fmt.temp($0, 0) })
            Button {
                withAnimation(Motion.ease(0.2)) { expanded.value.toggle() }
            } label: {
                HStack(spacing: DS.xs) {
                    Text(L(expanded.value ? "Esconder sensores" : String(localized: "Ver os \(t.sensors.count) sensores")))
                    Image(systemName: "chevron.down").rotationEffect(.degrees(expanded.value ? 180 : 0))
                }
                .font(DS.meta).modifier(AccentText())
            }
            .buttonStyle(.plain)
            if expanded.value {
                ForEach(Array(t.sensors.enumerated()), id: \.offset) { _, s in
                    StatRow(label: s.name, value: Fmt.temp(s.value))
                }
            }
        }
    }
}
