import SwiftUI
import AppKit

/// Ícone da ferramenta em uso, neutro, com o ponto de estado no canto.
struct StateIcon: View {
    let state: AgentState

    var body: some View {
        Image(systemName: state.icon)
            .font(DS.body)
            .foregroundStyle(state.needsAttention ? AnyShapeStyle(Color.attentionText) : AnyShapeStyle(Color.text2))
            .frame(width: 24, height: 24)
            .background(RoundedRectangle(cornerRadius: DS.rSmall, style: .continuous).fill(DS.raised))
            .overlay(alignment: .bottomTrailing) {
                StatusDot(state.statusKind, size: 8)
                    .padding(1.5)
                    .background(Circle().fill(Color.panel))
                    .offset(x: 3, y: 3)
            }
    }
}

struct SessionCard: View {
    @Environment(Monitor.self) private var m
    let session: AgentSession
    @AppStorage("panel.density") private var densityRawValue = PanelDensity.normal.rawValue
    @StateObject private var hover = Box(false)

    private var isCommand: Bool { session.state.toolName == "Bash" }
    private var density: PanelDensity { PanelDensity(rawValue: densityRawValue) ?? .normal }

    /// Pasta · modelo · subagentes · CPU · tokens e custo, numa só linha discreta.
    /// O CPU só aparece quando é relevante (≥ 5%) e vai no fim, para ser o que corta se não couber.
    private var meta: String {
        var parts = [session.project]
        if let model = Fmt.model(session.model) { parts.append(model) }
        if let u = m.usage.perSession[session.id], !u.isEmpty {
            var t = Fmt.tokens(u.total) + " tok"
            if let c = m.usage.perSessionCost[session.id], c >= 0.01 { t += " ~" + Fmt.usd(c) }
            parts.append(t)
        }
        if session.subagents > 0 { parts.append("\(session.subagents) subagente\(session.subagents == 1 ? "" : "s")") }
        // Por último: se a linha não couber, é o CPU que fica cortado.
        if let p = session.process, p.cpu >= 5 { parts.append(Fmt.num(p.cpu, 0) + "% CPU") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: DS.md) {
            StateIcon(state: session.state)
            VStack(alignment: .leading, spacing: density == .detailed ? DS.sm : DS.xs) {
                HStack(alignment: .firstTextBaseline, spacing: DS.sm) {
                    Text(session.title).font(DS.title).lineLimit(1)
                        // Terminada: recua no título, sem tirar contraste ao resto do cartão.
                        .foregroundStyle(session.state == .finished ? Color.text2 : Color.primary)
                    Spacer(minLength: DS.xs)
                    if hover.value { actions } else {
                        Text(Fmt.ago(session.lastActivity)).font(DS.meta.monospacedDigit()).foregroundStyle(Color.text3)
                    }
                }

                if density == .compact {
                    Text("\(session.state.label) · \(session.kind == "Claude Code" ? "Claude" : session.kind) · \(session.project)")
                        .font(DS.meta)
                        .foregroundStyle(session.state.needsAttention ? AnyShapeStyle(Color.attentionText) : AnyShapeStyle(Color.text2))
                        .lineLimit(1).truncationMode(.middle)
                } else {
                    HStack(spacing: DS.xs) {
                        Text(session.state.label)
                            .foregroundStyle(session.state.needsAttention ? AnyShapeStyle(Color.attentionText) : AnyShapeStyle(Color.text2))
                        Text("· " + (session.kind == "Claude Code" ? "Claude" : session.kind)).foregroundStyle(Color.text3)
                    }
                    .font(DS.body)

                    if let d = session.detail {
                        if isCommand {
                            // O momento da app: o comando em curso, como uma linha de terminal.
                            Text("$ " + d)
                                .font(DS.mono).foregroundStyle(Color.primary)
                                .lineLimit(density == .detailed ? 5 : 2)
                                .padding(.horizontal, DS.sm).padding(.vertical, DS.xs)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: DS.rSmall, style: .continuous).fill(DS.raised))
                        } else {
                            Text(d).font(DS.body).foregroundStyle(Color.text2)
                                .lineLimit(density == .detailed ? 5 : 2)
                        }
                    }

                    Text(meta)
                        .font(DS.meta.monospacedDigit()).foregroundStyle(Color.text3)
                        .lineLimit(density == .detailed ? 3 : 1).truncationMode(.tail)
                        .help(m.usage.perSession[session.id].map { u in
                            "Tokens nesta sessão: \(Fmt.tokens(u.total)) · saída \(Fmt.tokens(u.output)) · entrada \(Fmt.tokens(u.input)) · cache lida \(Fmt.tokens(u.cacheRead)) · cache escrita \(Fmt.tokens(u.cacheWrite))"
                        } ?? "")

                    if let p = session.process, !p.children.isEmpty, session.state.isWorking {
                        Text("↳ " + p.children.joined(separator: " · "))
                            .font(DS.mono).foregroundStyle(Color.text3).lineLimit(density == .detailed ? 3 : 1)
                    }
                }
            }
        }
        .cardStyle(padding: density == .compact ? DS.sm : DS.md,
                   highlight: session.state.needsAttention ? Palette.attention.opacity(0.5) : nil)
        .background(RoundedRectangle(cornerRadius: DS.rCard, style: .continuous).fill(hover.value ? DS.surface : .clear))
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
            if let cwd = session.cwd { AgentActions.openFolder(cwd) }
        }
        .accessibilityAction(named: "Mostrar transcript") {
            AgentActions.revealTranscript(session.id)
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
                mini("folder", "Abrir pasta") { AgentActions.openFolder(cwd) }
            }
            mini("doc.text.magnifyingglass", "Mostrar transcript") {
                AgentActions.revealTranscript(session.id)
            }
        }
    }

    private func mini(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(DS.meta).foregroundStyle(Color.text2).frame(width: 20, height: 16)
        }
        .buttonStyle(.plain).help(help)
    }

    @ViewBuilder private var menu: some View {
        if let cwd = session.cwd {
            Button("Abrir pasta no Finder") { AgentActions.openFolder(cwd) }
            Button("Abrir no Terminal") { AgentActions.openInTerminal(cwd) }
            Button("Copiar caminho") { AgentActions.copyPath(cwd) }
        }
        Button("Mostrar transcript") { AgentActions.revealTranscript(session.id) }
        if let p = session.process {
            Divider()
            Button("Terminar agente… (PID \(String(p.pid)))", role: .destructive) { ProcessKiller.confirmAndTerminate(pid: p.pid, name: session.title) }
        }
    }
}
