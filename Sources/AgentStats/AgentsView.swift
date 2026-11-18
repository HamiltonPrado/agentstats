import SwiftUI
import AppKit

extension AgentState {
    var color: Color {
        switch self {
        case .runningTool, .thinking: return .green
        case .needsApproval, .needsAnswer: return .red
        case .waitingUser: return .orange
        case .finished: return .gray
        case .unknown: return .blue
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
        case .needsApproval: return "hand.raised.fill"
        case .needsAnswer: return "questionmark.bubble.fill"
        case .thinking: return "brain"
        case .waitingUser: return "bubble.left.and.text.bubble.right"
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
        case "skill": return "wand.and.stars"
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
        let recent = m.sessions.filter { !$0.state.isWorking && $0.state != .waitingUser }
        let linked = Set(m.sessions.compactMap { $0.process?.pid })
        // o executor do Codex é um auxiliar interno da app: não aparece em separado
        let others = m.agents.filter { !linked.contains($0.pid) && $0.role != "executor" }

        VStack(alignment: .leading, spacing: 12) {
            if !m.usage.todayTotal.isEmpty { TodayUsage(usage: m.usage) }
            if attention.isEmpty && working.isEmpty && waiting.isEmpty && others.isEmpty {
                EmptyAgents()
            }
            if !attention.isEmpty {
                group("Precisa de ti", attention.count, .red) { ForEach(attention) { SessionCard(session: $0) } }
            }
            if !working.isEmpty {
                group("A trabalhar", working.count, .green) { ForEach(working) { SessionCard(session: $0) } }
            }
            if !waiting.isEmpty {
                group("À tua espera", waiting.count, .orange) { ForEach(waiting) { SessionCard(session: $0) } }
            }
            if !others.isEmpty {
                group("Outros agentes", others.count, .blue) { ForEach(others) { OtherAgentRow(agent: $0) } }
            }
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Button { withAnimation(.easeInOut(duration: 0.2)) { showRecent.toggle() } } label: {
                        HStack {
                            SectionHeader(title: "Recentes", count: recent.count, color: .gray)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
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

    private func group<C: View>(_ title: String, _ count: Int, _ color: Color, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: title, count: count, color: color)
            content()
        }
    }
}

struct EmptyAgents: View {
    private let supported = ["Claude Code", "Codex", "Gemini CLI", "Aider", "Cursor Agent", "OpenCode", "Goose", "Amp"]
    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.primary.opacity(0.06)).frame(width: 64, height: 64)
                Image(systemName: "moon.zzz.fill").font(.system(size: 26)).foregroundStyle(.secondary)
            }
            Text("Nenhum agente a trabalhar").font(.system(size: 13, weight: .semibold))
            Text("Quando abrires uma sessão de um agente de código, ela aparece aqui com o que está a fazer em tempo real.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
            FlowPills(items: supported).padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}

/// Linhas de pills simples (sem layout lazy, para renderizar bem em snapshots).
struct FlowPills: View {
    let items: [String]
    var body: some View {
        VStack(spacing: 5) {
            ForEach(Array(stride(from: 0, to: items.count, by: 4)), id: \.self) { i in
                HStack(spacing: 5) {
                    ForEach(items[i..<min(i + 4, items.count)], id: \.self) { Pill(text: $0) }
                }
            }
        }
    }
}

struct StateIcon: View {
    let state: AgentState

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(state.color.opacity(0.16))
                if state.needsAttention {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(state.color, lineWidth: 1.2)
                }
                Image(systemName: state.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(state.color)
            }
            .frame(width: 26, height: 26)
            // Indicador nativo (animado pelo macOS fora do processo): bem mais leve que uma animação SwiftUI contínua
            if state.isWorking {
                ProgressView().controlSize(.mini).scaleEffect(0.6)
                    .frame(width: 10, height: 10)
                    .background(Circle().fill(.background))
                    .offset(x: 3, y: 3)
            }
        }
    }
}

struct SessionCard: View {
    @Environment(Monitor.self) private var m
    let session: AgentSession
    @StateObject private var hover = Box(false)

    private var isCommand: Bool { session.state.toolName == "Bash" }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            StateIcon(state: session.state)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .center, spacing: 6) {
                    Text(session.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    if hover.value { actions } else {
                        Text(Fmt.ago(session.lastActivity)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
                    }
                }
                .frame(height: 18)

                HStack(spacing: 5) {
                    Text(session.state.label).font(.system(size: 11, weight: .semibold)).foregroundStyle(session.state.color)
                    Text("· " + (session.kind == "Claude Code" ? "Claude" : session.kind))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(session.kind == "Codex" ? Color.teal : Color.orange)
                    if session.subagents > 0 {
                        Pill(text: "\(session.subagents) subagente\(session.subagents == 1 ? "" : "s")", icon: "person.2.fill", color: .purple)
                    }
                }

                if let d = session.detail {
                    Text(d)
                        .font(isCommand ? .system(size: 10.5, design: .monospaced) : .system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.horizontal, isCommand ? 7 : 0).padding(.vertical, isCommand ? 4 : 0)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(isCommand ? 0.06 : 0)))
                }

                HStack(spacing: 4) {
                    Pill(text: session.project, icon: "folder.fill").layoutPriority(-1)
                    if let model = Fmt.model(session.model) { Pill(text: model, icon: "cpu", color: .indigo) }
                    Spacer(minLength: 2)
                    let tokens = m.usage.perSession[session.id].flatMap { $0.isEmpty ? nil : Fmt.tokens($0.total) + " tok" }
                    let cpu = session.process.map { String(format: "%.0f%%", $0.cpu) }
                    let stats = [cpu, tokens].compactMap { $0 }
                    if !stats.isEmpty {
                        Text(stats.joined(separator: " · "))
                            .font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
                            .help(m.usage.perSession[session.id].map { u in
                                "Tokens nesta sessão: \(Fmt.tokens(u.total)) — saída \(Fmt.tokens(u.output)), entrada \(Fmt.tokens(u.input)), cache lida \(Fmt.tokens(u.cacheRead)), cache escrita \(Fmt.tokens(u.cacheWrite))"
                            } ?? "")
                    }
                }
                if let p = session.process, !p.children.isEmpty, session.state.isWorking {
                    Text("↳ " + p.children.joined(separator: "  ·  "))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
        .cardStyle(padding: 8, highlight: session.state.isWorking || session.state.needsAttention ? session.state.color.opacity(session.state.needsAttention ? 0.8 : 0.4) : nil)
        .opacity(session.state == .finished ? 0.7 : 1)
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
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 22, height: 18)
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

    private var subtitle: String {
        if agent.role == "app" {
            let n = m.sessions.filter { $0.kind == agent.kind && $0.state.isWorking }.count
            return n > 0 ? "\(n) tarefa\(n == 1 ? "" : "s") em curso" : "Aberto · sem tarefas em curso"
        }
        return agent.cwd.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "PID \(String(agent.pid))"
    }
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.blue.opacity(0.14))
                Image(systemName: agent.isSubagent ? "arrow.turn.down.right" : "terminal")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.blue)
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.kind + (agent.role == "app" ? " · app ChatGPT" : agent.role == "executor" ? " · executor" : agent.isSubagent ? " · subagente" : "")).font(.system(size: 12.5, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "%.0f%% CPU", agent.cpu)).font(.system(size: 11, weight: .medium).monospacedDigit())
                Text(Fmt.etime(agent.elapsed)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
        .cardStyle(padding: 8)
        .contextMenu {
            Button("Terminar processo… (PID \(String(agent.pid)))", role: .destructive) { ProcessKiller.confirmAndTerminate(pid: agent.pid, name: agent.kind) }
        }
    }
}

/// Resumo dos tokens de hoje (Claude + Codex).
struct TodayUsage: View {
    let usage: UsageSnapshot
    var body: some View {
        let t = usage.todayTotal
        HStack(spacing: 8) {
            Image(systemName: "chart.bar.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(.purple)
            Text("Hoje").font(.system(size: 11, weight: .semibold))
            Text("\(Fmt.tokens(t.total)) tokens").font(.system(size: 11).monospacedDigit())
            Text("· \(Fmt.tokens(t.output)) saída").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if !usage.todayClaude.isEmpty { Pill(text: Fmt.tokens(usage.todayClaude.total), icon: "asterisk", color: .orange) }
            if !usage.todayCodex.isEmpty { Pill(text: Fmt.tokens(usage.todayCodex.total), icon: "chevron.left.forwardslash.chevron.right", color: .teal) }
        }
        .cardStyle(padding: 7)
        .help("Inclui leituras de cache (\(Fmt.tokens(t.cacheRead))), que são a maior parte e custam muito menos do que tokens novos. Entrada nova: \(Fmt.tokens(t.input)) · cache escrita: \(Fmt.tokens(t.cacheWrite)) · saída: \(Fmt.tokens(t.output)).")
    }
}
