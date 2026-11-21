import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @Environment(Monitor.self) private var m
    @AppStorage("bar.agents") var showAgents = true
    @AppStorage("bar.cpu") var showCPU = true
    @AppStorage("bar.ram") var showRAM = true
    @AppStorage("bar.temp") var showTemp = true
    @AppStorage("bar.gpu") var showGPU = false
    @AppStorage("bar.net") var showNet = true
    @AppStorage("bar.battery") var showBattery = false
    @AppStorage(MenuBarDrawer.metricOrderKey) private var barOrder = "agents,cpu,ram,gpu,temp,net,battery"
    @AppStorage("panel.showUsage") private var showUsage = true
    @AppStorage("panel.showActivity") private var showActivity = true
    @AppStorage("agents.showRecentSection") private var showRecentSection = true
    @AppStorage("agents.showHistorySection") private var showHistorySection = true
    @AppStorage("panel.density") private var densityRawValue = PanelDensity.normal.rawValue
    @AppStorage("appearance.theme") private var appearanceThemeRaw = PanelTheme.system.rawValue
    @AppStorage("appearance.accentHex") private var accentHex = "#0A84FF"
    @AppStorage("profiles.active") private var activeProfile = "custom"
    @AppStorage("profiles.work") private var workProfileData = ""
    @AppStorage("profiles.monitoring") private var monitoringProfileData = ""
    @AppStorage(GlobalHotKey.defaultsKey) var hotkey = GlobalHotKey.defaultPreset
    @AppStorage("settings.section") private var sectionRaw = SettingsSection.general.rawValue
    @AppStorage(MenuBarStyle.defaultsKey) private var barStyle = MenuBarStyle.labeled.rawValue
    @AppStorage(MenuBarDrawer.colorDotKey) private var colorDot = false
    @AppStorage(PanelWidth.defaultsKey) private var panelWidth = PanelWidth.normal.rawValue
    @AppStorage(TextSize.defaultsKey) private var textSize = TextSize.normal.rawValue
    @StateObject private var login = Box(SMAppService.mainApp.status == .enabled)
    @StateObject private var loginErr = Box<String?>(nil)
    @StateObject private var savedProfile = Box<String?>(nil)

    var body: some View {
        VStack(alignment: .leading, spacing: DS.lg) {
            sectionPicker
            switch SettingsSection(rawValue: sectionRaw) ?? .general {
            case .general: generalSection
            case .menuBar: menuBarSection
            case .panel: panelSection
            case .appearance: appearanceSection
            case .alerts: alertsSection
            }
            HStack {
                Text("AgentStats " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")).font(DS.meta).foregroundStyle(.tertiary)
                Spacer()
                Link("Código no GitHub", destination: URL(string: "https://github.com/HamiltonPrado/agentstats")!)
                    .font(DS.meta)
            }
            .padding(.horizontal, DS.xs)
        }
        .onChange(of: currentSnapshot) { _, _ in savedProfile.value = nil }
    }

    /// Bindings para as definições guardadas no Monitor.
    private var bm: Bindable<Monitor> { Bindable(m) }

    /// Seletor das secções, no mesmo estilo dos separadores do painel.
    private var sectionPicker: some View {
        HStack(spacing: 0) {
            ForEach(SettingsSection.allCases) { section in
                let selected = sectionRaw == section.rawValue
                Button { withAnimation(Motion.ease(0.16)) { sectionRaw = section.rawValue } } label: {
                    Text(section.title)
                        .font(DS.meta.weight(.medium)).lineLimit(1)
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity).frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: DS.rSmall, style: .continuous)
                            .fill(selected ? DS.raised : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: DS.rControl, style: .continuous).fill(DS.surface))
    }

    @ViewBuilder private var generalSection: some View {
        VStack(alignment: .leading, spacing: DS.lg) {
            group("Geral") {
                VStack(alignment: .leading, spacing: DS.md) {
                    HStack(spacing: DS.md) {
                        icon("arrow.clockwise")
                        Text("Atualizar a cada").font(DS.body)
                        Spacer()
                        Picker("", selection: bm.refreshInterval) {
                            Text("1 s").tag(1.0); Text("2 s").tag(2.0); Text("5 s").tag(5.0)
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 128)
                    }
                    row("bell", "Notificações", "Ao terminar e quando precisa de ti", bm.notifyOnFinish)
                    HStack(spacing: DS.md) {
                        icon("keyboard")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Atalho para abrir o painel").font(DS.body)
                            Text("Funciona em qualquer app").font(DS.meta).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Picker("", selection: $hotkey) {
                            Text("Desligado").tag("off")
                            ForEach(GlobalHotKey.presets, id: \.key) { p in Text(p.combo.label).tag(p.key) }
                        }
                        .labelsHidden().frame(width: 104)
                    }
                    row("power", "Abrir ao iniciar sessão", nil, Binding(
                        get: { login.value },
                        set: { on in
                            do {
                                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                                login.value = on; loginErr.value = nil
                            } catch { loginErr.value = error.localizedDescription }
                        }))
                    if let e = loginErr.value { Text(e).font(DS.meta).foregroundStyle(.red) }
                }
            }
            group("Energia") {
                VStack(alignment: .leading, spacing: DS.md) {
                    row("moon.zzz", "Manter o Mac acordado", "Termina automaticamente após o período", Binding(
                        get: { m.keepAwake }, set: { m.keepAwake = $0 }))
                    if m.keepAwake {
                        HStack(spacing: DS.md) {
                            icon("timer")
                            Text("Duração").font(DS.body)
                            Spacer()
                            Picker("Duração", selection: bm.keepAwakeMinutes) {
                                Text("30 min").tag(30.0); Text("1 hora").tag(60.0)
                                Text("2 horas").tag(120.0); Text("Sem limite").tag(0.0)
                            }.labelsHidden().frame(width: 118)
                        }
                    }
                }
            }
            group("Perfis") {
                VStack(alignment: .leading, spacing: DS.md) {
                    HStack(spacing: DS.md) {
                        icon("square.stack.3d.up")
                        Text("Perfil atual").font(DS.body)
                        Spacer()
                        Picker("Perfil atual", selection: Binding(
                            get: { activeProfile },
                            set: { selectProfile($0) }
                        )) {
                            Text("Manual").tag("custom")
                            Text("Trabalho").tag("work")
                            Text("Monitorização").tag("monitoring")
                        }
                        .labelsHidden().frame(width: 132)
                    }
                    Button { saveActiveProfile() } label: {
                        let didSave = savedProfile.value == activeProfile
                        // Mesma coluna de ícone (16 pt) e espaçamento das outras linhas, para alinhar
                        HStack(spacing: DS.md) {
                            icon(didSave ? "checkmark.circle" : "square.and.arrow.down")
                            Text(didSave ? "Perfil guardado" : "Guardar alterações no perfil").font(DS.body)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(activeProfile == "custom")
                    Text("Aplica Trabalho ou Monitorização e guarda aqui as alterações feitas.")
                        .font(DS.meta).foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder private var menuBarSection: some View {
        VStack(alignment: .leading, spacing: DS.lg) {
            group("Barra de menus") {
                VStack(alignment: .leading, spacing: DS.md) {
                    MenuBarLabel()
                        .padding(.horizontal, DS.sm).padding(.vertical, DS.xs)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .background(RoundedRectangle(cornerRadius: DS.rSmall, style: .continuous).fill(DS.raised))
                        .help("Pré-visualização")
                    HStack(spacing: DS.md) {
                        icon("textformat.size")
                        Text("Estilo").font(DS.body)
                        Spacer(minLength: DS.xs)
                        Picker("Estilo", selection: $barStyle) {
                            ForEach(MenuBarStyle.allCases) { Text($0.title).tag($0.rawValue) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    row("circle.fill", "Ponto dos agentes a cores", "Verde a trabalhar, vermelho quando precisa de ti", $colorDot)
                    Divider().opacity(0.5)
                    ForEach(Array(orderedMetrics.enumerated()), id: \.element.id) { index, metric in
                        HStack(spacing: DS.md) {
                            icon(metric.icon)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(metric.title).font(DS.body)
                                if let subtitle = metric.subtitle {
                                    Text(subtitle).font(DS.meta).foregroundStyle(.tertiary)
                                }
                            }
                            Spacer(minLength: DS.xs)
                            Button { moveMetric(from: index, by: -1) } label: {
                                Image(systemName: "arrow.up").font(DS.meta)
                            }
                            .buttonStyle(.plain).disabled(index == 0)
                            .help("Mover \(metric.title) para cima")
                            .accessibilityLabel("Mover \(metric.title) para cima")
                            Button { moveMetric(from: index, by: 1) } label: {
                                Image(systemName: "arrow.down").font(DS.meta)
                            }
                            .buttonStyle(.plain).disabled(index == orderedMetrics.count - 1)
                            .help("Mover \(metric.title) para baixo")
                            .accessibilityLabel("Mover \(metric.title) para baixo")
                            Toggle("", isOn: metric.isEnabled)
                                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var panelSection: some View {
        VStack(alignment: .leading, spacing: DS.lg) {
            group("Conteúdo do painel") {
                VStack(alignment: .leading, spacing: DS.md) {
                    HStack(spacing: DS.md) {
                        icon("arrow.left.and.right")
                        Text("Largura").font(DS.body).lineLimit(1).fixedSize().layoutPriority(1)
                        Spacer(minLength: DS.xs)
                        Picker("Largura", selection: $panelWidth) {
                            ForEach(PanelWidth.allCases) { Text($0.title).tag($0.rawValue) }
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 200)
                    }
                    HStack(spacing: DS.md) {
                        icon("textformat.size")
                        Text("Texto").font(DS.body).lineLimit(1).fixedSize().layoutPriority(1)
                        Spacer(minLength: DS.xs)
                        Picker("Tamanho do texto", selection: $textSize) {
                            ForEach(TextSize.allCases) { Text($0.title).tag($0.rawValue) }
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 200)
                    }
                    Divider().opacity(0.5)
                    HStack(spacing: DS.md) {
                        icon("rectangle.compress.vertical")
                        Text("Densidade").font(DS.body).lineLimit(1)
                        Spacer(minLength: DS.xs)
                        Picker("Densidade", selection: $densityRawValue) {
                            ForEach(PanelDensity.allCases) { density in
                                Text(density.title).tag(density.rawValue)
                            }
                        }
                        .pickerStyle(.menu).labelsHidden().frame(width: 110, alignment: .trailing)
                    }
                    row("number", "Utilização de tokens", "Resumo diário e semanal", $showUsage)
                    row("chart.bar", "Atividade nas últimas 24 h", nil, $showActivity)
                    row("clock.arrow.circlepath", "Sessões recentes", nil, $showRecentSection)
                    row("clock", "Histórico de agentes", nil, $showHistorySection)
                }
            }
        }
    }

    @ViewBuilder private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: DS.lg) {
            group("Aparência") {
                VStack(alignment: .leading, spacing: DS.md) {
                    HStack(spacing: DS.md) {
                        icon("circle.lefthalf.filled")
                        Text("Tema").font(DS.body)
                        Spacer()
                        Picker("Tema", selection: $appearanceThemeRaw) {
                            ForEach(PanelTheme.allCases) { theme in
                                Text(theme.title).tag(theme.rawValue)
                            }
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 186)
                    }
                    HStack(spacing: DS.md) {
                        icon("paintpalette")
                        Text("Cor de destaque").font(DS.body)
                        Spacer()
                        ColorPicker("Cor de destaque", selection: accentColorBinding, supportsOpacity: false)
                            .labelsHidden()
                    }
                }
            }
        }
    }

    @ViewBuilder private var alertsSection: some View {
        VStack(alignment: .leading, spacing: DS.lg) {
            group("Alertas") {
                VStack(alignment: .leading, spacing: DS.md) {
                    row("cpu", "CPU alta", "Notifica após 20 s acima do limite", bm.cpuAlertEnabled)
                    if m.cpuAlertEnabled {
                        Picker("", selection: bm.cpuThreshold) {
                            Text("70%").tag(0.7); Text("80%").tag(0.8); Text("85%").tag(0.85); Text("90%").tag(0.9); Text("95%").tag(0.95)
                        }
                        .pickerStyle(.segmented).labelsHidden().padding(.leading, 28)
                    }
                    row("thermometer.high", "Temperatura alta", "Máximo da CPU", bm.tempAlertEnabled)
                    if m.tempAlertEnabled {
                        Picker("", selection: bm.tempThreshold) {
                            Text("75°").tag(75.0); Text("80°").tag(80.0); Text("85°").tag(85.0); Text("90°").tag(90.0); Text("95°").tag(95.0)
                        }
                        .pickerStyle(.segmented).labelsHidden().padding(.leading, 28)
                    }
                    row("memorychip", "Memória alta", "Alerta após 20 s acima do limite", bm.memoryAlertEnabled)
                    if m.memoryAlertEnabled {
                        Picker("", selection: bm.memoryThreshold) {
                            Text("80%").tag(0.8); Text("85%").tag(0.85); Text("90%").tag(0.9); Text("95%").tag(0.95)
                        }.pickerStyle(.segmented).labelsHidden().padding(.leading, 28)
                    }
                    row("internaldrive", "Pouco espaço em disco", "Quando o espaço livre fica baixo", bm.diskAlertEnabled)
                    if m.diskAlertEnabled {
                        Picker("", selection: bm.diskThreshold) {
                            Text("10% livre").tag(0.9); Text("5% livre").tag(0.95); Text("2% livre").tag(0.98)
                        }.pickerStyle(.segmented).labelsHidden().padding(.leading, 28)
                    }
                    row("battery.25", "Bateria fraca", "Só sem carregador ligado", bm.batteryAlertEnabled)
                    if m.batteryAlertEnabled {
                        Picker("", selection: bm.batteryThreshold) {
                            Text("25%").tag(0.25); Text("20%").tag(0.2); Text("15%").tag(0.15); Text("10%").tag(0.1)
                        }.pickerStyle(.segmented).labelsHidden().padding(.leading, 28)
                    }
                    row("hourglass", "Lembretes de espera", "Avisa se um agente continuar à espera", bm.waitingAlertEnabled)
                    if m.waitingAlertEnabled {
                        HStack(spacing: DS.md) {
                            icon("bell.badge")
                            Text("Lembrar após").font(DS.body)
                            Spacer()
                            Picker("", selection: bm.waitingAlertMinutes) {
                                Text("3 min").tag(3.0); Text("5 min").tag(5.0); Text("10 min").tag(10.0)
                            }
                            .pickerStyle(.segmented).labelsHidden().frame(width: 150)
                        }
                        .padding(.leading, 28)
                    }
                }
            }
        }
    }


    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            Text(title).font(DS.meta.weight(.medium)).foregroundStyle(.secondary)
                .padding(.leading, DS.xs)
            content().cardStyle()
        }
    }

    private var metricSettings: [MenuBarMetricSetting] {
        [
            .init(id: "agents", icon: "terminal", title: "Agentes", subtitle: "A trabalhar e total", isEnabled: $showAgents),
            .init(id: "cpu", icon: "cpu", title: "CPU", isEnabled: $showCPU),
            .init(id: "ram", icon: "memorychip", title: "Memória", isEnabled: $showRAM),
            .init(id: "temp", icon: "thermometer.medium", title: "Temperatura", subtitle: "Máximo da CPU", isEnabled: $showTemp),
            .init(id: "gpu", icon: "cube", title: "GPU", isEnabled: $showGPU),
            .init(id: "net", icon: "network", title: "Rede", subtitle: "Upload e download", isEnabled: $showNet),
            .init(id: "battery", icon: "battery.75percent", title: "Bateria", isEnabled: $showBattery),
        ]
    }

    private var orderedMetrics: [MenuBarMetricSetting] {
        let byID = Dictionary(uniqueKeysWithValues: metricSettings.map { ($0.id, $0) })
        let defaults = metricSettings.map(\.id)
        var seen = Set<String>()
        var ids = barOrder.split(separator: ",").map(String.init)
            .filter { byID[$0] != nil && seen.insert($0).inserted }
        ids += defaults.filter { seen.insert($0).inserted }
        return ids.compactMap { byID[$0] }
    }

    private var accentColorBinding: Binding<Color> {
        Binding(get: { Color(hexRGB: accentHex) }, set: { accentHex = $0.hexRGB })
    }

    private var currentSnapshot: SettingsSnapshot {
        SettingsSnapshot(
            barOrder: barOrder,
            showAgents: showAgents, showCPU: showCPU, showRAM: showRAM, showTemp: showTemp,
            showGPU: showGPU, showNet: showNet, showBattery: showBattery,
            showUsage: showUsage, showActivity: showActivity,
            showRecentSection: showRecentSection, showHistorySection: showHistorySection,
            density: densityRawValue, theme: appearanceThemeRaw, accentHex: accentHex
        )
    }

    private func selectProfile(_ profile: String) {
        savedProfile.value = nil
        activeProfile = profile
        guard profile != "custom" else { return }

        let saved = profile == "work" ? workProfileData : monitoringProfileData
        if let data = saved.data(using: .utf8), let snapshot = try? JSONDecoder().decode(SettingsSnapshot.self, from: data) {
            apply(snapshot)
        } else {
            apply(profile == "work" ? .workDefault : .monitoringDefault)
        }
    }

    private func saveActiveProfile() {
        guard activeProfile != "custom",
              let data = try? JSONEncoder().encode(currentSnapshot),
              let json = String(data: data, encoding: .utf8) else { return }
        if activeProfile == "work" { workProfileData = json }
        else { monitoringProfileData = json }
        savedProfile.value = activeProfile
    }

    private func apply(_ snapshot: SettingsSnapshot) {
        barOrder = snapshot.barOrder
        showAgents = snapshot.showAgents; showCPU = snapshot.showCPU; showRAM = snapshot.showRAM
        showTemp = snapshot.showTemp; showGPU = snapshot.showGPU; showNet = snapshot.showNet
        showBattery = snapshot.showBattery
        showUsage = snapshot.showUsage; showActivity = snapshot.showActivity
        showRecentSection = snapshot.showRecentSection; showHistorySection = snapshot.showHistorySection
        densityRawValue = snapshot.density
        appearanceThemeRaw = snapshot.theme
        accentHex = snapshot.accentHex
    }

    private func moveMetric(from index: Int, by offset: Int) {
        var ids = orderedMetrics.map(\.id)
        let destination = index + offset
        guard ids.indices.contains(index), ids.indices.contains(destination) else { return }
        ids.swapAt(index, destination)
        barOrder = ids.joined(separator: ",")
    }

    /// Ícones de linha, todos do mesmo tamanho e na cor do texto secundário.
    private func icon(_ name: String) -> some View {
        Image(systemName: name).font(DS.body).foregroundStyle(.secondary).frame(width: 16)
    }

    private func row(_ iconName: String, _ title: String, _ sub: String?, _ binding: Binding<Bool>) -> some View {
        HStack(spacing: DS.md) {
            icon(iconName)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(DS.body).lineLimit(1)
                if let sub { Text(sub).font(DS.meta).foregroundStyle(.tertiary).lineLimit(2) }
            }
            Spacer()
            Toggle("", isOn: binding).toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
    }
}

private struct MenuBarMetricSetting: Identifiable {
    let id: String
    let icon: String
    let title: String
    var subtitle: String? = nil
    let isEnabled: Binding<Bool>
}

private struct SettingsSnapshot: Codable, Equatable {
    let barOrder: String
    let showAgents: Bool
    let showCPU: Bool
    let showRAM: Bool
    let showTemp: Bool
    let showGPU: Bool
    let showNet: Bool
    let showBattery: Bool
    let showUsage: Bool
    let showActivity: Bool
    let showRecentSection: Bool
    let showHistorySection: Bool
    let density: String
    let theme: String
    let accentHex: String

    static let workDefault = SettingsSnapshot(
        barOrder: "agents,cpu,ram,temp,net,gpu,battery",
        showAgents: true, showCPU: true, showRAM: true, showTemp: true,
        showGPU: false, showNet: true, showBattery: false,
        showUsage: true, showActivity: false, showRecentSection: true, showHistorySection: false,
        density: PanelDensity.compact.rawValue, theme: PanelTheme.system.rawValue, accentHex: "#0A84FF"
    )

    static let monitoringDefault = SettingsSnapshot(
        barOrder: "agents,cpu,ram,gpu,temp,net,battery",
        showAgents: true, showCPU: true, showRAM: true, showTemp: true,
        showGPU: true, showNet: true, showBattery: true,
        showUsage: true, showActivity: true, showRecentSection: true, showHistorySection: true,
        density: PanelDensity.detailed.rawValue, theme: PanelTheme.dark.rawValue, accentHex: "#0A84FF"
    )
}

/// Secções das Definições.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, menuBar, panel, appearance, alerts
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "Geral"
        case .menuBar: "Barra"
        case .panel: "Painel"
        case .appearance: "Aspeto"
        case .alerts: "Alertas"
        }
    }
}
