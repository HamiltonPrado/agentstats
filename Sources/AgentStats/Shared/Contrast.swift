import AppKit
import SwiftUI

/// Uma cor sRGB, com as contas de contraste do WCAG.
struct RGB: Sendable, Equatable {
    let r: Double
    let g: Double
    let b: Double

    init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    init(_ hex: UInt32) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
    }

    var luminance: Double {
        let red: Double = 0.2126 * Self.linear(r)
        let green: Double = 0.7152 * Self.linear(g)
        let blue: Double = 0.0722 * Self.linear(b)
        return red + green + blue
    }

    private static func linear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    func contrast(with other: RGB) -> Double {
        let high: Double = max(luminance, other.luminance)
        let low: Double = min(luminance, other.luminance)
        return (high + 0.05) / (low + 0.05)
    }

    func mixed(with other: RGB, _ amount: Double) -> RGB {
        let keep: Double = 1 - amount
        return RGB(r: r * keep + other.r * amount, g: g * keep + other.g * amount, b: b * keep + other.b * amount)
    }

    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
}

struct Tone: Sendable {
    let light: RGB
    let dark: RGB

    /// O sistema pede a cor em qualquer thread: a closure não pode herdar o main actor.
    var color: Color {
        let light = light, dark = dark
        return Color(nsColor: NSColor(name: nil, dynamicProvider: { @Sendable appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark.nsColor : light.nsColor
        }))
    }
}

/// Texto legível (4,5:1) em qualquer superfície do painel. Não usar `.secondary` nem `.tertiary` em texto:
/// são translúcidos e ficam entre 1,8 e 3,9:1. As cores vivas da `Palette` são para pontos, barras e gráficos.
enum Contrast {
    static let minimum = 4.5

    static let panel = Tone(light: RGB(0xF4F4F4), dark: RGB(0x242424))
    /// A pior superfície onde há texto: `raised` dentro de um cartão.
    static let backdrop = Tone(light: RGB(0xD9D9D9), dark: RGB(0x3B3B3B))

    static let text2 = Tone(light: RGB(0x484848), dark: RGB(0xC2C2C2))
    static let text3 = Tone(light: RGB(0x5A5A5A), dark: RGB(0xA8A8A8))
    static let working = Tone(light: RGB(0x12652A), dark: RGB(0x32D74B))
    static let waiting = Tone(light: RGB(0x874300), dark: RGB(0xFF9F0A))
    static let attention = Tone(light: RGB(0xAD160E), dark: RGB(0xFF8A80))

    /// A cor escolhida, escurecida (tema claro) ou clareada (tema escuro) só até se ler.
    static func readable(_ color: RGB) -> Tone {
        Tone(light: adjusted(color, toward: RGB(0x000000), on: backdrop.light),
             dark: adjusted(color, toward: RGB(0xFFFFFF), on: backdrop.dark))
    }

    private static func adjusted(_ color: RGB, toward end: RGB, on background: RGB) -> RGB {
        for step in 0..<20 {
            let candidate = color.mixed(with: end, Double(step) / 20)
            // Do lado certo: no tema claro o texto é mais escuro que o fundo, no escuro mais claro.
            let rightSide: Bool = (candidate.luminance < background.luminance) == (end.luminance < background.luminance)
            if rightSide && candidate.contrast(with: background) >= minimum { return candidate }
        }
        return end
    }
}

extension Color {
    static let panel = Contrast.panel.color
    static let text2 = Contrast.text2.color
    static let text3 = Contrast.text3.color
    static let workingText = Contrast.working.color
    static let waitingText = Contrast.waiting.color
    static let attentionText = Contrast.attention.color

    var readableText: Color {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return .text2 }
        let base = RGB(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent))
        return Contrast.readable(base).color
    }
}

/// Texto clicável na cor de destaque do painel.
struct AccentText: ViewModifier {
    @Environment(\.agentAccentColor) private var accent

    func body(content: Content) -> some View {
        content.foregroundStyle(accent.readableText)
    }
}
