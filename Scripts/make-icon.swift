// Gera o ícone da app (1024×1024) com SwiftUI.
// Uso: swiftc -O Scripts/make-icon.swift -o /tmp/make-icon && /tmp/make-icon Resources/AppIcon-1024.png
//
// Direção: um mostrador de instrumento à noite. Grafite neutro, um traço sólido quase branco,
// e o ponto de estado verde (a assinatura da app) no centro. Sem gradientes de cor, brilhos ou ✨.
import SwiftUI
import AppKit

struct AppIcon: View {
    let top = Color(red: 0.13, green: 0.13, blue: 0.14)      // #212123
    let bottom = Color(red: 0.08, green: 0.08, blue: 0.09)   // #141416 (só um passo de tom, mesmo neutro)
    let ink = Color(red: 0.93, green: 0.93, blue: 0.93)      // #ededed
    let live = Color(red: 0.30, green: 0.76, blue: 0.54)     // #4cc38a, verde de estado

    var body: some View {
        ZStack {
            // Corpo (grelha de ícones do macOS: 824 pt dentro de 1024)
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: 185, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 4)
                )
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.3), radius: 18, y: 10)

            // Escala do mostrador: pista fina e marcas, abre em baixo
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(ink.opacity(0.14), style: StrokeStyle(lineWidth: 44, lineCap: .round))
                .rotationEffect(.degrees(135))
                .frame(width: 520, height: 520)
            ForEach(0..<7) { i in
                Capsule()
                    .fill(ink.opacity(0.35))
                    .frame(width: 10, height: 36)
                    .offset(y: -330)
                    .rotationEffect(.degrees(-135 + Double(i) * 45))
            }

            // Leitura: um traço sólido, uma só cor
            Circle()
                .trim(from: 0, to: 0.48)
                .stroke(ink, style: StrokeStyle(lineWidth: 44, lineCap: .round))
                .rotationEffect(.degrees(135))
                .frame(width: 520, height: 520)

            // Ponteiro até ao fim da leitura
            Capsule()
                .fill(ink)
                .frame(width: 22, height: 200)
                .offset(y: -100)
                // o arco vai de 135° a 135° + 0,48 × 360°; o ponteiro (em repouso aponta para cima, 270°) acompanha o fim
                .rotationEffect(.degrees(135 + 0.48 * 360 - 270))

            // Centro: o ponto de estado
            Circle().fill(bottom).frame(width: 120, height: 120)
            Circle().fill(live).frame(width: 76, height: 76)
        }
        .frame(width: 1024, height: 1024)
    }
}

@MainActor func render(to path: String) {
    let r = ImageRenderer(content: AppIcon())
    r.scale = 1
    guard let cg = r.cgImage else { fatalError("falhou a renderização") }
    let rep = NSBitmapImageRep(cgImage: cg)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("✅ \(path)")
}

MainActor.assumeIsolated { render(to: CommandLine.arguments.dropFirst().first ?? "AppIcon-1024.png") }
