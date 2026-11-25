import AppKit
import CoreGraphics
import Foundation
import UserNotifications
import Vision

/// Ler o ecrã: texto e códigos QR de uma área, e a cor de um ponto. Tudo no Mac, sem rede.
enum ScreenReading {
    /// Linhas pela ordem de leitura: de cima para baixo e, na mesma altura, da esquerda para a direita.
    static func text(in image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["pt-PT", "pt-BR", "en-US", "es-ES", "fr-FR"]
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? []).compactMap { o -> (CGRect, String)? in
            guard let t = o.topCandidates(1).first?.string else { return nil }
            return (o.boundingBox, t)
        }
        return ordered(lines).joined(separator: "\n")
    }

    /// As caixas do Vision têm a origem em baixo: maior y é mais acima.
    static func ordered(_ lines: [(CGRect, String)]) -> [String] {
        lines.sorted { a, b in
            if abs(a.0.midY - b.0.midY) > min(a.0.height, b.0.height) / 2 { return a.0.midY > b.0.midY }
            return a.0.minX < b.0.minX
        }.map(\.1)
    }

    static func codes(in image: CGImage) -> [String] {
        let request = VNDetectBarcodesRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        var seen = Set<String>()
        return (request.results ?? []).compactMap(\.payloadStringValue).filter { seen.insert($0).inserted }
    }

    /// Só se oferece para abrir endereços web.
    static func webLink(_ s: String) -> URL? {
        guard let url = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host != nil else { return nil }
        return url
    }

    static func hex(_ c: NSColor) -> String {
        let (r, g, b) = rgb(c)
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    static func rgbText(_ c: NSColor) -> String {
        let (r, g, b) = rgb(c)
        return String(localized: "rgb(\(r), \(g), \(b))")
    }

    static func rgb(_ c: NSColor) -> (Int, Int, Int) {
        let s = c.usingColorSpace(.sRGB) ?? c
        func v(_ x: CGFloat) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        return (v(s.redComponent), v(s.greenComponent), v(s.blueComponent))
    }
}

@MainActor
final class ScreenToolsStore: ObservableObject {
    static let shared = ScreenToolsStore()

    enum Result: Equatable {
        case text(String)
        case codes([String])
        case color(hex: String, rgb: String)
        case nothing(String)
    }

    @Published private(set) var result: Result?
    @Published private(set) var busy = false
    @Published var colorFormat: String = Pref.string("screen.colorFormat") ?? "hex" { didSet { Pref.set(colorFormat, "screen.colorFormat") } }
    private var demo = false

    /// Seleciona uma área com a ferramenta do macOS e devolve-a como imagem. nil se cancelada.
    private func selectArea() async -> CGImage? {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            result = .nothing("Falta a permissão de Gravação de ecrã. Dá-a nas Definições do Sistema e volta a abrir o AgentStats.")
            return nil
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("agentstats-read-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        _ = await ToolRunner.run("/usr/sbin/screencapture", ["-i", "-s", "-x", file.path], timeout: 300)
        guard let data = try? Data(contentsOf: file), let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return image
    }

    func readText() async {
        guard !demo, !busy else { return }
        busy = true
        defer { busy = false }
        guard let image = await selectArea() else { return }
        let text = await Task.detached(priority: .userInitiated) { ScreenReading.text(in: image) }.value
        if text.isEmpty {
            result = .nothing("Não encontrei texto nessa área.")
            notify("Sem texto", "Não encontrei texto nessa área.")
        } else {
            copy(text)
            result = .text(text)
            let lines = text.split(separator: "\n").count
            notify("Texto copiado", lines == 1 ? text : String(localized: "\(lines) linhas: ") + text.prefix(80))
        }
    }

    func readCode() async {
        guard !demo, !busy else { return }
        busy = true
        defer { busy = false }
        guard let image = await selectArea() else { return }
        let codes = await Task.detached(priority: .userInitiated) { ScreenReading.codes(in: image) }.value
        if codes.isEmpty {
            result = .nothing("Não encontrei nenhum código QR nessa área.")
            notify("Sem código QR", "Não encontrei nenhum código QR nessa área.")
        } else {
            copy(codes.joined(separator: "\n"))
            result = .codes(codes)
            notify("Código QR copiado", codes[0])
        }
    }

    /// A lupa do próprio macOS: Esc cancela.
    func pickColor() {
        guard !demo else { return }
        NSColorSampler().show { [weak self] color in
            guard let color else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                let hex = ScreenReading.hex(color), rgb = ScreenReading.rgbText(color)
                self.copy(self.colorFormat == "rgb" ? rgb : hex)
                self.result = .color(hex: hex, rgb: rgb)
                self.notify("Cor copiada", "\(hex) · \(rgb)")
            }
        }
    }

    func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = L(title)
        c.body = L(String(L(body).prefix(200)))
        Notify.add(UNNotificationRequest(identifier: "screen-\(UUID().uuidString)", content: c, trigger: nil))
    }

    func loadDemo() {
        demo = true
        result = .color(hex: "#3478F6", rgb: "rgb(52, 120, 246)")
    }
}

import SwiftUI

extension Color {
    /// "#3478F6" → cor sRGB.
    init(hexString: String) {
        let h = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let v = UInt32(h, radix: 16) ?? 0
        self.init(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
