import Darwin
import SwiftUI

/// O disco por categorias, aproximadas por pastas: o macOS não dá às apps a divisão das Definições.
enum DiskStorage {
    enum Category: CaseIterable, Sendable {
        case apps, documents, music, photos, videos, developer, other, pending, used, free

        var label: String {
            switch self {
            case .apps: "Aplicações"
            case .documents: "Documentos"
            case .music: "Música"
            case .photos: "Fotografias"
            case .videos: "Filmes"
            case .developer: "Programador"
            case .other: "Sistema e outros"
            case .pending: "Por medir"
            case .used: "Usado"
            case .free: "Livre"
            }
        }

        /// As cores da barra de Armazenamento do iOS e do macOS.
        func color(usage: Double) -> Color {
            // Por analisar, o usado continua a avisar quando o disco enche, como a barra de antes.
            self == .used && usage > 0.7 ? Palette.heat(usage) : color
        }

        private var color: Color {
            switch self {
            case .apps: .red
            case .documents: .orange
            case .music: .yellow
            case .photos: .green
            case .videos: .purple
            case .developer: .teal
            case .other, .pending, .used: .gray
            case .free: Contrast.backdrop.color   // leva texto por cima
            }
        }
    }

    struct Root: Sendable, Equatable {
        let category: Category
        let path: String
        /// O nome na lista "Pastas maiores", só para as pastas pessoais.
        var listed: String? = nil
    }

    struct Measure: Sendable, Equatable {
        let root: Root
        let bytes: UInt64
        /// Falso: houve pastas que não se puderam ler, e o total fica por baixo.
        let complete: Bool
    }

    struct Part: Sendable, Equatable, Identifiable {
        var id: Category { category }
        let category: Category
        let bytes: UInt64
    }

    static func roots(home: String) -> [Root] {
        var out: [Root] = []
        out.append(Root(category: .apps, path: "/Applications"))
        out.append(Root(category: .apps, path: home + "/Applications"))
        out.append(Root(category: .documents, path: home + "/Desktop", listed: "Desktop"))
        out.append(Root(category: .documents, path: home + "/Documents", listed: "Documents"))
        out.append(Root(category: .documents, path: home + "/Downloads", listed: "Downloads"))
        out.append(Root(category: .music, path: home + "/Music", listed: "Music"))
        out.append(Root(category: .photos, path: home + "/Pictures", listed: "Pictures"))
        out.append(Root(category: .videos, path: home + "/Movies", listed: "Movies"))
        out.append(Root(category: .developer, path: home + "/Library/Developer"))
        out.append(Root(category: .developer, path: "/Library/Developer"))
        out.append(Root(category: .developer, path: "/opt/homebrew"))
        return out
    }

    /// Ocupação real em disco, com o interior dos pacotes. O `du` não segue ligações nem sai do volume.
    /// nil: a pasta não existe ou é uma ligação.
    static func measure(_ root: Root, timeout: TimeInterval = 5 * 60) async -> Measure? {
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
        let result = await ToolRunner.run("/usr/bin/du", ["-skxP", root.path], timeout: timeout)
        let bytes: UInt64? = bytes(duOutput: result.out)
        return Measure(root: root, bytes: bytes ?? 0, complete: result.ok && bytes != nil)
    }

    static func bytes(duOutput: String) -> UInt64? {
        guard let field = duOutput.split(separator: "\t").first,
              let kilobytes = UInt64(field.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let (bytes, overflow) = kilobytes.multipliedReportingOverflow(by: 1024)
        return overflow ? nil : bytes
    }

    /// Somam exatamente o disco. Sem medição é só usado e livre; a meio da primeira, o resto está "Por medir";
    /// no fim, o que não se mediu é "Sistema e outros".
    static func parts(total: UInt64, free: UInt64, measures: [Measure]?, finished: Bool = true) -> [Part] {
        let available: UInt64 = min(free, total)
        var left: UInt64 = total - available
        var out: [Part] = []
        if let measures {
            let measured: [Category] = [.apps, .documents, .music, .photos, .videos, .developer]
            for category in measured {
                var sum: UInt64 = 0
                for m in measures where m.root.category == category { sum += m.bytes }
                // Cópias APFS partilham blocos e o du conta-as duas vezes: nunca passa do que está usado.
                let taken: UInt64 = min(sum, left)
                left -= taken
                out.append(Part(category: category, bytes: taken))
            }
            out.append(Part(category: finished ? .other : .pending, bytes: left))
        } else {
            out.append(Part(category: .used, bytes: left))
        }
        out.append(Part(category: .free, bytes: available))
        return out.filter { $0.bytes > 0 }
    }

    /// Larguras que enchem a barra exatamente. Uma parte muito pequena continua a ver-se, à custa da maior.
    static func widths(_ parts: [Part], width: Double, gap: Double, minimum: Double = 3) -> [Double] {
        guard !parts.isEmpty else { return [] }
        let available: Double = max(0, width - gap * Double(parts.count - 1))
        let sum: Double = parts.reduce(0.0) { $0 + Double($1.bytes) }
        guard sum > 0, available >= minimum * Double(parts.count) else {
            return Array(repeating: available / Double(parts.count), count: parts.count)
        }
        var out: [Double] = parts.map { max(minimum, available * Double($0.bytes) / sum) }
        let excess: Double = out.reduce(0, +) - available
        if let widest = out.indices.max(by: { out[$0] < out[$1] }) {
            out[widest] = max(minimum, out[widest] - excess)
        }
        return out
    }
}

/// Mede sozinho quando o cartão do Disco aparece (nunca ao arrancar) e guarda o resultado, para a barra
/// abrir logo com cores. Vive fora da vista: o pedido de permissão do macOS fecha o painel e a medição continua.
@MainActor
final class DiskScanStore: ObservableObject {
    static let shared = DiskScanStore(cacheFile: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AgentStats/disk.json"))

    /// Com uma medição mais velha do que isto, abrir o Disco volta a medir.
    static let maxAge: TimeInterval = 6 * 3600

    private struct Saved: Codable {
        struct Item: Codable {
            let path: String
            let bytes: UInt64
            let complete: Bool
        }
        let date: Date
        let items: [Item]
    }

    @Published private(set) var measures: [DiskStorage.Measure]?
    /// Quando acabou a última medição (nil: ainda não houve uma inteira).
    @Published private(set) var measuredAt: Date?
    /// A categoria que está a ser medida (nil: parado).
    @Published private(set) var current: DiskStorage.Category?

    private let roots: [DiskStorage.Root]
    private let cacheFile: URL?
    private let measure: @Sendable (DiskStorage.Root) async -> DiskStorage.Measure?
    private var restored = false
    private var demo = false

    /// `cacheFile` nil: só em memória.
    init(roots: [DiskStorage.Root] = DiskStorage.roots(home: FileManager.default.homeDirectoryForCurrentUser.path),
         cacheFile: URL? = nil,
         measure: @escaping @Sendable (DiskStorage.Root) async -> DiskStorage.Measure? = { await DiskStorage.measure($0) }) {
        self.roots = roots
        self.cacheFile = cacheFile
        self.measure = measure
    }

    var running: Bool { current != nil }

    var folders: [DiskStorage.Measure] {
        (measures ?? []).filter { $0.root.listed != nil }.sorted { $0.bytes > $1.bytes }
    }

    var incomplete: [DiskStorage.Category] {
        let unread = Set((measures ?? []).filter { !$0.complete }.map(\.root.category))
        return DiskStorage.Category.allCases.filter { unread.contains($0) }
    }

    /// Chamado quando o cartão aparece: mostra o que está guardado e, se faltar ou for antigo, mede.
    @discardableResult
    func refreshIfNeeded(now: Date = Date()) -> Task<Void, Never>? {
        guard !demo else { return nil }
        restore()
        // Uma data no futuro (relógio acertado) também conta como antiga.
        if let last = measuredAt, (0..<Self.maxAge).contains(now.timeIntervalSince(last)) { return nil }
        return start(now: now)
    }

    /// Uma pasta de cada vez, para os pedidos de permissão não aparecerem todos juntos.
    @discardableResult
    func start(now: Date = Date()) -> Task<Void, Never>? {
        guard !demo, !running, let first = roots.first else { return nil }
        current = first.category
        // A primeira vez vai pintando à medida que mede; ao atualizar, fica a anterior até haver a nova inteira.
        let progressive: Bool = measuredAt == nil
        return Task {
            var found: [DiskStorage.Measure] = []
            for root in roots {
                current = root.category
                guard let m = await measure(root) else { continue }
                found.append(m)
                if progressive { measures = found }
            }
            measures = found
            measuredAt = now
            current = nil
            save(found, date: now)
        }
    }

    private func restore() {
        guard !restored else { return }
        restored = true
        guard measures == nil, let cacheFile, case .value(let saved) = PrivateFile.load(Saved.self, from: cacheFile) else { return }
        var found: [DiskStorage.Measure] = []
        for item in saved.items {
            guard let root = roots.first(where: { $0.path == item.path }) else { continue }
            found.append(DiskStorage.Measure(root: root, bytes: item.bytes, complete: item.complete))
        }
        guard !found.isEmpty else { return }
        measures = found
        measuredAt = saved.date
    }

    private func save(_ found: [DiskStorage.Measure], date: Date) {
        guard let cacheFile else { return }
        var items: [Saved.Item] = []
        for m in found { items.append(Saved.Item(path: m.root.path, bytes: m.bytes, complete: m.complete)) }
        // Só tamanhos, e volta-se a medir: se não gravar, não se perde nada.
        _ = PrivateFile.save(Saved(date: date, items: items), to: cacheFile, backup: false)
    }

    /// Para as capturas: nunca os tamanhos reais.
    func loadDemo() {
        demo = true
        let sizes: [UInt64] = [62, 0, 6, 30, 12, 14, 22, 9, 0, 4, 12]
        var found: [DiskStorage.Measure] = []
        for (root, size) in zip(DiskStorage.roots(home: "/Users/demo"), sizes) {
            found.append(DiskStorage.Measure(root: root, bytes: size * 1_000_000_000, complete: true))
        }
        measures = found
        measuredAt = Date().addingTimeInterval(-600)
    }
}

/// Barra segmentada como a de Armazenamento, com o livre por dentro quando cabe.
struct DiskBar: View {
    let parts: [DiskStorage.Part]
    let usage: Double

    private static let gap: CGFloat = 1
    private static let height: CGFloat = 22

    var body: some View {
        GeometryReader { g in
            let widths = DiskStorage.widths(parts, width: Double(g.size.width), gap: Double(Self.gap))
            HStack(spacing: Self.gap) {
                ForEach(Array(parts.enumerated()), id: \.element.id) { i, part in
                    part.category.color(usage: usage)
                        .frame(width: CGFloat(widths[i]), height: Self.height)
                        .overlay { if part.category == .free { freeLabel(part.bytes) } }
                }
            }
        }
        .frame(height: Self.height)
        .clipShape(RoundedRectangle(cornerRadius: DS.rSmall, style: .continuous))
        .accessibilityHidden(true)   // os valores estão na legenda, por extenso
    }

    private func freeLabel(_ bytes: UInt64) -> some View {
        ViewThatFits(in: .horizontal) {
            label(Fmt.disk(bytes))   // igual à legenda
            label(Fmt.diskShort(bytes))
            Color.clear.frame(width: 0, height: 0)
        }
    }

    private func label(_ text: String) -> some View {
        Text(L(text))
            .font(DS.meta.weight(.medium).monospacedDigit())
            .foregroundStyle(Color.primary)
            .fixedSize()
            .padding(.horizontal, 2)
    }
}

/// O cartão do Disco: barra por categorias, leitura e escrita, e as pastas maiores.
struct DiskCard: View {
    let disk: DiskSample
    @ObservedObject var store: DiskScanStore
    @AppStorage("panel.tab2") private var tab: Tab = .agents
    @AppStorage("tools.section") private var toolSection: ToolSection = .ports
    @AppStorage(TabLayout.orderKey) private var tabOrder = ""
    @AppStorage(TabLayout.hiddenKey) private var hiddenTabs = ""

    var body: some View {
        let parts = DiskStorage.parts(total: disk.total, free: disk.free, measures: store.measures,
                                      finished: store.measuredAt != nil)
        Card(title: "Disco", icon: "internaldrive", trailing: String(localized: "\(Fmt.disk(disk.used)) de \(Fmt.disk(disk.total))")) {
            DiskBar(parts: parts, usage: disk.usage)
            ForEach(parts) { legend($0) }
            if let current = store.current {
                note(store.measuredAt == nil
                     ? String(localized: "A medir \(current.label). Se o macOS pedir acesso, é para isto. Continua se fechares o painel.")
                     : String(localized: "A atualizar \(current.label)…"))
            } else if let at = store.measuredAt {
                note(String(localized: "Aproximado por pastas · medido \(Fmt.ago(at))"))
            }
            if !store.incomplete.isEmpty {
                let names: String = store.incomplete.map(\.label).joined(separator: ", ")
                note(String(localized: "Não consegui ler tudo em \(names). O que falta conta em Sistema e outros."), color: .waitingText)
            }
            if TabLayout.visible(order: tabOrder, hidden: hiddenTabs).contains(.tools) {
                Button("Limpar caches…") {
                    toolSection = .cleanup
                    tab = .tools
                }
                .buttonStyle(.plain).modifier(AccentText()).font(DS.meta)
                .help("Abre Ferramentas → Limpeza. Nada se move sem confirmares.")
            }
            Divider().opacity(0.5)
            StatRow(label: "Leitura", value: Fmt.rate(disk.readPerSec))
            StatRow(label: "Escrita", value: Fmt.rate(disk.writePerSec))
            Divider().opacity(0.5)
            HStack {
                Text("Pastas maiores").font(DS.body.weight(.medium))
                Spacer()
                if store.running {
                    note("A medir…")   // estado, e não um botão desativado que mal se lê
                } else {
                    Button("Atualizar") { store.start() }
                        .buttonStyle(.plain).modifier(AccentText()).font(DS.meta)
                }
            }
            ForEach(store.folders, id: \.root.path) { item in
                StatRow(label: item.root.listed ?? "", value: Fmt.disk(item.bytes))
            }
        }
        .onAppear { _ = store.refreshIfNeeded() }
    }

    private func legend(_ part: DiskStorage.Part) -> some View {
        HStack(spacing: DS.sm) {
            Circle().fill(part.category.color(usage: disk.usage)).overlay(Circle().strokeBorder(DS.hairline)).frame(width: 8, height: 8)
            Text(L(part.category.label)).foregroundStyle(Color.text2)
            Spacer(minLength: DS.sm)
            Text(L(Fmt.disk(part.bytes))).monospacedDigit().foregroundStyle(Color.primary)
        }
        .font(DS.body)
        .accessibilityElement(children: .combine)
    }
}
