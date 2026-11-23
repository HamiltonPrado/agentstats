import Foundation
import Testing
@testable import AgentStats

@Suite("Contas dos tokens")
struct UsageAccuracyTests {
    private var isoNow: String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    private func tempFile(_ content: String, dir: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let url = dir.appendingPathComponent("agentstats-\(UUID().uuidString).jsonl")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func claudeLine(_ id: String, input: Int = 1, output: Int = 1, extra: String = "") -> String {
        #"{"type":"assistant","timestamp":"\#(isoNow)","message":{"id":"\#(id)","model":"claude-opus-5-5","usage":{"input_tokens":\#(input),"output_tokens":\#(output)\#(extra)}}}"#
    }

    @Test func oneHourCacheWritesCostTwiceTheInput() {
        let price = ModelPrice(input: 4, output: 20, cacheRead: 0.2, cacheWrite: 5)
        let fiveMinutes = TokenUsage(cacheWrite: 1_000_000)
        let oneHour = TokenUsage(cacheWrite: 1_000_000, cacheWrite1h: 1_000_000)
        #expect(price.cost(fiveMinutes) == 5)
        #expect(price.cost(oneHour) == 8)
        // Mistura: 400 mil de 1 h e 600 mil de 5 min.
        #expect(abs(price.cost(TokenUsage(cacheWrite: 1_000_000, cacheWrite1h: 400_000)) - (3 + 3.2)) < 1e-9)
    }

    @Test func claudeReadsTheOneHourSplit() throws {
        let extra = #","cache_creation_input_tokens":300,"cache_creation":{"ephemeral_5m_input_tokens":100,"ephemeral_1h_input_tokens":200}"#
        let url = try tempFile(claudeLine("m1", extra: extra) + "\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let u = UsageTracker().usage(ofFile: url.path, codex: false).session
        #expect(u.cacheWrite == 300)
        #expect(u.cacheWrite1h == 200)
        #expect(u.total == 302)   // a divisão não conta duas vezes no total
    }

    @Test func olderClaudeWithoutSplitCountsAsFiveMinutes() {
        let u = UsageTracker.claudeUsage(["cache_creation_input_tokens": 50])
        #expect(u.cacheWrite == 50 && u.cacheWrite1h == 0)
    }

    @Test func continuedSessionDoesNotCountCopiedMessagesAgain() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentstats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = try tempFile(claudeLine("a", input: 10) + "\n" + claudeLine("b", input: 20) + "\n", dir: dir)
        // A continuação copia "a" e "b" e acrescenta "c".
        let continued = try tempFile(claudeLine("a", input: 10) + "\n" + claudeLine("b", input: 20) + "\n"
                                     + claudeLine("c", input: 40) + "\n", dir: dir)
        let tracker = UsageTracker()
        #expect(tracker.usage(ofFile: original.path, codex: false).session.input == 30)
        #expect(tracker.usage(ofFile: continued.path, codex: false).session.input == 40)
        // Voltar a ler não muda nada.
        #expect(tracker.usage(ofFile: original.path, codex: false).session.input == 30)
    }

    @Test func repeatedCodexEventIsCountedOnce() throws {
        func event(_ total: Int) -> String {
            #"{"timestamp":"\#(isoNow)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(total),"cached_input_tokens":0,"output_tokens":0,"total_tokens":\#(total)},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0}}}}"#
        }
        let url = try tempFile([event(100), event(100), event(200)].joined(separator: "\n") + "\n")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(UsageTracker().usage(ofFile: url.path, codex: true).session.input == 200)
    }

    @Test func linesSplitAcrossChunksAreStillRead() throws {
        let content = (0..<50).map { claudeLine("m\($0)", input: 1, output: 0) }.joined(separator: "\n") + "\n"
        let url = try tempFile(content)
        defer { try? FileManager.default.removeItem(at: url) }
        let tracker = UsageTracker()
        tracker.chunkSize = 37   // bem mais pequeno do que uma linha
        #expect(tracker.usage(ofFile: url.path, codex: false).session.input == 50)
    }
}
