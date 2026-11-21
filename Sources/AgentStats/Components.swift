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

enum PanelDensity: String, CaseIterable, Identifiable {
    case compact, normal, detailed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .compact: "Compacto"
        case .normal: "Normal"
        case .detailed: "Detalhado"
        }
    }
}

enum PanelTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "Sistema"
        case .light: "Claro"
        case .dark: "Escuro"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

private struct AgentAccentColorKey: EnvironmentKey {
    static let defaultValue = Color.accentColor
}

extension EnvironmentValues {
    var agentAccentColor: Color {
        get { self[AgentAccentColorKey.self] }
        set { self[AgentAccentColorKey.self] = newValue }
    }
}

extension Color {
    init(hexRGB: String) {
        let cleaned = hexRGB.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else {
            self = .blue
            return
        }
        self.init(.sRGB,
                  red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255,
                  opacity: 1)
    }

    var hexRGB: String {
        let rgb = NSColor(self).usingColorSpace(.deviceRGB) ?? .systemBlue
        func channel(_ value: CGFloat) -> Int {
            Int((min(max(value, 0), 1) * 255).rounded())
        }
        return String(format: "#%02X%02X%02X",
                      channel(rgb.redComponent), channel(rgb.greenComponent), channel(rgb.blueComponent))
    }
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

/// Estados que o ponto mostra. Cada um tem cor E forma própria, para não depender só da cor
/// (daltonismo, ecrãs a preto e branco): cheio a trabalhar, anel à espera, losango precisa de ti, traço inativo.
enum StatusKind: Sendable {
    case working, waiting, attention, idle

    var color: Color {
        switch self {
        case .working: return Palette.working
        case .waiting: return Palette.waiting
        case .attention: return Palette.attention
        case .idle: return Color.secondary.opacity(0.6)
        }
    }
}

/// O ponto de estado: a assinatura da app. Fixo, nunca pulsa.
struct StatusDot: View {
    let kind: StatusKind
    var size: CGFloat = 6

    init(_ kind: StatusKind, size: CGFloat = 6) {
        self.kind = kind
        self.size = size
    }

    var body: some View {
        Group {
            switch kind {
            case .working: Circle().fill(kind.color)
            case .waiting: Circle().strokeBorder(kind.color, lineWidth: max(1.2, size * 0.22))
            case .attention:
                RoundedRectangle(cornerRadius: 1).fill(kind.color)
                    .rotationEffect(.degrees(45)).padding(size * 0.14)
            case .idle: Capsule().fill(kind.color).frame(height: max(1.5, size * 0.3))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)   // o estado é sempre dito por extenso ao lado
    }
}

/// Animações que respeitam a opção "Reduzir movimento" do macOS.
@MainActor
enum Motion {
    static func ease(_ duration: Double) -> Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: duration)
    }
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
    var kind: StatusKind? = nil
    var body: some View {
        HStack(spacing: DS.sm) {
            if let kind { StatusDot(kind) }
            Text(title).font(DS.meta.weight(.medium)).foregroundStyle(.secondary)
            if let count { Text("\(count)").font(DS.meta.monospacedDigit()).foregroundStyle(.tertiary) }
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

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
        .accessibilityElement(children: .combine)
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

/// Gráfico das últimas 24 h (um ponto por minuto), com as horas de início e fim.
struct DayChart: View {
    let samples: [MinuteSample]
    let value: (MinuteSample) -> Double?
    var maxValue: Double
    let title: String
    let format: (Double) -> String

    var body: some View {
        let vals = samples.compactMap(value)
        VStack(alignment: .leading, spacing: DS.xs) {
            HStack {
                Text("Últimas 24 h").font(DS.meta).foregroundStyle(.secondary)
                Spacer()
                if let mx = vals.max() {
                    Text("máximo " + format(mx)).font(DS.meta.monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
            if vals.count > 1 {
                Sparkline(values: vals, maxValue: maxValue, color: .secondary).frame(height: 32)
                    .accessibilityLabel("\(title) nas últimas 24 horas")
                    .accessibilityValue(vals.max().map { "máximo " + format($0) } ?? "")
                HStack {
                    Text(samples.first.map { Self.hour($0.t) } ?? "").font(DS.meta.monospacedDigit()).foregroundStyle(.tertiary)
                    Spacer()
                    Text("agora").font(DS.meta).foregroundStyle(.tertiary)
                }
                .accessibilityHidden(true)
            } else {
                Text("A recolher histórico, um ponto por minuto").font(DS.meta).foregroundStyle(.tertiary)
            }
        }
    }

    static func hour(_ t: TimeInterval) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: t))
    }
}
