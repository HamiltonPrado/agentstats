import Foundation

struct TokenUsage: Equatable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    var total: Int { input + output + cacheRead + cacheWrite }
    var isEmpty: Bool { total == 0 }
    static func + (a: TokenUsage, b: TokenUsage) -> TokenUsage {
        TokenUsage(input: a.input + b.input, output: a.output + b.output,
                   cacheRead: a.cacheRead + b.cacheRead, cacheWrite: a.cacheWrite + b.cacheWrite)
    }
}

/// Tokens de um dia, separados por agente.
struct DayUsage: Equatable {
    var day: String            // yyyy-MM-dd (hora local)
    var claude = TokenUsage()
    var codex = TokenUsage()
    var total: TokenUsage { claude + codex }
}

/// Tokens de um projeto (a pasta onde o agente trabalhou) nos últimos 7 dias.
struct ProjectUsage: Equatable {
    var name: String
    var usage: TokenUsage
}

struct UsageSnapshot {
    var perSession: [String: TokenUsage] = [:]   // chave: caminho do transcript/rollout
    var todayClaude = TokenUsage()
    var todayCodex = TokenUsage()
    var todayTotal: TokenUsage { todayClaude + todayCodex }
    /// Últimos 7 dias, do mais antigo para hoje (dias sem uso incluídos, com zero).
    var week: [DayUsage] = []
    /// Projetos com mais tokens nos últimos 7 dias, do maior para o menor.
    var projects: [ProjectUsage] = []
    var weekTotal: TokenUsage { week.reduce(TokenUsage()) { $0 + $1.total } }
}

/// Soma os tokens registados nos transcripts do Claude Code e nos rollouts do Codex.
/// Lê cada ficheiro de forma incremental (só os bytes novos desde a última vez).
final class UsageTracker {
    private struct FileState {
        var offset: UInt64 = 0
        var session = TokenUsage()
        var byDay: [String: TokenUsage] = [:]
        var seenIDs = Set<String>()   // o Claude repete a mesma mensagem (e o mesmo usage) em várias linhas
        var project: String?          // último componente da pasta onde o agente trabalhou
    }
    private var files: [String: FileState] = [:]
    private let home = FileManager.default.homeDirectoryForCurrentUser

    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    func update(now: Date = Date()) -> UsageSnapshot {
        let cal = Calendar.current
        let today = dayFormat.string(from: now)
        let days = (0..<7).reversed().compactMap { cal.date(byAdding: .day, value: -$0, to: now) }.map { dayFormat.string(from: $0) }
        let since = cal.startOfDay(for: cal.date(byAdding: .day, value: -6, to: now) ?? now)
        var snap = UsageSnapshot()
        var week = Dictionary(uniqueKeysWithValues: days.map { ($0, DayUsage(day: $0)) })
        var projects: [String: TokenUsage] = [:]

        func add(_ st: FileState, path: String, codex: Bool) {
            snap.perSession[path] = st.session
            for (day, u) in st.byDay where week[day] != nil {
                if codex { week[day]!.codex = week[day]!.codex + u } else { week[day]!.claude = week[day]!.claude + u }
                projects[st.project ?? "Sem projeto", default: TokenUsage()] = projects[st.project ?? "Sem projeto", default: TokenUsage()] + u
            }
        }
        for url in claudeFiles(modifiedSince: since) { add(scan(url.path, codex: false), path: url.path, codex: false) }
        for path in codexFiles(modifiedSince: since) { add(scan(path, codex: true), path: path, codex: true) }

        snap.week = days.compactMap { week[$0] }
        snap.todayClaude = week[today]?.claude ?? TokenUsage()
        snap.todayCodex = week[today]?.codex ?? TokenUsage()
        snap.projects = projects.map { ProjectUsage(name: $0.key, usage: $0.value) }
            .sorted { $0.usage.total > $1.usage.total }
        return snap
    }

    // MARK: Ficheiros

    private func claudeFiles(modifiedSince since: Date) -> [URL] {
        let base = home.appendingPathComponent(".claude/projects")
        let fm = FileManager.default
        var out: [URL] = []
        guard let dirs = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { return [] }
        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for f in items where f.pathExtension == "jsonl" && modified(f) >= since {
                out.append(f)
                // subagentes: <sessão>/subagents/*.jsonl contam para o total do dia
                let sub = f.deletingPathExtension().appendingPathComponent("subagents")
                if let subs = try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: [.contentModificationDateKey]) {
                    out.append(contentsOf: subs.filter { $0.pathExtension == "jsonl" && modified($0) >= since })
                }
            }
        }
        return out
    }

    private func codexFiles(modifiedSince since: Date) -> [String] {
        let base = home.appendingPathComponent(".codex/sessions")
        guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.contentModificationDateKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        var out: [String] = []
        for case let url as URL in e where url.pathExtension == "jsonl" && modified(url) >= since {
            out.append(url.path)
        }
        return out
    }

    private func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// Tokens de um único ficheiro (lido de forma incremental, tal como em `update()`). Usado nos testes.
    func usage(ofFile path: String, codex: Bool) -> (session: TokenUsage, byDay: [String: TokenUsage], project: String?) {
        let st = scan(path, codex: codex)
        return (st.session, st.byDay, st.project)
    }

    // MARK: Leitura incremental

    private func scan(_ path: String, codex: Bool) -> FileState {
        var st = files[path] ?? FileState()
        guard let h = FileHandle(forReadingAtPath: path) else { return st }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        if size < st.offset { st = FileState() }        // ficheiro reescrito
        guard size > st.offset else { files[path] = st; return st }
        try? h.seek(toOffset: st.offset)
        let data = (try? h.readToEnd()) ?? Data()
        // Só processa até à última linha completa; o resto fica para a próxima vez.
        guard let lastNL = data.lastIndex(of: UInt8(ascii: "\n")) else { files[path] = st; return st }
        let complete = data[data.startIndex...lastNL]
        st.offset += UInt64(complete.count)

        let marker = Data((codex ? "\"token_count\"" : "\"usage\"").utf8)
        let metaMarker = Data("\"session_meta\"".utf8)
        for line in complete.split(separator: UInt8(ascii: "\n")) {
            // Codex: a pasta do projeto só vem na linha inicial (session_meta)
            let isMeta = codex && st.project == nil && line.range(of: metaMarker) != nil
            guard line.count > 20, isMeta || line.range(of: marker) != nil,
                  let j = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if st.project == nil {
                let cwd = codex ? (j["payload"] as? [String: Any])?["cwd"] as? String : j["cwd"] as? String
                if let cwd, !cwd.isEmpty { st.project = (cwd as NSString).lastPathComponent }
            }
            if isMeta { continue }
            let day = (j["timestamp"] as? String).flatMap { iso.date(from: $0) }.map { dayFormat.string(from: $0) } ?? ""
            var u: TokenUsage?
            if codex {
                // event_msg/token_count: info.last_token_usage é o consumo deste pedido
                if let info = (j["payload"] as? [String: Any])?["info"] as? [String: Any],
                   let last = info["last_token_usage"] as? [String: Any] {
                    let input = (last["input_tokens"] as? Int) ?? 0
                    let cached = (last["cached_input_tokens"] as? Int) ?? 0
                    u = TokenUsage(input: max(0, input - cached), output: (last["output_tokens"] as? Int) ?? 0, cacheRead: cached)
                }
            } else if j["type"] as? String == "assistant",
                      let msg = j["message"] as? [String: Any],
                      let usage = msg["usage"] as? [String: Any] {
                let id = (msg["id"] as? String) ?? UUID().uuidString
                if st.seenIDs.insert(id).inserted {
                    u = TokenUsage(input: (usage["input_tokens"] as? Int) ?? 0,
                                   output: (usage["output_tokens"] as? Int) ?? 0,
                                   cacheRead: (usage["cache_read_input_tokens"] as? Int) ?? 0,
                                   cacheWrite: (usage["cache_creation_input_tokens"] as? Int) ?? 0)
                }
            }
            if let u {
                st.session = st.session + u
                st.byDay[day, default: TokenUsage()] = st.byDay[day, default: TokenUsage()] + u
            }
        }
        files[path] = st
        return st
    }
}
