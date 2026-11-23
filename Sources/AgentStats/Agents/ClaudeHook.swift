import Foundation

/// O hook de `Notification` do Claude Code em `~/.claude/settings.json`: diz ao AgentStats quando um agente
/// pede aprovação ou fica à espera, em vez de o adivinhar pelos processos.
/// Só se mexe nas entradas do AgentStats; o resto do ficheiro fica como estava, a menos da formatação.
enum ClaudeHook {
    enum State: Equatable, Sendable {
        /// Sem `~/.claude`: o Claude Code não está instalado.
        case noClaude
        case off
        case on
        /// Existe, mas aponta para uma app que já não está lá.
        case stale
        /// O ficheiro existe e não é JSON que se perceba: não se lhe toca.
        case unreadable
    }

    enum Failure: Error, Equatable {
        case unreadable, notSaved
    }

    static let marker = "--hook"

    static func command(executable: String) -> String {
        "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "' \(marker) 2>/dev/null || true"
    }

    static func isOurs(_ command: String) -> Bool {
        command.contains("AgentStats") && command.contains(marker)
    }

    /// O executável a que um comando nosso aponta, com ou sem aspas.
    static func executable(in command: String) -> String? {
        guard let range = command.range(of: " " + marker) else { return nil }
        var path = String(command[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        if path.hasPrefix("'") && path.hasSuffix("'") && path.count >= 2 {
            path = String(path.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
        } else if path.hasPrefix("\"") && path.hasSuffix("\"") && path.count >= 2 {
            path = String(path.dropFirst().dropLast())
        }
        return path
    }

    static func ourCommands(_ settings: [String: Any]) -> [String] {
        let groups = (settings["hooks"] as? [String: Any])?["Notification"] as? [Any] ?? []
        return groups.flatMap { group -> [String] in
            ((group as? [String: Any])?["hooks"] as? [Any] ?? []).compactMap { ($0 as? [String: Any])?["command"] as? String }
        }.filter(isOurs)
    }

    static func state(settings: [String: Any]?, claudeExists: Bool, exists: (String) -> Bool) -> State {
        guard claudeExists else { return .noClaude }
        guard let settings else { return .off }
        let ours = ourCommands(settings)
        guard !ours.isEmpty else { return .off }
        return ours.contains { executable(in: $0).map(exists) ?? false } ? .on : .stale
    }

    /// Junta o hook (ou repara um que aponta para outro sítio). As outras entradas ficam.
    static func installing(_ settings: [String: Any], executable: String) -> [String: Any] {
        var copy = removing(settings)
        var hooks = copy["hooks"] as? [String: Any] ?? [:]
        var groups = hooks["Notification"] as? [Any] ?? []
        groups.append(["hooks": [["type": "command", "command": command(executable: executable)]]])
        hooks["Notification"] = groups
        copy["hooks"] = hooks
        return copy
    }

    /// Tira só as entradas do AgentStats; grupos e chaves que fiquem vazios saem também.
    static func removing(_ settings: [String: Any]) -> [String: Any] {
        var copy = settings
        guard var hooks = copy["hooks"] as? [String: Any], let groups = hooks["Notification"] as? [Any] else { return copy }
        var kept: [Any] = []
        for group in groups {
            guard var g = group as? [String: Any], let list = g["hooks"] as? [Any] else { kept.append(group); continue }
            let rest = list.filter { !isOurs(($0 as? [String: Any])?["command"] as? String ?? "") }
            if rest.isEmpty && !list.isEmpty { continue }
            g["hooks"] = rest
            kept.append(g)
        }
        if kept.isEmpty { hooks["Notification"] = nil } else { hooks["Notification"] = kept }
        if hooks.isEmpty { copy["hooks"] = nil } else { copy["hooks"] = hooks }
        return copy
    }
}

/// Lê e escreve o ficheiro, com cópia de segurança antes de cada alteração.
@MainActor
final class ClaudeHookStore: ObservableObject {
    struct Environment {
        var claudeDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        var executable = Bundle.main.executablePath ?? "/Applications/AgentStats.app/Contents/MacOS/AgentStats"
        var exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static let shared = ClaudeHookStore(environment: Environment())

    @Published private(set) var state: ClaudeHook.State = .off
    @Published private(set) var message: String?
    private let environment: Environment
    private var demo = false

    init(environment: Environment) {
        self.environment = environment
    }

    private var file: URL { environment.claudeDir.appendingPathComponent("settings.json") }

    /// nil sem ficheiro; Failure se não se perceber.
    private func read() -> Result<[String: Any]?, ClaudeHook.Failure> {
        guard FileManager.default.fileExists(atPath: file.path) else { return .success(nil) }
        guard let data = try? Data(contentsOf: file),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .failure(.unreadable) }
        return .success(json)
    }

    func refresh() {
        guard !demo else { return }
        let claude = FileManager.default.fileExists(atPath: environment.claudeDir.path)
        switch read() {
        case .failure: state = claude ? .unreadable : .noClaude
        case .success(let json): state = ClaudeHook.state(settings: json, claudeExists: claude, exists: environment.exists)
        }
    }

    func set(_ on: Bool) {
        guard !demo else { return }
        message = nil
        // Lê outra vez agora: o Claude Code pode ter mudado o ficheiro desde que o ecrã o mostrou.
        guard case .success(let current) = read() else {
            message = "O ~/.claude/settings.json não é JSON válido. Não lhe mexi."
            refresh()
            return
        }
        let before = current ?? [:]
        let after = on ? ClaudeHook.installing(before, executable: environment.executable) : ClaudeHook.removing(before)
        do {
            try FileManager.default.createDirectory(at: environment.claudeDir, withIntermediateDirectories: true)
            // A cópia é do ficheiro tal como estava, byte a byte.
            if current != nil, let original = try? Data(contentsOf: file) {
                try original.write(to: environment.claudeDir.appendingPathComponent("settings.json.agentstats-backup"), options: .atomic)
            }
            let data = try JSONSerialization.data(withJSONObject: after, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: file, options: .atomic)
        } catch {
            message = "Não consegui gravar o ~/.claude/settings.json."
        }
        refresh()
    }

    func loadDemo() {
        demo = true
        state = .on
    }
}
