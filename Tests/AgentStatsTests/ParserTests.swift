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
