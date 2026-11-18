// Gera o ícone da app (1024×1024) com SwiftUI.
// Uso: swiftc -O Scripts/make-icon.swift -o /tmp/make-icon && /tmp/make-icon Resources/AppIcon-1024.png
import SwiftUI
import AppKit

struct AppIcon: View {
    let purple = Color(red: 0.56, green: 0.33, blue: 0.97)
    let blue = Color(red: 0.13, green: 0.42, blue: 0.96)
    let cyan = Color(red: 0.42, green: 0.93, blue: 0.98)

    var body: some View {
        ZStack {
            // Corpo (grelha de ícones do macOS: 824 pt dentro de 1024)
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [purple, blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(
                    RoundedRectangle(cornerRadius: 185, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0.22), .clear], startPoint: .top, endPoint: .center))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 185, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 3)
                )
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 22, y: 14)

            // Medidor: pista + arco de valor (abre em baixo, como um conta-rotações)
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(.white.opacity(0.2), style: StrokeStyle(lineWidth: 58, lineCap: .round))
                .rotationEffect(.degrees(135))
                .frame(width: 540, height: 540)
            Circle()
                .trim(from: 0, to: 0.5)
                .stroke(
                    // ângulos no referencial antes da rotação: o arco vai de 0° a 180°
                    AngularGradient(colors: [cyan, .white], center: .center,
                                    startAngle: .degrees(0), endAngle: .degrees(180)),
                    style: StrokeStyle(lineWidth: 58, lineCap: .round))
                .rotationEffect(.degrees(135))
                .frame(width: 540, height: 540)
                .shadow(color: cyan.opacity(0.6), radius: 18)

            // Agente: brilho no centro
            Image(systemName: "sparkles")
                .font(.system(size: 250, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.2), radius: 10, y: 6)
                .offset(y: -6)

            // Pequena linha de atividade na abertura do medidor
            Path { p in
                let pts: [CGPoint] = [(-110, 0), (-50, 0), (-25, -38), (10, 34), (38, -14), (55, 0), (110, 0)]
                    .map { CGPoint(x: 512 + $0.0, y: 512 + 238 + $0.1) }
                p.move(to: pts[0]); pts.dropFirst().forEach { p.addLine(to: $0) }
            }
            .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 16, lineCap: .round, lineJoin: .round))
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
