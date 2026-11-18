import SwiftUI
import AppKit

/// Substituto de @State (as Command Line Tools não incluem o plugin de macros do SwiftUI).
final class Box<T>: ObservableObject {
    @Published var value: T
    init(_ v: T) { value = v }
}

// MARK: - Sistema de design
//
// Direção: um painel de instrumentos à noite — atento, exato, discreto.
// Superfícies em grafite neutro (os materiais do macOS), uma só cor de destaque (a do sistema),
// e cor de estado apenas onde tem significado: verde a trabalhar, âmbar à espera, vermelho precisa de ti.

enum DS {
    // Espaçamento: grelha de 4
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16

    // Tipo: quatro tamanhos, pesos 400 e 500
    static let meta = Font.system(size: 11)
    static let body = Font.system(size: 12)
    static let title = Font.system(size: 13, weight: .medium)
    static let figure = Font.system(size: 20, weight: .medium).monospacedDigit()
    static let mono = Font.system(size: 11, design: .monospaced)

    // Raios (aninhados: interior = exterior − padding)
    static let rSmall: CGFloat = 6
    static let rControl: CGFloat = 8
    static let rCard: CGFloat = 12

    // Superfícies (passos do mesmo neutro) e linha fina
    static let surface = Color.primary.opacity(0.04)
    static let raised = Color.primary.opacity(0.08)
    static let hairline = Color.primary.opacity(0.08)
}

enum Palette {
    /// Cor de calor só quando há algo a assinalar; o normal fica neutro.
    static func heat(_ fraction: Double) -> Color { fraction > 0.85 ? .red : fraction > 0.7 ? .orange : .secondary }
    static func temp(_ c: Double) -> Color { c >= 90 ? .red : c >= 80 ? .orange : .secondary }
    static let working = Color.green
    static let waiting = Color.orange
    static let attention = Color.red
}

extension View {
    /// Cartão: superfície neutra com linha fina; `highlight` só para o que precisa de atenção.
    func cardStyle(padding: CGFloat = DS.md, highlight: Color? = nil) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.rCard, style: .continuous).fill(DS.surface))
            .overlay(
                RoundedRectangle(cornerRadius: DS.rCard, style: .continuous)
                    .strokeBorder(highlight ?? DS.hairline, lineWidth: 1)
            )
    }
}

/// O ponto de estado: a assinatura da app. Fixo, nunca pulsa.
struct StatusDot: View {
    let color: Color
    var size: CGFloat = 6
    var body: some View { Circle().fill(color).frame(width: size, height: size) }
}

struct Card<Content: View>: View {
    let title: String
    let icon: String
    var trailing: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            HStack(spacing: DS.sm) {
                Image(systemName: icon).font(DS.body).foregroundStyle(.secondary).frame(width: 16)
                Text(title).font(DS.title)
                Spacer()
                if let trailing {
                    Text(trailing).font(DS.body.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            content
        }
        .cardStyle()
    }
}

struct SectionHeader: View {
    let title: String
    var count: Int? = nil
    var color: Color? = nil
    var body: some View {
        HStack(spacing: DS.sm) {
            if let color { StatusDot(color: color) }
            Text(title).font(DS.meta.weight(.medium)).foregroundStyle(.secondary)
            if let count { Text("\(count)").font(DS.meta.monospacedDigit()).foregroundStyle(.tertiary) }
            Spacer()
        }
    }
}

struct Sparkline: View {
    let values: [Double]
    var maxValue: Double? = nil
    var color: Color = .accentColor
    var fill = true

    var body: some View {
        GeometryReader { g in
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
                    .fill(color.opacity(0.10))
                }
                Path { p in
                    guard let f = pts.first else { return }
                    p.move(to: f)
                    pts.dropFirst().forEach { p.addLine(to: $0) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
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
    }
}

struct StatRow: View {
    let label: String
    let value: String
    /// Amostra da legenda, quando a linha corresponde a uma série de um gráfico.
    var swatch: Color? = nil
    var valueColor: Color = .primary
    var body: some View {
        HStack(spacing: DS.sm) {
            if let swatch { RoundedRectangle(cornerRadius: 2).fill(swatch).frame(width: 8, height: 8) }
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: DS.sm)
            Text(value).monospacedDigit().foregroundStyle(valueColor)
        }
        .font(DS.body)
    }
}

struct IconButton: View {
    let systemName: String
    var help: String = ""
    let action: () -> Void
    @StateObject private var hover = Box(false)

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(DS.body)
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: DS.rSmall, style: .continuous)
                    .fill(hover.value ? DS.raised : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hover.value = $0 }
    }
}
