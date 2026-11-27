import Foundation

struct TokenUsage: Equatable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    /// A parte de `cacheWrite` guardada por 1 hora (o Claude Code usa-a), que custa mais do que a de 5 minutos.
    var cacheWrite1h = 0
    var total: Int { input + output + cacheRead + cacheWrite }
    var isEmpty: Bool { total == 0 }
    static func + (a: TokenUsage, b: TokenUsage) -> TokenUsage {
        TokenUsage(input: a.input + b.input, output: a.output + b.output,
                   cacheRead: a.cacheRead + b.cacheRead, cacheWrite: a.cacheWrite + b.cacheWrite,
                   cacheWrite1h: a.cacheWrite1h + b.cacheWrite1h)
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
        var codexTotal: [Int]?        // Codex: total acumulado do último token_count (repetido = evento duplicado)
    }
    private var files: [String: FileState] = [:]
    /// Claude: id da mensagem → ficheiro onde conta. Uma sessão continuada copia o histórico da anterior,
    /// e cada pedido só deve contar uma vez, no ficheiro mais antigo.
    private var claudeOwner: [String: String] = [:]
    private let home = FileManager.default.homeDirectoryForCurrentUser


    func update(now: Date = Date()) -> UsageSnapshot {
        let cal = Calendar.current
        let today = DayKey.string(now)
        let days = (0..<7).reversed().compactMap { cal.date(byAdding: .day, value: -$0, to: now) }.map { DayKey.string($0) }
        let since = cal.startOfDay(for: cal.date(byAdding: .day, value: -6, to: now) ?? now)
        var snap = UsageSnapshot()
        var week = Dictionary(uniqueKeysWithValues: days.map { ($0, DayUsage(day: $0)) })
        var projects: [String: TokenUsage] = [:]
        var projectCost: [String: Double] = [:]

        var seen = Set<String>()
        func add(_ st: FileState, path: String, source: Source) {
            seen.insert(path)
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
        // Os ficheiros que saíram da semana já não contam: o estado deles sai também (a memória não cresce para sempre).
        if files.count > seen.count {
            files = files.filter { seen.contains($0.key) }
            claudeOwner = claudeOwner.filter { seen.contains($0.value) }
        }

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
        // Os mais antigos primeiro: ficam donos das mensagens que as continuações copiam.
        // A data de criação lê-se uma vez por ficheiro, não em cada comparação da ordenação.
        return out.map { ($0, created($0)) }.sorted { ($0.1, $0.0.path) < ($1.1, $1.0.path) }.map(\.0)
    }

    private func created(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
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
                rows.append((sid, cwd, DayKey.string(u.date ?? Date()), u.usage, Pricing.cost(u.usage, model: u.model)))
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

    #if DEBUG
    // Só para os testes: não vão no binário de produção.

    /// Tokens de um único ficheiro (lido de forma incremental, tal como em `update()`).
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
    #endif

    /// false quando o `total_token_usage` é igual ao do evento anterior (evento repetido).
    static func codexIsNew(_ info: [String: Any], previous: inout [Int]?) -> Bool {
        guard let total = info["total_token_usage"] as? [String: Any] else { return true }
        let key = ["input_tokens", "cached_input_tokens", "output_tokens", "reasoning_output_tokens", "total_tokens"]
            .map { (total[$0] as? Int) ?? -1 }
        defer { previous = key }
        return key != previous
    }

    /// Os tokens de um pedido do Claude. A divisão entre cache de 5 min e de 1 h vem em `cache_creation`;
    /// sem ela (versões antigas), conta tudo como 5 min.
    static func claudeUsage(_ usage: [String: Any]) -> TokenUsage {
        let write = (usage["cache_creation_input_tokens"] as? Int) ?? 0
        let long = ((usage["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"] as? Int) ?? 0
        return TokenUsage(input: (usage["input_tokens"] as? Int) ?? 0,
                          output: (usage["output_tokens"] as? Int) ?? 0,
                          cacheRead: (usage["cache_read_input_tokens"] as? Int) ?? 0,
                          cacheWrite: write, cacheWrite1h: min(max(0, long), write))
    }

    // MARK: Leitura incremental

    enum Source { case claude, codex, copilot }

    /// Quanto se lê de cada vez. Os testes usam blocos pequenos para cortar linhas a meio.
    var chunkSize = 4 << 20

    private func scan(_ path: String, source: Source) -> FileState {
        let codex = source == .codex
        let copilot = source == .copilot
        var st = files[path] ?? FileState()
        guard let h = FileHandle(forReadingAtPath: path) else { return st }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        if size < st.offset {                           // ficheiro reescrito
            st = FileState()
            claudeOwner = claudeOwner.filter { $0.value != path }
        }
        guard size > st.offset else { files[path] = st; return st }
        try? h.seek(toOffset: st.offset)

        let marker = Data((codex ? "\"token_count\"" : copilot ? "\"session.usage_record\"" : "\"usage\"").utf8)
        let copilotStart = Data("\"session.start\"".utf8)
        let metaMarker = Data("\"session_meta\"".utf8)
        let contextMarker = Data("\"turn_context\"".utf8)
        let newline = UInt8(ascii: "\n")
        // Aos blocos: um transcript pode ter centenas de MB e lê-lo de uma vez fazia disparar a memória.
        // Só se processa até à última linha completa; o resto fica para o bloco seguinte ou para a próxima vez.
        var carry = Data()
        while true {
            let chunk = autoreleasepool { (try? h.read(upToCount: chunkSize)) ?? Data() }
            guard !chunk.isEmpty else { break }
            carry.append(chunk)
            guard let lastNL = carry.lastIndex(of: newline) else { continue }
            let complete = carry[carry.startIndex...lastNL]
            st.offset += UInt64(complete.count)
            autoreleasepool {
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
                    let date = (j["timestamp"] as? String).flatMap { ISODate.shared.parse($0) }
                    let day = date.map { DayKey.string($0) } ?? ""
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
                        // O mesmo evento pode vir repetido: o total acumulado não muda e não há consumo novo.
                        if let info = (j["payload"] as? [String: Any])?["info"] as? [String: Any],
                           let last = info["last_token_usage"] as? [String: Any],
                           Self.codexIsNew(info, previous: &st.codexTotal) {
                            let input = (last["input_tokens"] as? Int) ?? 0
                            let cached = (last["cached_input_tokens"] as? Int) ?? 0
                            u = TokenUsage(input: max(0, input - cached), output: (last["output_tokens"] as? Int) ?? 0, cacheRead: cached)
                        }
                    } else if j["type"] as? String == "assistant",
                              let msg = j["message"] as? [String: Any],
                              let usage = msg["usage"] as? [String: Any] {
                        let id = (msg["id"] as? String) ?? UUID().uuidString
                        model = msg["model"] as? String
                        let owner = claudeOwner[id]
                        if owner == nil || owner == path, st.seenIDs.insert(id).inserted {
                            claudeOwner[id] = path
                            u = Self.claudeUsage(usage)
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
            }
            carry = Data(carry[carry.index(after: lastNL)...])
        }
        files[path] = st
        return st
    }
}
