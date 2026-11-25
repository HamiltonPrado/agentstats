import AppKit
import CoreImage
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AgentStats

private func pngData(width: Int, height: Int, color: NSColor = .systemBlue) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    color.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

private func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("agentstats-media-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

@MainActor @Suite("Microfone")
struct MicMuteTests {
    @Test func presetsAreDistinct() {
        #expect(Set(MicMute.presets.map(\.combo.label)).count == MicMute.presets.count)
        #expect(MicMute.presets.contains { $0.key == MicMute.defaultPreset })
        #expect(MicMute.hotkeyID != 1 && MicMute.hotkeyID < TabHotKeys.firstID)   // não choca com os outros atalhos
    }
}

@Suite("Código QR")
struct QRMakerTests {
    @Test func makesAReadableCode() {
        let text = "https://github.com/HamiltonPrado/agentstats"
        let image = QRMaker.image(text)
        #expect(image != nil)
        #expect(ScreenReading.codes(in: image!) == [text])   // o leitor da app lê o que o gerador faz
        #expect(QRMaker.png(image!) != nil)
    }

    @Test func limits() {
        #expect(QRMaker.image("") == nil)
        #expect(QRMaker.image(String(repeating: "a", count: QRMaker.maxBytes + 1)) == nil)
        #expect(QRMaker.suggestion(from: "  https://x.pt  ") == "https://x.pt")
        #expect(QRMaker.suggestion(from: "duas\nlinhas") == "")
        #expect(QRMaker.suggestion(from: nil) == "")
    }
}

@Suite("Imagens")
struct ImageConverterTests {
    @Test func neverEnlarges() {
        #expect(ImageConverter.targetSide(width: 4000, height: 3000, maxSide: 1920) == 1920)
        #expect(ImageConverter.targetSide(width: 800, height: 600, maxSide: 1920) == 800)
        #expect(ImageConverter.targetSide(width: 800, height: 1200, maxSide: 0) == 1200)
    }

    @Test func outputNameDoesNotOverwrite() {
        let src = URL(fileURLWithPath: "/x/Férias.heic")
        var taken: Set<String> = ["/x/Férias (convertida).jpg"]
        let out = ImageConverter.outputURL(for: src, format: .jpeg) { taken.contains($0.path) }
        #expect(out.lastPathComponent == "Férias (convertida 2).jpg")
        taken = []
        #expect(ImageConverter.outputURL(for: src, format: .png) { taken.contains($0.path) }.lastPathComponent == "Férias (convertida).png")
    }

    @Test func convertsAndShrinksWithoutLocation() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Uma foto com GPS nos metadados.
        let src = dir.appendingPathComponent("foto.png")
        let dest = CGImageDestinationCreateWithURL(src as CFURL, UTType.png.identifier as CFString, 1, nil)!
        let cg = NSBitmapImageRep(data: pngData(width: 3000, height: 2000))!.cgImage!
        CGImageDestinationAddImage(dest, cg, [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 38.7, kCGImagePropertyGPSLatitudeRef: "N"]] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))

        let r = ImageConverter.convert(src, options: .init(format: .jpeg, maxSide: 1280, quality: 0.7))
        let out = try #require(r.output)
        #expect(out.lastPathComponent == "foto (convertida).jpg")
        let source = CGImageSourceCreateWithURL(out as CFURL, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        #expect(props[kCGImagePropertyPixelWidth] as? Int == 1280)
        #expect(props[kCGImagePropertyPixelHeight] as? Int == 853 || props[kCGImagePropertyPixelHeight] as? Int == 854)
        #expect(props[kCGImagePropertyGPSDictionary] == nil)
        #expect(r.after > 0 && r.after < r.before)
    }

    @Test func onlyImagesAreTaken() {
        #expect(ImageConverter.isImage(URL(fileURLWithPath: "/a/b.HEIC")))
        #expect(ImageConverter.isImage(URL(fileURLWithPath: "/a/b.png")))
        #expect(!ImageConverter.isImage(URL(fileURLWithPath: "/a/b.pdf")))
        #expect(!ImageConverter.isImage(URL(fileURLWithPath: "/a/b.mov")))
    }
}

@Suite("GIF")
struct GifMakerTests {
    @Test func framesAndLimit() {
        #expect(GifMaker.times(duration: 2, options: .init()).count == 20)
        #expect(GifMaker.times(duration: 120, options: .init()).count == 300)   // só 30 s
        #expect(GifMaker.times(duration: 0.05, options: .init()) == [0])
    }

    @Test func outputNextToTheVideo() {
        let v = URL(fileURLWithPath: "/x/Gravação.mov")
        #expect(GifMaker.outputURL(for: v) { _ in false }.path == "/x/Gravação.gif")
        #expect(GifMaker.outputURL(for: v) { $0.path == "/x/Gravação.gif" }.path == "/x/Gravação 2.gif")
    }
}

@MainActor @Suite("Clipboard com imagens", .serialized)
struct ClipboardImageTests {
    @Test func rules() {
        #expect(ClipboardRules.isImageCopy(types: ["public.png"]))
        #expect(!ClipboardRules.isImageCopy(types: ["public.png", "public.utf8-plain-text"]))   // texto ganha
        #expect(!ClipboardRules.isImageCopy(types: ["public.utf8-plain-text"]))
        let now = Date()
        var items: [ClipItem] = []
        for i in 0..<(ClipboardRules.maxImages + 3) { items = ClipboardRules.addingImage("\(i).png", size: "1×1", to: items, now: now) }
        #expect(items.filter { $0.image != nil }.count == ClipboardRules.maxImages)
        items = ClipboardRules.addingImage("5.png", size: "1×1", to: items, now: now)
        #expect(items.first?.image == "5.png" && items.filter { $0.image == "5.png" }.count == 1)
        #expect(ClipboardRules.orphanImages(files: ["a.png", "b.png", "x.json"], items: [ClipItem(text: "", date: now, image: "a.png")]) == ["b.png"])
    }

    @Test func oldHistoryStillLoads() throws {
        let json = #"[{"id":"7C9E4C79-6F1C-4E0B-9C2C-1D2B3A4F5E6D","text":"olá","date":0,"pinned":false}]"#
        let items = try JSONDecoder().decode([ClipItem].self, from: Data(json.utf8))
        #expect(items.first?.text == "olá" && items.first?.image == nil)
    }

    @Test func keepsCopiedImagesOnlyWhenAsked() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = ClipboardStore(pasteboard: board, directory: dir, defaults: nil, accessOverride: .allowed, frontApp: { "com.example.editor" })
        s.setEnabled(true)
        let png = pngData(width: 40, height: 20)

        board.clearContents(); board.setData(png, forType: .png); s.poll()
        #expect(s.items.isEmpty)   // imagens desligadas por defeito

        s.setImagesEnabled(true)
        board.clearContents(); board.setData(png, forType: .png); s.poll()
        let item = try #require(s.items.first)
        #expect(item.imageSize == "40×20")
        let file = try #require(s.imageURL(item))
        #expect(FileManager.default.fileExists(atPath: file.path))
        let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)

        // A mesma imagem outra vez não duplica.
        board.clearContents(); board.setData(png, forType: .png); s.poll()
        #expect(s.items.count == 1)

        // De um gestor de passwords, nunca.
        let other = ClipboardStore(pasteboard: board, directory: nil, defaults: nil, accessOverride: .allowed, frontApp: { "com.1password.1password" })
        other.setEnabled(true); other.setImagesEnabled(true)
        board.clearContents(); board.setData(pngData(width: 10, height: 10), forType: .png); other.poll()
        #expect(other.items.isEmpty)

        // Copiar de volta põe a imagem no clipboard; apagar o item apaga o ficheiro.
        s.copyItem(item)
        #expect(board.data(forType: .png) == (try Data(contentsOf: file)))
        s.remove(item.id)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
