import AppKit
import SwiftUI

struct WindowsView: View {
    @AppStorage(WindowShortcuts.enabledKey) private var shortcuts = true
    @StateObject private var message = Box<String?>(nil)
    @StateObject private var trusted = Box(AXIsProcessTrusted())

    private let grid: [[WindowAction]] = [
        [.leftHalf, .rightHalf, .topHalf, .bottomHalf],
        [.topLeft, .topRight, .bottomLeft, .bottomRight],
        [.firstThird, .centerThird, .lastThird, .maximize],
        [.firstTwoThirds, .lastTwoThirds, .center, .nextDisplay],
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.md) {
            VStack(alignment: .leading, spacing: DS.sm) {
                Text("Organizar janelas").font(DS.body.weight(.medium))
                if !trusted.value {
                    note("Precisa da Acessibilidade para mexer nas janelas das outras apps. O macOS pede-a no primeiro uso.", color: .text2)
                }
                VStack(spacing: DS.xs) {
                    ForEach(grid, id: \.self) { row in
                        HStack(spacing: DS.xs) {
                            ForEach(row) { action in tile(action) }
                        }
                    }
                }
                if let m = message.value { note(m, color: .attentionText) }
                note("Aplica à janela da app onde estavas. Carregar outra vez na metade esquerda ou direita alterna entre ½, ⅔ e ⅓.")
            }
            .cardStyle()

            VStack(alignment: .leading, spacing: DS.sm) {
                HStack {
                    Text("Atalhos").font(DS.body.weight(.medium))
                    Spacer()
                    Toggle("Atalhos", isOn: $shortcuts).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                }
                if shortcuts {
                    ForEach(WindowShortcuts.map, id: \.action) { entry in
                        HStack {
                            Text(L(entry.action.title)).font(DS.body)
                            Spacer()
                            Text(entry.combo.label).font(DS.body.monospaced()).foregroundStyle(Color.text2)
                        }
                    }
                    note("Funcionam em qualquer app. Se outra app já usar uma combinação, essa fica com ela.")
                }
            }
            .cardStyle()
        }
        .onAppear { trusted.value = AXIsProcessTrusted() }
    }

    private func tile(_ action: WindowAction) -> some View {
        Button {
            switch WindowMover.apply(action) {
            case .moved: message.value = nil
            case .noPermission: message.value = L("Falta a Acessibilidade: dá-a nas Definições do Sistema e tenta outra vez.")
            case .noWindow: message.value = L(action.changesDisplay ? "Só há um ecrã." : "Não encontrei uma janela para organizar.")
            case .refused: message.value = L("Essa janela não deixa mudar de tamanho ou de lugar.")
            }
            trusted.value = AXIsProcessTrusted()
        } label: {
            preview(action)
                .frame(maxWidth: .infinity).frame(height: 34)
                .background(RoundedRectangle(cornerRadius: DS.rSmall, style: .continuous).fill(DS.raised))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L(action.title) + (WindowShortcuts.label(action).map { "  " + $0 } ?? ""))
        .accessibilityLabel(L(action.title))
    }

    /// Um ecrã em miniatura com a zona que a janela vai ocupar, calculada pela mesma conta que a move.
    @ViewBuilder private func preview(_ action: WindowAction) -> some View {
        if action.changesDisplay {
            Image(systemName: action.symbol).font(.system(size: 15 * TextSize.current.scale))
        } else {
            let screen = CGRect(x: 0, y: 0, width: 26, height: 17)
            let window = CGRect(x: 0, y: 0, width: 15, height: 10)
            let r = WindowLayout.frame(action, in: screen, window: window)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 2.5).stroke(Color.primary.opacity(0.55), lineWidth: 1.2)
                RoundedRectangle(cornerRadius: 1.5).fill(Color.primary.opacity(0.85))
                    .frame(width: max(r.width - 3, 2), height: max(r.height - 3, 2))
                    // Coordenadas do AppKit (origem em baixo): o y conta a partir de cima.
                    .offset(x: r.minX + 1.5, y: screen.height - r.maxY + 1.5)
            }
            .frame(width: screen.width, height: screen.height)
        }
    }
}
