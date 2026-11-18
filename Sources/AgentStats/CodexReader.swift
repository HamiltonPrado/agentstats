import Foundation
import SQLite3

/// Lê as conversas do Codex (CLI e app ChatGPT/Codex):
/// - `~/.codex/state_5.sqlite` → tabela `threads` (título, cwd, modelo, ficheiro rollout)
/// - `~/.codex/sqlite/codex.db` → `active_chat_turns` (turnos a decorrer na app)
/// - `~/.codex/sessions/**/rollout-*.jsonl` → eventos (tarefa iniciada/concluída, ferramentas)
final class CodexReader {
    private let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")

    private struct Thread {
        let id: String
        let rollout: String
        let cwd: String
        let title: String
        let model: String?
        let updated: Date
    }

    private struct TailInfo {
        var state: AgentState = .unknown
        var detail: String?
        var timestamp: Date?
    }
    private var tailCache: [String: (mtime: Date, size: UInt64, info: TailInfo)] = [:]

    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func sessions(recentWindow: TimeInterval = 20 * 60) -> [AgentSession] {
        guard FileManager.default.fileExists(atPath: home.path) else { return [] }
        let active = activeThreadIDs()
        var threads = recentThreads()
        // Recurso: se a base de dados falhar, usa os ficheiros rollout recentes
        if threads.isEmpty { threads = recentRolloutsFallback() }

        let now = Date()
        var out: [AgentSession] = []
        for t in threads {
            let attrs = try? FileManager.default.attributesOfItem(atPath: t.rollout)
            let mtime = (attrs?[.modificationDate] as? Date) ?? t.updated
            let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
            let last = max(mtime, t.updated)
            let isActive = active.contains(t.id)
            let age = now.timeIntervalSince(last)
            if !isActive && age > recentWindow { continue }

            let info = size > 0 ? tail(t.rollout, mtime: mtime, size: size) : TailInfo()
            var state = info.state
            if isActive && !state.isWorking { state = .thinking }
            // trabalho sem atividade há muito tempo e sem turno ativo → interrompido
            if !isActive && state.isWorking && age > 5 * 60 { state = .finished }
            if state == .unknown { state = age < 30 ? .thinking : .finished }

            out.append(AgentSession(
                id: t.rollout,
                kind: "Codex",
                title: t.title,
                cwd: t.cwd.isEmpty ? nil : t.cwd,
                model: t.model,
                state: state,
                detail: info.detail,
                lastActivity: info.timestamp.map { max($0, last) } ?? last,
                subagents: 0,
                process: nil
            ))
        }
        return out
    }

    // MARK: SQLite

    private func query(_ path: String, _ sql: String, _ row: (OpaquePointer) -> Void) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
    }

    private func text(_ s: OpaquePointer, _ i: Int32) -> String? {
        sqlite3_column_text(s, i).map { String(cString: $0) }
    }

    private func activeThreadIDs() -> Set<String> {
        var ids = Set<String>()
        query(home.appendingPathComponent("sqlite/codex.db").path, "SELECT thread_id FROM active_chat_turns") { s in
            if let id = text(s, 0) { ids.insert(id) }
        }
        return ids
    }

    private func recentThreads() -> [Thread] {
        var out: [Thread] = []
        let sql = """
        SELECT id, rollout_path, cwd, COALESCE(name, ''), title, first_user_message, model,
               COALESCE(updated_at_ms, updated_at * 1000)
        FROM threads WHERE archived = 0
        ORDER BY COALESCE(updated_at_ms, updated_at * 1000) DESC LIMIT 20
        """
        query(home.appendingPathComponent("state_5.sqlite").path, sql) { s in
            guard let id = text(s, 0), let rollout = text(s, 1) else { return }
            let title = Self.cleanTitle(name: text(s, 3), title: text(s, 4), first: text(s, 5))
            out.append(Thread(
                id: id, rollout: rollout, cwd: text(s, 2) ?? "", title: title,
                model: text(s, 6),
                updated: Date(timeIntervalSince1970: Double(sqlite3_column_int64(s, 7)) / 1000)))
        }
        return out
    }

    private func recentRolloutsFallback() -> [Thread] {
        let base = home.appendingPathComponent("sessions")
        guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var out: [Thread] = []
        let now = Date()
        for case let url as URL in e where url.pathExtension == "jsonl" {
            guard let m = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  now.timeIntervalSince(m) < 3600 else { continue }
            out.append(Thread(id: url.lastPathComponent, rollout: url.path, cwd: "", title: "Sessão Codex", model: nil, updated: m))
        }
        return out
    }

    /// Os títulos de conversas continuadas a partir do ChatGPT trazem um bloco de contexto enorme:
    /// usa o nome da thread ou o texto depois de "## My request:".
    private static func cleanTitle(name: String?, title: String?, first: String?) -> String {
        if let n = name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { return n }
        for raw in [title, first].compactMap({ $0 }) {
            var t = raw
            if let r = t.range(of: "## My request:") { t = String(t[r.upperBound...]) }
            if let r = t.range(of: "): ", options: [], range: t.startIndex..<t.endIndex), t.hasPrefix("\nContinuing from") || t.hasPrefix("Continuing from") {
                t = String(t[r.upperBound...])
            }
            let line = t.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n").first.map(String.init) ?? ""
            if !line.isEmpty, !line.hasPrefix("#") { return String(line.prefix(80)) }
        }
        return "Sessão Codex"
    }

    // MARK: Rollout

    private func tail(_ path: String, mtime: Date, size: UInt64) -> TailInfo {
        if let c = tailCache[path], c.mtime == mtime, c.size == size { return c.info }
        var info = TailInfo()
        guard let h = FileHandle(forReadingAtPath: path) else { return info }
        defer { try? h.close() }
        let chunk: UInt64 = 384 * 1024
        let start = size > chunk ? size - chunk : 0
        try? h.seek(toOffset: start)
        var lines = ((try? h.readToEnd()) ?? Data()).split(separator: UInt8(ascii: "\n"))
        if start > 0, !lines.isEmpty { lines.removeFirst() }

        for line in lines.reversed() {
            guard let j = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = j["type"] as? String,
                  let p = j["payload"] as? [String: Any] else { continue }
            let ptype = p["type"] as? String ?? ""
            var matched = true

            switch (type, ptype) {
            case ("event_msg", "task_complete"):
                info.state = .waitingUser
                info.detail = (p["last_agent_message"] as? String).map(AgentReader.oneLine)
            case ("event_msg", "turn_aborted"):
                info.state = .waitingUser
                info.detail = "Interrompido"
            case ("event_msg", "task_started"):
                info.state = .thinking
                info.detail = "Tarefa iniciada"
            case ("response_item", "function_call"), ("response_item", "custom_tool_call"):
                let name = p["name"] as? String ?? "ferramenta"
                let input = (p["arguments"] as? String) ?? (p["input"] as? String) ?? ""
                let (tool, detail) = Self.describeTool(name: name, input: input)
                info.state = .runningTool(tool)
                info.detail = detail
            case ("response_item", "function_call_output"), ("response_item", "custom_tool_call_output"):
                info.state = .thinking
                info.detail = "A analisar o resultado"
            case ("response_item", "reasoning"):
                info.state = .thinking
                info.detail = "A raciocinar"
            case ("response_item", "message"):
                info.state = .thinking
                if p["role"] as? String == "assistant",
                   let c = (p["content"] as? [[String: Any]])?.first(where: { $0["type"] as? String == "output_text" }),
                   let t = c["text"] as? String {
                    info.detail = AgentReader.oneLine(t)
                } else {
                    info.detail = "Nova mensagem recebida"
                }
            default:
                matched = false
            }
            if matched {
                if let ts = j["timestamp"] as? String { info.timestamp = iso.date(from: ts) }
                break
            }
        }
        tailCache[path] = (mtime, size, info)
        return info
    }

    /// Converte chamadas de ferramentas do Codex em nome + descrição legíveis.
    private static func describeTool(name: String, input: String) -> (String, String?) {
        // function_call: argumentos em JSON
        if let d = input.data(using: .utf8),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            for key in ["cmd", "command", "path", "query", "url", "pattern"] {
                if let v = j[key] as? String { return (toolLabel(name, key: key), AgentReader.oneLine(v)) }
                if let a = j[key] as? [String] { return (toolLabel(name, key: key), AgentReader.oneLine(a.joined(separator: " "))) }
            }
            return (toolLabel(name, key: nil), nil)
        }
        // custom_tool_call "exec": código JS que chama tools.exec_command({cmd:"…"})
        if let r = input.range(of: #"cmd:\s*"((?:[^"\\]|\\.)*)""#, options: .regularExpression) {
            let raw = String(input[r]).replacingOccurrences(of: #"^cmd:\s*""#, with: "", options: .regularExpression)
            return ("Bash", AgentReader.oneLine(String(raw.dropLast()).replacingOccurrences(of: "\\\"", with: "\"")))
        }
        if input.contains("apply_patch") { return ("Edit", "A aplicar alterações a ficheiros") }
        return (toolLabel(name, key: nil), input.isEmpty ? nil : AgentReader.oneLine(input))
    }

    private static func toolLabel(_ name: String, key: String?) -> String {
        switch name {
        case "shell", "exec_command", "local_shell", "container.exec": return "Bash"
        case "apply_patch": return "Edit"
        case "read_file", "view_image": return "Read"
        case "web_search", "web.run": return "WebSearch"
        case "wait", "write_stdin": return "Bash"
        default: return key == "cmd" || key == "command" ? "Bash" : name
        }
    }
}
