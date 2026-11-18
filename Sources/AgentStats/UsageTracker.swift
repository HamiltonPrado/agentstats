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

struct UsageSnapshot {
    var perSession: [String: TokenUsage] = [:]   // chave: caminho do transcript/rollout
    var todayClaude = TokenUsage()
    var todayCodex = TokenUsage()
    var todayTotal: TokenUsage { todayClaude + todayCodex }
}

/// Soma os tokens registados nos transcripts do Claude Code e nos rollouts do Codex.
/// Lê cada ficheiro de forma incremental (só os bytes novos desde a última vez).
final class UsageTracker {
    private struct FileState {
        var offset: UInt64 = 0
        var session = TokenUsage()
        var byDay: [String: TokenUsage] = [:]
        var seenIDs = Set<String>()   // o Claude repete a mesma mensagem (e o mesmo usage) em várias linhas
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

    func update() -> UsageSnapshot {
        let today = dayFormat.string(from: Date())
        let since = Calendar.current.startOfDay(for: Date())
        var snap = UsageSnapshot()

        for url in claudeFiles(modifiedSince: since) {
            let st = scan(url.path, codex: false)
            snap.perSession[url.path] = st.session
            snap.todayClaude = snap.todayClaude + (st.byDay[today] ?? TokenUsage())
        }
        for path in codexFiles(modifiedSince: since) {
            let st = scan(path, codex: true)
            snap.perSession[path] = st.session
            snap.todayCodex = snap.todayCodex + (st.byDay[today] ?? TokenUsage())
        }
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
    func usage(ofFile path: String, codex: Bool) -> (session: TokenUsage, byDay: [String: TokenUsage]) {
        let st = scan(path, codex: codex)
        return (st.session, st.byDay)
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
        for line in complete.split(separator: UInt8(ascii: "\n")) {
            guard line.count > 20, line.range(of: marker) != nil,
                  let j = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
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
