import Foundation
import SQLite3

/// Lê as conversas do Antigravity (Google DeepMind):
/// - `~/.gemini/antigravity/conversation_summaries.db` → tabela `conversation_summaries`
/// - `~/.gemini/antigravity/brain/<id>/.system_generated/logs/transcript.jsonl` → passos e ferramentas
final class AntigravityReader {
    private let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/antigravity")

    private struct Summary {
        let id: String
        let title: String
        let preview: String
        let cwd: String?
        let notFullyIdle: Bool
        let status: String
        let updated: Date
    }

    struct TailInfo: Equatable {
        var state: AgentState = .unknown
        var detail: String?
        var model: String?
        var timestamp: Date?
    }

    private let tailCache = FileCache<TailInfo>()
    private var logged = Set<String>()


    func sessions(processes: [AgentProcess] = [], recentWindow: TimeInterval = AgentSession.recentWindow) -> [AgentSession] {
        guard FileManager.default.fileExists(atPath: home.path) else { return [] }
        let summaries = recentSummaries()
        let antigravityProcs = processes.filter { $0.kind == "Antigravity" && !$0.isSubagent }
        var usedPids = Set<Int>()

        let now = Date()
        var out: [AgentSession] = []

        for s in summaries {
            let transcriptURL = home.appendingPathComponent("brain/\(s.id)/.system_generated/logs/transcript.jsonl")
            let attrs = try? FileManager.default.attributesOfItem(atPath: transcriptURL.path)
            let mtime = (attrs?[.modificationDate] as? Date) ?? s.updated
            let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
            let last = max(mtime, s.updated)
            let age = now.timeIntervalSince(last)

            // Se não estiver ativo e for mais antigo que a janela recente, ignora
            if !s.notFullyIdle && age > recentWindow { continue }

            let info = size > 0 ? tail(transcriptURL, mtime: mtime, size: size) : TailInfo()

            var state = info.state
            if s.notFullyIdle {
                if !state.isWorking { state = .thinking }
            } else {
                if state.isWorking && age > 90 { state = .waitingUser }
                if state == .unknown { state = age < 30 ? .thinking : .waitingUser }
            }

            let detail = info.detail ?? (s.preview.isEmpty ? nil : s.preview)

            // Liga ao processo correspondente
            let proc = antigravityProcs.first { p in
                !usedPids.contains(p.pid) && (s.cwd == nil || p.cwd == s.cwd || antigravityProcs.count == 1)
            }
            if let proc { usedPids.insert(proc.pid) }

            out.append(AgentSession(
                id: transcriptURL.path,
                kind: "Antigravity",
                title: s.title.isEmpty ? "Conversa Antigravity" : s.title,
                cwd: s.cwd,
                model: info.model ?? "Gemini",
                state: state,
                detail: detail,
                lastActivity: info.timestamp.map { max($0, last) } ?? last,
                subagents: 0,
                process: proc
            ))
        }
        return out
    }

    // MARK: - SQLite

    private func recentSummaries() -> [Summary] {
        var out: [Summary] = []
        let dbPath = home.appendingPathComponent("conversation_summaries.db").path
        let sql = """
        SELECT conversation_id, title, preview, last_modified_time, workspace_uris, not_fully_idle, status
        FROM conversation_summaries
        ORDER BY last_modified_time DESC LIMIT 10
        """
        query(dbPath, sql) { stmt in
            guard let id = text(stmt, 0) else { return }
            let title = text(stmt, 1) ?? ""
            let preview = text(stmt, 2) ?? ""
            let timeStr = text(stmt, 3) ?? ""
            guard let date = parseDate(timeStr) else { return }
            let uris = text(stmt, 4) ?? ""
            let cwd = parseCwd(uris)
            let notFullyIdle = sqlite3_column_int(stmt, 5) != 0
            let status = text(stmt, 6) ?? ""

            out.append(Summary(
                id: id,
                title: title,
                preview: preview,
                cwd: cwd,
                notFullyIdle: notFullyIdle,
                status: status,
                updated: date
            ))
        }
        return out
    }

    private func query(_ path: String, _ sql: String, _ row: (OpaquePointer) -> Void) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        var db: OpaquePointer?
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK || !canRead(db) {
            sqlite3_close(db); db = nil
            let uri = "file:" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path) + "?immutable=1"
            guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
                logOnce("open:\(path)", "Não foi possível abrir \(path): \(String(cString: sqlite3_errmsg(db)))")
                sqlite3_close(db); return
            }
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            logOnce("prepare:\(path)", "Consulta falhou em \(path): \(String(cString: sqlite3_errmsg(db)))")
            return
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
    }

    private func canRead(_ db: OpaquePointer?) -> Bool {
        sqlite3_exec(db, "SELECT 1 FROM sqlite_master LIMIT 1", nil, nil, nil) == SQLITE_OK
    }

    private func text(_ s: OpaquePointer, _ i: Int32) -> String? {
        sqlite3_column_text(s, i).map { String(cString: $0) }
    }

    private func logOnce(_ key: String, _ message: String) {
        guard logged.insert(key).inserted else { return }
        Log.readers.error("Antigravity: \(message, privacy: .public)")
    }

    /// ISO 8601 (com espaço ou "T"), ou época em segundos ou milissegundos. Uma data que não se lê é nil:
    /// usar "agora" punha a conversa como "a pensar" para sempre.
    func parseDate(_ s: String) -> Date? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if let d = ISODate.shared.parse(trimmed) ?? ISODate.shared.parse(trimmed.replacingOccurrences(of: " ", with: "T")) { return d }
        if let n = Double(trimmed), n > 0 { return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n) }
        return nil
    }

    func parseCwd(_ raw: String) -> String? {
        if let data = raw.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [String],
           let first = arr.first, let url = URL(string: first) {
            return url.path
        }
        if raw.contains("file://") {
            let parts = raw.components(separatedBy: "file://")
            if parts.count > 1 {
                let path = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"[]' \n\r"))
                return path.isEmpty ? nil : "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
        }
        return nil
    }

    // MARK: - Tail & Parsing de Transcripts

    private func tail(_ url: URL, mtime: Date, size: UInt64) -> TailInfo {
        tailCache.value(url.path, mtime: mtime, size: size) { parseTail(TextTail.lines(url.path, maxBytes: 256 * 1024)) }
    }

    /// Analisa as linhas do transcript do Antigravity (do mais recente para trás).
    func parseTail(_ lines: [Data]) -> TailInfo {
        var info = TailInfo()
        for line in lines.reversed() {
            guard let j = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if info.timestamp == nil, let ts = j["created_at"] as? String {
                info.timestamp = parseDate(ts)
            }

            let type = (j["type"] as? String) ?? ""
            let source = (j["source"] as? String) ?? ""

            // Procura o modelo nos settings ou metadados
            if info.model == nil, let content = j["content"] as? String, content.contains("Model Selection") {
                if let range = content.range(of: "to Gemini ") {
                    let rest = content[range.upperBound...]
                    if let dotSpace = rest.range(of: ". ") {
                        let candidate = String(rest[..<dotSpace.lowerBound]).trimmingCharacters(in: .whitespaces)
                        if !candidate.isEmpty { info.model = "Gemini " + candidate }
                    } else {
                        let lineEnd = rest.firstIndex(where: { $0 == "\n" || $0 == "<" }) ?? rest.endIndex
                        var candidate = String(rest[..<lineEnd]).trimmingCharacters(in: .whitespaces)
                        if candidate.hasSuffix(".") { candidate.removeLast() }
                        if !candidate.isEmpty { info.model = "Gemini " + candidate }
                    }
                }
            }

            if info.state == .unknown {
                if type == "PLANNER_RESPONSE" {
                    if let toolCalls = j["tool_calls"] as? [[String: Any]], let first = toolCalls.first {
                        let name = (first["name"] as? String) ?? "ferramenta"
                        info.state = .runningTool(Self.prettyTool(name))
                        info.detail = Self.describe(tool: name, args: first["args"] as? [String: Any])
                    } else if let content = j["content"] as? String, !content.isEmpty {
                        info.state = .waitingUser
                        info.detail = Self.oneLine(content)
                    } else {
                        info.state = .thinking
                        info.detail = (j["thinking"] as? String).map(Self.oneLine) ?? "A planear a resposta…"
                    }
                } else if type == "GENERIC" {
                    info.state = .thinking
                    info.detail = "A analisar o resultado"
                } else if type == "USER_INPUT" || source == "USER_EXPLICIT" {
                    info.state = .thinking
                    info.detail = "Nova mensagem recebida"
                }
            }

            if info.state != .unknown && info.model != nil { break }
        }
        return info
    }

    static func prettyTool(_ name: String) -> String {
        switch name {
        case "run_command": return "Bash"
        case "read_file": return "Read"
        case "edit_file": return "Edit"
        case "write_file": return "Write"
        case "search_web": return "WebSearch"
        case "manage_task": return "Task"
        case "invoke_subagent": return "Subagent"
        case "send_message": return "Message"
        default: return name
        }
    }

    static func describe(tool: String, args: [String: Any]?) -> String? {
        guard let args else { return nil }
        if let summary = args["toolSummary"] as? String, !summary.isEmpty {
            let clean = summary.trimmingCharacters(in: CharacterSet(charactersIn: "\" '"))
            return oneLine(clean)
        }
        if let cmd = args["CommandLine"] as? String, !cmd.isEmpty {
            let clean = cmd.trimmingCharacters(in: CharacterSet(charactersIn: "\" '"))
            return oneLine(clean)
        }
        if let path = args["Path"] as? String, !path.isEmpty {
            return (path as NSString).lastPathComponent
        }
        if let query = args["query"] as? String, !query.isEmpty {
            return oneLine(query)
        }
        return nil
    }

    static func oneLine(_ s: String) -> String {
        let clean = s.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return clean.count > 90 ? String(clean.prefix(90)) + "…" : clean
    }
}
