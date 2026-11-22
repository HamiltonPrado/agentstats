import SwiftUI
import AppKit

extension AgentState {
    /// Cor do ponto de estado (a assinatura): só três cores com significado, o resto neutro.
    var color: Color {
        switch self {
        case .runningTool, .thinking: return Palette.working
        case .needsApproval, .needsAnswer: return Palette.attention
        case .waitingUser: return Palette.waiting
        case .finished, .unknown: return Color.secondary.opacity(0.6)
        }
    }
    var statusKind: StatusKind {
        switch self {
        case .runningTool, .thinking: return .working
        case .needsApproval, .needsAnswer: return .attention
        case .waitingUser: return .waiting
        case .finished, .unknown: return .idle
        }
    }
    var toolName: String? {
        if case .runningTool(let t) = self { return t }
        if case .needsApproval(let t) = self { return t }
        return nil
    }
    var icon: String {
        switch self {
        case .runningTool(let t): return AgentState.toolIcon(t)
        case .needsApproval: return "hand.raised"
        case .needsAnswer: return "questionmark.bubble"
        case .thinking: return "ellipsis"
        case .waitingUser: return "text.bubble"
        case .finished: return "checkmark"
        case .unknown: return "circle.dotted"
        }
    }
    static func toolIcon(_ t: String) -> String {
        switch t.lowercased() {
        case "bash", "monitor": return "terminal"
        case "edit", "write", "multiedit", "notebookedit": return "pencil"
        case "read": return "doc.text"
        case "grep", "glob", "toolsearch": return "magnifyingglass"
        case "webfetch", "websearch", "navigate": return "globe"
        case "task", "agent", "sendmessage": return "person.2"
        case "skill": return "book.closed"
        default: return "wrench.and.screwdriver"
        }
    }
}
