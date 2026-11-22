import Foundation
import Testing
@testable import AgentStats

@Suite struct BrokenPipeTests {
    /// O `claude` pode sair antes de lhe escrevermos. Sem proteção, o SIGPIPE mata o processo inteiro:
    /// se isto regredir, são os próprios testes que morrem com o sinal 13.
    @Test func writingToAClaudeThatAlreadyExitedFailsWithoutKillingTheApp() throws {
        let pipe = Pipe()
        try pipe.fileHandleForReading.close()   // o mesmo que o outro processo ter saído
        #expect(!ClaudeLimitsFetcher.send(Data("{}\n".utf8), to: pipe.fileHandleForWriting))
    }
}
