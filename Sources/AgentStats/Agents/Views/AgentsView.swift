import SwiftUI
import AppKit

struct AgentsView: View {
    @Environment(Monitor.self) private var m
    @AppStorage("agents.showRecent") private var showRecent = false
    @AppStorage("panel.showUsage") private var showUsage = true
    @AppStorage("panel.showLimits") private var showLimits = true
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
            // O que precisa de ti vem antes de tudo: é a razão de abrir o painel.
            if !attention.isEmpty {
                group("Precisa de ti", attention.count, .attention) { ForEach(attention) { SessionCard(session: $0) } }
            }
            if showLimits && (!m.planLimits.isEmpty || m.claudeLimitsHint != nil) { PlanLimitsCard(limits: m.planLimits, hint: m.claudeLimitsHint) }
            if showUsage && !m.usage.todayTotal.isEmpty {
                TodayUsage(usage: m.usage, budget: m.budgetEnabled ? (m.budgetSpent, m.budgetAmount, m.budgetPeriod) : nil)
            }
            if showActivity && !m.day.isEmpty { ActivityStrip(day: m.day) }
            if !hasAnyAgent {
                EmptyAgents()
            } else if !hasVisibleItems {
                Text("Nenhuma sessão neste filtro")
                    .font(DS.body).foregroundStyle(Color.text2)
                    .frame(maxWidth: .infinity).padding(.vertical, DS.md)
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
                                .font(DS.meta).foregroundStyle(Color.text3)
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
                                .font(DS.meta).foregroundStyle(Color.text3)
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
        // Uma sessão que muda de estado desliza para o grupo novo em vez de saltar.
        .animation(Motion.ease(0.25), value: sessions.map { "\($0.id)|\($0.state)" })
    }

    @StateObject private var showHistory = Box(false)

    private var searchAndFilters: some View {
        HStack(spacing: DS.sm) {
            Text("Sessões")
                .font(DS.meta.weight(.medium))
                .foregroundStyle(Color.text2)
            Spacer(minLength: DS.sm)
            Button { isFilterPopoverShown.value.toggle() } label: {
                HStack(spacing: DS.xs) {
                    Image(systemName: "line.3.horizontal.decrease")
                    Text((AgentSessionFilter(rawValue: selectedFilter.value) ?? .all).title)
                }
                .font(DS.meta)
                .foregroundStyle(selectedFilter.value == AgentSessionFilter.all.rawValue ? Color.text2 : Color.primary)
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
                                    Image(systemName: "checkmark").foregroundStyle(Color.text2)
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
                .font(.system(size: 20)).foregroundStyle(Color.text3)
                .frame(width: 48, height: 48)
                .background(Circle().fill(DS.surface))
            Text("Nenhum agente a trabalhar").font(DS.title)
            Text("Quando abrires uma sessão de um agente de código, ela aparece aqui com o que está a fazer")
                .font(DS.body).foregroundStyle(Color.text2)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Text("Claude Code, Codex, Gemini CLI, Aider, Cursor Agent, OpenCode, Goose e Amp")
                .font(DS.meta).foregroundStyle(Color.text3)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, DS.lg)
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.lg)
    }
}
