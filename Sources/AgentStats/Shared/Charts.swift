import SwiftUI
import AppKit

struct Sparkline: View {
    @Environment(\.agentAccentColor) private var agentAccentColor
    let values: [Double]
    var maxValue: Double? = nil
    var color: Color? = nil
    var fill = true

    var body: some View {
        GeometryReader { g in
            let lineColor = color ?? agentAccentColor
            let mx = max(maxValue ?? (values.max() ?? 1), 0.0001)
            let pts = values.enumerated().map { i, v in
                CGPoint(x: g.size.width * CGFloat(i) / CGFloat(max(values.count - 1, 1)),
                        y: g.size.height * (1 - CGFloat(min(v / mx, 1))))
            }
            ZStack {
                if fill {
                    Path { p in
                        guard let f = pts.first, let l = pts.last else { return }
                        p.move(to: CGPoint(x: f.x, y: g.size.height))
                        pts.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: l.x, y: g.size.height))
                    }
                    .fill(lineColor.opacity(0.10))
                }
                Path { p in
                    guard let f = pts.first else { return }
                    p.move(to: f)
                    pts.dropFirst().forEach { p.addLine(to: $0) }
                }
                .stroke(lineColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Gráfico")
    }
}

struct Bar: View {
    let value: Double
    var color: Color = .secondary
    var height: CGFloat = 4
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(DS.raised)
                Capsule().fill(color).frame(width: max(height, g.size.width * CGFloat(min(max(value, 0), 1))))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)   // o valor está sempre escrito ao lado
    }
}

/// Gráfico do histórico guardado (até 7 dias), com o intervalo visível.
struct DayChart: View {
    let samples: [MinuteSample]
    let value: (MinuteSample) -> Double?
    var maxValue: Double
    let title: String
    let format: (Double) -> String

    /// Acima de 2 dias de minutos, desenha médias por hora: a forma é a mesma e o gráfico
    /// passa de até 10 080 pontos para 168 (é redesenhado a cada amostra com o painel aberto).
    nonisolated static func downsampled(_ values: [Double], maxPoints: Int = 2880, bucket: Int = 60) -> [Double] {
        guard values.count > maxPoints else { return values }
        return stride(from: 0, to: values.count, by: bucket).map { i in
            let chunk = values[i..<min(i + bucket, values.count)]
            return chunk.reduce(0, +) / Double(chunk.count)
        }
    }

    var body: some View {
        let vals = Self.downsampled(samples.compactMap(value))
        VStack(alignment: .leading, spacing: DS.xs) {
            HStack {
                Text(L(samples.count > 1440 ? "Últimos 7 dias" : "Histórico · até 7 dias")).font(DS.meta).foregroundStyle(Color.text2)
                Spacer()
                if let mx = vals.max() {
                    Text(String(localized: "máximo \(format(mx))")).font(DS.meta.monospacedDigit()).foregroundStyle(Color.text3)
                }
            }
            if vals.count > 1 {
                Sparkline(values: vals, maxValue: maxValue, color: .secondary).frame(height: 32)
                    .accessibilityLabel("\(title) no histórico de até sete dias")
                    .accessibilityValue(vals.max().map { String(localized: "máximo \(format($0))") } ?? "")
                HStack {
                    Text(L(samples.first.map { Self.hour($0.t) } ?? "")).font(DS.meta.monospacedDigit()).foregroundStyle(Color.text3)
                    Spacer()
                    Text("agora").font(DS.meta).foregroundStyle(Color.text3)
                }
                .accessibilityHidden(true)
            } else {
                Text("A recolher histórico, um ponto por minuto").font(DS.meta).foregroundStyle(Color.text3)
            }
        }
    }

    static func hour(_ t: TimeInterval) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: t))
    }
}
