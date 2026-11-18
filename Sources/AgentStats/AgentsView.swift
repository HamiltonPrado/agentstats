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

struct AgentsView: View {
    @Environment(Monitor.self) private var m
    @AppStorage("agents.showRecent") private var showRecent = false

    var body: some View {
        let attention = m.sessions.filter { $0.state.needsAttention }
        let working = m.sessions.filter { $0.state.isWorking }
        let waiting = m.sessions.filter { $0.state == .waitingUser }
        let recent = m.sessions.filter { !$0.state.isWorking && !$0.state.needsAttention && $0.state != .waitingUser }
        let linked = Set(m.sessions.compactMap { $0.process?.pid })
        // o executor do Codex é um auxiliar interno da app: não aparece em separado
        let others = m.agents.filter { !linked.contains($0.pid) && $0.role != "executor" }

        VStack(alignment: .leading, spacing: DS.lg) {
            if !m.usage.todayTotal.isEmpty { TodayUsage(usage: m.usage) }
            if attention.isEmpty && working.isEmpty && waiting.isEmpty && others.isEmpty {
                EmptyAgents()
            }
            if !attention.isEmpty {
                group("Precisa de ti", attention.count, Palette.attention) { ForEach(attention) { SessionCard(session: $0) } }
            }
            if !working.isEmpty {
                group("A trabalhar", working.count, Palette.working) { ForEach(working) { SessionCard(session: $0) } }
            }
            if !waiting.isEmpty {
                group("À tua espera", waiting.count, Palette.waiting) { ForEach(waiting) { SessionCard(session: $0) } }
            }
            if !others.isEmpty {
                group("Outros agentes", others.count, nil) { ForEach(others) { OtherAgentRow(agent: $0) } }
            }
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: DS.sm) {
                    Button { withAnimation(.easeOut(duration: 0.2)) { showRecent.toggle() } } label: {
                        HStack(spacing: DS.xs) {
                            SectionHeader(title: "Recentes", count: recent.count)
                            Image(systemName: "chevron.right")
                                .font(DS.meta).foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(showRecent ? 90 : 0))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if showRecent { ForEach(recent) { SessionCard(session: $0) } }
                }
            }
        }
    }

    private func group<C: View>(_ title: String, _ count: Int, _ color: Color?, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            SectionHeader(title: title, count: count, color: color)
            content()
        }
    }
}

struct EmptyAgents: View {
    var body: some View {
        VStack(spacing: DS.sm) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 20)).foregroundStyle(.tertiary)
                .frame(width: 48, height: 48)
                .background(Circle().fill(DS.surface))
            Text("Nenhum agente a trabalhar").font(DS.title)
            Text("Quando abrires uma sessão de um agente de código, ela aparece aqui com o que está a fazer")
                .font(DS.body).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Text("Claude Code, Codex, Gemini CLI, Aider, Cursor Agent, OpenCode, Goose e Amp")
                .font(DS.meta).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, DS.lg)
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.lg)
    }
}

/// Ícone da ferramenta em uso, neutro, com o ponto de estado no canto.
struct StateIcon: View {
    let state: AgentState

    var body: some View {
        Image(systemName: state.icon)
            .font(DS.body)
            .foregroundStyle(state.needsAttention ? AnyShapeStyle(Palette.attention) : AnyShapeStyle(.secondary))
            .frame(width: 24, height: 24)
            .background(RoundedRectangle(cornerRadius: DS.rSmall, style: .continuous).fill(DS.raised))
            .overlay(alignment: .bottomTrailing) {
                StatusDot(color: state.color, size: 8)
                    .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                    .offset(x: 2, y: 2)
            }
    }
}

struct SessionCard: View {
    @Environment(Monitor.self) private var m
    let session: AgentSession
    @StateObject private var hover = Box(false)

    private var isCommand: Bool { session.state.toolName == "Bash" }

    /// Pasta · modelo · subagentes · CPU · tokens, numa só linha discreta.
    private var meta: String {
        var parts = [session.project]
        if let model = Fmt.model(session.model) { parts.append(model) }
        if session.subagents > 0 { parts.append("\(session.subagents) subagente\(session.subagents == 1 ? "" : "s")") }
        if let p = session.process { parts.append(Fmt.num(p.cpu, 0) + "% CPU") }
        if let u = m.usage.perSession[session.id], !u.isEmpty { parts.append(Fmt.tokens(u.total) + " tokens") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: DS.md) {
            StateIcon(state: session.state)
            VStack(alignment: .leading, spacing: DS.xs) {
                HStack(alignment: .firstTextBaseline, spacing: DS.sm) {
                    Text(session.title).font(DS.title).lineLimit(1)
                    Spacer(minLength: DS.xs)
                    if hover.value { actions } else {
                        Text(Fmt.ago(session.lastActivity)).font(DS.meta.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                }

                HStack(spacing: DS.xs) {
                    Text(session.state.label)
                        .foregroundStyle(session.state.needsAttention ? AnyShapeStyle(Palette.attention) : AnyShapeStyle(.secondary))
                    Text("· " + (session.kind == "Claude Code" ? "Claude" : session.kind)).foregroundStyle(.tertiary)
                }
                .font(DS.body)

                if let d = session.detail {
                    if isCommand {
                        // O momento da app: o comando em curso, como uma linha de terminal
                        Text("$ " + d)
                            .font(DS.mono).foregroundStyle(.primary)
                            .lineLimit(2)
                            .padding(.horizontal, DS.sm).padding(.vertical, DS.xs)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: DS.rSmall, style: .continuous).fill(DS.raised))
                    } else {
                        Text(d).font(DS.body).foregroundStyle(.secondary).lineLimit(2)
                    }
                }

                Text(meta)
                    .font(DS.meta.monospacedDigit()).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(m.usage.perSession[session.id].map { u in
                        "Tokens nesta sessão: \(Fmt.tokens(u.total)) · saída \(Fmt.tokens(u.output)) · entrada \(Fmt.tokens(u.input)) · cache lida \(Fmt.tokens(u.cacheRead)) · cache escrita \(Fmt.tokens(u.cacheWrite))"
                    } ?? "")

                if let p = session.process, !p.children.isEmpty, session.state.isWorking {
                    Text("↳ " + p.children.joined(separator: " · "))
                        .font(DS.mono).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
        .cardStyle(highlight: session.state.needsAttention ? Palette.attention.opacity(0.5) : nil)
        .background(RoundedRectangle(cornerRadius: DS.rCard, style: .continuous).fill(hover.value ? DS.surface : .clear))
        .opacity(session.state == .finished ? 0.6 : 1)
        .contentShape(Rectangle())
        .onTapGesture { AppState.controller?.open(session) }
        .help("Clica para ir para o agente")
        .onHover { hover.value = $0 }
        .contextMenu { menu }
    }

    private var actions: some View {
        HStack(spacing: 0) {
            if let cwd = session.cwd {
                mini("folder", "Abrir pasta") { NSWorkspace.shared.open(URL(fileURLWithPath: cwd)) }
            }
            mini("doc.text.magnifyingglass", "Mostrar transcript") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.id)])
            }
        }
    }

    private func mini(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(DS.meta).foregroundStyle(.secondary).frame(width: 20, height: 16)
        }
        .buttonStyle(.plain).help(help)
    }

    @ViewBuilder private var menu: some View {
        if let cwd = session.cwd {
            Button("Abrir pasta no Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: cwd)) }
            Button("Abrir no Terminal") {
                NSWorkspace.shared.open([URL(fileURLWithPath: cwd)],
                                        withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                        configuration: NSWorkspace.OpenConfiguration())
            }
            Button("Copiar caminho") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(cwd, forType: .string)
            }
        }
        Button("Mostrar transcript") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.id)]) }
        if let p = session.process {
            Divider()
            Button("Terminar agente… (PID \(String(p.pid)))", role: .destructive) { ProcessKiller.confirmAndTerminate(pid: p.pid, name: session.title) }
        }
    }
}

struct OtherAgentRow: View {
    @Environment(Monitor.self) private var m
    let agent: AgentProcess

    private var title: String {
        agent.kind + (agent.role == "app" ? " · app ChatGPT" : agent.role == "executor" ? " · executor" : agent.isSubagent ? " · subagente" : "")
    }
    private var subtitle: String {
        if agent.role == "app" {
            let n = m.sessions.filter { $0.kind == agent.kind && $0.state.isWorking }.count
            return n > 0 ? "\(n) tarefa\(n == 1 ? "" : "s") em curso" : "Aberto, sem tarefas em curso"
        }
        return agent.cwd.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "PID \(String(agent.pid))"
    }

    var body: some View {
        HStack(spacing: DS.md) {
            Image(systemName: agent.isSubagent ? "arrow.turn.down.right" : "terminal")
                .font(DS.body).foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: DS.rSmall, style: .continuous).fill(DS.raised))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(DS.title)
                Text(subtitle).font(DS.meta).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.num(agent.cpu, 0) + "% CPU").font(DS.body.monospacedDigit())
                Text(Fmt.etime(agent.elapsed)).font(DS.meta.monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
        .cardStyle()
        .contextMenu {
            Button("Terminar processo… (PID \(String(agent.pid)))", role: .destructive) { ProcessKiller.confirmAndTerminate(pid: agent.pid, name: agent.kind) }
        }
    }
}

/// Resumo dos tokens de hoje (Claude + Codex): números, sem decoração.
struct TodayUsage: View {
    let usage: UsageSnapshot
    var body: some View {
        let t = usage.todayTotal
        HStack(alignment: .firstTextBaseline, spacing: DS.sm) {
            Text("Hoje").font(DS.body).foregroundStyle(.secondary)
            Text("\(Fmt.tokens(t.total)) tokens").font(DS.title.monospacedDigit())
            Text("\(Fmt.tokens(t.output)) de saída").font(DS.meta.monospacedDigit()).foregroundStyle(.tertiary)
            Spacer(minLength: DS.xs)
            Text(split).font(DS.meta.monospacedDigit()).foregroundStyle(.tertiary)
        }
        .cardStyle(padding: DS.md)
        .help("Inclui leituras de cache (\(Fmt.tokens(t.cacheRead))), que são a maior parte e custam muito menos do que tokens novos. Entrada nova \(Fmt.tokens(t.input)) · cache escrita \(Fmt.tokens(t.cacheWrite)) · saída \(Fmt.tokens(t.output))")
    }

    private var split: String {
        var parts: [String] = []
        if !usage.todayClaude.isEmpty { parts.append("Claude \(Fmt.tokens(usage.todayClaude.total))") }
        if !usage.todayCodex.isEmpty { parts.append("Codex \(Fmt.tokens(usage.todayCodex.total))") }
        return parts.count > 1 ? parts.joined(separator: " · ") : ""
    }
}
