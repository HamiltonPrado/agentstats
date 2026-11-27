import SwiftUI

/// A caixa tracejada onde se largam ficheiros (ou se clica para os escolher).
struct DropZone: View {
    let symbol: String
    let text: String
    var busy = false
    let onPick: () -> Void
    /// Devolve se aceitou o que foi largado.
    let onDrop: ([URL]) -> Bool
    @StateObject private var targeted = Box(false)

    var body: some View {
        Button(action: onPick) {
            VStack(spacing: DS.xs) {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol).font(.system(size: 20 * TextSize.current.scale))
                }
                Text(L(text)).font(DS.meta)
            }
            .foregroundStyle(targeted.value ? Color.accentColor : Color.text2)
            .frame(maxWidth: .infinity).frame(height: 76)
            .background(RoundedRectangle(cornerRadius: DS.rControl, style: .continuous)
                .strokeBorder(targeted.value ? Color.accentColor : Color.text3.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .dropDestination(for: URL.self) { urls, _ in onDrop(urls) } isTargeted: { targeted.value = $0 }
    }
}

/// Um código QR pronto a ler: píxeis nítidos, fundo branco (as câmaras não leem bem em fundo escuro).
struct QRImage: View {
    let image: CGImage
    var size: CGFloat = 132

    var body: some View {
        Image(decorative: image, scale: 1).interpolation(.none).resizable()
            .frame(width: size, height: size).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
