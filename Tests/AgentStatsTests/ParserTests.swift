import Foundation
import Testing
import SQLite3
@testable import AgentStats

// Linhas no formato dos ficheiros reais do Claude Code (~/.claude/projects/*/*.jsonl)
// e do Codex (~/.codex/sessions/**/rollout-*.jsonl). Os conteúdos são inventados.

private func lines(_ jsons: [String]) -> [Data] { jsons.map { Data($0.utf8) } }

private let isoNow: String = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: Date())
}()

// MARK: - Formatação

@Suite("Formatação")
struct FormattingTests {
    @Test(arguments: [
        (950, "950"), (1_234, "1,2k"), (12_300, "12k"),
        (4_560_000, "4,6M"), (84_000_000, "84M"), (1_500_000_000, "1,5B"),
    ])
    func tokens(_ n: Int, _ expected: String) {
        #expect(Fmt.tokens(n) == expected)
    }

    @Test(arguments: [
        ("claude-opus-5-5", "Opus 5.5"),
        ("claude-sonnet-4-5-20250929", "Sonnet 4.5"),   // a data no fim é descartada
    ])
    func model(_ raw: String, _ expected: String) {
        #expect(Fmt.model(raw) == expected)
    }

    @Test(arguments: [
        ("02-22:16:01", "2d 22h"), ("01:02:03", "1h 2min"), ("20:29", "20min"), ("00:05", "5s"),
    ])
    func etime(_ raw: String, _ expected: String) {
        #expect(Fmt.etime(raw) == expected)
    }

    @Test func etimeRoundTrip() {
        #expect(ProcessSampler.etime(93_784) == "01-02:03:04")
        #expect(Fmt.etime(ProcessSampler.etime(93_784)) == "1d 2h")
    }
}

// MARK: - Nomes de processos (bug: leitura sem terminador nulo)

@Suite("Arrays C de tamanho fixo")
struct FixedCStringTests {
    @Test func fullArrayWithoutTerminatorStopsAtArrayEnd() {
        let full: (CChar, CChar, CChar, CChar) = (65, 66, 67, 68)   // "ABCD", sem nulo
        #expect(Sys.fixedCString(full) == "ABCD")
    }

    @Test func stopsAtTerminator() {
        let short: (CChar, CChar, CChar, CChar) = (122, 115, 104, 0)   // "zsh\0"
        #expect(Sys.fixedCString(short) == "zsh")
    }

    @Test func bufferHelper() {
        #expect(Sys.string([104, 105, 0, 120]) == "hi")
        #expect(Sys.string([104, 105]) == "hi")
    }
}

// MARK: - Claude Code

@Suite("Transcripts do Claude Code")
struct ClaudeTranscriptTests {
    let reader = AgentReader()

    @Test func pendingBashToolIsRunningTool() {
        let info = reader.parseTail(lines([
            #"{"type":"user","cwd":"/Users/demo/api","timestamp":"\#(isoNow)","message":{"role":"user","content":"corre os testes"}}"#,
            #"{"type":"assistant","cwd":"/Users/demo/api","timestamp":"\#(isoNow)","message":{"model":"claude-opus-5-5","content":[{"type":"tool_use","name":"Bash","input":{"command":"npm test","description":"Run the test suite"}}]}}"#,
        ]))
        #expect(info.state == .runningTool("Bash"))
        #expect(info.detail == "Run the test suite")
        #expect(info.cwd == "/Users/demo/api")
        #expect(info.model == "claude-opus-5-5")
    }

    @Test func endTurnMeansWaitingForUser() {
        let info = reader.parseTail(lines([
            #"{"type":"assistant","cwd":"/x","timestamp":"\#(isoNow)","message":{"model":"claude-opus-5-5","stop_reason":"end_turn","content":[{"type":"text","text":"Feito.\nTodos os testes passam."}]}}"#,
        ]))
        #expect(info.state == .waitingUser)
        #expect(info.detail == "Feito. Todos os testes passam.")
    }

    @Test func toolResultMeansThinking() {
        let info = reader.parseTail(lines([
            #"{"type":"assistant","cwd":"/x","message":{"model":"m","content":[{"type":"tool_use","name":"Read","input":{"file_path":"/x/a.swift"}}]}}"#,
            #"{"type":"user","cwd":"/x","message":{"role":"user","content":[{"type":"tool_result","content":"..."}]}}"#,
        ]))
        #expect(info.state == .thinking)
        #expect(info.detail == "A analisar o resultado")
    }

    @Test func sidechainLinesDoNotDecideTheState() {
        let info = reader.parseTail(lines([
            #"{"type":"assistant","cwd":"/x","message":{"model":"m","stop_reason":"end_turn","content":[{"type":"text","text":"pronto"}]}}"#,
            #"{"type":"assistant","isSidechain":true,"cwd":"/x","message":{"model":"m","content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}"#,
        ]))
        #expect(info.state == .waitingUser)
    }

    @Test func malformedLinesAreSkipped() {
        let info = reader.parseTail(lines([
            #"{"type":"assistant","cwd":"/x","message":{"model":"m","stop_reason":"end_turn","content":[{"type":"text","text":"ok"}]}}"#,
            #"{"truncated": "#,
        ]))
        #expect(info.state == .waitingUser)
    }
}

// MARK: - "Precisa de aprovação"

@Suite("Deteção de aprovação")
struct ApprovalTests {
    private func process(shells: Int) -> AgentProcess {
        AgentProcess(pid: 1, kind: "Claude Code", cpu: 0, memKB: 0, elapsed: "00:01", cwd: "/x",
                     children: [], isSubagent: false, shellChildren: shells)
    }
    private func ago(_ s: TimeInterval) -> Date { Date().addingTimeInterval(-s) }

    @Test func bashWithoutShellAfterThreeSecondsNeedsApproval() {
        #expect(AgentReader.approvalState(tool: "Bash", since: ago(10), process: process(shells: 0)) == .needsApproval("Bash"))
    }

    @Test func bashWithShellIsRunning() {
        #expect(AgentReader.approvalState(tool: "Bash", since: ago(10), process: process(shells: 1)) == nil)
    }

    @Test func bashJustStartedIsNotYetApproval() {
        #expect(AgentReader.approvalState(tool: "Bash", since: ago(1), process: process(shells: 0)) == nil)
    }

    @Test(arguments: ["Edit", "Write", "MultiEdit", "NotebookEdit"])
    func instantToolsPendingTooLongNeedApproval(_ tool: String) {
        #expect(AgentReader.approvalState(tool: tool, since: ago(6), process: process(shells: 0)) == .needsApproval(tool))
        #expect(AgentReader.approvalState(tool: tool, since: ago(2), process: process(shells: 0)) == nil)
    }

    @Test(arguments: ["AskUserQuestion", "ExitPlanMode"])
    func questionsNeedAnAnswer(_ tool: String) {
        #expect(AgentReader.approvalState(tool: tool, since: ago(0), process: process(shells: 0)) == .needsAnswer)
    }

    @Test(arguments: ["Read", "Grep", "WebFetch", "Agent"])
    func otherToolsAreNeverFlagged(_ tool: String) {
        #expect(AgentReader.approvalState(tool: tool, since: ago(60), process: process(shells: 0)) == nil)
    }
}

// MARK: - Codex

@Suite("Rollouts do Codex")
struct CodexRolloutTests {
    let reader = CodexReader()

    @Test func taskCompleteIsWaitingWithLastMessage() {
        let info = reader.parseTail(lines([
            #"{"timestamp":"\#(isoNow)","type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"timestamp":"\#(isoNow)","type":"event_msg","payload":{"type":"task_complete","last_agent_message":"O servidor foi reiniciado."}}"#,
        ]))
        #expect(info.state == .waitingUser)
        #expect(info.detail == "O servidor foi reiniciado.")
    }

    @Test func execCustomToolCallShowsTheCommand() {
        let call = #"{"timestamp":"\#(isoNow)","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"text(await tools.exec_command({cmd:\"ssh nas@host 'uptime'\"}))"}}"#
        let info = reader.parseTail(lines([call]))
        #expect(info.state == .runningTool("Bash"))
        #expect(info.detail == "ssh nas@host 'uptime'")
    }

    @Test func toolOutputMeansThinking() {
        let info = reader.parseTail(lines([
            #"{"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"cmd\":\"ls\"}"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call_output","output":"a b c"}}"#,
        ]))
        #expect(info.state == .thinking)
    }

    @Test func abortedTurnWaitsForUser() {
        let info = reader.parseTail(lines([#"{"type":"event_msg","payload":{"type":"turn_aborted","reason":"interrupted"}}"#]))
        #expect(info.state == .waitingUser)
        #expect(info.detail == "Interrompido")
    }

    @Test func tokenCountLinesAreIgnoredForState() {
        let info = reader.parseTail(lines([
            #"{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"fim"}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","info":{}}}"#,
        ]))
        #expect(info.state == .waitingUser)
    }

    @Test(arguments: [
        ("shell", #"{"cmd":"ls -la"}"#, "Bash", "ls -la"),
        ("exec_command", #"{"command":["git","status"]}"#, "Bash", "git status"),
        ("apply_patch", #"{"input":"*** Begin Patch"}"#, "Edit", nil),
    ] as [(String, String, String, String?)])
    func describeTool(_ name: String, _ input: String, _ tool: String, _ detail: String?) {
        let (t, d) = CodexReader.describeTool(name: name, input: input)
        #expect(t == tool)
        #expect(d == detail)
    }

    @Test func titlePrefersThreadName() {
        #expect(CodexReader.cleanTitle(name: "Configurar NAS", title: "## Referenced…", first: nil) == "Configurar NAS")
    }

    @Test func titleSkipsReferencedConversationPreamble() {
        let raw = "## Referenced ChatGPT conversation:\n{...}\n## My request:\nContinuing from [Rede](chatgpt-conversation://abc): Melhorar a pesquisa\nmais contexto"
        #expect(CodexReader.cleanTitle(name: nil, title: raw, first: nil) == "Melhorar a pesquisa")
    }
}

// MARK: - Tokens

@Suite("Contagem de tokens")
struct UsageTests {
    private func tempFile(_ content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agentstats-\(UUID().uuidString).jsonl")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func claudeRepeatedMessageIsCountedOnce() throws {
        // O Claude Code escreve uma linha por bloco de conteúdo, repetindo o mesmo id e o mesmo usage.
        let usage = #""usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":100,"cache_creation_input_tokens":20}"#
        let line1 = #"{"type":"assistant","timestamp":"\#(isoNow)","message":{"id":"msg_1",\#(usage),"content":[]}}"#
        let line2 = #"{"type":"assistant","timestamp":"\#(isoNow)","message":{"id":"msg_1",\#(usage),"content":[]}}"#
        let url = try tempFile(line1 + "\n" + line2 + "\n")
        defer { try? FileManager.default.removeItem(at: url) }

        let u = UsageTracker().usage(ofFile: url.path, codex: false).session
        #expect(u == TokenUsage(input: 10, output: 5, cacheRead: 100, cacheWrite: 20))
        #expect(u.total == 135)
    }

    @Test func readsOnlyNewBytesAndWaitsForCompleteLines() throws {
        let msg = { (id: String) in #"{"type":"assistant","timestamp":"\#(isoNow)","message":{"id":"\#(id)","usage":{"input_tokens":1,"output_tokens":1}}}"# }
        let url = try tempFile(msg("a") + "\n" + msg("b"))   // a última linha ainda não terminou
        defer { try? FileManager.default.removeItem(at: url) }
        let tracker = UsageTracker()

        #expect(tracker.usage(ofFile: url.path, codex: false).session.total == 2)   // só "a"

        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data(("\n" + msg("c") + "\n").utf8))
        try h.close()

        #expect(tracker.usage(ofFile: url.path, codex: false).session.total == 6)   // a + b + c
    }

    @Test func codexUsesLastTokenUsageAndSplitsCache() throws {
        let line = #"{"timestamp":"\#(isoNow)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":800,"output_tokens":50}}}}"#
        let url = try tempFile(line + "\n")
        defer { try? FileManager.default.removeItem(at: url) }

        let u = UsageTracker().usage(ofFile: url.path, codex: true).session
        #expect(u == TokenUsage(input: 200, output: 50, cacheRead: 800, cacheWrite: 0))
    }
}

// MARK: - Utilitários

@Test func uniquedKeepsFirstOccurrenceOrder() {
    #expect(["zsh", "node", "zsh", "git", "node"].uniqued() == ["zsh", "node", "git"])
}

// MARK: - Hook de notificações do Claude Code

@Suite("Hook de notificações")
struct HookTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("agentstats-hook-\(UUID().uuidString)")
    }
    private func process() -> AgentProcess {
        AgentProcess(pid: 1, kind: "Claude Code", cpu: 0, memKB: 0, elapsed: "00:01", cwd: "/x",
                     children: [], isSubagent: false, shellChildren: 0)
    }

    @Test(arguments: [
        ("permission_prompt", "Claude needs your permission to use Bash", HookEvent.Kind.permission),
        (nil, "Claude needs your permission to use Edit", .permission),
        ("idle_prompt", "Claude is waiting for your input", .idle),
        ("auth_success", "Login concluído", .other),
    ] as [(String?, String, HookEvent.Kind)])
    func classifiesNotifications(_ type: String?, _ message: String, _ expected: HookEvent.Kind) {
        #expect(HookEvents.kind(type: type, message: message) == expected)
    }

    @Test func recordsAndReadsBackTheLatestEvent() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = #"{"session_id":"abc-123","hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}"#
        HookEvents.record(stdin: Data(json.utf8), now: Date(timeIntervalSince1970: 1000), in: dir)
        let e = try #require(HookEvents.latest(session: "abc-123", in: dir))
        #expect(e.kind == .permission)
        #expect(e.date == Date(timeIntervalSince1970: 1000))
    }

    @Test func ignoresInvalidInputAndUnsafeSessionIDs() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        HookEvents.record(stdin: Data("não é json".utf8), in: dir)
        HookEvents.record(stdin: Data(#"{"session_id":"../../etc/x","message":"m"}"#.utf8), in: dir)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func permissionEventAfterTheToolCallMeansApproval() {
        let since = Date(timeIntervalSince1970: 1000)
        let hook = HookEvent(kind: .permission, message: "", date: since.addingTimeInterval(1))
        #expect(AgentReader.approvalState(tool: "Bash", since: since, process: process(), hook: hook, hookActive: true) == .needsApproval("Bash"))
    }

    @Test func oldPermissionEventIsIgnored() {
        // aviso de um pedido anterior, já aprovado: o transcript avançou para outro pedido
        let since = Date(timeIntervalSince1970: 1000)
        let hook = HookEvent(kind: .permission, message: "", date: since.addingTimeInterval(-30))
        #expect(AgentReader.approvalState(tool: "Bash", since: since, process: process(), hook: hook, hookActive: true) == nil)
    }

    @Test func withHookActiveTheHeuristicIsNotUsed() {
        // sem aviso do hook, um Bash pendente há muito tempo sem shell já não é "aprovação"
        let since = Date().addingTimeInterval(-60)
        #expect(AgentReader.approvalState(tool: "Bash", since: since, process: process(), hook: nil, hookActive: true) == nil)
        #expect(AgentReader.approvalState(tool: "Bash", since: since, process: process(), hook: nil, hookActive: false) == .needsApproval("Bash"))
    }

    @Test func questionsNeedAnAnswerEvenWithHook() {
        #expect(AgentReader.approvalState(tool: "AskUserQuestion", since: Date(), process: process(), hook: nil, hookActive: true) == .needsAnswer)
    }
}

// MARK: - Histórico de 24 h

@Suite("Histórico de 24 h")
struct HistoryTests {
    private func at(_ minute: Double, _ second: Double = 0) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + minute * 60 + second) }

    @Test func accumulatorClosesAMinuteWithAveragesAndMaxima() throws {
        var acc = MinuteAccumulator()
        #expect(acc.add(cpu: 0.2, mem: 0.5, temp: 40, working: 0, attention: false, at: at(0, 1)) == nil)
        #expect(acc.add(cpu: 0.4, mem: 0.7, temp: 50, working: 2, attention: true, at: at(0, 30)) == nil)
        let closed = acc.add(cpu: 0.9, mem: 0.9, temp: 70, working: 0, attention: false, at: at(1, 2))
        let done = try #require(closed)
        #expect(abs(done.cpu - 0.3) < 1e-9)
        #expect(abs(done.mem - 0.6) < 1e-9)
        #expect(done.temp == 50)
        #expect(done.working == 2)
        #expect(done.attention)
        #expect(done.t == at(0).timeIntervalSince1970)
    }

    @Test func pruneKeepsOnlyTheLast7Days() {
        // o histórico guarda 7 dias (10 080 minutos); a faixa de atividade continua a mostrar 24 h
        let now = at(20_000)
        let samples = [12_000.0, 10_081, 10_079, 1439].map {
            MinuteSample(t: now.timeIntervalSince1970 - $0 * 60, cpu: 0, mem: 0, temp: nil, working: 0, attention: false)
        }
        #expect(History24h.pruned(samples, now: now).count == 2)
    }

    @Test func activeMinutesOnlyCountTheLast24Hours() {
        let now = at(20_000)
        let samples = [3000.0, 100, 10].map {
            MinuteSample(t: now.timeIntervalSince1970 - $0 * 60, cpu: 0, mem: 0, temp: nil, working: 1, attention: false)
        }
        #expect(History24h.activeMinutes(samples, now: now) == 2)
    }

    @Test func savesAndLoadsFromDisk() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agentstats-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date()
        let s = MinuteSample(t: now.timeIntervalSince1970 - 120, cpu: 0.25, mem: 0.5, temp: 44, working: 1, attention: false)
        History24h.save([s], to: url)
        #expect(History24h.load(from: url, now: now) == [s])
    }

    @Test func bucketsCoverTheDayAndCountActiveMinutes() {
        let now = at(10_000)
        let base = (now.timeIntervalSince1970 / 600).rounded(.down) * 600   // início do bloco atual
        let samples = (0..<10).map {
            MinuteSample(t: base + Double($0) * 60, cpu: 0, mem: 0, temp: nil, working: $0 < 5 ? 1 : 0, attention: $0 == 3)
        }
        let b = History24h.buckets(samples, now: now)
        #expect(b.count == 144)
        #expect(abs(b.last!.working - 0.5) < 1e-9)
        #expect(b.last!.attention)
        #expect(History24h.activeMinutes(samples) == 5)
    }
}

// MARK: - Tokens por projeto e por semana

@Suite("Tokens por projeto")
struct ProjectUsageTests {
    private func tempFile(_ content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agentstats-\(UUID().uuidString).jsonl")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func claudeProjectComesFromTheWorkingFolder() throws {
        let line = #"{"type":"assistant","cwd":"/Users/demo/Projetos/loja-online","timestamp":"\#(isoNow)","message":{"id":"m1","usage":{"input_tokens":1,"output_tokens":2}}}"#
        let url = try tempFile(line + "\n")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(UsageTracker().usage(ofFile: url.path, codex: false).project == "loja-online")
    }

    @Test func codexProjectComesFromSessionMeta() throws {
        let meta = #"{"timestamp":"\#(isoNow)","type":"session_meta","payload":{"cwd":"/Users/demo/nas-config","id":"x"}}"#
        let tokens = #"{"timestamp":"\#(isoNow)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5}}}}"#
        let url = try tempFile(meta + "\n" + tokens + "\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let r = UsageTracker().usage(ofFile: url.path, codex: true)
        #expect(r.project == "nas-config")
        #expect(r.session.total == 15)
    }

    @Test(arguments: [("2026-11-15", "dom"), ("2026-11-19", "qui"), ("2026-11-21", "sáb")])
    func weekdayAbbreviations(_ day: String, _ expected: String) {
        #expect(TodayUsage.weekday(day) == expected)
    }

    @MainActor @Test func hotkeyPresetsHaveUniqueKeysAndLabels() {
        let keys = GlobalHotKey.presets.map(\.key), labels = GlobalHotKey.presets.map(\.combo.label)
        #expect(Set(keys).count == keys.count)
        #expect(Set(labels).count == labels.count)
        #expect(keys.contains(GlobalHotKey.defaultPreset))
    }
}

// MARK: - Deteção de processos de agentes

@Suite("Deteção de processos de agentes")
struct AgentProcessDetectionTests {
    private func proc(name: String, args: String) -> ProcSample {
        ProcSample(pid: 1234, ppid: 1, cpu: 5.0, rssKB: 50_000, elapsed: "01:23", name: name, args: args)
    }

    @Test func directGeminiBinary() {
        #expect(AgentReader.agentKind(proc(name: "gemini", args: "gemini")) == "Gemini CLI")
        #expect(AgentReader.agentKind(proc(name: "gemini-cli", args: "gemini-cli")) == "Gemini CLI")
    }

    @Test func nodeRunningGlobalGemini() {
        #expect(AgentReader.agentKind(proc(name: "node", args: "node /opt/homebrew/bin/gemini")) == "Gemini CLI")
        #expect(AgentReader.agentKind(proc(name: "node", args: "node /usr/local/bin/gemini-cli")) == "Gemini CLI")
        #expect(AgentReader.agentKind(proc(name: "node", args: "node /Users/demo/.nvm/versions/node/v20.0.0/bin/gemini --prompt hello")) == "Gemini CLI")
        #expect(AgentReader.agentKind(proc(name: "node", args: "node /path/to/gemini.js")) == "Gemini CLI")
    }

    @Test func nodeRunningNpmScopedPackage() {
        #expect(AgentReader.agentKind(proc(name: "node", args: "node /Users/demo/.npm/_npx/abc/node_modules/@google/gemini-cli/dist/index.js")) == "Gemini CLI")
    }

    @Test func pythonRunningGemini() {
        #expect(AgentReader.agentKind(proc(name: "python3", args: "python3 /usr/local/bin/gemini")) == "Gemini CLI")
        #expect(AgentReader.agentKind(proc(name: "python", args: "python -u /usr/local/bin/gemini-cli")) == "Gemini CLI")
    }

    @Test func antigravityAgent() {
        #expect(AgentReader.agentKind(proc(name: "agy", args: "agy")) == "Antigravity")
        #expect(AgentReader.agentKind(proc(name: "antigravity", args: "antigravity")) == "Antigravity")
        #expect(AgentReader.agentKind(proc(name: "node", args: "node /opt/homebrew/bin/agy")) == "Antigravity")
    }

    @Test func arbitraryNodeScriptDoesNotFalsePositive() {
        #expect(AgentReader.agentKind(proc(name: "node", args: "node server.js --model gemini")) == nil)
        #expect(AgentReader.agentKind(proc(name: "node", args: "node index.js")) == nil)
        #expect(AgentReader.agentKind(proc(name: "python3", args: "python3 train.py --api gemini")) == nil)
    }
}

// MARK: - Antigravity

@Suite("Transcripts do Antigravity")
struct AntigravityTranscriptTests {
    let reader = AntigravityReader()

    @Test func toolCallStepIsRunningTool() {
        let line = #"{"step_index":10,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"\#(isoNow)","tool_calls":[{"name":"run_command","args":{"toolSummary":"Inspect project files","CommandLine":"ls -la"}}]}"#
        let info = reader.parseTail(lines([line]))
        #expect(info.state == .runningTool("Bash"))
        #expect(info.detail == "Inspect project files")
    }

    @Test func genericOutputMeansThinking() {
        let line = #"{"step_index":11,"source":"MODEL","type":"GENERIC","status":"DONE","created_at":"\#(isoNow)","content":"Command exited with code 0"}"#
        let info = reader.parseTail(lines([line]))
        #expect(info.state == .thinking)
        #expect(info.detail == "A analisar o resultado")
    }

    @Test func userContentWithoutToolCallsWaitsForUser() {
        let line = #"{"step_index":12,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"\#(isoNow)","content":"Pronto, tudo configurado."}"#
        let info = reader.parseTail(lines([line]))
        #expect(info.state == .waitingUser)
        #expect(info.detail == "Pronto, tudo configurado.")
    }

    @Test func extractsModelSelection() {
        let line = #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"\#(isoNow)","content":"<USER_SETTINGS_CHANGE>\nThe user changed setting `Model Selection` from None to Gemini 3.8 Flash (High).\n</USER_SETTINGS_CHANGE>"}"#
        let info = reader.parseTail(lines([line]))
        #expect(info.model == "Gemini 3.8 Flash (High)")
    }

    @Test func parseCwdFromJsonArray() {
        let raw = #"["file:///Users/demo/Documents/AgentStats"]"#
        #expect(reader.parseCwd(raw) == "/Users/demo/Documents/AgentStats")
    }
}

// MARK: - Outras IAs

@Suite("Leitura de outras IAs")
struct OtherAIsTests {
    let reader = OtherAIsReader()

    @Test func parseAiderHistory() {
        let lines = [
            "# aider chat started at 2026-11-20 12:00:00",
            "",
            "#### Corrigir bug no parser de markdown",
            "",
            "> O ficheiro Parser.swift foi atualizado com a correção pedida.",
        ]
        let info = reader.parseAiderLines(lines)
        #expect(info.title == "Corrigir bug no parser de markdown")
        #expect(info.detail == "O ficheiro Parser.swift foi atualizado com a correção pedida.")
    }

    @Test func activeAgentProcessWithChildrenBecomesRunningToolSession() {
        let p = AgentProcess(pid: 999, kind: "Aider", cpu: 12.5, memKB: 80_000, elapsed: "02:10",
                             cwd: "/Users/demo/app", children: ["pytest", "git"], isSubagent: false)
        let sessions = reader.sessions(processes: [p], existingSessions: [])
        #expect(sessions.count == 1)
        let s = sessions[0]
        #expect(s.kind == "Aider")
        #expect(s.state == .runningTool("pytest"))
        #expect(s.detail == "pytest, git")
        #expect(s.project == "app")
        #expect(s.process?.pid == 999)
    }

    @Test func idleAgentProcessBecomesWaitingUserSession() {
        let p = AgentProcess(pid: 888, kind: "Cursor Agent", cpu: 0.1, memKB: 100_000, elapsed: "10:00",
                             cwd: "/Users/demo/frontend", children: [], isSubagent: false)
        let sessions = reader.sessions(processes: [p], existingSessions: [])
        #expect(sessions.count == 1)
        let s = sessions[0]
        #expect(s.kind == "Cursor Agent")
        #expect(s.state == .waitingUser)
        #expect(s.project == "frontend")
    }

    @Test func alreadyLinkedProcessIsSkipped() {
        let p = AgentProcess(pid: 777, kind: "Claude Code", cpu: 5.0, memKB: 50_000, elapsed: "01:00",
                             cwd: "/x", children: [], isSubagent: false)
        let existing = AgentSession(id: "s1", kind: "Claude Code", title: "Existente", cwd: "/x",
                                    model: nil, state: .thinking, detail: nil, lastActivity: Date(),
                                    subagents: 0, process: p)
        let sessions = reader.sessions(processes: [p], existingSessions: [existing])
        #expect(sessions.isEmpty)
    }
}

// MARK: - Correções da revisão

@Suite("Histórico de 7 dias")
struct SevenDayHistoryTests {
    private func at(_ minute: Double, _ second: Double = 0) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + minute * 60 + second) }

    @Test func batteryIsAveragedPerMinuteAndOptional() throws {
        var acc = MinuteAccumulator()
        _ = acc.add(cpu: 0.1, mem: 0.5, temp: nil, battery: 0.8, working: 0, attention: false, at: at(0, 1))
        _ = acc.add(cpu: 0.1, mem: 0.5, temp: nil, battery: 0.6, working: 0, attention: false, at: at(0, 20))
        let closed = acc.add(cpu: 0.1, mem: 0.5, temp: nil, working: 0, attention: false, at: at(1, 1))
        let done = try #require(closed)
        #expect(abs((done.battery ?? -1) - 0.7) < 1e-9)
    }

    @Test func weekOfMinutesIsDrawnAsHourlyAverages() {
        let week = (0..<10_080).map { Double($0 / 60) }   // valor constante dentro de cada hora
        let drawn = DayChart.downsampled(week)
        #expect(drawn.count == 168)
        #expect(drawn.first == 0 && drawn.last == 167)
    }

    @Test func shortHistoryIsDrawnAsIs() {
        let day = (0..<1440).map(Double.init)
        #expect(DayChart.downsampled(day) == day)
    }
}

@Suite struct PlanLimitsTests {
    private func json(_ s: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
    }

    @Test func codexRateLimitsBecomeWindows() throws {
        let l = try #require(PlanLimitsParser.codex(json("""
        {"primary":{"used_percent":40.0,"window_minutes":43200,"resets_at":1798000000},
         "secondary":{"used_percent":12,"window_minutes":10080,"resets_at":1797000000},"plan_type":"free"}
        """), observed: Date(timeIntervalSince1970: 1_796_000_000)))
        #expect(l.provider == .codex)
        #expect(l.plan == "Grátis")
        #expect(l.windows.map(\.label) == ["30 dias", "Semana"])
        #expect(l.windows[0].usedPercent == 40)
        #expect(l.windows[0].resetsAt == Date(timeIntervalSince1970: 1798000000))
    }

    @Test func codexOldFormatResetsRelativeToTheLine() throws {
        let t = Date(timeIntervalSince1970: 1_000_000)
        let l = try #require(PlanLimitsParser.codex(json("""
        {"primary":{"used_percent":40,"window_minutes":300,"resets_in_seconds":600},"secondary":null}
        """), observed: t))
        #expect(l.windows.count == 1)
        #expect(l.windows[0].label == "5 horas")
        #expect(l.windows[0].resetsAt == t.addingTimeInterval(600))
    }

    @Test func claudeUsageResponse() throws {
        let l = try #require(PlanLimitsParser.claudeUsage(json("""
        {"subscription_type":"max","rate_limits_available":true,"rate_limits":{
          "five_hour":{"utilization":45.5,"resets_at":"2026-11-22T14:30:00.000Z"},
          "seven_day":{"utilization":20,"resets_at":"2026-11-27T09:00:00Z"},
          "seven_day_opus":null}}
        """), observed: Date()))
        #expect(l.plan == "Max")
        #expect(l.windows.map(\.id) == ["claude.five_hour", "claude.seven_day"])
        #expect(l.windows[0].usedPercent == 45.5)
        #expect(l.windows[0].resetsAt != nil && l.windows[1].resetsAt != nil)
    }

    @Test func signedOutClaudeHasNoLimits() {
        let out = Data("""
        {"type":"control_response","response":{"subtype":"success","request_id":"i","response":{}}}
        {"type":"control_response","response":{"subtype":"success","request_id":"u","response":{"subscription_type":null,"rate_limits_available":false,"rate_limits":null}}}

        """.utf8)
        #expect(ClaudeLimitsFetcher.parse(out, observed: Date()) == .signedOut)
        #expect(ClaudeLimitsFetcher.parse(Data(), observed: Date()) == .failed)
    }

    @Test func claudeDesktopHistoryUsesTheLastReadingWithValues() throws {
        let data = Data("""
        {"version":2,"samples":[{"t":1700000000000,"u":{"fh":10,"sd":5}},{"t":1700003600500,"u":{"fh":60,"sd":25}},{"t":1700007200000,"u":{}}]}
        """.utf8)
        let l = try #require(PlanLimitsParser.claudeDesktopHistory(data))
        #expect(l.windows.map(\.usedPercent) == [60, 25])
        #expect(l.observedAt == Date(timeIntervalSince1970: 1700003600.5))
    }

    @Test func renewedWindowsAreDropped() {
        let now = Date()
        let l = PlanLimits(provider: .codex, plan: nil, windows: [
            LimitWindow(id: "a", label: "5 horas", usedPercent: 90, resetsAt: now.addingTimeInterval(-60)),
            LimitWindow(id: "b", label: "Semana", usedPercent: 30, resetsAt: now.addingTimeInterval(3600)),
        ], observedAt: now.addingTimeInterval(-600))
        #expect(l.current(now: now)?.windows.map(\.id) == ["b"])
        #expect(PlanLimits(provider: .claude, plan: nil, windows: [l.windows[0]], observedAt: now).current(now: now) == nil)
    }

    @Test func resetTextIsShortAndRelative() {
        let cal = Calendar.current
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 10))!
        #expect(PlanLimitsCard.resetText(cal.date(byAdding: .hour, value: 4, to: now)!, now: now) == "às 14:00")
        #expect(PlanLimitsCard.resetText(cal.date(byAdding: .hour, value: 24, to: now)!, now: now) == "amanhã às 10:00")
        #expect(PlanLimitsCard.resetText(cal.date(byAdding: .day, value: 10, to: now)!, now: now) == "2 dez")
    }

    @Test func trackerKeepsTheLatestCodexLimits() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("limits-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let text = """
        {"timestamp":"2026-11-20T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":10,"window_minutes":300,"resets_at":1797000000}}}}
        {"timestamp":"2026-11-20T11:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":55,"window_minutes":300,"resets_at":1797000000}}}}

        """
        try text.write(to: url, atomically: true, encoding: .utf8)
        let l = try #require(UsageTracker().limits(ofFile: url.path))
        #expect(l.windows.first?.usedPercent == 55)
    }
}

@Suite struct PricingTests {
    @Test func modelNamesResolveToTheirPrice() {
        #expect(Pricing.price(for: "claude-opus-5-5")?.input == 4)
        #expect(Pricing.price(for: "claude-opus-5")?.input == 5)
        #expect(Pricing.price(for: "us.anthropic.claude-sonnet-5-5-20261001")?.output == 10)
        #expect(Pricing.price(for: "claude-opus-4-20250514")?.input == 15)
        #expect(Pricing.price(for: "claude-opus-4-7")?.input == 5)
        #expect(Pricing.price(for: "gpt-6.1-sol")?.cacheRead == 0.1)
        #expect(Pricing.price(for: "gpt-6.2-sol") == Pricing.price(for: "gpt-6.1-sol"))   // versão nova: usa a família
        #expect(Pricing.price(for: "<synthetic>") == nil)
        #expect(Pricing.price(for: "llama-3") == nil)
        #expect(Pricing.price(for: nil) == nil)
    }

    @Test func costPerMillionTokens() {
        let u = TokenUsage(input: 1_000_000, output: 100_000, cacheRead: 2_000_000, cacheWrite: 0)
        // opus 5.5: 4 + 0.1×20 + 2×0.2 = 6.4
        #expect(abs((Pricing.cost(u, model: "claude-opus-5-5") ?? 0) - 6.4) < 1e-9)
    }

    @Test func usdFormatting() {
        #expect(Fmt.usd(0.004) == "<$0,01")
        #expect(Fmt.usd(0.42) == "$0,42")
        #expect(Fmt.usd(12.4) == "$12,40")
        #expect(Fmt.usd(250) == "$250")
    }

    @Test func trackerAddsCostFromEachModel() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cost-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let text = """
        {"timestamp":"2026-11-20T10:00:00.000Z","type":"turn_context","payload":{"cwd":"/x","model":"gpt-6.1-sol"}}
        {"timestamp":"2026-11-20T10:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000000,"cached_input_tokens":0,"output_tokens":0}}}}
        {"timestamp":"2026-11-20T10:01:00.000Z","type":"turn_context","payload":{"cwd":"/x","model":"gpt-6-luna"}}
        {"timestamp":"2026-11-20T10:01:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000000,"cached_input_tokens":0,"output_tokens":0}}}}

        """
        try text.write(to: url, atomically: true, encoding: .utf8)
        // 1M a $2 (sol) + 1M a $0,10 (luna)
        let c = try #require(UsageTracker().cost(ofFile: url.path, codex: true))
        #expect(abs(c - 2.1) < 1e-9)
    }
}

@Suite("Transcripts do Claude Code: casos especiais")
struct ClaudeTranscriptEdgeTests {
    let reader = AgentReader()
    private let base = #"{"type":"assistant","cwd":"/x","message":{"model":"claude-opus-5-5","content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}"#

    @Test func hittingTheLimitStopsWork() {
        let info = reader.parseTail(lines([base,
            #"{"type":"assistant","cwd":"/x","isApiErrorMessage":true,"error":"rate_limit","message":{"model":"<synthetic>","stop_reason":"stop_sequence","content":[{"type":"text","text":"You've hit your 5-hour limit · resets 3:00pm (UTC)"}]}}"#,
        ]))
        #expect(info.state == .waitingUser)
        #expect(info.detail == "Limite de 5 horas atingido · renova 3:00pm")
        #expect(info.model == "claude-opus-5-5")   // o "<synthetic>" não substitui o modelo real
    }

    @Test func weeklyLimitText() {
        #expect(AgentReader.limitText("You've hit your weekly limit · resets Jan 2 at 8am (UTC)")
                == "Limite semanal atingido · renova Jan 2 at 8am")
    }

    @Test func interruptionMeansWaiting() {
        let info = reader.parseTail(lines([base,
            #"{"type":"user","cwd":"/x","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#,
        ]))
        #expect(info.state == .waitingUser)
        #expect(info.detail == "Interrompido por ti")
    }

    @Test func localCommandOutputIsNotWork() {
        let info = reader.parseTail(lines([
            #"{"type":"assistant","cwd":"/x","message":{"model":"m","stop_reason":"end_turn","content":[{"type":"text","text":"ok"}]}}"#,
            #"{"type":"user","cwd":"/x","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>Caveat</local-command-caveat>"}}"#,
            #"{"type":"user","cwd":"/x","message":{"role":"user","content":"<command-name>/model</command-name>"}}"#,
            #"{"type":"user","cwd":"/x","message":{"role":"user","content":"<local-command-stdout>Set model to Opus</local-command-stdout>"}}"#,
        ]))
        #expect(info.state == .waitingUser)
    }

    @Test func customSlashCommandStartsWork() {
        let info = reader.parseTail(lines([
            #"{"type":"user","cwd":"/x","message":{"role":"user","content":"<command-message>review</command-message>\n<command-name>/review</command-name>"}}"#,
            #"{"type":"user","cwd":"/x","isMeta":true,"message":{"role":"user","content":[{"type":"text","text":"Review the diff..."}]}}"#,
        ]))
        #expect(info.state == .thinking)
    }

    @Test func subagentToolIsNamed() {
        let info = reader.parseTail(lines([
            #"{"type":"assistant","cwd":"/x","message":{"model":"m","content":[{"type":"tool_use","name":"Agent","input":{"description":"Find callers"}}]}}"#,
            #"{"type":"assistant","cwd":"/x","isSidechain":true,"message":{"model":"m","stop_reason":"end_turn","content":[{"type":"text","text":"sub done"}]}}"#,
        ]))
        #expect(info.state == .runningTool("subagente"))
        #expect(info.detail == "Find callers")
    }

    @Test func projectFollowsTheLatestFolder() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("moved-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let text = """
        {"type":"assistant","cwd":"/tmp/scratch","timestamp":"2026-11-20T10:00:00.000Z","message":{"id":"a","model":"m","usage":{"input_tokens":1,"output_tokens":1}}}
        {"type":"assistant","cwd":"/Users/me/AgentStats","timestamp":"2026-11-20T11:00:00.000Z","message":{"id":"b","model":"m","usage":{"input_tokens":1,"output_tokens":1}}}

        """
        try text.write(to: url, atomically: true, encoding: .utf8)
        #expect(UsageTracker().usage(ofFile: url.path, codex: false).project == "AgentStats")
    }
}

@Suite struct MoreAgentsTests {
    private func events(_ s: String) -> [[String: Any]] {
        s.split(separator: "\n").compactMap { TextTail.json(Data($0.utf8)) }
    }
    private let now = Date()
    private var ts: String { ISO8601DateFormatter().string(from: now.addingTimeInterval(-60)) }

    @Test func copilotPendingPermissionNeedsApproval() {
        let t = CopilotReader.parse(events("""
        {"type":"session.start","data":{"context":{"cwd":"/Users/me/app"}},"timestamp":"\(ts)"}
        {"type":"assistant.turn_start","data":{"turnId":"0"},"timestamp":"\(ts)"}
        {"type":"tool.execution_start","data":{"toolCallId":"c1","toolName":"bash","arguments":{"command":"npm test"},"model":"gpt-6-luna"},"timestamp":"\(ts)"}
        {"type":"permission.requested","data":{"requestId":"r1","permissionRequest":{"kind":"shell","toolTitle":"bash","args":{"command":"npm test"}}},"timestamp":"\(ts)"}
        """), now: now)
        #expect(t.state == .needsApproval("bash"))
        #expect(t.detail == "npm test")
        #expect(t.model == "gpt-6-luna")
    }

    @Test func copilotApprovedToolIsRunningAndTurnEndIsWaiting() {
        let running = CopilotReader.parse(events("""
        {"type":"tool.execution_start","data":{"toolCallId":"c1","toolName":"bash","arguments":{"command":"ls"}},"timestamp":"\(ts)"}
        {"type":"permission.requested","data":{"requestId":"r1","permissionRequest":{"toolTitle":"bash"}},"timestamp":"\(ts)"}
        {"type":"permission.completed","data":{"requestId":"r1","result":{"kind":"approved"}},"timestamp":"\(ts)"}
        """), now: now)
        #expect(running.state == .runningTool("bash"))

        let done = CopilotReader.parse(events("""
        {"type":"assistant.message","data":{"content":"Exemplo concluído.","model":"gpt-6-luna"},"timestamp":"\(ts)"}
        {"type":"assistant.turn_end","data":{"turnId":"0"},"timestamp":"\(ts)"}
        """), now: now)
        #expect(done.state == .waitingUser)
        #expect(done.detail == "Exemplo concluído.")

        let shut = CopilotReader.parse(events(#"{"type":"session.shutdown","data":{},"timestamp":"\#(ts)"}"#), now: now)
        #expect(shut.state == .finished)
    }

    @Test func copilotTitleAndTokens() throws {
        let head = CopilotReader.head(events("""
        {"type":"session.start","data":{"context":{"cwd":"/Users/me/app"}}}
        {"type":"user.message","data":{"content":"/explain este exemplo"}}
        """))
        #expect(head.title == "/explain este exemplo")
        #expect(head.cwd == "/Users/me/app")

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("copilot-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try """
        {"type":"session.start","data":{"context":{"cwd":"/Users/me/app"}},"timestamp":"2026-11-20T10:00:00.000Z"}
        {"type":"session.usage_record","data":{"usage":{"model":"gpt-6-luna","inputTokens":1000000,"outputTokens":0,"cacheReadTokens":0,"cacheWriteTokens":0}},"timestamp":"2026-11-20T10:00:01.000Z"}

        """.write(to: url, atomically: true, encoding: .utf8)
        let u = UsageTracker().copilotUsage(ofFile: url.path)
        #expect(u.session.input == 1_000_000)
        #expect(u.project == "app")
        #expect(abs((u.cost ?? 0) - 0.1) < 1e-9)   // gpt-6-luna: $0,10 por milhão de entrada
    }

    @Test func cursorTurns() {
        let lines = events("""
        {"role":"user","message":{"content":[{"type":"text","text":"<user_query>\\nCorrige o login\\n</user_query>"}]}}
        {"role":"assistant","message":{"content":[{"type":"tool_use","name":"Shell","input":{"command":"npm test"}}]}}
        """)
        #expect(CursorReader.title(lines) == "Corrige o login")
        #expect(CursorReader.parse(lines, age: 2).state == .runningTool("Shell"))
        let ended = lines + events(#"{"type":"turn_ended","status":"success"}"#)
        #expect(CursorReader.parse(ended, age: 2).state == .waitingUser)
        let oldStyle = events(#"{"role":"assistant","message":{"content":[{"type":"text","text":"Feito."}]}}"#)
        #expect(CursorReader.parse(oldStyle, age: 5).state == .thinking)
        #expect(CursorReader.parse(oldStyle, age: 120).state == .waitingUser)
    }

    @Test func cursorProjectSlugIsResolvedOnDisk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cur\(UUID().uuidString.prefix(6))")
        let project = root.appendingPathComponent("Documents/meu-projeto")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let slug = project.path.split(separator: "/").joined(separator: "-")
        #expect(CursorReader.decodeProject(slug, home: root.path) == project.resolvingSymlinksInPath().path
                || CursorReader.decodeProject(slug, home: root.path) == project.path)
    }

    @Test func openCodeMessages() throws {
        #expect(OpenCodeReader.parse(["role": "user"]).state == .thinking)
        #expect(OpenCodeReader.parse(["role": "assistant", "time": ["created": 1]]).state == .thinking)
        #expect(OpenCodeReader.parse(["role": "assistant", "time": ["created": 1, "completed": 2], "finish": "stop"]).state == .waitingUser)
        let u = try #require(OpenCodeReader.usage(["role": "assistant", "modelID": "claude-sonnet-5-5",
            "tokens": ["input": 10, "output": 20, "reasoning": 5, "cache": ["read": 100, "write": 7]],
            "time": ["created": 1_795_000_000_000]]))
        #expect(u.usage == TokenUsage(input: 10, output: 25, cacheRead: 100, cacheWrite: 7))
        #expect(u.model == "claude-sonnet-5-5")
    }

    @Test func openCodeDatabaseSessions() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("oc-\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        let ms = Int64(Date().timeIntervalSince1970 * 1000)
        let sql = """
        CREATE TABLE session (id TEXT PRIMARY KEY, title TEXT, directory TEXT, time_created INTEGER, time_updated INTEGER);
        CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);
        INSERT INTO session VALUES ('s1', 'Refatorar API', '/Users/me/api', \(ms - 5000), \(ms - 1000));
        INSERT INTO message VALUES ('m1', 's1', \(ms - 4000), \(ms - 4000), '{"role":"user"}');
        INSERT INTO message VALUES ('m2', 's1', \(ms - 2000), \(ms - 1000), '{"role":"assistant","modelID":"claude-sonnet-5-5","time":{"created":\(ms - 2000)}}');
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let s = OpenCodeReader().sessions(path: path)
        #expect(s.count == 1)
        #expect(s.first?.title == "Refatorar API")
        #expect(s.first?.project == "api")
        #expect(s.first?.state == .thinking)
        #expect(s.first?.model == "claude-sonnet-5-5")
    }
}
