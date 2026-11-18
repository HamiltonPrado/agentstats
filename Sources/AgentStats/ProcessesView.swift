import SwiftUI
import AppKit

struct ProcessesView: View {
    @EnvironmentObject var m: Monitor
    @AppStorage("proc.sortByMem") private var sortByMem = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let list = sortByMem ? m.topMemory : m.topProcesses
        let maxValue = max(sortByMem ? Double(list.first?.rssKB ?? 1) : (list.first?.cpu ?? 1), 1)

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 2) {
                sortButton("CPU", "cpu", selected: !sortByMem) { sortByMem = false }
                sortButton("Memória", "memorychip", selected: sortByMem) { sortByMem = true }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07)))

            VStack(spacing: 0) {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, p in
                    ProcRow(p: p, sortByMem: sortByMem, maxValue: maxValue)
                    if i < list.count - 1 { Divider().opacity(0.4).padding(.leading, 40) }
                }
            }
            .cardStyle(padding: 4)

            Text("Clique com o botão direito num processo para o terminar.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
        }
    }

    private func sortButton(_ title: String, _ icon: String, selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity).frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? (scheme == .dark ? Color.white.opacity(0.14) : Color.white) : .clear)
                    .shadow(color: .black.opacity(selected ? 0.1 : 0), radius: 1, y: 0.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ProcRow: View {
    @EnvironmentObject var m: Monitor
    let p: ProcSample
    let sortByMem: Bool
    let maxValue: Double
    @StateObject private var hover = Box(false)

    private var app: NSRunningApplication? { NSRunningApplication(processIdentifier: pid_t(p.pid)) }

    var body: some View {
        let running = app
        let fraction = sortByMem ? Double(p.rssKB) / maxValue : p.cpu / maxValue
        HStack(spacing: 10) {
            Group {
                if let icon = running?.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "gearshape.fill").resizable().scaledToFit().padding(4).foregroundStyle(.tertiary)
                }
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(running?.localizedName ?? p.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text("PID \(String(p.pid)) · \(Fmt.etime(p.elapsed))").font(.system(size: 9.5).monospacedDigit()).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 6) {
                    Text(String(format: "%.1f%%", p.cpu))
                        .foregroundStyle(sortByMem ? Color.secondary : (p.cpu > 80 ? Color.red : Color.primary))
                    Text(Fmt.bytes(p.rssKB * 1024))
                        .foregroundStyle(sortByMem ? Color.primary : Color.secondary)
                        .frame(width: 62, alignment: .trailing)
                }
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                Bar(value: fraction, color: sortByMem ? .purple : .blue, height: 3).frame(width: 110)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hover.value ? 0.05 : 0)))
        .onHover { hover.value = $0 }
        .contextMenu {
            Button("Terminar \(running?.localizedName ?? p.name)") { m.terminate(pid: p.pid) }
            Button("Forçar terminação", role: .destructive) { m.terminate(pid: p.pid, force: true) }
            Divider()
            Button("Copiar PID (\(String(p.pid)))") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(p.pid)", forType: .string)
            }
        }
    }
}
