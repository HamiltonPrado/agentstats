import SwiftUI
import AppKit

// Direção: um painel de instrumentos à noite — atento, exato, discreto.
// Superfícies em grafite neutro e opaco (o texto tem de se ler, esteja o que estiver atrás), uma só cor de destaque,
// e cor de estado apenas onde tem significado: verde a trabalhar, âmbar à espera, vermelho precisa de ti.
// Exceção: a barra do disco, colorida por categoria como a de Armazenamento do iOS.
enum DS {
    // Espaçamento: grelha de 4
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16

    // Tipo: quatro tamanhos, pesos 400 e 500, multiplicados pelo tamanho de texto escolhido
    static var meta: Font { .system(size: 11 * TextSize.current.scale) }
    static var body: Font { .system(size: 12 * TextSize.current.scale) }
    static var title: Font { .system(size: 13 * TextSize.current.scale, weight: .medium) }
    static var figure: Font { .system(size: 20 * TextSize.current.scale, weight: .medium).monospacedDigit() }
    static var mono: Font { .system(size: 11 * TextSize.current.scale, design: .monospaced) }

    // Raios (aninhados: interior = exterior − padding)
    static let rSmall: CGFloat = 6
    static let rControl: CGFloat = 8
    static let rCard: CGFloat = 12
    static let rPanel: CGFloat = 13

    // Superfícies (passos do mesmo neutro) e linha fina
    static let surface = Color.primary.opacity(0.04)
    static let raised = Color.primary.opacity(0.08)
    static let hairline = Color.primary.opacity(0.08)
}

/// Tamanho do texto do painel (Definições → Painel).
enum TextSize: String, CaseIterable, Identifiable {
    case small, normal, large
    static let defaultsKey = "ui.textSize"
    var id: String { rawValue }
    var title: String {
        switch self { case .small: "Pequeno"; case .normal: "Normal"; case .large: "Grande" }
    }
    var scale: CGFloat {
        switch self { case .small: 0.92; case .normal: 1; case .large: 1.12 }
    }
    static var current: TextSize {
        TextSize(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .normal
    }
}

/// Largura do painel (Definições → Painel).
enum PanelWidth: String, CaseIterable, Identifiable {
    case compact, normal, wide
    static let defaultsKey = "ui.panelWidth"
    var id: String { rawValue }
    var title: String {
        switch self { case .compact: "Compacta"; case .normal: "Normal"; case .wide: "Larga" }
    }
    var points: CGFloat {
        switch self { case .compact: 320; case .normal: 340; case .wide: 400 }
    }
    static var current: PanelWidth {
        PanelWidth(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .normal
    }
}

enum Palette {
    /// Cor de calor só quando há algo a assinalar; o normal fica neutro.
    static func heat(_ fraction: Double) -> Color { fraction > 0.85 ? .red : fraction > 0.7 ? .orange : .secondary }
    static func temp(_ c: Double) -> Color { c >= 90 ? .red : c >= 80 ? .orange : .secondary }
    static func heatText(_ fraction: Double) -> Color { fraction > 0.85 ? .attentionText : fraction > 0.7 ? .waitingText : .primary }
    static func tempText(_ c: Double) -> Color { c >= 90 ? .attentionText : c >= 80 ? .waitingText : .primary }
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

/// Animações que respeitam a opção "Reduzir movimento" do macOS.
@MainActor
enum Motion {
    static func ease(_ duration: Double) -> Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: duration)
    }
}

extension View {
    /// Um botão em mosaico: largura toda, altura fixa, fundo elevado e área de clique inteira.
    func raisedTile(height: CGFloat, radius: CGFloat = DS.rSmall) -> some View {
        frame(maxWidth: .infinity).frame(height: height)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(DS.raised))
            .contentShape(Rectangle())
    }

    /// O fundo de uma opção de um seletor segmentado (separadores do painel, secções das Ferramentas).
    /// `lifted`: uma sombra leve por baixo da opção escolhida (só no fundo, nunca no ícone).
    func segmentFill(_ selected: Bool, scheme: ColorScheme, lifted: Bool = false) -> some View {
        background(RoundedRectangle(cornerRadius: DS.rSmall, style: .continuous)
            .fill(selected ? (scheme == .dark ? Color.white.opacity(0.12) : Color.white) : .clear)
            .shadow(color: .black.opacity(selected && lifted ? 0.06 : 0), radius: 1, y: 1))
    }

    /// A calha à volta das opções de um seletor segmentado.
    func segmentTrack(_ fill: Color = DS.raised) -> some View {
        padding(2).background(RoundedRectangle(cornerRadius: DS.rControl, style: .continuous).fill(fill))
    }
}
