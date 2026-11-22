import SwiftUI
import AppKit

struct ProcessesView: View {
    @Environment(Monitor.self) private var m
    @AppStorage("proc.sortByMem") private var sortByMem = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let list = Array((sortByMem ? m.topMemory : m.topProcesses).prefix(10))
        let maxValue = max(sortByMem ? Double(list.first?.rssKB ?? 1) : (list.first?.cpu ?? 1), 1)

        VStack(alignment: .leading, spacing: DS.md) {
            HStack(spacing: 0) {
                sortButton("CPU", selected: !sortByMem) { sortByMem = false }
                sortButton("Memória", selected: sortByMem) { sortByMem = true }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: DS.rControl, style: .continuous).fill(DS.raised))

            VStack(spacing: 0) {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, p in
                    ProcRow(p: p, sortByMem: sortByMem, maxValue: maxValue)
                    if i < list.count - 1 { Divider().opacity(0.4).padding(.leading, 36) }
                }
            }
            .cardStyle(padding: DS.xs)

            Text("Botão direito num processo para o terminar")
                .font(DS.meta).foregroundStyle(Color.text3)
                .frame(maxWidth: .infinity)
        }
    }

    private func sortButton(_ title: String, selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(DS.body.weight(.medium))
                .foregroundStyle(selected ? Color.primary : Color.text2)
                .frame(maxWidth: .infinity).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: DS.rSmall, style: .continuous)
                    .fill(selected ? (scheme == .dark ? Color.white.opacity(0.12) : Color.white) : .clear)
                    .shadow(color: .black.opacity(selected ? 0.06 : 0), radius: 1, y: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ProcRow: View {
    @Environment(Monitor.self) private var m
    let p: ProcSample
    let sortByMem: Bool
    let maxValue: Double
    @StateObject private var hover = Box(false)

    var body: some View {
        let running = AppInfo.lookup(p.pid)
        let fraction = sortByMem ? Double(p.rssKB) / maxValue : p.cpu / maxValue
        let metricWidth: CGFloat = 104   // CPU 44 + memória 56 + espaço; o resto fica para o nome
        HStack(spacing: DS.md) {
            Group {
                if let icon = running.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "gearshape").resizable().scaledToFit().padding(2).foregroundStyle(Color.text3)
                }
            }
            .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(running.name ?? p.name).font(DS.body).lineLimit(1)
                Text("PID \(String(p.pid)) · \(Fmt.etime(p.elapsed))")
                    .font(DS.meta.monospacedDigit()).foregroundStyle(Color.text3)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            Spacer(minLength: DS.sm)
            VStack(alignment: .trailing, spacing: DS.xs) {
                HStack(spacing: DS.xs) {
                    Text(Fmt.num(p.cpu, 1) + "%")
                        .foregroundStyle(sortByMem ? Color.text2 : (p.cpu > 80 ? Color.attentionText : Color.primary))
                        .frame(width: 44, alignment: .trailing)
                        .lineLimit(1).minimumScaleFactor(0.75)
                    Text(Fmt.bytesShort(p.rssKB * 1024))
                        .foregroundStyle(sortByMem ? Color.primary : Color.text2)
                        .frame(width: 56, alignment: .trailing)
                        .lineLimit(1).minimumScaleFactor(0.75)
                }
                .font(DS.body.monospacedDigit())
                Bar(value: fraction, color: .accentColor, height: 2).frame(width: metricWidth)
            }
            .frame(width: metricWidth, alignment: .trailing)
        }
        .padding(.horizontal, DS.sm).padding(.vertical, DS.sm)
        .background(RoundedRectangle(cornerRadius: DS.rControl).fill(hover.value ? DS.surface : .clear))
        .onHover { hover.value = $0 }
        .contextMenu {
            Button("Terminar \(running.name ?? p.name)…") { ProcessKiller.confirmAndTerminate(pid: p.pid, name: running.name ?? p.name) }
            Button("Forçar terminação…", role: .destructive) { ProcessKiller.confirmAndTerminate(pid: p.pid, name: running.name ?? p.name, force: true) }
            Divider()
            Button("Copiar PID (\(String(p.pid)))") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(p.pid)", forType: .string)
            }
        }
    }
}
