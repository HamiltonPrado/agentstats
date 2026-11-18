import SwiftUI
import AppKit

enum Tab: String, CaseIterable, Identifiable {
    case agents, system, processes, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .agents: return "Agentes"
        case .system: return "Sistema"
        case .processes: return "Processos"
        case .settings: return "Definições"
        }
    }
    var icon: String {
        switch self {
        case .agents: return "sparkles"
        case .system: return "gauge.with.dots.needle.50percent"
        case .processes: return "list.bullet.rectangle"
        case .settings: return "gearshape"
        }
    }
    static let main: [Tab] = [.agents, .system, .processes]
}

struct PanelView: View {
    @EnvironmentObject var m: Monitor
    @Environment(\.colorScheme) private var scheme
    @AppStorage("panel.tab2") private var storedTab: Tab = .agents
    var forcedTab: Tab? = nil
    var scrollable = true
    @StateObject private var contentHeight = Box<CGFloat>(300)
    static let maxContentHeight: CGFloat = 600

    private var tab: Tab { forcedTab ?? storedTab }

    var body: some View {
        VStack(spacing: 0) {
            header
            if tab != .settings { tabBar.padding(.horizontal, 12).padding(.bottom, 10) }
            Divider().opacity(0.6)
            if scrollable {
                // Altura ajusta-se ao conteúdo; só faz scroll acima do máximo.
                ScrollView {
                    content.padding(12)
                        .background(GeometryReader { g in
                            Color.clear.preference(key: ContentHeightKey.self, value: g.size.height)
                        })
                }
                .frame(height: min(max(contentHeight.value, 80), Self.maxContentHeight))
                .onPreferenceChange(ContentHeightKey.self) { h in
                    if abs(h - contentHeight.value) > 0.5 { contentHeight.value = h }
                }
            } else {
                content.padding(12)
            }
            Divider().opacity(0.6)
            footer
        }
        .frame(width: 400)
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .agents: AgentsView()
        case .system: SystemView()
        case .processes: ProcessesView()
        case .settings: SettingsView()
        }
    }

    // MARK: Cabeçalho

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.brand)
                Image(systemName: "sparkles").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(tab == .settings ? "Definições" : "AgentStats").font(.system(size: 13.5, weight: .bold))
                statusLine
            }
            Spacer()
            if tab == .settings {
                IconButton(systemName: "xmark", help: "Fechar definições") { storedTab = .agents }
            } else {
                IconButton(systemName: "gearshape", help: "Definições") { storedTab = .settings }
            }
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
    }

    private var statusLine: some View {
        let working = m.workingCount
        let waiting = m.sessions.filter { $0.state == .waitingUser }.count
        let (text, color): (String, Color) =
            working > 0 ? ("\(working) agente\(working == 1 ? "" : "s") a trabalhar", .green)
            : waiting > 0 ? ("\(waiting) à tua espera", .orange)
            : ("Nenhum agente a trabalhar", .secondary)
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
            Text("·").foregroundStyle(.tertiary)
            Text("CPU \(Fmt.pct(m.cpu.total))").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            if let t = m.temps?.cpuMax {
                Text("· \(String(format: "%.0f°", t))").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Separadores

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(Tab.main) { t in
                Button { withAnimation(.easeInOut(duration: 0.15)) { storedTab = t } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: t.icon).font(.system(size: 10.5, weight: .semibold))
                        Text(t.title).font(.system(size: 11.5, weight: .medium))
                        if t == .agents, m.workingCount > 0 {
                            Text("\(m.workingCount)")
                                .font(.system(size: 9, weight: .bold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(.green))
                        }
                    }
                    .foregroundStyle(tab == t ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity).frame(height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(tab == t ? (scheme == .dark ? Color.white.opacity(0.14) : Color.white) : .clear)
                            .shadow(color: .black.opacity(tab == t ? 0.12 : 0), radius: 1.5, y: 0.5)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.07)))
    }

    // MARK: Rodapé

    private var footer: some View {
        HStack(spacing: 4) {
            Image(systemName: "apple.logo").font(.system(size: 10)).foregroundStyle(.tertiary)
            Text("\(m.machine.replacingOccurrences(of: "Apple ", with: "")) · ligado há \(Fmt.duration(m.uptime))")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
            Spacer()
            IconButton(systemName: "waveform.path.ecg", help: "Abrir Monitor de Atividade") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            }
            IconButton(systemName: "power", help: "Sair do AgentStats") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
