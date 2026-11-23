import Testing
@testable import AgentStats

@Suite struct AgentActionsTests {
    private let present: (String) -> Bool = { _ in true }

    @Test func onlySessionsBackedByAFileHaveATranscript() {
        #expect(AgentActions.transcriptPath("/Users/demo/.claude/projects/x/abc.jsonl", exists: present) == "/Users/demo/.claude/projects/x/abc.jsonl")
        #expect(AgentActions.transcriptPath("opencode:ses_123", exists: present) == nil)
        #expect(AgentActions.transcriptPath("proc-4100-Aider", exists: present) == nil)
        #expect(AgentActions.transcriptPath("gemini-cli-4200", exists: present) == nil)
    }

    @Test func aDeletedTranscriptIsNotOffered() {
        #expect(AgentActions.transcriptPath("/Users/demo/apagado.jsonl", exists: { _ in false }) == nil)
    }
}
