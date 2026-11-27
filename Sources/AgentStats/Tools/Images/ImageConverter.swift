import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Converter e reduzir imagens (HEIC, PNG, JPG, TIFF…) para JPG ou PNG. Tudo no Mac, com o ImageIO.
/// Os metadados (incluindo a localização GPS das fotos) não passam para a cópia.
enum ImageConverter {
    enum Format: String, CaseIterable, Identifiable, Sendable {
        case jpeg, png
        var id: String { rawValue }
        var title: String { self == .jpeg ? "JPG" : "PNG" }
        var ext: String { self == .jpeg ? "jpg" : "png" }
        var type: UTType { self == .jpeg ? .jpeg : .png }
    }

    struct Options: Equatable, Sendable {
        var format: Format = .jpeg
        /// Lado maior em píxeis; 0 mantém o tamanho.
        var maxSide: Int = 1920
        /// Só no JPG: 0…1.
        var quality: Double = 0.8
    }

    static let sides = [0, 2560, 1920, 1280, 800]

    struct Result: Equatable, Sendable {
        let source: URL
        let output: URL?
        let before: Int64
        let after: Int64
    }

    /// O tamanho final, sem nunca aumentar a imagem.
    static func targetSide(width: Int, height: Int, maxSide: Int) -> Int {
        let longest = max(width, height)
        return maxSide > 0 ? min(longest, maxSide) : longest
    }

    /// "Férias.heic" → "Férias (convertida).jpg", e se já existir "Férias (convertida 2).jpg".
    static func outputURL(for source: URL, format: Format, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let base = source.deletingPathExtension().lastPathComponent
        let dir = source.deletingLastPathComponent()
        let suffix = L("convertida")
        var n = 1
        while true {
            let name = n == 1 ? "\(base) (\(suffix)).\(format.ext)" : "\(base) (\(suffix) \(n)).\(format.ext)"
            let url = dir.appendingPathComponent(name)
            if !exists(url) { return url }
            n += 1
        }
    }

    static func convert(_ source: URL, options: Options) -> Result {
        let before = size(source)
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            return Result(source: source, output: nil, before: before, after: 0)
        }
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let side = targetSide(width: w, height: h, maxSide: options.maxSide)
        // A miniatura com a transformação aplica a orientação da foto e reduz numa só passagem.
        var thumbOptions: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                             kCGImageSourceCreateThumbnailWithTransform: true]
        // Sem dimensões conhecidas, o limite fica o escolhido (ou nenhum): com 0 saía uma imagem de 1 píxel.
        if side > 0 { thumbOptions[kCGImageSourceThumbnailMaxPixelSize] = side }
        else if options.maxSide > 0 { thumbOptions[kCGImageSourceThumbnailMaxPixelSize] = options.maxSide }
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOptions as CFDictionary) else {
            return Result(source: source, output: nil, before: before, after: 0)
        }
        let out = outputURL(for: source, format: options.format)
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, options.format.type.identifier as CFString, 1, nil) else {
            return Result(source: source, output: nil, before: before, after: 0)
        }
        var destProps: [CFString: Any] = [:]
        if options.format == .jpeg { destProps[kCGImageDestinationLossyCompressionQuality] = options.quality }
        CGImageDestinationAddImage(dest, image, destProps as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return Result(source: source, output: nil, before: before, after: 0) }
        return Result(source: source, output: out, before: before, after: size(out))
    }

    static func size(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .image)
    }
}
