import CoreGraphics
import Foundation

/// Onde pôr a janela da frente. Contas puras, em coordenadas do AppKit (origem em baixo à esquerda).
enum WindowAction: String, CaseIterable, Identifiable, Sendable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case firstThird, centerThird, lastThird, firstTwoThirds, lastTwoThirds
    case maximize, center
    case nextDisplay, previousDisplay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leftHalf: "Metade esquerda"
        case .rightHalf: "Metade direita"
        case .topHalf: "Metade de cima"
        case .bottomHalf: "Metade de baixo"
        case .topLeft: "Canto superior esquerdo"
        case .topRight: "Canto superior direito"
        case .bottomLeft: "Canto inferior esquerdo"
        case .bottomRight: "Canto inferior direito"
        case .firstThird: "Primeiro terço"
        case .centerThird: "Terço do meio"
        case .lastThird: "Último terço"
        case .firstTwoThirds: "Primeiros dois terços"
        case .lastTwoThirds: "Últimos dois terços"
        case .maximize: "Ecrã inteiro"
        case .center: "Centrar"
        case .nextDisplay: "Próximo ecrã"
        case .previousDisplay: "Ecrã anterior"
        }
    }

    /// Só as ações de mudar de ecrã têm ícone; as outras desenham a zona da janela numa miniatura.
    var symbol: String { self == .previousDisplay ? "rectangle.portrait.and.arrow.forward" : "rectangle.portrait.and.arrow.right" }

    var changesDisplay: Bool { self == .nextDisplay || self == .previousDisplay }
}

enum WindowLayout {
    /// O retângulo de cada ação dentro da área útil do ecrã (sem a barra de menus nem a Dock).
    static func frame(_ action: WindowAction, in v: CGRect, window: CGRect) -> CGRect {
        let w = v.width, h = v.height
        func r(_ x: CGFloat, _ y: CGFloat, _ ww: CGFloat, _ hh: CGFloat) -> CGRect {
            CGRect(x: v.minX + x, y: v.minY + y, width: ww, height: hh).integral
        }
        switch action {
        case .leftHalf: return r(0, 0, w / 2, h)
        case .rightHalf: return r(w / 2, 0, w / 2, h)
        case .topHalf: return r(0, h / 2, w, h / 2)
        case .bottomHalf: return r(0, 0, w, h / 2)
        case .topLeft: return r(0, h / 2, w / 2, h / 2)
        case .topRight: return r(w / 2, h / 2, w / 2, h / 2)
        case .bottomLeft: return r(0, 0, w / 2, h / 2)
        case .bottomRight: return r(w / 2, 0, w / 2, h / 2)
        case .firstThird: return r(0, 0, w / 3, h)
        case .centerThird: return r(w / 3, 0, w / 3, h)
        case .lastThird: return r(2 * w / 3, 0, w / 3, h)
        case .firstTwoThirds: return r(0, 0, 2 * w / 3, h)
        case .lastTwoThirds: return r(w / 3, 0, 2 * w / 3, h)
        case .maximize: return r(0, 0, w, h)
        case .center:
            let ww = min(window.width, w), hh = min(window.height, h)
            return r((w - ww) / 2, (h - hh) / 2, ww, hh)
        case .nextDisplay, .previousDisplay: return window
        }
    }

    /// Carregar outra vez no mesmo atalho alterna: metade → dois terços → um terço → metade.
    static func cycled(_ action: WindowAction, current: CGRect, in v: CGRect) -> WindowAction {
        let cycles: [WindowAction: [WindowAction]] = [.leftHalf: [.leftHalf, .firstTwoThirds, .firstThird],
                                                       .rightHalf: [.rightHalf, .lastTwoThirds, .lastThird]]
        guard let cycle = cycles[action] else { return action }
        for (i, step) in cycle.enumerated() where close(frame(step, in: v, window: current), current) {
            return cycle[(i + 1) % cycle.count]
        }
        return action
    }

    /// Para o ecrã seguinte, mantendo a posição e o tamanho relativos (e sem passar do ecrã novo).
    static func moved(_ window: CGRect, from a: CGRect, to b: CGRect) -> CGRect {
        guard a.width > 0, a.height > 0 else { return window }
        let fx = (window.minX - a.minX) / a.width, fy = (window.minY - a.minY) / a.height
        let fw = window.width / a.width, fh = window.height / a.height
        let w = min(b.width, fw * b.width), h = min(b.height, fh * b.height)
        let x = min(max(b.minX + fx * b.width, b.minX), b.maxX - w)
        let y = min(max(b.minY + fy * b.height, b.minY), b.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h).integral
    }

    /// O ecrã seguinte (ou anterior), da esquerda para a direita.
    static func neighbour(of index: Int, in screens: [CGRect], forward: Bool) -> Int? {
        guard screens.count > 1, screens.indices.contains(index) else { return nil }
        let order = screens.indices.sorted { (screens[$0].minX, screens[$0].minY) < (screens[$1].minX, screens[$1].minY) }
        guard let pos = order.firstIndex(of: index) else { return nil }
        return order[(pos + (forward ? 1 : order.count - 1)) % order.count]
    }

    /// O ecrã com mais área da janela.
    static func screenIndex(for window: CGRect, in screens: [CGRect]) -> Int? {
        screens.indices.max { a, b in
            let ia = screens[a].intersection(window), ib = screens[b].intersection(window)
            return (ia.isNull ? 0 : ia.width * ia.height) < (ib.isNull ? 0 : ib.width * ib.height)
        }
    }

    /// AppKit (origem em baixo) ↔ Acessibilidade (origem em cima, no ecrã principal). A conta é a mesma nos dois sentidos.
    static func flipped(_ r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func close(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 12) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}
