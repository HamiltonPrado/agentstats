import Foundation

struct FolderSize: Identifiable, Sendable {
    let name: String
    let bytes: UInt64
    var id: String { name }
}

enum FolderScanState: Sendable {
    case idle, scanning, loaded([FolderSize])
    var isScanning: Bool { if case .scanning = self { true } else { false } }
    var results: [FolderSize]? { if case .loaded(let values) = self { values } else { nil } }
}

/// Varre apenas pastas comuns da pasta pessoal e só é chamado por ação do utilizador.
enum FolderScanner {
    static func scanHome() -> [FolderSize] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let names = ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures"]
        return names.compactMap { name -> FolderSize? in
            let root = home.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .fileAllocatedSizeKey]
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }) else { return nil }
            var total: UInt64 = 0
            // O varrimento termina com um limite para não ocupar o Mac em bibliotecas enormes.
            var visited = 0
            for case let url as URL in enumerator {
                visited += 1
                if visited > 100_000 { break }
                guard let values = try? url.resourceValues(forKeys: keys), values.isDirectory != true,
                      values.isSymbolicLink != true else { continue }
                total += UInt64(max(values.fileAllocatedSize ?? 0, 0))
            }
            return FolderSize(name: name, bytes: total)
        }.sorted { $0.bytes > $1.bytes }
    }
}
