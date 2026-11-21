import Foundation
import Testing
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
        #expect(ProcessSampler.fixedCString(full) == "ABCD")
    }

    @Test func stopsAtTerminator() {
        let short: (CChar, CChar, CChar, CChar) = (122, 115, 104, 0)   // "zsh\0"
        #expect(ProcessSampler.fixedCString(short) == "zsh")
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

    @Test func pruneKeepsOnlyTheLast24Hours() {
        let now = at(3000)
        let samples = [2000.0, 1500, 1441, 1439].map {
            MinuteSample(t: now.timeIntervalSince1970 - $0 * 60, cpu: 0, mem: 0, temp: nil, working: 0, attention: false)
        }
        #expect(History24h.pruned(samples, now: now).count == 1)
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
