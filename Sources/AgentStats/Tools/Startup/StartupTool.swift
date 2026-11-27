import AppKit
import Foundation

/// Um LaunchAgent ou LaunchDaemon: o que arranca sozinho com a sessão ou com o Mac.
struct LaunchItem: Identifiable, Equatable, Sendable {
    enum Scope: String, Sendable { case user, agent, daemon }
    var id: String { plist }
    let label: String
    let plist: String
    let scope: Scope
    var program: String?
    var appName: String?
    var runAtLoad = false
    var keepAlive = false
    var disabled = false
    var running = false

    /// Só os teus se desligam por aqui: os outros são do administrador e às vezes de segurança.
    var canToggle: Bool { scope == .user }
    var title: String { appName ?? label }
}

enum StartupRules {
    static func folders(home: String) -> [(String, LaunchItem.Scope)] {
        [(home + "/Library/LaunchAgents", .user), ("/Library/LaunchAgents", .agent), ("/Library/LaunchDaemons", .daemon)]
    }

    static func item(plist: [String: Any], path: String, scope: LaunchItem.Scope) -> LaunchItem? {
        guard let label = plist["Label"] as? String, !label.isEmpty else { return nil }
        let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [Any])?.first as? String
        let keepAlive: Bool = {
            if let b = plist["KeepAlive"] as? Bool { return b }
            return plist["KeepAlive"] is [String: Any]
        }()
        return LaunchItem(label: label, plist: path, scope: scope, program: program, appName: program.flatMap(appName),
                          runAtLoad: plist["RunAtLoad"] as? Bool ?? false, keepAlive: keepAlive,
                          disabled: plist["Disabled"] as? Bool ?? false)
    }

    /// "/Applications/AltTab.app/Contents/MacOS/AltTab" → "AltTab".
    static func appName(program: String) -> String? {
        guard let r = program.range(of: ".app/") ?? (program.hasSuffix(".app") ? program.range(of: ".app") : nil) else { return nil }
        let bundle = String(program[..<r.lowerBound])
        let name = (bundle as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    /// `launchctl print-disabled`: `"label" => disabled` (ou `=> true` nas versões antigas).
    static func disabledLabels(_ output: String) -> (disabled: Set<String>, enabled: Set<String>) {
        var off = Set<String>(), on = Set<String>()
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\"")
            guard parts.count >= 3 else { continue }
            let label = String(parts[1])
            let state = parts[2].trimmingCharacters(in: .whitespaces)
            if state.hasSuffix("disabled") || state.hasSuffix("true") { off.insert(label) }
            else if state.hasSuffix("enabled") || state.hasSuffix("false") { on.insert(label) }
        }
        return (off, on)
    }

    /// `launchctl list`: PID, estado e label. Com PID, está a correr.
    static func runningLabels(_ output: String) -> Set<String> {
        var out = Set<String>()
        for line in output.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count >= 3, Int(cols[0]) != nil else { continue }
            out.insert(String(cols[2]))
        }
        return out
    }

    static func sorted(_ items: [LaunchItem]) -> [LaunchItem] {
        let order: [LaunchItem.Scope: Int] = [.user: 0, .agent: 1, .daemon: 2]
        return items.sorted { (order[$0.scope]!, $0.title.lowercased()) < (order[$1.scope]!, $1.title.lowercased()) }
    }
}

@MainActor
final class StartupStore: ObservableObject {
    static let shared = StartupStore()

    @Published private(set) var items: [LaunchItem] = []
    @Published private(set) var loaded = false
    @Published private(set) var busy: Set<String> = []
    @Published var confirming: String?
    @Published private(set) var message: String?
    private var demo = false
    private var domain: String { "gui/\(getuid())" }

    func refresh() async {
        guard !demo else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var found: [LaunchItem] = []
        for (folder, scope) in StartupRules.folders(home: home) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            for name in names where name.hasSuffix(".plist") {
                let path = folder + "/" + name
                guard let data = FileManager.default.contents(atPath: path),
                      let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                      let item = StartupRules.item(plist: plist, path: path, scope: scope) else { continue }
                found.append(item)
            }
        }
        let user = StartupRules.disabledLabels(await ToolRunner.run("/bin/launchctl", ["print-disabled", domain], timeout: 10).out)
        let system = StartupRules.disabledLabels(await ToolRunner.run("/bin/launchctl", ["print-disabled", "system"], timeout: 10).out)
        let running = StartupRules.runningLabels(await ToolRunner.run("/bin/launchctl", ["list"], timeout: 10).out)
        for i in found.indices {
            let states = found[i].scope == .daemon ? system : user
            if states.disabled.contains(found[i].label) { found[i].disabled = true }
            if states.enabled.contains(found[i].label) { found[i].disabled = false }
            found[i].running = found[i].scope != .daemon && running.contains(found[i].label)
        }
        items = StartupRules.sorted(found)
        loaded = true
    }

    /// Desligar: para o serviço e diz ao launchd para não o voltar a abrir. Ligar faz o contrário.
    func set(_ item: LaunchItem, enabled: Bool) async {
        guard !demo, item.canToggle, !busy.contains(item.id) else { return }
        busy.insert(item.id)
        confirming = nil
        message = nil
        let ok: Bool
        if enabled {
            let a = await ToolRunner.run("/bin/launchctl", ["enable", "\(domain)/\(item.label)"], timeout: 15)
            _ = await ToolRunner.run("/bin/launchctl", ["bootstrap", domain, item.plist], timeout: 15)   // já carregado também conta
            ok = a.ok
        } else {
            _ = await ToolRunner.run("/bin/launchctl", ["bootout", domain, item.plist], timeout: 15)      // pode não estar a correr
            ok = await ToolRunner.run("/bin/launchctl", ["disable", "\(domain)/\(item.label)"], timeout: 15).ok
        }
        if !ok { message = String(localized: "Não consegui \(L(enabled ? "ligar" : "desligar")) \(item.title).") }
        busy.remove(item.id)
        await refresh()
    }

    func reveal(_ item: LaunchItem) {
        Finder.reveal(path: item.plist)
    }

    func openLoginItems() {
        SystemSettings.open(.loginItems)
    }

    func loadDemo() {
        demo = true
        loaded = true
        items = [
            LaunchItem(label: "com.example.sync", plist: "~/Library/LaunchAgents/com.example.sync.plist", scope: .user,
                       program: "/Applications/Sync.app/Contents/MacOS/Sync", appName: "Sync", runAtLoad: true, running: true),
            LaunchItem(label: "org.example.backup", plist: "~/Library/LaunchAgents/org.example.backup.plist", scope: .user,
                       program: "/usr/local/bin/backup", runAtLoad: true, disabled: true),
            LaunchItem(label: "com.example.updater", plist: "/Library/LaunchAgents/com.example.updater.plist", scope: .agent,
                       program: "/Library/Application Support/Example/Updater.app/Contents/MacOS/Updater", appName: "Updater", runAtLoad: true),
            LaunchItem(label: "com.example.helper", plist: "/Library/LaunchDaemons/com.example.helper.plist", scope: .daemon,
                       program: "/Library/PrivilegedHelperTools/com.example.helper", keepAlive: true),
        ]
    }
}
