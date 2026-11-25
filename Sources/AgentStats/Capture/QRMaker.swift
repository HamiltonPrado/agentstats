import AppKit
import CoreImage
import SwiftUI
import UniformTypeIdentifiers

/// Gera um código QR (no Mac, sem rede) para abrir um link ou um texto no telemóvel.
enum QRMaker {
    /// Nas capturas (README e site): nunca o clipboard real.
    @MainActor static var demoText: String?

    /// Até onde um QR fica fácil de ler com a câmara do telemóvel.
    static let maxBytes = 1_200

    static func image(_ text: String, size: CGFloat = 512) -> CGImage? {
        let data = Data(text.utf8)
        guard !data.isEmpty, data.count <= maxBytes, let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = (size / output.extent.width).rounded(.down)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: max(scale, 1), y: max(scale, 1)))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }

    static func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// O texto do clipboard serve de ponto de partida se for curto e numa linha (um link, um código).
    static func suggestion(from clipboard: String?) -> String {
        guard let t = clipboard?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty,
              t.count <= 300, !t.contains("\n") else { return "" }
        return t
    }
}

struct QRMakerCard: View {
    @StateObject private var text = Box("")
    @StateObject private var note = Box<String?>(nil)

    var body: some View {
        let image = QRMaker.image(text.value)
        VStack(alignment: .leading, spacing: DS.sm) {
            Text("Gerar código QR").font(DS.body.weight(.medium))
            TextField("Link ou texto", text: $text.value).textFieldStyle(.roundedBorder).font(DS.body)
            if let image {
                HStack(alignment: .top, spacing: DS.md) {
                    Image(decorative: image, scale: 1).interpolation(.none).resizable()
                        .frame(width: 132, height: 132).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: DS.sm) {
                        Button("Copiar imagem") { copy(image) }.controlSize(.small)
                        Button("Guardar PNG…") { save(image) }.controlSize(.small)
                        if let n = note.value { AgentStats.note(n, color: .text2) }
                    }
                }
            } else if Data(text.value.utf8).count > QRMaker.maxBytes {
                AgentStats.note("Texto demasiado longo para um QR que se leia bem.", color: .text2)
            }
            AgentStats.note("Aponta a câmara do telemóvel. Feito neste Mac, sem rede.")
        }
        .cardStyle()
        .onAppear {
            // Ler o clipboard sem acesso dado faria o macOS (15.4+) mostrar um alerta: aí começa vazio.
            if let demo = QRMaker.demoText {
                text.value = demo
            } else if text.value.isEmpty, ClipboardStore.shared.access == .allowed {
                text.value = QRMaker.suggestion(from: NSPasteboard.general.string(forType: .string))
            }
        }
    }

    private func copy(_ image: CGImage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))])
        note.value = L("Copiado")
    }

    private func save(_ image: CGImage) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = L("Código QR") + ".png"
        panel.allowedContentTypes = [.png]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url, let data = QRMaker.png(image) else { return }
        note.value = (try? data.write(to: url, options: .atomic)) != nil ? L("Guardado") : L("Não consegui guardar o ficheiro.")
    }
}
