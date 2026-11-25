import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ImagesStore: ObservableObject {
    static let shared = ImagesStore()

    @Published var options = ImageConverter.Options(
        format: ImageConverter.Format(rawValue: Pref.string("images.format") ?? "") ?? .jpeg,
        maxSide: UserDefaults.standard.object(forKey: "images.maxSide") as? Int ?? 1920,
        quality: Pref.double("images.quality", 0.8)) {
        didSet {
            guard !demo else { return }
            Pref.set(options.format.rawValue, "images.format")
            Pref.set(options.maxSide, "images.maxSide")
            Pref.set(options.quality, "images.quality")
        }
    }
    @Published private(set) var results: [ImageConverter.Result] = []
    @Published private(set) var converting = false
    @Published private(set) var gifProgress: Double?
    @Published private(set) var gifMessage: String?
    @Published private(set) var lastGIF: URL?
    private var demo = false

    func convert(_ urls: [URL]) async {
        let images = urls.filter(ImageConverter.isImage)
        guard !demo, !converting, !images.isEmpty else { return }
        converting = true
        let options = self.options
        results = await Task.detached(priority: .userInitiated) { images.map { ImageConverter.convert($0, options: options) } }.value
        converting = false
    }

    func pickImages() async {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        await convert(panel.urls)
    }

    func makeGIF(from video: URL) async {
        guard !demo, gifProgress == nil else { return }
        gifProgress = 0
        gifMessage = nil
        do {
            let r = try await GifMaker.make(from: video) { p in Task { @MainActor in ImagesStore.shared.gifProgress = p } }
            lastGIF = r.url
            let size = Fmt.disk(UInt64(max(ImageConverter.size(r.url), 0)))
            gifMessage = r.trimmed ? String(localized: "GIF criado (\(size)), com os primeiros 30 segundos.") : String(localized: "GIF criado (\(size)).")
        } catch {
            gifMessage = L("Não consegui converter esse vídeo em GIF.")
        }
        gifProgress = nil
    }

    func pickVideo() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await makeGIF(from: url)
    }

    func reveal(_ urls: [URL]) { NSWorkspace.shared.activateFileViewerSelecting(urls) }

    func loadDemo() {
        demo = true
        let dir = URL(fileURLWithPath: "/Users/demo/Pictures")
        results = [ImageConverter.Result(source: dir.appendingPathComponent("IMG_2041.heic"), output: dir.appendingPathComponent("IMG_2041 (convertida).jpg"),
                                         before: 3_400_000, after: 610_000),
                   ImageConverter.Result(source: dir.appendingPathComponent("captura.png"), output: dir.appendingPathComponent("captura (convertida).jpg"),
                                         before: 2_100_000, after: 280_000)]
    }
}

struct ImagesView: View {
    @ObservedObject var store: ImagesStore
    @ObservedObject private var capture = CaptureStore.shared
    @StateObject private var targeted = Box(false)

    var body: some View {
        VStack(alignment: .leading, spacing: DS.md) {
            converterCard
            gifCard
        }
    }

    private var converterCard: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            Text("Converter e reduzir").font(DS.body.weight(.medium))
            dropZone
            HStack(spacing: DS.sm) {
                Text("Formato").font(DS.body)
                Spacer()
                Picker("Formato", selection: $store.options.format) {
                    ForEach(ImageConverter.Format.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 120)
            }
            HStack(spacing: DS.sm) {
                Text("Lado maior").font(DS.body)
                Spacer()
                Picker("Lado maior", selection: $store.options.maxSide) {
                    ForEach(ImageConverter.sides, id: \.self) { s in Text(s == 0 ? L("Original") : "\(s) px").tag(s) }
                }
                .labelsHidden().fixedSize()
            }
            if store.options.format == .jpeg {
                HStack(spacing: DS.sm) {
                    Text("Qualidade").font(DS.body)
                    Slider(value: Binding(get: { store.options.quality }, set: { store.options.quality = ($0 * 20).rounded() / 20 }), in: 0.4...1)
                        .controlSize(.small)
                    Text(Fmt.pct(store.options.quality)).font(DS.meta.monospacedDigit()).frame(width: 36, alignment: .trailing)
                }
            }
            if !store.results.isEmpty { resultsList }
            note("Fica ao lado do original, com “(convertida)” no nome. A localização e os outros metadados das fotos não passam para a cópia.")
        }
        .cardStyle()
    }

    private var dropZone: some View {
        Button { Task { await store.pickImages() } } label: {
            VStack(spacing: DS.xs) {
                if store.converting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 20 * TextSize.current.scale))
                }
                Text(store.converting ? L("A converter…") : L("Larga aqui imagens, ou clica para escolher")).font(DS.meta)
            }
            .foregroundStyle(targeted.value ? Color.accentColor : Color.text2)
            .frame(maxWidth: .infinity).frame(height: 76)
            .background(RoundedRectangle(cornerRadius: DS.rControl, style: .continuous)
                .strokeBorder(targeted.value ? Color.accentColor : Color.text3.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.converting)
        .dropDestination(for: URL.self) { urls, _ in
            Task { await store.convert(urls) }
            return urls.contains(where: ImageConverter.isImage)
        } isTargeted: { targeted.value = $0 }
    }

    private var resultsList: some View {
        let done = store.results.filter { $0.output != nil }
        let before = done.reduce(Int64(0)) { $0 + $1.before }, after = done.reduce(Int64(0)) { $0 + $1.after }
        return VStack(alignment: .leading, spacing: DS.xs) {
            ForEach(store.results, id: \.source) { r in
                HStack(spacing: DS.sm) {
                    Text(r.source.lastPathComponent).font(DS.body).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: DS.sm)
                    if r.output != nil {
                        Text(Fmt.disk(UInt64(r.before)) + " → " + Fmt.disk(UInt64(r.after)))
                            .font(DS.meta.monospacedDigit()).foregroundStyle(Color.text2)
                    } else {
                        Text("Falhou").font(DS.meta).foregroundStyle(Color.attentionText)
                    }
                }
            }
            HStack {
                if before > 0 && done.count > 1 {
                    Text(String(localized: "Total: \(Fmt.disk(UInt64(before))) → \(Fmt.disk(UInt64(after)))")).font(DS.meta).foregroundStyle(Color.text2)
                }
                Spacer()
                textLink("Mostrar no Finder") { store.reveal(done.compactMap(\.output)) }
            }
        }
    }

    private var gifCard: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            Text("Vídeo para GIF").font(DS.body.weight(.medium))
            if let p = store.gifProgress {
                ProgressView(value: p).controlSize(.small)
            } else {
                HStack(spacing: DS.sm) {
                    if let last = capture.last, last.pathExtension.lowercased() == "mov" {
                        Button("Última gravação") { Task { await store.makeGIF(from: last) } }.controlSize(.small)
                    }
                    Button("Escolher vídeo…") { Task { await store.pickVideo() } }.controlSize(.small)
                    Spacer()
                }
            }
            if let m = store.gifMessage {
                HStack {
                    note(m, color: .text2)
                    Spacer()
                    if let gif = store.lastGIF { textLink("Mostrar no Finder") { store.reveal([gif]) } }
                }
            }
            note("10 imagens por segundo, até 720 px de largura e 30 segundos. Fica ao lado do vídeo.")
        }
        .cardStyle()
    }
}
