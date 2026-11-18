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
    @Environment(Monitor.self) private var m
    @Environment(\.colorScheme) private var scheme
    @AppStorage("panel.tab2") private var storedTab: Tab = .agents
    var forcedTab: Tab? = nil
    var scrollable = true
    @StateObject private var contentHeight = Box<CGFloat>(300)
    static let maxContentHeight: CGFloat = 480
    static let width: CGFloat = 340

    private var tab: Tab { forcedTab ?? storedTab }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !m.activeAlerts.isEmpty { AlertBanner(alerts: m.activeAlerts).padding(.horizontal, 10).padding(.bottom, 8) }
            if tab != .settings { tabBar.padding(.horizontal, 10).padding(.bottom, 8) }
            Divider().opacity(0.6)
            if scrollable {
                // Altura ajusta-se ao conteúdo; só faz scroll acima do máximo.
                ScrollView {
                    content.padding(10)
                        .background(GeometryReader { g in
                            Color.clear.preference(key: ContentHeightKey.self, value: g.size.height)
                        })
                }
                .frame(height: min(max(contentHeight.value, 80), Self.maxContentHeight))
                .onPreferenceChange(ContentHeightKey.self) { h in
                    if abs(h - contentHeight.value) > 0.5 { contentHeight.value = h }
                }
            } else {
                content.padding(10)
            }
            Divider().opacity(0.6)
            footer
        }
        .frame(width: Self.width)
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
        HStack(spacing: 8) {
            AppLogo().frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(tab == .settings ? "Definições" : "AgentStats").font(.system(size: 12.5, weight: .bold))
                statusLine
            }
            Spacer()
            if tab == .settings {
                IconButton(systemName: "xmark", help: "Fechar definições") { storedTab = .agents }
            } else {
                IconButton(systemName: "gearshape", help: "Definições") { storedTab = .settings }
            }
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
    }

    private var statusLine: some View {
        let working = m.workingCount
        let waiting = m.sessions.filter { $0.state == .waitingUser }.count
        let attention = m.needsAttentionCount
        let (text, color): (String, Color) =
            attention > 0 ? ("\(attention) precisa\(attention == 1 ? "" : "m") de ti", .red)
            : working > 0 ? ("\(working) agente\(working == 1 ? "" : "s") a trabalhar", .green)
            : waiting > 0 ? ("\(waiting) à tua espera", .orange)
            : ("Nenhum agente a trabalhar", .secondary)
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            Text("·").foregroundStyle(.tertiary)
            Text("CPU \(Fmt.pct(m.cpu.total))").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
            if let t = m.temps?.cpuMax {
                Text("· \(String(format: "%.0f°", t))").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Separadores

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(Tab.main) { t in
                Button { withAnimation(.easeInOut(duration: 0.15)) { storedTab = t } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: t.icon).font(.system(size: 10, weight: .semibold))
                        Text(t.title).font(.system(size: 11, weight: .medium))
                        if t == .agents, m.workingCount > 0 {
                            Text("\(m.workingCount)")
                                .font(.system(size: 9, weight: .bold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(.green))
                        }
                    }
                    .foregroundStyle(tab == t ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity).frame(height: 22)
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
        .padding(.horizontal, 10).padding(.vertical, 3)
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct AlertBanner: View {
    let alerts: [SystemAlert]
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(alerts) { a in
                HStack(spacing: 6) {
                    Image(systemName: a.kind == .cpu ? "cpu" : "thermometer.high")
                        .font(.system(size: 10, weight: .bold))
                    Text(a.kind == .cpu ? "CPU alta · \(a.value)" : "Temperatura alta · \(a.value)")
                        .font(.system(size: 11, weight: .semibold))
                    if let d = a.detail {
                        Text(d).font(.system(size: 10.5)).opacity(0.8).lineLimit(1).truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                    Text(Fmt.ago(a.since).replacingOccurrences(of: "há ", with: ""))
                        .font(.system(size: 9.5).monospacedDigit()).opacity(0.7)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(LinearGradient(colors: [.red, .orange], startPoint: .leading, endPoint: .trailing)))
    }
}

/// Ícone da app (o mesmo do Finder). O .icns tem margem à volta do corpo, por isso é ampliado
/// para o corpo ocupar o espaço todo.
struct AppLogo: View {
    private static let icon: NSImage? = Bundle.main.image(forResource: "AppIcon")
    var body: some View {
        if let icon = Self.icon {
            Image(nsImage: icon).resizable().interpolation(.high)
                .scaleEffect(1024 / 824)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.brand)
                Image(systemName: "sparkles").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
            }
        }
    }
}
