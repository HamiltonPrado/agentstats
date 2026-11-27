import Foundation

/// A pasta da app em Application Support, onde vivem os históricos e as caches.
enum AppPaths {
    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AgentStats")

    static func support(_ name: String) -> URL { support.appendingPathComponent(name) }
}

/// JSON legível só pelo utilizador (0600) e fora das cópias de segurança do Time Machine.
enum PrivateFile {
    enum Loaded<T> {
        case missing
        case value(T)
        case unreadable
    }

    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> Loaded<T> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(type, from: data) else { return .unreadable }
        return .value(value)
    }

    /// O ficheiro temporário já nasce com 0600: nunca há um instante em que outros o possam ler.
    @discardableResult
    static func save<T: Encodable>(_ value: T, to url: URL, backup: Bool) -> Bool {
        let fm = FileManager.default
        guard let data = try? JSONEncoder().encode(value) else { return false }
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
            guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return false }
            guard rename(temp.path, url.path) == 0 else {
                try? fm.removeItem(at: temp)
                return false
            }
            if !backup {
                var target = url
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? target.setResourceValues(values)
            }
            return true
        } catch {
            return false
        }
    }
}
