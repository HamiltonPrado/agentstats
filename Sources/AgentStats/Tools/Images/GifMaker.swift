@preconcurrency import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Converte um vídeo (as gravações de ecrã) num GIF leve, para PRs, issues e mensagens.
enum GifMaker {
    struct Options: Equatable, Sendable {
        var fps: Double = 10
        var maxWidth: Int = 720
        /// GIFs longos ficam enormes: só os primeiros segundos.
        var maxSeconds: Double = 30
    }

    /// Os instantes das imagens, com o fim limitado.
    /// As imagens ficam todas em memória até o GIF ser fechado: no total, cerca de 400 MB no máximo.
    static let memoryBudget = 400_000_000

    /// A largura pedida, e uma altura máxima que cabe no orçamento (os vídeos verticais e longos é que pesam).
    static func frameSize(maxWidth: Int, frames: Int) -> CGSize {
        let perFrame = Double(memoryBudget) / Double(max(frames, 1)) / 4   // 4 bytes por píxel
        let height = min(Double(maxWidth) * 4, perFrame / Double(max(maxWidth, 1)))
        return CGSize(width: CGFloat(maxWidth), height: CGFloat(max(64, height.rounded(.down))))
    }

    static func times(duration: Double, options: Options) -> [Double] {
        let length = min(max(duration, 0), options.maxSeconds)
        let count = max(1, Int((length * options.fps).rounded(.down)))
        return (0..<count).map { Double($0) / options.fps }
    }

    static func outputURL(for video: URL, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let base = video.deletingPathExtension()
        var url = base.appendingPathExtension("gif")
        var n = 2
        while exists(url) {
            url = video.deletingLastPathComponent().appendingPathComponent("\(base.lastPathComponent) \(n).gif")
            n += 1
        }
        return url
    }

    enum Failure: Error, Equatable { case unreadable, noFrames, notWritten }

    /// `progress` recebe 0…1. Devolve o GIF e se foi cortado.
    static func make(from video: URL, options: Options = Options(),
                     progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> (url: URL, trimmed: Bool) {
        let asset = AVURLAsset(url: video)
        guard let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0 else { throw Failure.unreadable }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let instants = times(duration: duration, options: options)
        generator.maximumSize = Self.frameSize(maxWidth: options.maxWidth, frames: instants.count)
        let tolerance = CMTime(seconds: 0.5 / options.fps, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let out = outputURL(for: video)
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, instants.count, nil) else {
            throw Failure.notWritten
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / options.fps]] as CFDictionary
        var added = 0
        for (i, t) in instants.enumerated() {
            if let image = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image {
                CGImageDestinationAddImage(dest, image, frameProps)
                added += 1
            }
            progress(Double(i + 1) / Double(instants.count))
        }
        guard added > 0 else { throw Failure.noFrames }
        guard CGImageDestinationFinalize(dest) else { throw Failure.notWritten }
        return (out, duration > options.maxSeconds)
    }
}
