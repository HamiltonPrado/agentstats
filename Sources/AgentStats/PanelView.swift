import SwiftUI
import AppKit

enum Tab: String, CaseIterable, Identifiable {
    case agents, system, processes, audio, clipboard, capture, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .agents: return "Agentes"
        case .system: return "Sistema"
        case .processes: return "Processos"
        case .audio: return "Áudio"
        case .clipboard: return "Clipboard"
        case .capture: return "Captura"
        case .settings: return "Definições"
        }
    }
    var icon: String {
        switch self {
        case .agents: return "terminal"
        case .system: return "gauge.with.needle"
        case .processes: return "list.bullet"
        case .audio: return "speaker.wave.2"
        case .clipboard: return "list.clipboard"
        case .capture: return "camera.viewfinder"
        case .settings: return "gearshape"
        }
    }
    static let main: [Tab] = [.agents, .system, .processes, .audio, .clipboard, .capture]
}

struct PanelView: View {
    @Environment(Monitor.self) private var m
    @Environment(\.colorScheme) private var scheme
    @AppStorage("panel.tab2") private var storedTab: Tab = .agents
    @AppStorage("appearance.theme") private var themeRawValue = PanelTheme.system.rawValue
    @AppStorage("appearance.accentHex") private var accentHex = "#0A84FF"
    @AppStorage(TextSize.defaultsKey) private var textSizeRaw = TextSize.normal.rawValue
    @AppStorage(PanelWidth.defaultsKey) private var panelWidthRaw = PanelWidth.normal.rawValue
    var forcedTab: Tab? = nil
    var scrollable = true
    @StateObject private var contentHeight = Box<CGFloat>(300)
    static var width: CGFloat { PanelWidth.current.points }
    static let maxContentHeight: CGFloat = 480

    private var tab: Tab { forcedTab ?? storedTab }
    private var selectedTheme: PanelTheme { PanelTheme(rawValue: themeRawValue) ?? .system }
    private var effectiveScheme: ColorScheme { selectedTheme.colorScheme ?? scheme }
    private var accentColor: Color { Color(hexRGB: accentHex) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !m.activeAlerts.isEmpty { AlertBanner(alerts: m.activeAlerts).padding(.horizontal, DS.md).padding(.bottom, DS.sm) }
            if tab != .settings { tabBar.padding(.horizontal, DS.md).padding(.bottom, DS.md) }
            Divider().opacity(0.6)
            if scrollable {
                ScrollView {
                    content.padding(DS.md)
                        .background(GeometryReader { g in
                            Color.clear.preference(key: ContentHeightKey.self, value: g.size.height)
                        })
                }
                // Sem barra de scroll visível: com "Mostrar barras de deslocamento: Sempre" (ou um rato
                // ligado) a barra ocupava ~14 pt à direita e o conteúdo ficava encostado à esquerda.
                // O scroll continua a funcionar com trackpad e roda do rato.
                .scrollIndicators(.never)
                .frame(height: min(max(contentHeight.value, 80), Self.maxContentHeight))
                .onPreferenceChange(ContentHeightKey.self) { h in
                    let snapped = (h / 8).rounded(.up) * 8
                    if snapped != contentHeight.value { contentHeight.value = snapped }
                }
            } else {
                content.padding(DS.md)
            }
            Divider().opacity(0.6)
            footer
        }
        // As fontes da escala DS são lidas quando cada vista se desenha: ao mudar o tamanho do texto,
        // reconstrói-se o painel para todas as vistas as voltarem a ler.
        .id(textSizeRaw)
        .frame(width: (PanelWidth(rawValue: panelWidthRaw) ?? .normal).points)
        .environment(\.agentAccentColor, accentColor)
        .tint(accentColor)
        .preferredColorScheme(selectedTheme.colorScheme)
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .agents: AgentsView()
        case .system: SystemView()
        case .processes: ProcessesView()
        case .audio: AudioView()
        case .clipboard: ClipboardView(store: .shared)
        case .capture: CaptureView(store: .shared)
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
                    // Só o ícone, numa caixa fixa: os símbolos têm larguras diferentes e assim ficam todos
                    // centrados. O ponto de estado fica sobreposto, sem mexer na centragem.
                    Image(systemName: t.icon)
                        .font(.system(size: 14 * TextSize.current.scale, weight: .medium))
                        .frame(width: 20, height: 20)
                        .overlay(alignment: .topTrailing) {
                            if t == .agents, let kind = agentsBadge {
                                StatusDot(kind, size: 6).offset(x: 6, y: -1)
                            }
                        }
                        .foregroundStyle(tab == t ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity).frame(height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: DS.rSmall, style: .continuous)
                                .fill(tab == t ? (effectiveScheme == .dark ? Color.white.opacity(0.12) : Color.white) : .clear)
                                .shadow(color: .black.opacity(tab == t ? 0.06 : 0), radius: 1, y: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Sem texto visível, o nome tem de vir na dica e no VoiceOver.
                .help(t.title)
                .accessibilityLabel(t.title)
                .accessibilityValue(t == .agents ? agentsBadgeDescription : "")
                .accessibilityAddTraits(tab == t ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: DS.rControl, style: .continuous).fill(DS.raised))
    }

    private var agentsBadge: StatusKind? {
        m.needsAttentionCount > 0 ? .attention : m.workingCount > 0 ? .working : nil
    }

    private var agentsBadgeDescription: String {
        m.needsAttentionCount > 0 ? "Precisa de ti" : m.workingCount > 0 ? "A trabalhar" : ""
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
                    Image(systemName: a.kind == .cpu ? "cpu" : a.kind == .temp ? "thermometer.high" : a.kind == .memory ? "memorychip" : a.kind == .disk ? "internaldrive" : "battery.25")
                        .font(DS.body).foregroundStyle(Palette.attention).frame(width: 16)
                    Text("\(a.kind.label) · \(a.value)")
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
