import AppKit
import Darwin
import SwiftUI

struct InstalledApp: Identifiable, Sendable, Equatable {
    var id: String { path }
    let path: String
    let name: String
    let bundleID: String
}

/// O que se mostrou para confirmar. `signature` prende cada caminho ao ficheiro que lá estava.
struct UninstallPlan: Sendable, Equatable {
    struct Entry: Sendable, Equatable, Identifiable {
        var id: String { path }
        let path: String
        let signature: UninstallRules.Signature
    }

    let app: InstalledApp
    let bundle: Entry
    let leftovers: [Entry]
    /// Há outra cópia com o mesmo identificador: os dados também são dela e não se oferecem.
    let sharedWithCopy: Bool
}

enum UninstallRules {
    struct Signature: Sendable, Equatable {
        let device: Int32
        let inode: UInt64
    }

    /// Sem seguir ligações simbólicas (que nunca entram).
    static func signature(_ path: String) -> Signature? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK else { return nil }
        return Signature(device: info.st_dev, inode: info.st_ino)
    }

    /// O identificador vai para dentro de caminhos a apagar: tem de ser mesmo um identificador.
    static func validBundleID(_ id: String) -> Bool {
        id.count <= 155 && id.range(of: #"\A[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)+\z"#, options: .regularExpression) != nil
    }

    static func removable(bundleID: String, ownID: String = "local.agentstats") -> Bool {
        let id = bundleID.lowercased()
        return validBundleID(bundleID) && !id.hasPrefix("com.apple.") && id != ownID
    }

    /// Só caminhos exatos pelo identificador, nunca por nomes parecidos. Os Group Containers ficam de
    /// fora, porque são partilhados entre apps. Nada se enumera: listar Containers de outras apps faz o
    /// macOS pedir permissão.
    static func candidates(bundleID id: String, home: String) -> [String] {
        guard validBundleID(id) else { return [] }
        let relative = [
            String(localized: "Application Support/\(id)"),
            String(localized: "Application Scripts/\(id)"),
            "Caches/\(id)",
            "Containers/\(id)",
            "Cookies/\(id).binarycookies",
            "HTTPStorages/\(id)",
            "HTTPStorages/\(id).binarycookies",
            "LaunchAgents/\(id).plist",
            "Logs/\(id)",
            "Preferences/\(id).plist",
            String(localized: "Saved Application State/\(id).savedState"),
            "WebKit/\(id)",
        ]
        return relative.map { "\(home)/Library/\($0)" }
    }

    static func bundleID(appPath: String) -> String? {
        // Não usa Bundle(url:), que guarda em cache o que leu: aqui interessa o que está lá agora.
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: appPath + "/Contents/Info.plist")),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return nil }
        return plist["CFBundleIdentifier"] as? String
    }

    /// Todas as apps das pastas, também as que não se podem remover (contam como cópias).
    static func scan(_ roots: [String]) -> [InstalledApp] {
        var out: [InstalledApp] = []
        for root in roots {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for name in names where name.hasSuffix(".app") {
                let path = "\(root)/\(name)"
                guard signature(path) != nil, let id = bundleID(appPath: path) else { continue }
                out.append(InstalledApp(path: path, name: String(name.dropLast(4)), bundleID: id))
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func plan(app: InstalledApp, home: String, copies: [String]) -> UninstallPlan? {
        guard removable(bundleID: app.bundleID), let appSignature = signature(app.path) else { return nil }
        let own = URL(fileURLWithPath: app.path).resolvingSymlinksInPath().path
        let shared = copies.contains { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path != own }
        let leftovers: [UninstallPlan.Entry] = shared ? [] : candidates(bundleID: app.bundleID, home: home).compactMap { path in
            signature(path).map { UninstallPlan.Entry(path: path, signature: $0) }
        }
        return UninstallPlan(app: app, bundle: .init(path: app.path, signature: appSignature),
                             leftovers: leftovers, sharedWithCopy: shared)
    }
}

@MainActor
final class UninstallStore: ObservableObject {
    struct Environment {
        var home = FileManager.default.homeDirectoryForCurrentUser.path
        var roots = ["/Applications", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        /// A única forma de remover: nada aqui apaga de vez.
        var trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
        var isRunning: (String) -> Bool = { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
        /// Outras cópias que o macOS conhece fora das pastas de apps (as que já estão no Lixo não contam).
        var knownCopies: (String) -> [String] = { id in
            NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id).map(\.path)
                .filter { !$0.contains("/.Trash/") && !$0.contains("/.Trashes/") && FileManager.default.fileExists(atPath: $0) }
        }
    }

    static let shared = UninstallStore(environment: Environment())

    @Published private(set) var apps: [InstalledApp] = []
    @Published private(set) var loaded = false
    @Published private(set) var plan: UninstallPlan?
    @Published var selected = Set<String>()
    @Published var confirming = false
    @Published private(set) var message: String?

    private let environment: Environment
    private var all: [InstalledApp] = []
    private var demo = false

    init(environment: Environment) {
        self.environment = environment
    }

    func refresh() async {
        guard !demo else { return }
        let roots = environment.roots
        all = await Task.detached(priority: .userInitiated) { UninstallRules.scan(roots) }.value
        apps = all.filter { UninstallRules.removable(bundleID: $0.bundleID) }
        loaded = true
    }

    private func copies(of id: String) -> [String] {
        all.filter { $0.bundleID.caseInsensitiveCompare(id) == .orderedSame }.map(\.path) + environment.knownCopies(id)
    }

    /// Os restos começam todos por marcar: um Container pode ter documentos.
    func choose(_ app: InstalledApp) {
        guard !demo else { return }
        confirming = false
        selected = []
        message = nil
        plan = UninstallRules.plan(app: app, home: environment.home, copies: copies(of: app.bundleID))
        if plan == nil { message = "Esta app não pode ser removida por aqui." }
    }

    func cancel() {
        plan = nil
        selected = []
        confirming = false
    }

    func moveToTrash() {
        confirming = false
        guard !demo, let plan else { return }
        let app = plan.app
        guard UninstallRules.signature(app.path) == plan.bundle.signature,
              UninstallRules.bundleID(appPath: app.path) == app.bundleID else {
            cancel()
            message = String(localized: "\(app.name) mudou entretanto. Não removi nada.")
            return
        }
        guard !environment.isRunning(app.bundleID) else {
            message = String(localized: "Fecha \(app.name) primeiro. Não removi nada.")
            return
        }
        do {
            try environment.trash(URL(fileURLWithPath: app.path))
        } catch {
            // Se a app fica, os dados dela também ficam.
            message = String(localized: "O macOS não me deixou mover \(app.name), por isso não mexi nos restos. Arrasta-a no Finder, que pede a password.")
            return
        }

        var failed: [String] = []
        for entry in plan.leftovers where selected.contains(entry.path) {
            guard UninstallRules.signature(entry.path) == entry.signature else {
                failed.append(entry.path)
                continue
            }
            do { try environment.trash(URL(fileURLWithPath: entry.path)) } catch { failed.append(entry.path) }
        }
        apps.removeAll { $0.path == app.path }
        all.removeAll { $0.path == app.path }
        cancel()
        message = failed.isEmpty
            ? String(localized: "\(app.name) está no Lixo. Se te enganaste, ainda a podes repor.")
            : String(localized: "\(app.name) está no Lixo, mas \(L(failed.count == 1 ? "este resto ficou" : "estes restos ficaram")): ")
                + failed.map(shortPath).joined(separator: ", ")
    }

    func shortPath(_ path: String) -> String {
        path.hasPrefix(environment.home) ? "~" + path.dropFirst(environment.home.count) : path
    }

    func loadDemo() {
        demo = true
        loaded = true
        all = [
            InstalledApp(path: "/Applications/Editor.app", name: "Editor", bundleID: "com.example.editor"),
            InstalledApp(path: "/Applications/Notas Rápidas.app", name: "Notas Rápidas", bundleID: "com.example.notes"),
            InstalledApp(path: "/Applications/Terminal Plus.app", name: "Terminal Plus", bundleID: "com.example.terminal"),
        ]
        apps = all
    }
}
