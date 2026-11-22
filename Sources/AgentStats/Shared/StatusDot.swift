import SwiftUI
import AppKit

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
