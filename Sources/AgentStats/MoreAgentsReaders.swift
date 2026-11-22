import Foundation
import SQLite3

// Leitores do GitHub Copilot, do Cursor e do OpenCode. Cada um lê só ficheiros locais que o próprio
// agente escreve, e produz `AgentSession`s como os outros leitores. A interpretação de cada formato
// fica em funções estáticas puras, para poder ser testada com linhas de exemplo.

/// Lê as últimas linhas de um ficheiro de texto (só a parte final, para ficheiros grandes).
enum TextTail {
    static func lines(_ path: String, maxBytes: UInt64 = 256 * 1024) -> [Data] {
        guard let h = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > maxBytes ? size - maxBytes : 0
        try? h.seek(toOffset: start)
        var lines = ((try? h.readToEnd()) ?? Data()).split(separator: UInt8(ascii: "\n")).map { Data($0) }
        if start > 0, !lines.isEmpty { lines.removeFirst() }   // a primeira linha veio cortada
        return lines
    }

    static func head(_ path: String, maxBytes: Int = 64 * 1024) -> [Data] {
        guard let h = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? h.close() }
        let data = (try? h.read(upToCount: maxBytes)) ?? Data()
        var lines = data.split(separator: UInt8(ascii: "\n")).map { Data($0) }
        if data.count == maxBytes, !lines.isEmpty { lines.removeLast() }
        return lines
    }

    static func json(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }
}

/// Uma sessão parada há muito num estado "a trabalhar" já não está a trabalhar (o agente foi fechado
/// a meio). Estes agentes não têm um processo a que ligar a sessão, por isso é por tempo.
private func settle(_ state: AgentState, age: TimeInterval) -> AgentState {
    if (state.isWorking || state.needsAttention) && age > 10 * 60 { return .finished }
    if state == .unknown { return age < 30 ? .thinking : .waitingUser }
    return state
}

/// ISO8601DateFormatter é seguro entre threads (documentado pela Apple).
nonisolated(unsafe) private let isoFrac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private func parseDate(_ v: Any?) -> Date? {
    if let s = v as? String { return isoFrac.date(from: s) ?? ISO8601DateFormatter().date(from: s) }
    if let n = v as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue > 1e12 ? n.doubleValue / 1000 : n.doubleValue) }
    return nil
}

private func describeArgs(_ args: Any?) -> String? {
    guard let a = args as? [String: Any] else { return nil }
    for key in ["description", "command", "query", "path", "file_path", "filePath", "pattern", "url", "q"] {
        if let v = a[key] as? String, !v.isEmpty { return AgentReader.oneLine(v) }
    }
    return nil
}

// MARK: - GitHub Copilot

/// Copilot (CLI e extensão do VS Code): `~/.copilot/session-state/<id>/events.jsonl`, um evento por linha
/// (`session.start`, `user.message`, `assistant.turn_start/end`, `tool.execution_start/complete`,
/// `permission.requested/completed`, `session.usage_record`, `session.shutdown`).
final class CopilotReader {
    private let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".copilot/session-state")
    private var headCache: [String: (title: String, cwd: String?)] = [:]

    func sessions(recentWindow: TimeInterval = 20 * 60, now: Date = Date()) -> [AgentSession] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { return [] }
        var out: [AgentSession] = []
        for dir in dirs where !dir.lastPathComponent.hasPrefix(".") {
            let file = dir.appendingPathComponent("events.jsonl")
            guard let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  now.timeIntervalSince(mtime) < recentWindow else { continue }
            let head = headCache[file.path] ?? {
                let h = Self.head(TextTail.head(file.path).compactMap(TextTail.json))
                headCache[file.path] = h
                return h
            }()
            let tail = Self.parse(TextTail.lines(file.path).compactMap(TextTail.json), now: now)
            let last = tail.date ?? mtime
            out.append(AgentSession(id: file.path, kind: "Copilot", title: head.title, cwd: tail.cwd ?? head.cwd,
                                    model: tail.model, state: settle(tail.state, age: now.timeIntervalSince(last)),
                                    detail: tail.detail, lastActivity: last, subagents: 0, process: nil))
        }
        return out
    }

    /// Título (primeiro pedido) e pasta, do início do ficheiro.
    static func head(_ events: [[String: Any]]) -> (title: String, cwd: String?) {
        var title = "Sessão do Copilot", cwd: String?
        for e in events {
            let data = e["data"] as? [String: Any] ?? [:]
            if e["type"] as? String == "session.start" {
                cwd = (data["context"] as? [String: Any])?["cwd"] as? String
            } else if e["type"] as? String == "user.message", let c = data["content"] as? String,
                      case let t = c.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                title = String(AgentReader.oneLine(t).prefix(80))
                break
            }
        }
        return (title, cwd)
    }

    struct Tail { var state: AgentState = .unknown; var detail: String?; var model: String?; var cwd: String?; var date: Date? }

    /// Estado a partir dos eventos mais recentes (lidos do fim para o princípio).
    static func parse(_ events: [[String: Any]], now: Date) -> Tail {
        var t = Tail()
        var doneTools = Set<String>(), donePerms = Set<String>()
        var decided = false
        for e in events.reversed() {
            let type = e["type"] as? String ?? ""
            let data = e["data"] as? [String: Any] ?? [:]
            if t.date == nil { t.date = parseDate(e["timestamp"]) }
            if t.model == nil {
                t.model = (data["model"] as? String) ?? ((data["usage"] as? [String: Any])?["model"] as? String)
            }
            if t.cwd == nil, type == "session.start" { t.cwd = (data["context"] as? [String: Any])?["cwd"] as? String }
            if decided { if t.model != nil { break } else { continue } }
            switch type {
            case "session.shutdown":
                t.state = .finished; decided = true
            case "permission.completed":
                if let id = data["requestId"] as? String { donePerms.insert(id) }
            case "permission.requested":
                guard let id = data["requestId"] as? String, !donePerms.contains(id) else { continue }
                let req = data["permissionRequest"] as? [String: Any] ?? [:]
                t.state = .needsApproval((req["toolTitle"] as? String) ?? (req["toolName"] as? String) ?? (req["kind"] as? String) ?? "ferramenta")
                t.detail = describeArgs(req["args"]) ?? (req["intention"] as? String)
                decided = true
            case "tool.execution_complete":
                if let id = data["toolCallId"] as? String { doneTools.insert(id) }
            case "tool.execution_start":
                guard let id = data["toolCallId"] as? String, !doneTools.contains(id) else { continue }
                t.state = .runningTool((data["toolName"] as? String) ?? "ferramenta")
                t.detail = describeArgs(data["arguments"])
                decided = true
            case "assistant.turn_end":
                // Um pedido pode ter vários turnos seguidos: só conta como terminado se não vier outro logo.
                let age = parseDate(e["timestamp"]).map { now.timeIntervalSince($0) } ?? 60
                t.state = age > 4 ? .waitingUser : .thinking
                t.detail = lastAssistantText(events)
                decided = true
            case "assistant.turn_start", "user.message", "assistant.message":
                t.state = .thinking
                t.detail = type == "user.message" ? "Nova mensagem recebida" : nil
                decided = true
            default:
                continue
            }
        }
        return t
    }

    private static func lastAssistantText(_ events: [[String: Any]]) -> String? {
        for e in events.reversed() where e["type"] as? String == "assistant.message" {
            if let c = (e["data"] as? [String: Any])?["content"] as? String, !c.isEmpty { return AgentReader.oneLine(c) }
        }
        return nil
    }
}

// MARK: - Cursor

/// Cursor (agente): `~/.cursor/projects/<pasta codificada>/agent-transcripts/<id>.jsonl` (ou numa
/// subpasta com o id). Linhas com `role` user/assistant e, nas versões novas, `{"type":"turn_ended"}`.
/// Não traz tokens.
final class CursorReader {
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var titleCache: [String: String] = [:]
    private var projectCache: [String: String] = [:]

    func sessions(recentWindow: TimeInterval = 20 * 60, now: Date = Date()) -> [AgentSession] {
        let projects = home.appendingPathComponent(".cursor/projects")
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else { return [] }
        var out: [AgentSession] = []
        for dir in dirs {
            let transcripts = dir.appendingPathComponent("agent-transcripts")
            guard let e = fm.enumerator(at: transcripts, includingPropertiesForKeys: [.contentModificationDateKey],
                                        options: [.skipsHiddenFiles]) else { continue }
            for case let f as URL in e where f.pathExtension == "jsonl" {
                guard let mtime = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      now.timeIntervalSince(mtime) < recentWindow else { continue }
                let slug = dir.lastPathComponent
                let cwd = projectCache[slug] ?? {
                    let p = Self.decodeProject(slug, home: home.path)
                    projectCache[slug] = p
                    return p
                }()
                let title = titleCache[f.path] ?? {
                    let t = Self.title(TextTail.head(f.path).compactMap(TextTail.json))
                    titleCache[f.path] = t
                    return t
                }()
                let tail = Self.parse(TextTail.lines(f.path).compactMap(TextTail.json), age: now.timeIntervalSince(mtime))
                out.append(AgentSession(id: f.path, kind: "Cursor", title: title, cwd: cwd, model: nil,
                                        state: settle(tail.state, age: now.timeIntervalSince(mtime)), detail: tail.detail,
                                        lastActivity: mtime, subagents: 0, process: nil))
            }
        }
        return out
    }

    static func text(_ line: [String: Any]) -> String? {
        let content = (line["message"] as? [String: Any])?["content"] ?? line["content"]
        if let s = content as? String { return s }
        return (content as? [[String: Any]])?.last(where: { $0["type"] as? String == "text" })?["text"] as? String
    }

    /// Tira as etiquetas que o Cursor põe à volta do pedido (`<user_query>…</user_query>`).
    static func clean(_ s: String) -> String {
        AgentReader.oneLine(s.replacingOccurrences(of: #"</?[a-z_]+>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func title(_ lines: [[String: Any]]) -> String {
        for l in lines where l["role"] as? String == "user" {
            if let t = text(l).map(clean), !t.isEmpty { return String(t.prefix(80)) }
        }
        return "Sessão do Cursor"
    }

    /// `age`: há quanto tempo o ficheiro mudou (as versões antigas não escrevem o fim do turno).
    static func parse(_ lines: [[String: Any]], age: TimeInterval) -> (state: AgentState, detail: String?) {
        guard let last = lines.last else { return (.unknown, nil) }
        if last["type"] as? String == "turn_ended" {
            let ok = (last["status"] as? String).map { $0 == "success" } ?? true
            let reply = lines.last(where: { $0["role"] as? String == "assistant" }).flatMap(text).map(clean)
            return (.waitingUser, ok ? reply : "Interrompido")
        }
        switch last["role"] as? String {
        case "user":
            return (.thinking, "Nova mensagem recebida")
        case "assistant":
            let content = ((last["message"] as? [String: Any])?["content"] ?? last["content"]) as? [[String: Any]] ?? []
            if let tool = content.last, tool["type"] as? String == "tool_use" {
                return (.runningTool((tool["name"] as? String) ?? "ferramenta"), describeArgs(tool["input"]))
            }
            return age > 30 ? (.waitingUser, text(last).map(clean)) : (.thinking, nil)
        default:
            return (.unknown, nil)
        }
    }

    /// "Users-ana-Documents-meu-projeto" → "/Users/ana/Documents/meu-projeto". Os "-" tanto podem ser
    /// "/" como parte do nome, por isso procura no disco o caminho que existe; se nada existir,
    /// fica o que vem depois da pasta pessoal.
    static func decodeProject(_ slug: String, home: String) -> String {
        let parts = slug.split(separator: "-").map(String.init)
        func search(_ i: Int, _ path: String) -> String? {
            if i == parts.count { return path }
            var name = ""
            for j in i..<parts.count {
                name += (j > i ? "-" : "") + parts[j]
                let candidate = path + "/" + name
                var dir: ObjCBool = false
                if FileManager.default.fileExists(atPath: candidate, isDirectory: &dir), dir.boolValue,
                   let found = search(j + 1, candidate) { return found }
            }
            return nil
        }
        if parts.count <= 12, let found = search(0, "") { return found }
        let encodedHome = home.split(separator: "/").joined(separator: "-")
        if slug.hasPrefix(encodedHome + "-") { return home + "/" + slug.dropFirst(encodedHome.count + 1) }
        return slug
    }
}

// MARK: - OpenCode

/// OpenCode: base de dados SQLite em `~/.local/share/opencode/opencode.db` (tabelas `session` e
/// `message`; cada mensagem guarda um JSON em `data` com `role`, `modelID`, `tokens`, `time`, `finish`).
final class OpenCodeReader {
    static var databasePath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode/opencode.db").path
    }

    func sessions(recentWindow: TimeInterval = 20 * 60, now: Date = Date(), path: String = OpenCodeReader.databasePath) -> [AgentSession] {
        let since = Int64((now.timeIntervalSince1970 - recentWindow) * 1000)
        var found: [(id: String, title: String, dir: String?, updated: Date)] = []
        SQLiteRead.query(path, "SELECT id, title, directory, time_updated FROM session WHERE time_updated > \(since) ORDER BY time_updated DESC LIMIT 20") { s in
            guard let id = SQLiteRead.text(s, 0) else { return }
            found.append((id, SQLiteRead.text(s, 1) ?? "Sessão do OpenCode", SQLiteRead.text(s, 2),
                          Date(timeIntervalSince1970: Double(sqlite3_column_int64(s, 3)) / 1000)))
        }
        return found.map { sess in
            var last: [String: Any] = [:]
            SQLiteRead.query(path, "SELECT data FROM message WHERE session_id = '\(sess.id.replacingOccurrences(of: "'", with: "''"))' ORDER BY time_created DESC LIMIT 1") { s in
                if let d = SQLiteRead.text(s, 0), let j = TextTail.json(Data(d.utf8)) { last = j }
            }
            let parsed = Self.parse(last)
            let cwd = ((last["path"] as? [String: Any])?["cwd"] as? String) ?? sess.dir
            return AgentSession(id: "opencode:" + sess.id, kind: "OpenCode", title: sess.title, cwd: cwd,
                                model: last["modelID"] as? String,
                                state: settle(parsed.state, age: now.timeIntervalSince(sess.updated)), detail: parsed.detail,
                                lastActivity: sess.updated, subagents: 0, process: nil)
        }
    }

    static func parse(_ message: [String: Any]) -> (state: AgentState, detail: String?) {
        switch message["role"] as? String {
        case "user":
            return (.thinking, "Nova mensagem recebida")
        case "assistant":
            if message["error"] != nil { return (.waitingUser, "Erro") }
            let completed = (message["time"] as? [String: Any])?["completed"] != nil
            if !completed { return (.thinking, nil) }
            if message["finish"] as? String == "tool-calls" { return (.thinking, "A usar ferramentas") }
            return (.waitingUser, nil)
        default:
            return (.unknown, nil)
        }
    }

    /// Tokens e modelo de uma mensagem do assistente (para a contagem diária e o custo).
    static func usage(_ message: [String: Any]) -> (usage: TokenUsage, model: String?, date: Date?)? {
        guard message["role"] as? String == "assistant", let t = message["tokens"] as? [String: Any] else { return nil }
        let cache = t["cache"] as? [String: Any] ?? [:]
        func int(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }
        let u = TokenUsage(input: int(t["input"]), output: int(t["output"]) + int(t["reasoning"]),
                           cacheRead: int(cache["read"]), cacheWrite: int(cache["write"]))
        guard !u.isEmpty else { return nil }
        return (u, message["modelID"] as? String, parseDate((message["time"] as? [String: Any])?["created"]))
    }
}

/// Consultas só de leitura a bases de dados de outras apps (também em modo imutável, se a app
/// estiver fechada e faltarem os ficheiros -wal/-shm).
enum SQLiteRead {
    static func query(_ path: String, _ sql: String, _ row: (OpaquePointer) -> Void) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        var db: OpaquePointer?
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK
            || sqlite3_exec(db, "SELECT 1 FROM sqlite_master LIMIT 1", nil, nil, nil) != SQLITE_OK {
            sqlite3_close(db); db = nil
            let uri = "file:" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path) + "?immutable=1"
            guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { sqlite3_close(db); return }
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
    }

    static func text(_ s: OpaquePointer, _ i: Int32) -> String? {
        sqlite3_column_text(s, i).map { String(cString: $0) }
    }
}
