import Foundation

/// Uma janela de limite do plano: quanto já se gastou e quando renova.
struct LimitWindow: Sendable, Equatable, Identifiable {
    var id: String
    var label: String          // "5 horas", "Semana", "Semana · Opus", "30 dias"
    var usedPercent: Double    // 0...100
    var resetsAt: Date?
    /// Quanto dura a janela inteira (para prever o ritmo). nil se não se souber.
    var duration: TimeInterval? = nil
}

/// Os limites de um agente, tal como foram lidos num dado momento.
struct PlanLimits: Sendable, Equatable {
    enum Provider: String, Sendable { case claude = "Claude", codex = "Codex" }
    var provider: Provider
    var plan: String?
    var windows: [LimitWindow]
    var observedAt: Date

    /// Só as janelas que ainda valem: uma que já renovou depois da leitura não diz nada sobre o
    /// que se gastou desde então, por isso sai (em vez de inventar 0%).
    func current(now: Date) -> PlanLimits? {
        var copy = self
        copy.windows.removeAll { w in
            if let r = w.resetsAt { return r <= now }
            return now.timeIntervalSince(observedAt) > 6 * 3600
        }
        return copy.windows.isEmpty ? nil : copy
    }
}

/// Converte as respostas do Claude Code e dos rollouts do Codex em `PlanLimits`.
enum PlanLimitsParser {
    static func label(minutes: Int) -> String {
        switch minutes {
        case 300: return "5 horas"
        case 10_080: return "Semana"
        case let m where m % 1440 == 0: return "\(m / 1440) dias"
        case let m where m % 60 == 0: return "\(m / 60) horas"
        default: return "\(minutes) min"
        }
    }

    static func planName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "free": return "Grátis"
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "max": return "Max"
        case "team": return "Team"
        case "enterprise": return "Enterprise"
        default: return raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }

    /// Codex: `payload.rate_limits` de um evento `token_count` num rollout.
    /// `primary` e `secondary` trazem `used_percent`, `window_minutes` e `resets_at` (segundos Unix);
    /// versões antigas traziam `resets_in_seconds`, relativo ao momento da linha.
    static func codex(_ limits: [String: Any], observed: Date) -> PlanLimits? {
        let windows: [LimitWindow] = ["primary", "secondary"].compactMap { key in
            guard let w = limits[key] as? [String: Any], let used = number(w["used_percent"]) else { return nil }
            let minutes = number(w["window_minutes"]).map { Int($0) }
            let resets = number(w["resets_at"]).map { Date(timeIntervalSince1970: $0) }
                ?? number(w["resets_in_seconds"]).map { observed.addingTimeInterval($0) }
            return LimitWindow(id: "codex.\(key)", label: minutes.map(label(minutes:)) ?? (key == "primary" ? "Sessão" : "Semana"),
                               usedPercent: min(100, max(0, used)), resetsAt: resets, duration: minutes.map { Double($0) * 60 })
        }
        guard !windows.isEmpty else { return nil }
        return PlanLimits(provider: .codex, plan: planName(limits["plan_type"] as? String), windows: windows, observedAt: observed)
    }

    /// Claude: resposta ao pedido `get_usage` do Claude Code (os mesmos dados que o `/usage`).
    static func claudeUsage(_ response: [String: Any], observed: Date) -> PlanLimits? {
        guard response["rate_limits_available"] as? Bool == true,
              let limits = response["rate_limits"] as? [String: Any] else { return nil }
        let hours: TimeInterval = 3600
        let keys: [(String, String, TimeInterval)] = [("five_hour", "5 horas", 5 * hours), ("seven_day", "Semana", 168 * hours),
                                                      ("seven_day_opus", "Semana · Opus", 168 * hours),
                                                      ("seven_day_sonnet", "Semana · Sonnet", 168 * hours)]
        let windows: [LimitWindow] = keys.compactMap { key, label, duration in
            guard let w = limits[key] as? [String: Any], let used = number(w["utilization"]) else { return nil }
            let resets = (w["resets_at"] as? String).flatMap(parseISO)
            return LimitWindow(id: "claude.\(key)", label: label, usedPercent: min(100, max(0, used)), resetsAt: resets,
                               duration: duration)
        }
        guard !windows.isEmpty else { return nil }
        return PlanLimits(provider: .claude, plan: planName(response["subscription_type"] as? String),
                          windows: windows, observedAt: observed)
    }

    /// Claude: histórico que a app Claude (desktop) guarda em
    /// `~/Library/Application Support/Claude/plan-usage-history.json` (`fh` = 5 h, `sd` = 7 dias).
    /// Não traz a hora de renovação. Usa-se a última leitura com valores.
    static func claudeDesktopHistory(_ data: Data) -> PlanLimits? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let samples = j["samples"] as? [[String: Any]] else { return nil }
        for s in samples.reversed() {
            guard let u = s["u"] as? [String: Any], !u.isEmpty, let t = number(s["t"]) else { continue }
            var windows: [LimitWindow] = []
            if let fh = number(u["fh"]) { windows.append(LimitWindow(id: "claude.five_hour", label: "5 horas", usedPercent: min(100, max(0, fh)))) }
            if let sd = number(u["sd"]) { windows.append(LimitWindow(id: "claude.seven_day", label: "Semana", usedPercent: min(100, max(0, sd)))) }
            guard !windows.isEmpty else { continue }
            return PlanLimits(provider: .claude, plan: nil, windows: windows, observedAt: Date(timeIntervalSince1970: t / 1000))
        }
        return nil
    }

    private static func number(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }

    private static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

/// Pergunta os limites ao Claude Code instalado (`claude`), pelo protocolo de controlo em JSON.
/// Não é enviada nenhuma mensagem ao modelo: só `initialize` e `get_usage`, sem ferramentas,
/// MCP nem hooks, e sem gravar sessão. A autenticação é a do próprio Claude Code.
enum ClaudeLimitsFetcher {
    enum Outcome: Sendable, Equatable {
        case limits(PlanLimits)
        case signedOut        // instalado, mas sem sessão iniciada com uma conta Pro/Max
        case notInstalled
        case failed
    }

    static func executable(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let candidates = [home.appendingPathComponent(".local/bin/claude").path,
                          home.appendingPathComponent(".claude/local/claude").path,
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// Bloqueia até ~15 s: chamar fora do main thread.
    static func fetch() -> Outcome {
        guard let exe = executable() else { return .notInstalled }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--print", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                       "--no-session-persistence", "--tools", "", "--strict-mcp-config",
                       "--mcp-config", "{\"mcpServers\":{}}", "--settings", "{\"disableAllHooks\":true}"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"].map { $0 + ":" } ?? "") + "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        p.environment = env
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return .failed }

        let requests = [["type": "control_request", "request_id": "i", "request": ["subtype": "initialize"]],
                        ["type": "control_request", "request_id": "u", "request": ["subtype": "get_usage"]]]
        for r in requests {
            guard let d = try? JSONSerialization.data(withJSONObject: r),
                  send(d + Data("\n".utf8), to: input.fileHandleForWriting) else { break }
        }
        try? input.fileHandleForWriting.close()

        // Corta o processo se não responder a tempo.
        let deadline = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: deadline)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        deadline.cancel()
        p.waitUntilExit()
        return parse(data, observed: Date())
    }

    /// Escreve sem arriscar a app: se o `claude` já saiu, escrever dá SIGPIPE, que mata o processo
    /// inteiro. Com F_SETNOSIGPIPE passa a ser um erro normal, e `write(contentsOf:)` devolve-o
    /// em vez de lançar uma exceção de Objective-C como o `write(_:)`.
    static func send(_ data: Data, to handle: FileHandle) -> Bool {
        guard fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else { return false }
        do {
            try handle.write(contentsOf: data)
            return true
        } catch {
            return false
        }
    }

    /// Procura a resposta ao pedido `u` na saída do Claude Code (uma linha JSON por evento).
    static func parse(_ data: Data, observed: Date) -> Outcome {
        for line in data.split(separator: UInt8(ascii: "\n")) where line.count > 10 {
            guard let j = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  j["type"] as? String == "control_response",
                  let r = j["response"] as? [String: Any], r["request_id"] as? String == "u" else { continue }
            guard r["subtype"] as? String == "success", let body = r["response"] as? [String: Any] else { return .failed }
            return PlanLimitsParser.claudeUsage(body, observed: observed).map(Outcome.limits) ?? .signedOut
        }
        return .failed
    }
}
