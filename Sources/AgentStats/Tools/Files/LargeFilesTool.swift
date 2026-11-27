import AppKit
import CoreServices
import Foundation

struct BigFile: Identifiable, Equatable, Sendable {
    var id: String { path }
    let path: String
    let size: UInt64
    let modified: Date
    var lastUsed: Date?
    /// O ficheiro visto na análise: ir para o Lixo só se ainda for esse (não um que o substituiu entretanto).
    var signature: UninstallRules.Signature? = nil
    var name: String { (path as NSString).lastPathComponent }
    /// A última vez que se lhe mexeu ou que foi aberto.
    var lastTouched: Date { max(modified, lastUsed ?? .distantPast) }
}

enum LargeFilesRules {
    static let floor: UInt64 = 100_000_000
    static let sizes: [UInt64] = [100_000_000, 500_000_000, 1_000_000_000]
    static let oldAfterMonths = 6
    /// Pastas que não interessam ou que são de apps: as apps limpam-nas, não tu.
    static let skipped: Set<String> = ["Library", "node_modules", ".Trash", "Applications"]

    static func isOld(_ f: BigFile, now: Date) -> Bool {
        guard let limit = Calendar.current.date(byAdding: .month, value: -oldAfterMonths, to: now) else { return false }
        return f.lastTouched < limit
    }

    static func shown(_ files: [BigFile], minSize: UInt64, onlyOld: Bool, now: Date) -> [BigFile] {
        files.filter { $0.size >= minSize && (!onlyOld || isOld($0, now: now)) }.sorted { $0.size > $1.size }
    }

    /// "hoje", "há 3 dias", "há 5 meses", "há 2 anos".
    static func age(_ d: Date, now: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d, to: now)
        if let y = c.year, y > 0 { return y == 1 ? "há 1 ano" : String(localized: "há \(y) anos") }
        if let m = c.month, m > 0 { return m == 1 ? "há 1 mês" : String(localized: "há \(m) meses") }
        if let dd = c.day, dd > 0 { return dd == 1 ? "ontem" : String(localized: "há \(dd) dias") }
        return "hoje"
    }

    /// Percorre a pasta pessoal (sem Library, pastas escondidas nem o interior de pacotes como .app ou .photoslibrary).
    static func scan(home: URL, minSize: UInt64 = floor, limit: Int = 300) -> [BigFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey,
                                      .totalFileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey]
        guard let e = FileManager.default.enumerator(at: home, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) else { return [] }
        var found: [BigFile] = []
        for case let url as URL in e {
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isDirectory == true {
                if v.isPackage == true || (skipped.contains(url.lastPathComponent)) { e.skipDescendants() }
                continue
            }
            guard v.isRegularFile == true, v.isSymbolicLink != true else { continue }
            let size = UInt64(v.totalFileAllocatedSize ?? v.fileSize ?? 0)
            guard size >= minSize else { continue }
            found.append(BigFile(path: url.path, size: size, modified: v.contentModificationDate ?? .distantPast,
                                 signature: UninstallRules.signature(url.path)))
        }
        found.sort { $0.size > $1.size }
        return Array(found.prefix(limit)).map { f in
            var f = f
            f.lastUsed = lastUsed(f.path)
            return f
        }
    }

    /// A data de "Última abertura" do Finder.
    static func lastUsed(_ path: String) -> Date? {
        guard let item = MDItemCreate(nil, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}

@MainActor
final class LargeFilesStore: ObservableObject {
    static let shared = LargeFilesStore()

    @Published private(set) var files: [BigFile] = []
    @Published private(set) var scanning = false
    @Published private(set) var scannedAt: Date?
    @Published var confirming: String?
    @Published private(set) var message: String?
    @Published var minSize: UInt64 = Pref.double("files.minSize", 500_000_000) > 0
        ? UInt64(Pref.double("files.minSize", 500_000_000)) : 500_000_000 {
        didSet { Pref.set(Double(minSize), "files.minSize") }
    }
    @Published var onlyOld: Bool = Pref.bool("files.onlyOld", false) { didSet { Pref.set(onlyOld, "files.onlyOld") } }
    private var demo = false
    private var demoNow: Date?

    var now: Date { demoNow ?? Date() }
    var shown: [BigFile] { LargeFilesRules.shown(files, minSize: minSize, onlyOld: onlyOld, now: demoNow ?? Date()) }

    func scan() async {
        guard !demo, !scanning else { return }
        scanning = true
        message = nil
        let home = FileManager.default.homeDirectoryForCurrentUser
        files = await Blocking.run(qos: .utility) { LargeFilesRules.scan(home: home) }
        scannedAt = Date()
        scanning = false
    }

    func trash(_ f: BigFile) {
        confirming = nil
        guard !demo else { return }
        let url = URL(fileURLWithPath: f.path)
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard let expected = f.signature, UninstallRules.signature(f.path) == expected, modified == f.modified else {
            message = String(localized: "\(f.name) mudou desde a análise. Não mexi; analisa outra vez.")
            return
        }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            files.removeAll { $0.id == f.id }
            message = String(localized: "\(f.name) foi para o Lixo. O espaço fica livre quando o esvaziares.")
        } catch {
            message = String(localized: "Não consegui mover \(f.name) para o Lixo.")
        }
    }

    func reveal(_ f: BigFile) {
        Finder.reveal(path: f.path)
    }

    func loadDemo(now: Date = Date()) {
        demo = true
        demoNow = now
        scannedAt = now
        let day: TimeInterval = 86_400
        files = [
            BigFile(path: "/Users/demo/Downloads/macOS-instalador.dmg", size: 13_400_000_000, modified: now - 400 * day),
            BigFile(path: "/Users/demo/Movies/Férias 2024.mov", size: 6_200_000_000, modified: now - 500 * day, lastUsed: now - 300 * day),
            BigFile(path: "/Users/demo/Documents/Projeto/dados.csv", size: 1_100_000_000, modified: now - 3 * day),
            BigFile(path: "/Users/demo/Downloads/ubuntu-24.04.iso", size: 6_000_000_000, modified: now - 60 * day),
        ]
    }
}
