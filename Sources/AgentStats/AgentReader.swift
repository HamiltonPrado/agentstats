import Foundation

// MARK: - Models

enum AgentState: Equatable {
    case runningTool(String)
    case thinking
    case needsApproval(String)   // bloqueado à espera de autorização para uma ferramenta
    case needsAnswer             // fez uma pergunta (AskUserQuestion / plano para aprovar)
    case waitingUser
    case finished
    case unknown

    var label: String {
        switch self {
        case .runningTool(let t): return "A executar \(t)"
        case .thinking: return "A pensar…"
        case .needsApproval(let t): return "Precisa de aprovação · \(t)"
        case .needsAnswer: return "Tem uma pergunta para ti"
        case .waitingUser: return "À tua espera"
        case .finished: return "Terminada"
        case .unknown: return "Ativo"
        }
    }

    var isWorking: Bool {
        switch self {
        case .runningTool, .thinking: return true
        default: return false
        }
    }

    var needsAttention: Bool {
        switch self {
        case .needsApproval, .needsAnswer: return true
        default: return false
        }
    }
}

struct AgentProcess: Identifiable {
    var id: Int { pid }
    let pid: Int
    let kind: String          // "Claude Code", "Codex", …
    let cpu: Double           // inclui subprocessos
    let memKB: UInt64
    let elapsed: String
    let cwd: String?
    let children: [String]    // nomes dos subprocessos ativos
    let isSubagent: Bool
    var role: String? = nil   // ex.: "app" / "executor" para os servidores do Codex
    var shellChildren: Int = 0 // shells filhas (o Claude Code corre cada comando Bash numa zsh)
    var ancestors: [Int] = []  // PIDs dos pais, do mais próximo ao mais distante (para encontrar a app onde corre)
}

struct AgentSession: Identifiable {
    let id: String            // caminho do transcript
    let kind: String          // "Claude Code", "Codex", …
    let title: String
    let cwd: String?
    let model: String?
    let state: AgentState
    let detail: String?
    let lastActivity: Date
    let subagents: Int
    let process: AgentProcess?

    var project: String {
        guard let cwd else { return "—" }
        return (cwd as NSString).lastPathComponent
    }
}

// MARK: - Reader

final class AgentReader {
    private let projectsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")

    struct TailInfo {
        var cwd: String?
        var model: String?
        var state: AgentState = .unknown
        var detail: String?
        var timestamp: Date?
    }
    private var tailCache: [String: (mtime: Date, size: UInt64, info: TailInfo)] = [:]
    private var titleCache: [String: String] = [:]

    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: Processos de agentes

    private static let directNames: [String: String] = [
        "claude": "Claude Code",
        "codex": "Codex",
        "gemini": "Gemini CLI",
        "gemini-cli": "Gemini CLI",
        "agy": "Antigravity",
        "antigravity": "Antigravity",
        "aider": "Aider",
        "cursor-agent": "Cursor Agent",
        "opencode": "OpenCode",
        "goose": "Goose",
        "amp": "Amp",
    ]
    private static let scriptMarkers: [(String, String)] = [
        ("@anthropic-ai/claude-code", "Claude Code"),
        ("@openai/codex", "Codex"),
        ("@google/gemini-cli", "Gemini CLI"),
        ("bin/aider", "Aider"),
        ("opencode", "OpenCode"),
    ]
    private static let runtimes: Set<String> = ["node", "bun", "deno", "python", "python3", "Python"]

    static func agentKind(_ p: ProcSample) -> String? {
        if let k = directNames[p.name] { return k }
        if runtimes.contains(p.name) || p.name.hasPrefix("python") {
            for (marker, kind) in scriptMarkers where p.args.contains(marker) { return kind }
            // Deteta scripts cujo executável é o agente (ex.: node /opt/homebrew/bin/gemini)
            let argsList = p.args.split(separator: " ")
            if let script = argsList.dropFirst().first(where: { !$0.hasPrefix("-") }) {
                let base = ((script as NSString).lastPathComponent as NSString).deletingPathExtension
                if let k = directNames[base] { return k }
            }
        }
        return nil
    }

    func agentProcesses(from procs: [ProcSample]) -> [AgentProcess] {
        var children: [Int: [ProcSample]] = [:]
        for p in procs { children[p.ppid, default: []].append(p) }
        let byPid = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })

        let agentPids = Set(procs.filter { Self.agentKind($0) != nil }.map(\.pid))

        func descendants(_ pid: Int) -> [ProcSample] {
            var out: [ProcSample] = []
            var stack = children[pid] ?? []
            while let c = stack.popLast() {
                if agentPids.contains(c.pid) { continue } // subagente é listado à parte
                out.append(c)
                stack.append(contentsOf: children[c.pid] ?? [])
            }
            return out
        }

        func ancestors(of p: ProcSample) -> [Int] {
            var out: [Int] = []
            var cur = byPid[p.ppid]
            while let c = cur, c.pid > 1, out.count < 32 {
                out.append(c.pid)
                cur = byPid[c.ppid]
            }
            return out
        }

        func hasAgentAncestor(_ p: ProcSample) -> Bool {
            var cur = byPid[p.ppid]
            var guardCount = 0
            while let c = cur, guardCount < 64 {
                if agentPids.contains(c.pid) { return true }
                cur = byPid[c.ppid]; guardCount += 1
            }
            return false
        }

        return procs.compactMap { p -> AgentProcess? in
            guard let kind = Self.agentKind(p) else { return nil }
            let desc = descendants(p.pid)
            // A app ChatGPT/Codex arranca um app-server e um exec-server auxiliar
            let role: String? = p.args.contains("app-server") ? "app" : p.args.contains("exec-server") ? "executor" : nil
            let busy = desc
                .filter { !["zsh", "bash", "sh", "caffeinate"].contains($0.name) || $0.cpu > 1 }
                .sorted { $0.cpu > $1.cpu }
                .map(\.name)
            return AgentProcess(
                pid: p.pid,
                kind: kind,
                cpu: p.cpu + desc.reduce(0) { $0 + $1.cpu },
                memKB: p.rssKB + desc.reduce(0) { $0 + $1.rssKB },
                elapsed: p.elapsed,
                cwd: Sys.cwd(of: p.pid),
                children: Array(busy.uniqued().prefix(4)),
                isSubagent: hasAgentAncestor(p) || role == "executor",
                role: role,
                shellChildren: desc.filter { ["zsh", "bash", "sh"].contains($0.name) }.count,
                ancestors: ancestors(of: p)
            )
        }
        .sorted { $0.cpu > $1.cpu }
    }

    // MARK: Sessões (transcripts do Claude Code)

    func sessions(processes: [AgentProcess], recentWindow: TimeInterval = 20 * 60) -> [AgentSession] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil) else { return [] }

        let now = Date()
        var candidates: [(url: URL, mtime: Date, size: UInt64)] = []
        for dir in projectDirs {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
            for f in files where f.pathExtension == "jsonl" {
                let v = try? f.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                guard let m = v?.contentModificationDate else { continue }
                // Mantém transcripts de até 12h para ligar a processos vivos que estão parados
                if now.timeIntervalSince(m) < 12 * 3600 {
                    candidates.append((f, m, UInt64(v?.fileSize ?? 0)))
                }
            }
        }
        candidates.sort { $0.mtime > $1.mtime }

        let claudeProcs = processes.filter { $0.kind == "Claude Code" && !$0.isSubagent }
        var usedPids = Set<Int>()
        var result: [AgentSession] = []

        for c in candidates {
            let info = tail(c.url, mtime: c.mtime, size: c.size)
            // O transcript mais recente para um cwd pertence ao processo vivo nesse cwd.
            let proc = claudeProcs.first { p in
                !usedPids.contains(p.pid) && p.cwd != nil && p.cwd == info.cwd
            }
            let age = now.timeIntervalSince(c.mtime)
            if proc == nil && age > recentWindow { continue }
            if let proc { usedPids.insert(proc.pid) }

            var state = info.state
            if proc == nil && age > 90 { state = .finished }
            if state == .unknown && age < 15 { state = .thinking }
            if let proc, case .runningTool(let tool) = state {
                let session = c.url.deletingPathExtension().lastPathComponent
                state = Self.approvalState(tool: tool, since: info.timestamp ?? c.mtime, process: proc,
                                           hook: HookEvents.latest(session: session), hookActive: HookEvents.isActive) ?? state
            }

            result.append(AgentSession(
                id: c.url.path,
                kind: "Claude Code",
                title: title(for: c.url),
                cwd: info.cwd,
                model: info.model,
                state: state,
                detail: info.detail,
                lastActivity: info.timestamp ?? c.mtime,
                subagents: activeSubagents(for: c.url),
                process: proc
            ))
        }
        return result
    }

    /// "À espera de aprovação" para um pedido de ferramenta ainda pendente (`since` = quando foi pedido).
    /// - Com o hook instalado: só quando o Claude Code avisou que mostrou um pedido de autorização
    ///   depois deste pedido de ferramenta (fonte fiável; quando é aprovado, o transcript avança e o aviso fica antigo).
    /// - Sem o hook (plano B, heurística):
    ///   - Bash: o Claude Code corre cada comando numa zsh filha; pendente sem zsh → à espera de autorização.
    ///   - Edit/Write/…: são instantâneas; pendentes há mais de 5 s → à espera de autorização.
    /// - AskUserQuestion / ExitPlanMode: esperam sempre por uma resposta tua.
    static func approvalState(tool: String, since: Date, process: AgentProcess,
                              hook: HookEvent? = nil, hookActive: Bool = false, now: Date = Date()) -> AgentState? {
        if tool == "AskUserQuestion" || tool == "ExitPlanMode" { return .needsAnswer }
        if hookActive {
            // tolerância de 2 s: o aviso pode ser gravado um instante antes da linha do transcript
            if let hook, hook.kind == .permission, hook.date >= since.addingTimeInterval(-2) { return .needsApproval(tool) }
            return nil
        }
        let age = now.timeIntervalSince(since)
        switch tool {
        case "Bash":
            return age > 3 && process.shellChildren == 0 ? .needsApproval(tool) : nil
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            return age > 5 ? .needsApproval(tool) : nil
        default:
            return nil
        }
    }

    private func activeSubagents(for transcript: URL) -> Int {
        let dir = transcript.deletingPathExtension().appendingPathComponent("subagents")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return 0 }
        let now = Date()
        return files.filter {
            $0.pathExtension == "jsonl" &&
            now.timeIntervalSince((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < 60
        }.count
    }

    private func title(for url: URL) -> String {
        let titleFile = url.deletingPathExtension().appendingPathComponent("custom-title.json")
        if let d = try? Data(contentsOf: titleFile),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let t = j["customTitle"] as? String, !t.isEmpty {
            return t
        }
        if let cached = titleCache[url.path] { return cached }

        var found = "Sessão sem título"
        if let h = try? FileHandle(forReadingFrom: url) {
            let data = (try? h.read(upToCount: 256 * 1024)) ?? Data()
            try? h.close()
            for line in data.split(separator: UInt8(ascii: "\n")) {
                guard let j = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                if j["type"] as? String == "summary", let s = j["summary"] as? String { found = s; break }
                if j["type"] as? String == "user", (j["isMeta"] as? Bool) != true,
                   let msg = j["message"] as? [String: Any] {
                    var text: String?
                    if let s = msg["content"] as? String { text = s }
                    else if let arr = msg["content"] as? [[String: Any]] {
                        text = arr.first(where: { $0["type"] as? String == "text" })?["text"] as? String
                    }
                    if let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, !t.hasPrefix("<") {
                        found = String(t.prefix(80)); break
                    }
                }
            }
        }
        titleCache[url.path] = found
        return found
    }

    private func tail(_ url: URL, mtime: Date, size: UInt64) -> TailInfo {
        if let c = tailCache[url.path], c.mtime == mtime, c.size == size { return c.info }

        var info = TailInfo()
        guard let h = try? FileHandle(forReadingFrom: url) else { return info }
        defer { try? h.close() }
        let chunk: UInt64 = 512 * 1024
        let start = size > chunk ? size - chunk : 0
        try? h.seek(toOffset: start)
        let data = (try? h.readToEnd()) ?? Data()
        var lines = data.split(separator: UInt8(ascii: "\n"))
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        info = parseTail(lines)
        tailCache[url.path] = (mtime, size, info)
        return info
    }

    /// Interpreta as linhas de um transcript do Claude Code, da mais recente para trás.
    /// (Separado da leitura do ficheiro para poder ser testado.)
    func parseTail(_ lines: [Data]) -> TailInfo {
        var info = TailInfo()
        var stateFound = false
        for line in lines.reversed() {
            guard let j = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if info.cwd == nil, let cwd = j["cwd"] as? String { info.cwd = cwd }
            let type = j["type"] as? String
            let sidechain = (j["isSidechain"] as? Bool) ?? false

            if !stateFound, !sidechain, type == "assistant" || type == "user" {
                if info.timestamp == nil, let ts = j["timestamp"] as? String { info.timestamp = iso.date(from: ts) }
                let msg = j["message"] as? [String: Any] ?? [:]
                if type == "assistant" {
                    let content = msg["content"] as? [[String: Any]] ?? []
                    if let last = content.last, last["type"] as? String == "tool_use" {
                        let name = (last["name"] as? String) ?? "ferramenta"
                        info.state = .runningTool(Self.prettyTool(name))
                        info.detail = Self.describe(last["input"] as? [String: Any])
                    } else if msg["stop_reason"] as? String == "end_turn" {
                        info.state = .waitingUser
                        if let t = content.last(where: { $0["type"] as? String == "text" })?["text"] as? String {
                            info.detail = Self.oneLine(t)
                        }
                    } else {
                        info.state = .thinking
                    }
                } else {
                    info.state = .thinking
                    if let arr = msg["content"] as? [[String: Any]], arr.contains(where: { $0["type"] as? String == "tool_result" }) {
                        info.detail = "A analisar o resultado"
                    } else {
                        info.detail = "Nova mensagem recebida"
                    }
                }
                stateFound = true
            }
            if info.model == nil, type == "assistant", let m = (j["message"] as? [String: Any])?["model"] as? String {
                info.model = m
            }
            if stateFound && info.cwd != nil && info.model != nil { break }
        }
        return info
    }

    private static func prettyTool(_ name: String) -> String {
        if name.hasPrefix("mcp__") {
            let parts = name.split(separator: "_").filter { !$0.isEmpty }
            return parts.last.map(String.init) ?? name
        }
        return name
    }

    private static func describe(_ input: [String: Any]?) -> String? {
        guard let input else { return nil }
        for key in ["description", "command", "file_path", "pattern", "url", "query", "prompt", "skill"] {
            if let v = input[key] as? String, !v.isEmpty { return oneLine(v) }
        }
        return nil
    }

    static func oneLine(_ s: String) -> String {
        let l = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return l.count > 90 ? String(l.prefix(90)) + "…" : l
    }
}

extension Sequence where Element: Hashable {
    /// Remove repetidos mantendo a ordem da primeira ocorrência.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
