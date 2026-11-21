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

struct AgentsView: View {
    @Environment(Monitor.self) private var m
    @AppStorage("agents.showRecent") private var showRecent = false
    @AppStorage("panel.showUsage") private var showUsage = true
    @AppStorage("panel.showActivity") private var showActivity = true
    @AppStorage("agents.showRecentSection") private var showRecentSection = true
    @AppStorage("agents.showHistorySection") private var showHistorySection = true
    @StateObject private var isFilterPopoverShown = Box(false)
    @StateObject private var selectedFilter = Box(AgentSessionFilter.all.rawValue)

    var body: some View {
        let sessions = m.sessions.filter(matches)
        let attention = sessions.filter { $0.state.needsAttention }
        let working = sessions.filter { $0.state.isWorking }
        let waiting = sessions.filter { $0.state == .waitingUser }
        let recent = sessions.filter { !$0.state.isWorking && !$0.state.needsAttention && $0.state != .waitingUser }
        let linked = Set(sessions.compactMap { $0.process?.pid })
        // o executor do Codex é um auxiliar interno da app: não aparece em separado
        let others = m.agents.filter { agent in
            guard !linked.contains(agent.pid), agent.role != "executor" else { return false }
            return matches(agent)
        }
        let history = m.activityHistory.filter(matches)
        let hasVisibleItems = !attention.isEmpty || !working.isEmpty || !waiting.isEmpty || !others.isEmpty
            || (showRecentSection && !recent.isEmpty) || (showHistorySection && !history.isEmpty)
        let hasAnyAgent = !m.sessions.isEmpty || !m.agents.isEmpty || !m.activityHistory.isEmpty

        VStack(alignment: .leading, spacing: DS.lg) {
            searchAndFilters
            if showUsage && !m.usage.todayTotal.isEmpty { TodayUsage(usage: m.usage) }
            if showActivity && !m.day.isEmpty { ActivityStrip(day: m.day) }
            if !hasAnyAgent {
                EmptyAgents()
            } else if !hasVisibleItems {
                Text("Nenhuma sessão neste filtro")
                    .font(DS.body).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, DS.md)
            }
            if !attention.isEmpty {
                group("Precisa de ti", attention.count, .attention) { ForEach(attention) { SessionCard(session: $0) } }
            }
            if !working.isEmpty {
                group("A trabalhar", working.count, .working) { ForEach(working) { SessionCard(session: $0) } }
            }
            if !waiting.isEmpty {
                group("À tua espera", waiting.count, .waiting) { ForEach(waiting) { SessionCard(session: $0) } }
            }
            if !others.isEmpty {
                group("Outros agentes", others.count, nil) { ForEach(others) { OtherAgentRow(agent: $0) } }
            }
            if showRecentSection && !recent.isEmpty {
                VStack(alignment: .leading, spacing: DS.sm) {
                    Button { withAnimation(Motion.ease(0.2)) { showRecent.toggle() } } label: {
                        HStack(spacing: DS.xs) {
                            SectionHeader(title: "Recentes", count: recent.count)
                            Image(systemName: "chevron.right")
                                .font(DS.meta).foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(showRecent ? 90 : 0))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if showRecent || selectedFilter.value == AgentSessionFilter.recent.rawValue {
                        ForEach(recent) { SessionCard(session: $0) }
                    }
                }
            }
            if showHistorySection && !history.isEmpty {
                VStack(alignment: .leading, spacing: DS.sm) {
                    Button { withAnimation(Motion.ease(0.2)) { showHistory.value.toggle() } } label: {
                        HStack(spacing: DS.xs) {
                            SectionHeader(title: "Histórico de agentes", count: history.count)
                            Image(systemName: "chevron.right")
                                .font(DS.meta).foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(showHistory.value ? 90 : 0))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if showHistory.value {
                        ForEach(history.prefix(8)) { ActivityHistoryRow(record: $0) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @StateObject private var showHistory = Box(false)

    private var searchAndFilters: some View {
        HStack(spacing: DS.sm) {
            Text("Sessões")
                .font(DS.meta.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: DS.sm)
            Button { isFilterPopoverShown.value.toggle() } label: {
                HStack(spacing: DS.xs) {
                    Image(systemName: "line.3.horizontal.decrease")
                    Text((AgentSessionFilter(rawValue: selectedFilter.value) ?? .all).title)
                }
                .font(DS.meta)
                .foregroundStyle(selectedFilter.value == AgentSessionFilter.all.rawValue ? .secondary : .primary)
                .padding(.horizontal, DS.sm)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: DS.rSmall, style: .continuous).fill(DS.raised))
            }
            .buttonStyle(.plain)
            .popover(isPresented: Binding(
                get: { isFilterPopoverShown.value },
                set: { isFilterPopoverShown.value = $0 }
            ), arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: DS.xs) {
                    ForEach(AgentSessionFilter.allCases) { filter in
                        Button {
                            selectedFilter.value = filter.rawValue
                            if filter == .recent { showRecent = true }
                            isFilterPopoverShown.value = false
                        } label: {
                            HStack {
                                Text(filter.title)
                                Spacer(minLength: DS.md)
                                if filter.rawValue == selectedFilter.value {
                                    Image(systemName: "checkmark").foregroundStyle(.secondary)
                                }
                            }
                            .font(DS.body)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(DS.sm)
                .frame(width: 150)
            }
            .help("Filtrar por estado")
            .accessibilityLabel("Filtrar sessões")
        }
    }

    private func matches(_ session: AgentSession) -> Bool {
        let filter = AgentSessionFilter(rawValue: selectedFilter.value) ?? .all
        return filter.accepts(session.state)
    }

    private func matches(_ agent: AgentProcess) -> Bool {
        let filter = AgentSessionFilter(rawValue: selectedFilter.value) ?? .all
        return filter == .all || filter == .working
    }

    private func matches(_ record: AgentActivityRecord) -> Bool {
        let filter = AgentSessionFilter(rawValue: selectedFilter.value) ?? .all
        return filter.accepts(record.phase)
    }

    private func group<C: View>(_ title: String, _ count: Int, _ kind: StatusKind?, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            SectionHeader(title: title, count: count, kind: kind)
            content()
        }
    }
}

private enum AgentSessionFilter: String, CaseIterable, Identifiable {
    case all, working, attention, waiting, recent
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "Todos"
        case .working: "A trabalhar"
        case .attention: "Precisa de ti"
        case .waiting: "À tua espera"
        case .recent: "Recentes"
        }
    }

    func accepts(_ state: AgentState) -> Bool {
        switch self {
        case .all: true
        case .working: state.isWorking
        case .attention: state.needsAttention
        case .waiting: state == .waitingUser
        case .recent: !state.isWorking && !state.needsAttention && state != .waitingUser
        }
    }

    func accepts(_ phase: AgentActivityPhase) -> Bool {
        switch self {
        case .all: true
        case .working: phase == .working
        case .attention: phase == .attention
        case .waiting: phase == .waiting
        case .recent: phase == .finished || phase == .active
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
                StatusDot(state.statusKind, size: 8)
                    .padding(1.5)
                    .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                    .offset(x: 3, y: 3)
            }
    }
}

private struct ActivityHistoryRow: View {
    @Environment(Monitor.self) private var m
    let record: AgentActivityRecord

    private var eventSummary: String {
        record.events.suffix(3).map { $0.phase.title }.joined(separator: " → ")
    }

    private var timeRange: String {
        let start = "Início \(Fmt.ago(record.firstSeen))"
        return start + (record.endedAt.map { " · fim \(Fmt.ago($0))" } ?? " · em curso")
    }

    var body: some View {
        HStack(alignment: .top, spacing: DS.sm) {
            Image(systemName: record.phase == .finished ? "checkmark.circle" : record.phase.shouldRemind ? "hourglass" : "clock")
                .font(DS.body).foregroundStyle(record.phase.shouldRemind ? Palette.attention : .secondary)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.title).font(DS.body.weight(.medium)).lineLimit(1)
                Text("\(record.kind) · \(record.project) · \(record.phase.title)")
                    .font(DS.meta).foregroundStyle(.secondary).lineLimit(1)
                Text(timeRange).font(DS.meta).foregroundStyle(.tertiary).lineLimit(1)
                if record.events.count > 1 {
                    Text(eventSummary).font(DS.meta).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: DS.xs)
            VStack(alignment: .trailing, spacing: 3) {
                Text(Fmt.duration(record.duration())).font(DS.meta.monospacedDigit())
                Text(record.tokens > 0 ? Fmt.tokens(record.tokens) + " tokens" : "sem tokens")
                    .font(DS.meta.monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, DS.md).padding(.vertical, DS.sm)
        .background(RoundedRectangle(cornerRadius: DS.rControl, style: .continuous).fill(DS.surface))
        .contentShape(Rectangle())
        .onTapGesture {
            if let session = m.sessions.first(where: { $0.id == record.id }) {
                AppState.controller?.open(session)
            } else if let cwd = record.cwd {
                NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
            } else if record.id.hasPrefix("/") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: record.id)])
            }
        }
        .help("Observada pela primeira vez \(Fmt.ago(record.firstSeen)); duração medida pela app")
        .accessibilityElement(children: .combine)
    }
}

struct SessionCard: View {
    @Environment(Monitor.self) private var m
    let session: AgentSession
    @AppStorage("panel.density") private var densityRawValue = PanelDensity.normal.rawValue
    @StateObject private var hover = Box(false)

    private var isCommand: Bool { session.state.toolName == "Bash" }
    private var density: PanelDensity { PanelDensity(rawValue: densityRawValue) ?? .normal }

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
            VStack(alignment: .leading, spacing: density == .detailed ? DS.sm : DS.xs) {
                HStack(alignment: .firstTextBaseline, spacing: DS.sm) {
                    Text(session.title).font(DS.title).lineLimit(1)
                    Spacer(minLength: DS.xs)
                    if hover.value { actions } else {
                        Text(Fmt.ago(session.lastActivity)).font(DS.meta.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                }

                if density == .compact {
                    Text("\(session.state.label) · \(session.kind == "Claude Code" ? "Claude" : session.kind) · \(session.project)")
                        .font(DS.meta)
                        .foregroundStyle(session.state.needsAttention ? AnyShapeStyle(Palette.attention) : AnyShapeStyle(.secondary))
                        .lineLimit(1).truncationMode(.middle)
                } else {
                    HStack(spacing: DS.xs) {
                        Text(session.state.label)
                            .foregroundStyle(session.state.needsAttention ? AnyShapeStyle(Palette.attention) : AnyShapeStyle(.secondary))
                        Text("· " + (session.kind == "Claude Code" ? "Claude" : session.kind)).foregroundStyle(.tertiary)
                    }
                    .font(DS.body)

                    if let d = session.detail {
                        if isCommand {
                            // O momento da app: o comando em curso, como uma linha de terminal.
                            Text("$ " + d)
                                .font(DS.mono).foregroundStyle(.primary)
                                .lineLimit(density == .detailed ? 5 : 2)
                                .padding(.horizontal, DS.sm).padding(.vertical, DS.xs)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: DS.rSmall, style: .continuous).fill(DS.raised))
                        } else {
                            Text(d).font(DS.body).foregroundStyle(.secondary)
                                .lineLimit(density == .detailed ? 5 : 2)
                        }
                    }

                    Text(meta)
                        .font(DS.meta.monospacedDigit()).foregroundStyle(.tertiary)
                        .lineLimit(density == .detailed ? 3 : 1).truncationMode(.middle)
                        .help(m.usage.perSession[session.id].map { u in
                            "Tokens nesta sessão: \(Fmt.tokens(u.total)) · saída \(Fmt.tokens(u.output)) · entrada \(Fmt.tokens(u.input)) · cache lida \(Fmt.tokens(u.cacheRead)) · cache escrita \(Fmt.tokens(u.cacheWrite))"
                        } ?? "")

                    if let p = session.process, !p.children.isEmpty, session.state.isWorking {
                        Text("↳ " + p.children.joined(separator: " · "))
                            .font(DS.mono).foregroundStyle(.tertiary).lineLimit(density == .detailed ? 3 : 1)
                    }
                }
            }
        }
        .cardStyle(padding: density == .compact ? DS.sm : DS.md,
                   highlight: session.state.needsAttention ? Palette.attention.opacity(0.5) : nil)
        .background(RoundedRectangle(cornerRadius: DS.rCard, style: .continuous).fill(hover.value ? DS.surface : .clear))
        .opacity(session.state == .finished ? 0.6 : 1)
        .contentShape(Rectangle())
        .onTapGesture { AppState.controller?.open(session) }
        .help("Clica para ir para o agente")
        .onHover { hover.value = $0 }
        // VoiceOver: o cartão é um só elemento, com tudo dito por extenso e as ações do menu
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Abre a app onde o agente corre")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { AppState.controller?.open(session) }
        .accessibilityAction(named: "Abrir pasta") {
            if let cwd = session.cwd { NSWorkspace.shared.open(URL(fileURLWithPath: cwd)) }
        }
        .accessibilityAction(named: "Mostrar transcript") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.id)])
        }
        .contextMenu { menu }
    }

    private var accessibilityText: String {
        var parts = [session.title, session.state.label, session.kind]
        if let d = session.detail { parts.append(isCommand ? "comando: " + d : d) }
        parts.append(meta)
        parts.append(Fmt.ago(session.lastActivity))
        return parts.joined(separator: ", ")
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
        .accessibilityElement(children: .combine)
        .contextMenu {
            Button("Terminar processo… (PID \(String(agent.pid)))", role: .destructive) { ProcessKiller.confirmAndTerminate(pid: agent.pid, name: agent.kind) }
        }
    }
}

/// Tokens de hoje (Claude + Codex). Clicar abre os últimos 7 dias e os projetos que mais gastaram.
struct TodayUsage: View {
    let usage: UsageSnapshot
    @AppStorage("usage.expanded") private var expanded = false

    var body: some View {
        let t = usage.todayTotal
        VStack(alignment: .leading, spacing: DS.md) {
            Button { withAnimation(Motion.ease(0.2)) { expanded.toggle() } } label: {
                HStack(alignment: .firstTextBaseline, spacing: DS.sm) {
                    Text("Hoje").font(DS.body).foregroundStyle(.secondary)
                    Text("\(Fmt.tokens(t.total)) tokens").font(DS.title.monospacedDigit())
                    Text("\(Fmt.tokens(t.output)) de saída").font(DS.meta.monospacedDigit()).foregroundStyle(.tertiary)
                    Spacer(minLength: DS.xs)
                    Image(systemName: "chevron.right")
                        .font(DS.meta).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hoje, \(Fmt.tokens(t.total)) tokens, \(Fmt.tokens(t.output)) de saída")
            .accessibilityHint(expanded ? "Esconde a semana" : "Mostra os últimos 7 dias e os projetos")

            if expanded {
                week
                if !usage.projects.isEmpty { projects }
            }
        }
        .cardStyle(padding: DS.md)
        .help("Inclui leituras de cache (\(Fmt.tokens(t.cacheRead))), que são a maior parte e custam muito menos do que tokens novos. Entrada nova \(Fmt.tokens(t.input)) · cache escrita \(Fmt.tokens(t.cacheWrite)) · saída \(Fmt.tokens(t.output))")
    }

    /// Barras dos últimos 7 dias; hoje com a cor de destaque, os outros em neutro.
    private var week: some View {
        let maxTotal = max(usage.week.map(\.total.total).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: DS.sm) {
            HStack {
                Text("Últimos 7 dias").font(DS.meta).foregroundStyle(.secondary)
                Spacer()
                Text(Fmt.tokens(usage.weekTotal.total) + " tokens").font(DS.meta.monospacedDigit()).foregroundStyle(.tertiary)
            }
            HStack(alignment: .bottom, spacing: DS.sm) {
                ForEach(Array(usage.week.enumerated()), id: \.offset) { i, d in
                    let isToday = i == usage.week.count - 1
                    VStack(spacing: DS.xs) {
                        Text(d.total.isEmpty ? "" : Fmt.tokens(d.total.total))
                            .font(.system(size: 9).monospacedDigit()).foregroundStyle(.tertiary)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(isToday ? Color.accentColor : Color.secondary.opacity(0.45))
                            .frame(height: max(2, 40 * Double(d.total.total) / Double(maxTotal)))
                        Text(Self.weekday(d.day)).font(DS.meta).foregroundStyle(isToday ? .primary : .tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(Self.weekday(d.day)): \(Fmt.tokens(d.total.total)) tokens")
                }
            }
            .frame(height: 72, alignment: .bottom)
        }
    }

    /// Projetos que mais gastaram na semana: lista com barras finas (não um segundo gráfico).
    private var projects: some View {
        let top = Array(usage.projects.prefix(5))
        let maxTotal = max(top.first?.usage.total ?? 1, 1)
        return VStack(alignment: .leading, spacing: DS.sm) {
            Text("Projetos esta semana").font(DS.meta).foregroundStyle(.secondary)
            ForEach(top, id: \.name) { p in
                VStack(alignment: .leading, spacing: DS.xs) {
                    HStack {
                        Text(p.name.trimmingCharacters(in: .whitespaces)).font(DS.body).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: DS.sm)
                        Text(Fmt.tokens(p.usage.total)).font(DS.body.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Bar(value: Double(p.usage.total) / Double(maxTotal), color: .secondary.opacity(0.5), height: 2)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// "2026-11-19" → "qui" (abreviatura fixa de 3 letras, para as barras ficarem alinhadas)
    nonisolated static func weekday(_ day: String) -> String {
        let parse = DateFormatter()
        parse.dateFormat = "yyyy-MM-dd"
        guard let d = parse.date(from: day) else { return "" }
        let names = ["dom", "seg", "ter", "qua", "qui", "sex", "sáb"]
        return names[Calendar.current.component(.weekday, from: d) - 1]
    }
}

/// Atividade dos agentes nas últimas 24 h, em blocos de 10 minutos.
struct ActivityStrip: View {
    @Environment(\.agentAccentColor) private var agentAccentColor
    let day: [MinuteSample]

    var body: some View {
        let now = Date()
        let cutoff = now.timeIntervalSince1970 - History24h.activityWindow
        let recent = day.filter { $0.t >= cutoff }
        let buckets = History24h.buckets(recent, now: now)
        let active = History24h.activeMinutes(recent, now: now)
        VStack(alignment: .leading, spacing: DS.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("Últimas 24 h").font(DS.body).foregroundStyle(.secondary)
                Spacer()
                Text(active > 0 ? "agentes ativos " + Fmt.minutes(active) : "sem atividade")
                    .font(DS.meta.monospacedDigit()).foregroundStyle(.tertiary)
            }
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(Array(buckets.enumerated()), id: \.offset) { _, b in
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 1)
                            .fill(b.attention ? Palette.attention.opacity(0.8) : (b.working > 0 ? agentAccentColor : DS.raised))
                            .frame(height: b.working > 0 ? max(3, 20 * b.working) : 2)
                    }
                }
            }
            .frame(height: 20)
            .accessibilityHidden(true)
            HStack {
                Text(DayChart.hour(buckets.first?.start ?? Date().timeIntervalSince1970)).font(DS.meta.monospacedDigit())
                Spacer()
                Text("agora").font(DS.meta)
            }
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
        }
        .cardStyle()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Atividade dos agentes nas últimas 24 horas: " + (active > 0 ? Fmt.minutes(active) + " com agentes a trabalhar" : "sem atividade"))
    }
}
