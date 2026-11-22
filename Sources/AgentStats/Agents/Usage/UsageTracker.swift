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
    var other = TokenUsage()   // Copilot, OpenCode
    var cost: Double = 0       // custo estimado em API (USD)
    var total: TokenUsage { claude + codex + other }
}

/// Tokens de um projeto (a pasta onde o agente trabalhou) nos últimos 7 dias.
struct ProjectUsage: Equatable {
    var name: String
    var usage: TokenUsage
    var cost: Double = 0
}

struct UsageSnapshot {
    var perSession: [String: TokenUsage] = [:]   // chave: caminho do transcript/rollout
    /// Custo estimado em API por sessão (só quando o modelo tem preço conhecido).
    var perSessionCost: [String: Double] = [:]
    var todayCost: Double { week.last?.cost ?? 0 }
    var weekCost: Double { week.reduce(0) { $0 + $1.cost } }
    var todayClaude = TokenUsage()
    var todayCodex = TokenUsage()
    var todayOther = TokenUsage()
    var todayTotal: TokenUsage { todayClaude + todayCodex + todayOther }
    /// Últimos 7 dias, do mais antigo para hoje (dias sem uso incluídos, com zero).
    var week: [DayUsage] = []
    /// Projetos com mais tokens nos últimos 7 dias, do maior para o menor.
    var projects: [ProjectUsage] = []
    var weekTotal: TokenUsage { week.reduce(TokenUsage()) { $0 + $1.total } }
    /// Limites do plano do Codex, da leitura mais recente nos rollouts.
    var codexLimits: PlanLimits?
}

/// Soma os tokens registados nos transcripts do Claude Code e nos rollouts do Codex.
/// Lê cada ficheiro de forma incremental (só os bytes novos desde a última vez).
final class UsageTracker {
    private struct FileState {
        var offset: UInt64 = 0
        var session = TokenUsage()
        var byDay: [String: TokenUsage] = [:]
        var seenIDs = Set<String>()   // o Claude repete a mesma mensagem (e o mesmo usage) em várias linhas
        var project: String?          // último componente da pasta mais recente onde o agente trabalhou
        var limits: PlanLimits?       // Codex: rate_limits do último token_count
        var model: String?            // Codex: modelo do último turn_context
        var cost: Double = 0
        var costByDay: [String: Double] = [:]
        var priced = false            // pelo menos um pedido com preço conhecido
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
        var projectCost: [String: Double] = [:]

        func add(_ st: FileState, path: String, source: Source) {
            snap.perSession[path] = st.session
            if st.priced { snap.perSessionCost[path] = st.cost }
            for (day, c) in st.costByDay where week[day] != nil {
                week[day]!.cost += c
                projectCost[st.project ?? "Sem projeto", default: 0] += c
            }
            if let l = st.limits, l.observedAt > (snap.codexLimits?.observedAt ?? .distantPast) { snap.codexLimits = l }
            for (day, u) in st.byDay where week[day] != nil {
                switch source {
                case .claude: week[day]!.claude = week[day]!.claude + u
                case .codex: week[day]!.codex = week[day]!.codex + u
                case .copilot: week[day]!.other = week[day]!.other + u
                }
                projects[st.project ?? "Sem projeto", default: TokenUsage()] = projects[st.project ?? "Sem projeto", default: TokenUsage()] + u
            }
        }
        for url in claudeFiles(modifiedSince: since) { add(scan(url.path, source: .claude), path: url.path, source: .claude) }
        for path in codexFiles(modifiedSince: since) { add(scan(path, source: .codex), path: path, source: .codex) }
        for path in copilotFiles(modifiedSince: since) { add(scan(path, source: .copilot), path: path, source: .copilot) }
        addOpenCode(since: since, into: &week, projects: &projects, projectCost: &projectCost, snap: &snap)

        snap.week = days.compactMap { week[$0] }
        snap.todayClaude = week[today]?.claude ?? TokenUsage()
        snap.todayCodex = week[today]?.codex ?? TokenUsage()
        snap.todayOther = week[today]?.other ?? TokenUsage()
        snap.projects = projects.map { ProjectUsage(name: $0.key, usage: $0.value, cost: projectCost[$0.key] ?? 0) }
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

    private func copilotFiles(modifiedSince since: Date) -> [String] {
        let base = home.appendingPathComponent(".copilot/session-state")
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { return [] }
        return dirs.map { $0.appendingPathComponent("events.jsonl") }.filter { modified($0) >= since }.map(\.path)
    }

    // MARK: OpenCode (SQLite)

    private var openCodeCache: (mtime: Date, since: Date, rows: [(session: String, cwd: String?, day: String, usage: TokenUsage, cost: Double?)])?

    /// Soma as mensagens do OpenCode dos últimos 7 dias. Só volta a ler quando a base de dados muda.
    private func addOpenCode(since: Date, into week: inout [String: DayUsage], projects: inout [String: TokenUsage],
                             projectCost: inout [String: Double], snap: inout UsageSnapshot) {
        let path = OpenCodeReader.databasePath
        let mtime = [path, path + "-wal"].map { modified(URL(fileURLWithPath: $0)) }.max() ?? .distantPast
        guard mtime != .distantPast else { return }
        if openCodeCache == nil || openCodeCache!.mtime != mtime || openCodeCache!.since != since {
            var rows: [(String, String?, String, TokenUsage, Double?)] = []
            let ms = Int64(since.timeIntervalSince1970 * 1000)
            SQLiteRead.query(path, "SELECT m.session_id, m.data, s.directory FROM message m LEFT JOIN session s ON s.id = m.session_id WHERE m.time_created > \(ms)") { st in
                guard let sid = SQLiteRead.text(st, 0), let d = SQLiteRead.text(st, 1),
                      let j = TextTail.json(Data(d.utf8)), let u = OpenCodeReader.usage(j) else { return }
                let cwd = ((j["path"] as? [String: Any])?["cwd"] as? String) ?? SQLiteRead.text(st, 2)
                rows.append((sid, cwd, dayFormat.string(from: u.date ?? Date()), u.usage, Pricing.cost(u.usage, model: u.model)))
            }
            openCodeCache = (mtime, since, rows)
        }
        for r in openCodeCache!.rows where week[r.day] != nil {
            let project = r.cwd.map { ($0 as NSString).lastPathComponent } ?? "Sem projeto"
            week[r.day]!.other = week[r.day]!.other + r.usage
            projects[project, default: TokenUsage()] = projects[project, default: TokenUsage()] + r.usage
            let key = "opencode:" + r.session
            snap.perSession[key, default: TokenUsage()] = snap.perSession[key, default: TokenUsage()] + r.usage
            if let c = r.cost {
                week[r.day]!.cost += c
                projectCost[project, default: 0] += c
                snap.perSessionCost[key, default: 0] += c
            }
        }
    }

    private func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// Tokens de um único ficheiro (lido de forma incremental, tal como em `update()`). Usado nos testes.
    func usage(ofFile path: String, codex: Bool) -> (session: TokenUsage, byDay: [String: TokenUsage], project: String?) {
        let st = scan(path, source: codex ? .codex : .claude)
        return (st.session, st.byDay, st.project)
    }

    /// Custo estimado de um único ficheiro (nil se nenhum modelo tiver preço). Usado nos testes.
    func cost(ofFile path: String, codex: Bool) -> Double? {
        let st = scan(path, source: codex ? .codex : .claude)
        return st.priced ? st.cost : nil
    }

    /// Limites lidos de um único rollout do Codex. Usado nos testes.
    func limits(ofFile path: String) -> PlanLimits? { scan(path, source: .codex).limits }

    /// Tokens de um events.jsonl do Copilot. Usado nos testes.
    func copilotUsage(ofFile path: String) -> (session: TokenUsage, cost: Double?, project: String?) {
        let st = scan(path, source: .copilot)
        return (st.session, st.priced ? st.cost : nil, st.project)
    }

    // MARK: Leitura incremental

    enum Source { case claude, codex, copilot }

    private func scan(_ path: String, source: Source) -> FileState {
        let codex = source == .codex
        let copilot = source == .copilot
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

        let marker = Data((codex ? "\"token_count\"" : copilot ? "\"session.usage_record\"" : "\"usage\"").utf8)
        let copilotStart = Data("\"session.start\"".utf8)
        let metaMarker = Data("\"session_meta\"".utf8)
        let contextMarker = Data("\"turn_context\"".utf8)
        for line in complete.split(separator: UInt8(ascii: "\n")) {
            // Codex: a pasta do projeto só vem na linha inicial (session_meta)
            let isMeta = codex && st.project == nil && line.range(of: metaMarker) != nil
            // Codex: o modelo vem em cada turn_context (pode mudar a meio da sessão)
            let isContext = codex && line.range(of: contextMarker) != nil
            let isCopilotStart = copilot && line.range(of: copilotStart) != nil
            guard line.count > 20, isMeta || isContext || isCopilotStart || line.range(of: marker) != nil,
                  let j = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            // Fica a pasta mais recente: uma sessão pode mudar de pasta a meio.
            let cwd = codex ? (j["payload"] as? [String: Any])?["cwd"] as? String
                : copilot ? ((j["data"] as? [String: Any])?["context"] as? [String: Any])?["cwd"] as? String
                : j["cwd"] as? String
            if let cwd, !cwd.isEmpty { st.project = (cwd as NSString).lastPathComponent }
            if isMeta || isCopilotStart { continue }
            if isContext {
                if j["type"] as? String == "turn_context", let model = (j["payload"] as? [String: Any])?["model"] as? String { st.model = model }
                continue
            }
            let date = (j["timestamp"] as? String).flatMap { iso.date(from: $0) }
            let day = date.map { dayFormat.string(from: $0) } ?? ""
            var u: TokenUsage?
            var model: String? = st.model
            if codex, let limits = (j["payload"] as? [String: Any])?["rate_limits"] as? [String: Any],
               let parsed = PlanLimitsParser.codex(limits, observed: date ?? Date()) {
                st.limits = parsed
            }
            if copilot {
                if let usage = (j["data"] as? [String: Any])?["usage"] as? [String: Any] {
                    func int(_ k: String) -> Int { (usage[k] as? NSNumber)?.intValue ?? 0 }
                    model = usage["model"] as? String
                    u = TokenUsage(input: int("inputTokens"), output: int("outputTokens"),
                                   cacheRead: int("cacheReadTokens"), cacheWrite: int("cacheWriteTokens"))
                }
            } else if codex {
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
                model = msg["model"] as? String
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
                if let c = Pricing.cost(u, model: model) {
                    st.cost += c
                    st.costByDay[day, default: 0] += c
                    st.priced = true
                }
            }
        }
        files[path] = st
        return st
    }
}
