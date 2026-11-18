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
        case .agents: return "terminal"
        case .system: return "gauge.with.needle"
        case .processes: return "list.bullet"
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
            if !m.activeAlerts.isEmpty { AlertBanner(alerts: m.activeAlerts).padding(.horizontal, DS.md).padding(.bottom, DS.sm) }
            if tab != .settings { tabBar.padding(.horizontal, DS.md).padding(.bottom, DS.md) }
            Divider().opacity(0.6)
            if scrollable {
                // Altura ajusta-se ao conteúdo; só faz scroll acima do máximo.
                ScrollView {
                    content.padding(DS.md)
                        .background(GeometryReader { g in
                            Color.clear.preference(key: ContentHeightKey.self, value: g.size.height)
                        })
                }
                .frame(height: min(max(contentHeight.value, 80), Self.maxContentHeight))
                .onPreferenceChange(ContentHeightKey.self) { h in
                    // Altura em passos de 8 pt: variações pequenas do texto a cada amostra não
                    // obrigam o popover a redimensionar (e o macOS a refazer o layout da janela).
                    let snapped = (h / 8).rounded(.up) * 8
                    if snapped != contentHeight.value { contentHeight.value = snapped }
                }
            } else {
                content.padding(DS.md)
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
        HStack(spacing: DS.sm) {
            AppLogo().frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(tab == .settings ? "Definições" : "AgentStats").font(DS.title)
                statusLine
            }
            Spacer()
            if tab == .settings {
                IconButton(systemName: "xmark", help: "Fechar definições") { storedTab = .agents }
            } else {
                IconButton(systemName: "gearshape", help: "Definições") { storedTab = .settings }
            }
        }
        .padding(.horizontal, DS.md).padding(.top, DS.md).padding(.bottom, DS.md)
    }

    private var statusLine: some View {
        let working = m.workingCount
        let waiting = m.sessions.filter { $0.state == .waitingUser }.count
        let attention = m.needsAttentionCount
        let (text, kind): (String, StatusKind) =
            attention > 0 ? ("\(attention) precisa\(attention == 1 ? "" : "m") de ti", .attention)
            : working > 0 ? ("\(working) agente\(working == 1 ? "" : "s") a trabalhar", .working)
            : waiting > 0 ? ("\(waiting) à tua espera", .waiting)
            : ("Nenhum agente a trabalhar", .idle)
        var line = text + " · CPU " + Fmt.pct(m.cpu.total)
        if let t = m.temps?.cpuMax { line += " · " + Fmt.num(t, 0) + "°" }
        return HStack(spacing: DS.sm) {
            StatusDot(kind)
            Text(line).font(DS.meta.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    // MARK: Separadores

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.main) { t in
                Button { withAnimation(Motion.ease(0.16)) { storedTab = t } } label: {
                    HStack(spacing: DS.xs + 2) {
                        Image(systemName: t.icon).font(DS.meta)
                        Text(t.title).font(DS.body.weight(.medium))
                        if t == .agents, m.workingCount + m.needsAttentionCount > 0 {
                            StatusDot(m.needsAttentionCount > 0 ? .attention : .working)
                        }
                    }
                    .foregroundStyle(tab == t ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity).frame(height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: DS.rSmall, style: .continuous)
                            .fill(tab == t ? (scheme == .dark ? Color.white.opacity(0.12) : Color.white) : .clear)
                            .shadow(color: .black.opacity(tab == t ? 0.06 : 0), radius: 1, y: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: DS.rControl, style: .continuous).fill(DS.raised))
    }

    // MARK: Rodapé

    private var footer: some View {
        HStack(spacing: DS.xs) {
            Text("\(m.machine.replacingOccurrences(of: "Apple ", with: "")) · ligado há \(Fmt.duration(m.uptime))")
                .font(DS.meta).foregroundStyle(.tertiary)
            Spacer()
            IconButton(systemName: "waveform.path.ecg", help: "Abrir Monitor de Atividade") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            }
            IconButton(systemName: "power", help: "Sair do AgentStats") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, DS.md).padding(.vertical, DS.xs)
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct AlertBanner: View {
    let alerts: [SystemAlert]
    var body: some View {
        VStack(alignment: .leading, spacing: DS.xs) {
            ForEach(alerts) { a in
                HStack(alignment: .firstTextBaseline, spacing: DS.sm) {
                    Image(systemName: a.kind == .cpu ? "cpu" : "thermometer.high")
                        .font(DS.body).foregroundStyle(Palette.attention).frame(width: 16)
                    Text(a.kind == .cpu ? "CPU alta · \(a.value)" : "Temperatura alta · \(a.value)")
                        .font(DS.body.weight(.medium))
                        .fixedSize().layoutPriority(1)   // o valor nunca quebra; o processo é que encolhe
                    if let d = a.detail {
                        Text(d).font(DS.meta).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                    Text(Fmt.ago(a.since).replacingOccurrences(of: "há ", with: ""))
                        .font(DS.meta.monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, DS.md).padding(.vertical, DS.sm)
        .accessibilityElement(children: .combine)
        .background(RoundedRectangle(cornerRadius: DS.rControl, style: .continuous).fill(Palette.attention.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: DS.rControl, style: .continuous).strokeBorder(Palette.attention.opacity(0.35), lineWidth: 1))
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
            Image(systemName: "gauge.with.needle")
                .font(DS.body).foregroundStyle(.primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: DS.rSmall, style: .continuous).fill(DS.raised))
        }
    }
}
