import SwiftUI
import AppKit

struct OtherAgentRow: View {
    @Environment(Monitor.self) private var m
    let agent: AgentProcess

    private var title: String {
        agent.kind + (agent.role == "app" ? " · app ChatGPT" : agent.role == "executor" ? " · executor" : agent.isSubagent ? " · subagente" : "")
    }
    private var subtitle: String {
        if agent.role == "app" {
            let n = m.sessions.filter { $0.kind == agent.kind && $0.state.isWorking }.count
            return n > 0 ? String(localized: "\(n) tarefa\(n == 1 ? "" : "s") em curso") : "Aberto, sem tarefas em curso"
        }
        return agent.cwd.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? String(localized: "PID \(String(agent.pid))")
    }

    var body: some View {
        HStack(spacing: DS.md) {
            Image(systemName: agent.isSubagent ? "arrow.turn.down.right" : "terminal")
                .font(DS.body).foregroundStyle(Color.text2)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: DS.rSmall, style: .continuous).fill(DS.raised))
            VStack(alignment: .leading, spacing: 2) {
                Text(L(title)).font(DS.title)
                Text(L(subtitle)).font(DS.meta).foregroundStyle(Color.text2).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(L(Fmt.num(agent.cpu, 0) + "% CPU")).font(DS.body.monospacedDigit())
                Text(L(Fmt.etime(agent.elapsed))).font(DS.meta.monospacedDigit()).foregroundStyle(Color.text3)
            }
        }
        .cardStyle()
        .accessibilityElement(children: .combine)
        .contextMenu {
            Button("Terminar processo… (PID \(String(agent.pid)))", role: .destructive) { ProcessKiller.confirmAndTerminate(pid: agent.pid, name: agent.kind) }
        }
    }
}
