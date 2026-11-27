import Foundation

/// Os modelos que todos os leitores de agentes produzem.

enum AgentState: Equatable {
    case runningTool(String)
    case thinking
    case needsApproval(String)   // bloqueado à espera de autorização para uma ferramenta
    case needsAnswer             // fez uma pergunta (AskUserQuestion / plano para aprovar)
    case waitingUser
    case finished
    case unknown

    var label: String {
        switch self {
        case .runningTool(let t): return String(localized: "A executar \(t)")
        case .thinking: return "A pensar…"
        case .needsApproval(let t): return String(localized: "Precisa de aprovação · \(t)")
        case .needsAnswer: return "Tem uma pergunta para ti"
        case .waitingUser: return "À tua espera"
        case .finished: return "Terminada"
        case .unknown: return "Ativo"
        }
    }

    var isWorking: Bool {
        switch self {
        case .runningTool, .thinking: return true
        default: return false
        }
    }

    var needsAttention: Bool {
        switch self {
        case .needsApproval, .needsAnswer: return true
        default: return false
        }
    }
}

struct AgentProcess: Identifiable {
    var id: Int { pid }
    let pid: Int
    let kind: String          // "Claude Code", "Codex", …
    let cpu: Double           // inclui subprocessos
    let memKB: UInt64
    let elapsed: String
    let cwd: String?
    let children: [String]    // nomes dos subprocessos ativos
    let isSubagent: Bool
    var role: String? = nil   // ex.: "app" / "executor" para os servidores do Codex
    var shellChildren: Int = 0 // shells filhas (o Claude Code corre cada comando Bash numa zsh)
    var ancestors: [Int] = []  // PIDs dos pais, do mais próximo ao mais distante (para encontrar a app onde corre)
}

struct AgentSession: Identifiable {
    /// Uma sessão sem processo aparece durante este tempo depois da última atividade (todos os leitores).
    static let recentWindow: TimeInterval = 20 * 60

    let id: String            // caminho do transcript
    let kind: String          // "Claude Code", "Codex", …
    let title: String
    let cwd: String?
    let model: String?
    let state: AgentState
    let detail: String?
    let lastActivity: Date
    let subagents: Int
    let process: AgentProcess?

    var project: String {
        guard let cwd else { return "—" }
        return (cwd as NSString).lastPathComponent
    }
}
