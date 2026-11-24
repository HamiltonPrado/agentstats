import SwiftUI
import AppKit

struct ActivityHistoryRow: View {
    @Environment(Monitor.self) private var m
    let record: AgentActivityRecord

    private var eventSummary: String {
        record.events.suffix(3).map { $0.phase.title }.joined(separator: " → ")
    }

    private var timeRange: String {
        let start = String(localized: "Início \(Fmt.ago(record.firstSeen))")
        return start + (record.endedAt.map { String(localized: " · fim \(Fmt.ago($0))") } ?? " · em curso")
    }

    var body: some View {
        HStack(alignment: .top, spacing: DS.sm) {
            Image(systemName: record.phase == .finished ? "checkmark.circle" : record.phase.shouldRemind ? "hourglass" : "clock")
                .font(DS.body).foregroundStyle(record.phase.shouldRemind ? Color.attentionText : Color.text2)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(L(record.title)).font(DS.body.weight(.medium)).lineLimit(1)
                Text("\(record.kind) · \(record.project) · \(record.phase.title)")
                    .font(DS.meta).foregroundStyle(Color.text2).lineLimit(1)
                Text(L(timeRange)).font(DS.meta).foregroundStyle(Color.text3).lineLimit(1)
                if record.events.count > 1 {
                    Text(L(eventSummary)).font(DS.meta).foregroundStyle(Color.text3).lineLimit(1)
                }
            }
            Spacer(minLength: DS.xs)
            VStack(alignment: .trailing, spacing: 3) {
                Text(L(Fmt.duration(record.duration()))).font(DS.meta.monospacedDigit())
                Text(record.tokens > 0 ? Fmt.tokens(record.tokens) + " tokens" : L("sem tokens"))
                    .font(DS.meta.monospacedDigit()).foregroundStyle(Color.text3)
            }
        }
        .padding(.horizontal, DS.md).padding(.vertical, DS.sm)
        .background(RoundedRectangle(cornerRadius: DS.rControl, style: .continuous).fill(DS.surface))
        .contentShape(Rectangle())
        .onTapGesture {
            if let session = m.sessions.first(where: { $0.id == record.id }) {
                AppState.controller?.open(session)
            } else if let cwd = record.cwd {
                AgentActions.openFolder(cwd)
            } else if let path = AgentActions.transcriptPath(record.id) {
                AgentActions.revealTranscript(path)
            }
        }
        .help("Observada pela primeira vez \(Fmt.ago(record.firstSeen)); duração medida pela app")
        .accessibilityElement(children: .combine)
    }
}
