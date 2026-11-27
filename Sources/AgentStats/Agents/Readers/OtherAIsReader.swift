import Foundation
import SQLite3

/// Lê sessões e histórico de outras IAs e agentes locais:
/// - Aider (`.aider.chat.history.md` na pasta do projeto)
/// - Goose (`~/.local/share/goose/sessions/`)
/// - Gemini CLI (`~/.gemini/tmp/*/chats/`)
/// - Cursor Agent, OpenCode, Amp e qualquer processo de agente ativo
final class OtherAIsReader {
    private let home = FileManager.default.homeDirectoryForCurrentUser

    struct TailInfo: Equatable {
        var title: String?
        var state: AgentState = .unknown
        var detail: String?
        var timestamp: Date?
    }

    private let fileCache = FileCache<TailInfo>()

    func sessions(processes: [AgentProcess], existingSessions: [AgentSession]) -> [AgentSession] {
        let linkedPids = Set(existingSessions.compactMap { $0.process?.pid })
        // Filtra processos de agentes que ainda não têm uma sessão associada
        let unlinked = processes.filter { !linkedPids.contains($0.pid) && !$0.isSubagent && $0.role != "executor" }
        guard !unlinked.isEmpty else { return [] }

        var out: [AgentSession] = []
        for p in unlinked {
            let session = sessionForProcess(p)
            out.append(session)
        }
        return out
    }

    private func sessionForProcess(_ p: AgentProcess) -> AgentSession {
        let now = Date()
        let project = p.cwd.map { ($0 as NSString).lastPathComponent } ?? "—"

        // 1. Tenta leitores específicos por tipo de agente
        if p.kind == "Aider", let cwd = p.cwd {
            if let aiderSession = readAider(cwd: cwd, process: p) { return aiderSession }
        } else if p.kind == "Goose" {
            if let gooseSession = readGoose(process: p) { return gooseSession }
        } else if p.kind == "Gemini CLI" {
            if let geminiSession = readGeminiCLI(process: p) { return geminiSession }
        }

        // 2. Fallback inteligente baseado em telemetria do processo
        // Se tem CPU alta (> 1.5%) ou subprocessos a correr (git, compiler, python, test), está a trabalhar
        let isBusy = p.cpu > 1.5 || !p.children.isEmpty
        let state: AgentState
        let detail: String?

        if isBusy {
            if let child = p.children.first {
                state = .runningTool(child)
                detail = p.children.joined(separator: ", ")
            } else {
                state = .thinking
                detail = "A processar tarefas no projeto"
            }
        } else {
            state = .waitingUser
            detail = "À espera de comandos no terminal"
        }

        let title = "\(p.kind): \(project)"

        return AgentSession(
            id: "proc-\(p.pid)-\(p.kind)",
            kind: p.kind,
            title: title,
            cwd: p.cwd,
            model: nil,
            state: state,
            detail: detail,
            lastActivity: now,
            subagents: 0,
            process: p
        )
    }

    // MARK: - Aider

    func readAider(cwd: String, process: AgentProcess) -> AgentSession? {
        let historyPath = (cwd as NSString).appendingPathComponent(".aider.chat.history.md")
        let fm = FileManager.default
        guard fm.fileExists(atPath: historyPath) else { return nil }

        let attrs = try? fm.attributesOfItem(atPath: historyPath)
        let mtime = (attrs?[.modificationDate] as? Date) ?? Date()
        let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0

        let info = tailAider(URL(fileURLWithPath: historyPath), mtime: mtime, size: size)

        let isBusy = process.cpu > 1.5 || !process.children.isEmpty
        let state: AgentState = isBusy ? (process.children.first.map { .runningTool($0) } ?? .thinking) : .waitingUser

        let title = info.title ?? String(localized: "Sessão Aider (\((cwd as NSString).lastPathComponent))")
        let detail = isBusy ? (process.children.first ?? "A editar código") : (info.detail ?? "À tua espera")

        return AgentSession(
            id: historyPath,
            kind: "Aider",
            title: title,
            cwd: cwd,
            model: nil,
            state: state,
            detail: detail,
            lastActivity: info.timestamp ?? mtime,
            subagents: 0,
            process: process
        )
    }

    func tailAider(_ url: URL, mtime: Date, size: UInt64) -> TailInfo {
        fileCache.value(url.path, mtime: mtime, size: size) {
            let lines = TextTail.lines(url.path, maxBytes: 64 * 1024).map { String(decoding: $0, as: UTF8.self) }
            return parseAiderLines(lines)
        }
    }

    func parseAiderLines(_ lines: [String]) -> TailInfo {
        var info = TailInfo()
        var lastUser: String?
        var lastAssistant: String?

        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#### ") && lastUser == nil {
                let prompt = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if !prompt.isEmpty { lastUser = prompt }
            } else if trimmed.hasPrefix("> ") && lastAssistant == nil {
                let reply = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if !reply.isEmpty && !reply.hasPrefix("####") { lastAssistant = reply }
            }
            if lastUser != nil { break }
        }

        info.title = lastUser.map { $0.count > 60 ? String($0.prefix(60)) + "…" : $0 }
        info.detail = lastAssistant.map { $0.count > 90 ? String($0.prefix(90)) + "…" : $0 }
        return info
    }

    // MARK: - Goose

    func readGoose(process: AgentProcess) -> AgentSession? {
        let gooseDb = home.appendingPathComponent(".local/share/goose/sessions/sessions.db").path
        let fm = FileManager.default
        guard fm.fileExists(atPath: gooseDb) else { return nil }

        var latestTitle: String?
        var latestUpdated: Date?

        var db: OpaquePointer?
        let uri = "file:" + (gooseDb.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? gooseDb) + "?immutable=1"
        if sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db {
            defer { sqlite3_close(db) }
            var stmt: OpaquePointer?
            let sql = "SELECT name, updated_at FROM sessions ORDER BY updated_at DESC LIMIT 1"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt {
                defer { sqlite3_finalize(stmt) }
                if sqlite3_step(stmt) == SQLITE_ROW {
                    if let text = sqlite3_column_text(stmt, 0) { latestTitle = String(cString: text) }
                    let ts = sqlite3_column_double(stmt, 1)
                    if ts > 0 { latestUpdated = Date(timeIntervalSince1970: ts > 1e11 ? ts / 1000 : ts) }
                }
            }
        }

        let isBusy = process.cpu > 1.5 || !process.children.isEmpty
        let state: AgentState = isBusy ? (process.children.first.map { .runningTool($0) } ?? .thinking) : .waitingUser
        let project = process.cwd.map { ($0 as NSString).lastPathComponent } ?? "Goose"
        let title = latestTitle.map { "\($0) (\(project))" } ?? String(localized: "Goose (\(project))")

        return AgentSession(
            id: gooseDb,
            kind: "Goose",
            title: title,
            cwd: process.cwd,
            model: nil,
            state: state,
            detail: isBusy ? (process.children.first ?? "A executar tarefas") : "À tua espera",
            lastActivity: latestUpdated ?? Date(),
            subagents: 0,
            process: process
        )
    }

    // MARK: - Gemini CLI

    func readGeminiCLI(process: AgentProcess) -> AgentSession? {
        let isBusy = process.cpu > 1.5 || !process.children.isEmpty
        let state: AgentState = isBusy ? (process.children.first.map { .runningTool($0) } ?? .thinking) : .waitingUser
        let project = process.cwd.map { ($0 as NSString).lastPathComponent } ?? "Gemini"
        let detail = isBusy ? (process.children.first ?? "A processar") : "À tua espera no terminal"

        return AgentSession(
            id: "gemini-cli-\(process.pid)",
            kind: "Gemini CLI",
            title: String(localized: "Gemini CLI (\(project))"),
            cwd: process.cwd,
            model: "Gemini",
            state: state,
            detail: detail,
            lastActivity: Date(),
            subagents: 0,
            process: process
        )
    }
}
