import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @Environment(Monitor.self) private var m
    @AppStorage(MenuBarMetric.agents.key) var showAgents = MenuBarMetric.agents.defaultOn
    @AppStorage(MenuBarMetric.cpu.key) var showCPU = MenuBarMetric.cpu.defaultOn
    @AppStorage(MenuBarMetric.ram.key) var showRAM = MenuBarMetric.ram.defaultOn
    @AppStorage(MenuBarMetric.temp.key) var showTemp = MenuBarMetric.temp.defaultOn
    @AppStorage(MenuBarMetric.gpu.key) var showGPU = MenuBarMetric.gpu.defaultOn
    @AppStorage(MenuBarMetric.net.key) var showNet = MenuBarMetric.net.defaultOn
    @AppStorage(MenuBarMetric.battery.key) var showBattery = MenuBarMetric.battery.defaultOn
    @AppStorage(MenuBarDrawer.metricOrderKey) var barOrder = MenuBarMetric.defaultOrder
    @AppStorage("panel.showUsage") var showUsage = true
    @AppStorage(PrefKey.showLimits) var showLimits = true
    @AppStorage("panel.showActivity") var showActivity = true
    @AppStorage("agents.showRecentSection") var showRecentSection = true
    @AppStorage("agents.showHistorySection") var showHistorySection = true
    @AppStorage("panel.density") var densityRawValue = PanelDensity.normal.rawValue
    @AppStorage("appearance.theme") var appearanceThemeRaw = PanelTheme.system.rawValue
    @AppStorage(PrefKey.accentHex) var accentHex = PrefKey.defaultAccentHex
    @AppStorage("profiles.active") var activeProfile = "custom"
    @AppStorage("profiles.work") var workProfileData = ""
    @AppStorage("profiles.monitoring") var monitoringProfileData = ""
    @AppStorage(GlobalHotKey.defaultsKey) var hotkey = GlobalHotKey.defaultPreset
    @AppStorage(MicMute.hotkeyKey) var micHotkey = MicMute.defaultPreset
    @AppStorage(ShortcutsOverlay.holdKey) var holdCommand = true
    @AppStorage("settings.section") var sectionRaw = SettingsSection.general.rawValue
    @AppStorage(MenuBarStyle.defaultsKey) var barStyle = MenuBarStyle.labeled.rawValue
    @AppStorage(MenuBarDrawer.colorDotKey) var colorDot = false
    @AppStorage(PanelWidth.defaultsKey) var panelWidth = PanelWidth.normal.rawValue
    @AppStorage(TextSize.defaultsKey) var textSize = TextSize.normal.rawValue
    @AppStorage(TabLayout.orderKey) var tabOrder = ""
    @AppStorage(TabLayout.hiddenKey) var hiddenTabs = ""
    @AppStorage(TabLayout.startKey) var startTab = TabLayout.lastUsed
    @AppStorage(TabLayout.shortcutsKey) var tabShortcuts = false
    @ObservedObject var hook = ClaudeHookStore.shared
    @ObservedObject var updates = UpdateStore.shared
    @StateObject var login = Box(SMAppService.mainApp.status == .enabled)
    @StateObject var loginErr = Box<String?>(nil)
    @StateObject var savedProfile = Box<String?>(nil)
    @StateObject var transferNote = Box<String?>(nil)
    @StateObject var language = Box(AppLanguage.current.rawValue)
    @StateObject var languageChanged = Box(false)

    var body: some View {
        VStack(alignment: .leading, spacing: DS.lg) {
            sectionPicker
            switch SettingsSection(rawValue: sectionRaw) ?? .general {
            case .general: generalSection
            case .menuBar: menuBarSection
            case .panel: panelSection
            case .appearance: appearanceSection
            case .alerts: alertsSection
            case .rules: RulesSettings(store: .shared)
            }
            HStack {
                Text("AgentStats " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")).font(DS.meta).foregroundStyle(Color.text3)
                Spacer()
                Link("Código no GitHub", destination: URL(string: "https://github.com/HamiltonPrado/agentstats")!)
                    .font(DS.meta).modifier(AccentText())
            }
            .padding(.horizontal, DS.xs)
        }
        .onChange(of: currentSnapshot) { _, _ in savedProfile.value = nil }
    }

    private var hookNeedsAction: Bool { hook.state == .stale || hook.state == .unreadable }

    private var hookSubtitle: String {
        switch hook.state {
        case .noClaude: "O Claude Code não está instalado"
        case .off: "Deteta melhor os pedidos de aprovação"
        case .on: "Ligada: os pedidos de aprovação chegam logo"
        case .stale: "Aponta para uma cópia da app que já não existe"
        case .unreadable: "O ~/.claude/settings.json não é JSON válido; não lhe mexo"
        }
    }

    /// Bindings para as definições guardadas no Monitor.
    var bm: Bindable<Monitor> { Bindable(m) }

    private var keepAwakeSubtitle: String {
        guard m.keepAwake else { return L("Termina automaticamente após o período") }
        return L(m.keepDisplayOn ? "Agora: o Mac e o ecrã ficam acordados" : "Agora: o Mac fica acordado; o ecrã pode apagar-se")
    }

    /// Diz porque é que os limites do Claude não aparecem, quando não aparecem.
    private var limitsSubtitle: String {
        switch m.claudeLimitsStatus {
        case .signedOut?: return m.claudeLimits == nil ? "Claude: inicia sessão no Claude Code (claude → /login)" : "% usada e quando renova"
        case .notInstalled?: return "Claude: precisa do Claude Code instalado"
        default: return "% usada e quando renova"
        }
    }

    /// Seletor das secções, no mesmo estilo dos separadores do painel.
    private var sectionPicker: some View {
        HStack(spacing: 0) {
            ForEach(SettingsSection.allCases) { section in
                let selected = sectionRaw == section.rawValue
                Button { withAnimation(Motion.ease(0.16)) { sectionRaw = section.rawValue } } label: {
                    Text(L(section.title))
                        .font(DS.meta.weight(.medium)).lineLimit(1)
                        .foregroundStyle(selected ? Color.primary : Color.text2)
                        .frame(maxWidth: .infinity).frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: DS.rSmall, style: .continuous)
                            .fill(selected ? DS.raised : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .segmentTrack(DS.surface)   // numa janela própria: a calha é a superfície e a opção escolhida a elevada
    }

    @ViewBuilder private var generalSection: some View {
        VStack(alignment: .leading, spacing: DS.lg) {
            group(nil) {
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
                    if m.notifyOnFinish {
                        // O seletor vai por baixo: ao lado, o texto ficava com a largura de uma letra.
                        VStack(alignment: .leading, spacing: DS.sm) {
                            HStack(spacing: DS.md) {
                                icon("timer")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Avisar ao terminar").font(DS.body)
                                    Text("Só tarefas com pelo menos").font(DS.meta).foregroundStyle(Color.text3)
                                }
                            }
                            Picker("", selection: bm.finishMinMinutes) {
                                Text("Todas").tag(0.0); Text("1 min").tag(1.0); Text("2 min").tag(2.0); Text("5 min").tag(5.0)
                            }
                            .pickerStyle(.segmented).labelsHidden()
                        }
                        .padding(.leading, 28)
                    }
                    HStack(spacing: DS.md) {
                        icon("keyboard")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Atalho para abrir o painel").font(DS.body)
                            Text("Funciona em qualquer app").font(DS.meta).foregroundStyle(Color.text3)
                        }
                        Spacer()
                        Picker("", selection: $hotkey) {
                            Text("Desligado").tag("off")
                            ForEach(GlobalHotKey.presets, id: \.key) { p in Text(L(p.combo.label)).tag(p.key) }
                        }
                        .labelsHidden().frame(width: 104)
                    }
                    HStack(spacing: DS.md) {
                        icon("mic.slash")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Silenciar o microfone").font(DS.body)
                            Text("Atalho global, para chamadas").font(DS.meta).foregroundStyle(Color.text3)
                        }
                        Spacer()
                        Picker("Silenciar o microfone", selection: $micHotkey) {
                            Text("Desligado").tag("off")
                            ForEach(MicMute.presets, id: \.key) { p in Text(p.combo.label).tag(p.key) }
                        }
                        .labelsHidden().frame(width: 104)
                    }
                    row("command", "Atalhos da app da frente", "Segurar ⌘ 1 s, ou ⌃⌥/", $holdCommand)
                    row("power", "Abrir ao iniciar sessão", nil, Binding(
                        get: { login.value },
                        set: { on in
                            do {
                                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                                login.value = on; loginErr.value = nil
                            } catch { loginErr.value = error.localizedDescription }
                        }))
                    if let e = loginErr.value { Text(L(e)).font(DS.meta).foregroundStyle(Color.attentionText) }
                    HStack(spacing: DS.md) {
                        icon("globe")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Idioma").font(DS.body)
                            if language.value != AppLanguage.current.rawValue || languageChanged.value {
                                Button("Reabrir para aplicar") { AppLanguage.relaunch() }
                                    .buttonStyle(.link).font(DS.meta)
                            }
                        }
                        Spacer()
                        Picker("Idioma", selection: Binding(get: { language.value }, set: {
                            language.value = $0
                            (AppLanguage(rawValue: $0) ?? .system).apply()
                            languageChanged.value = true
                        })) {
                            ForEach(AppLanguage.allCases) { Text(L($0.title)).tag($0.rawValue) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    HStack(spacing: DS.md) {
                        icon("square.and.arrow.up.on.square")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Definições noutro Mac").font(DS.body)
                            Text(L(transferNote.value ?? "Um ficheiro com as tuas escolhas, sem histórico")).font(DS.meta).foregroundStyle(Color.text3)
                        }
                        Spacer()
                        Button("Exportar…") { Task { transferNote.value = await SettingsFiles.exportSettings() } }.controlSize(.small)
                        Button("Importar…") { Task { transferNote.value = await SettingsFiles.importSettings(into: m) } }.controlSize(.small)
                    }
                    row("arrow.down.circle", "Procurar versões novas", "Uma vez por dia, no GitHub", Binding(
                        get: { updates.enabled }, set: { updates.enabled = $0 }))
                }
            }
            group("Claude Code") {
                VStack(alignment: .leading, spacing: DS.md) {
                    HStack(spacing: DS.md) {
                        icon("link")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Ligação ao Claude Code").font(DS.body)
                            Text(L(hookSubtitle)).font(DS.meta).foregroundStyle(hookNeedsAction ? Color.waitingText : Color.text3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: DS.sm)
                        switch hook.state {
                        case .off: Button("Ligar") { hook.set(true) }.controlSize(.small)
                        case .stale: Button("Reparar") { hook.set(true) }.controlSize(.small)
                        case .on: Button("Desligar") { hook.set(false) }.controlSize(.small)
                        case .noClaude, .unreadable: EmptyView()
                        }
                    }
                    if let message = hook.message { note(message, color: .waitingText) }
                    if hook.state == .off || hook.state == .stale {
                        note("Junta uma entrada ao ~/.claude/settings.json, com cópia de segurança ao lado. Desligar tira só essa entrada.")
                    }
                }
            }
            .onAppear { hook.refresh() }
            group("Energia") {
                VStack(alignment: .leading, spacing: DS.md) {
                    row("terminal", "Acordado com agentes a trabalhar",
                        m.holdingForAgents ? "Agora a manter acordado" : "Até 3 min depois de pararem; o ecrã pode desligar-se",
                        bm.keepAwakeForAgents)
                    row("moon.zzz", "Manter o Mac acordado", keepAwakeSubtitle, Binding(
                        get: { m.keepAwake }, set: { m.keepAwake = $0 }))
                    row("display", "Manter também o ecrã ligado", "O ecrã não se apaga enquanto o Mac estiver acordado", bm.keepDisplayOn)
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
                            Text(L(didSave ? "Perfil guardado" : "Guardar alterações no perfil")).font(DS.body)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(activeProfile == "custom")
                    Text("Aplica Trabalho ou Monitorização e guarda aqui as alterações feitas.")
                        .font(DS.meta).foregroundStyle(Color.text3)
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
                            ForEach(MenuBarStyle.allCases) { Text(L($0.title)).tag($0.rawValue) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    row("circle.fill", "Ponto dos agentes a cores", "Verde a trabalhar, vermelho quando precisa de ti", $colorDot)
                    Divider().opacity(0.5)
                    ForEach(Array(orderedMetrics.enumerated()), id: \.element.id) { index, metric in
                        HStack(spacing: DS.md) {
                            icon(metric.icon)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L(metric.title)).font(DS.body)
                                if let subtitle = metric.subtitle {
                                    Text(L(subtitle)).font(DS.meta).foregroundStyle(Color.text3)
                                }
                            }
                            Spacer(minLength: DS.xs)
                            Button { moveMetric(from: index, by: -1) } label: {
                                Image(systemName: "arrow.up").font(DS.meta)
                            }
                            .buttonStyle(.plain).disabled(index == 0)
                            .help("Mover \(L(metric.title)) para cima")
                            .accessibilityLabel("Mover \(L(metric.title)) para cima")
                            Button { moveMetric(from: index, by: 1) } label: {
                                Image(systemName: "arrow.down").font(DS.meta)
                            }
                            .buttonStyle(.plain).disabled(index == orderedMetrics.count - 1)
                            .help("Mover \(L(metric.title)) para baixo")
                            .accessibilityLabel("Mover \(L(metric.title)) para baixo")
                            Toggle("", isOn: metric.isEnabled)
                                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                        }
                        .contentShape(Rectangle())
                        .draggable(metric.id)
                        .dropDestination(for: String.self) { items, _ in moveMetric(items.first, to: metric.id) }
                    }
                    note("Arrasta para mudar a ordem.")
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
                            ForEach(PanelWidth.allCases) { Text(L($0.title)).tag($0.rawValue) }
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 200)
                    }
                    HStack(spacing: DS.md) {
                        icon("textformat.size")
                        Text("Texto").font(DS.body).lineLimit(1).fixedSize().layoutPriority(1)
                        Spacer(minLength: DS.xs)
                        Picker("Tamanho do texto", selection: $textSize) {
                            ForEach(TextSize.allCases) { Text(L($0.title)).tag($0.rawValue) }
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
                                Text(L(density.title)).tag(density.rawValue)
                            }
                        }
                        .pickerStyle(.menu).labelsHidden().frame(width: 110, alignment: .trailing)
                    }
                    row("gauge.with.dots.needle.33percent", "Limites do plano", limitsSubtitle, $showLimits)
                    row("number", "Utilização de tokens", "Resumo diário e semanal", $showUsage)
                    row("chart.bar", "Atividade nas últimas 24 h", nil, $showActivity)
                    row("clock.arrow.circlepath", "Sessões recentes", nil, $showRecentSection)
                    row("clock", "Histórico de agentes", nil, $showHistorySection)
                }
            }
            group("Separadores") {
                VStack(alignment: .leading, spacing: DS.md) {
                    let all = TabLayout.order(tabOrder)
                    let shown = TabLayout.visible(order: tabOrder, hidden: hiddenTabs)
                    ForEach(Array(all.enumerated()), id: \.element) { index, tab in
                        HStack(spacing: DS.md) {
                            icon(tab.icon)
                            Text(L(tab.title)).font(DS.body).lineLimit(1)
                                .foregroundStyle(shown.contains(tab) ? Color.primary : Color.text3)
                            Spacer(minLength: DS.xs)
                            Button { tabOrder = TabLayout.moved(order: tabOrder, tab, by: -1) } label: {
                                Image(systemName: "arrow.up").font(DS.meta)
                            }
                            .buttonStyle(.plain).disabled(index == 0)
                            .help("Mover \(L(tab.title)) para cima").accessibilityLabel("Mover \(L(tab.title)) para cima")
                            Button { tabOrder = TabLayout.moved(order: tabOrder, tab, by: 1) } label: {
                                Image(systemName: "arrow.down").font(DS.meta)
                            }
                            .buttonStyle(.plain).disabled(index == all.count - 1)
                            .help("Mover \(L(tab.title)) para baixo").accessibilityLabel("Mover \(L(tab.title)) para baixo")
                            Toggle(L(tab.title), isOn: Binding(
                                get: { shown.contains(tab) },
                                set: { _ in hiddenTabs = TabLayout.toggled(hidden: hiddenTabs, tab, order: tabOrder) }))
                                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                                .disabled(shown == [tab])   // fica sempre pelo menos um
                        }
                        .contentShape(Rectangle())
                        .draggable(tab.rawValue)
                        .dropDestination(for: String.self) { items, _ in
                            guard let raw = items.first, let dragged = Tab(rawValue: raw) else { return false }
                            tabOrder = TabLayout.moving(order: tabOrder, dragged, to: tab)
                            return true
                        }
                    }
                    note("Arrasta para mudar a ordem.")
                    Divider().opacity(0.5)
                    HStack(spacing: DS.md) {
                        icon("arrow.right.square")
                        Text("Abrir em").font(DS.body).lineLimit(1).fixedSize().layoutPriority(1)
                        Spacer(minLength: DS.xs)
                        Picker("Abrir em", selection: $startTab) {
                            Text("Último usado").tag(TabLayout.lastUsed)
                            ForEach(shown) { Text(L($0.title)).tag($0.rawValue) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    row("command", "Atalhos para cada separador",
                        String(localized: "⌥⌘1 a ⌥⌘\(shown.count), pela ordem acima. Funcionam em qualquer app"), $tabShortcuts)
                }
            }
        }
    }

    @ViewBuilder private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: DS.lg) {
            group(nil) {
                VStack(alignment: .leading, spacing: DS.md) {
                    HStack(spacing: DS.md) {
                        icon("circle.lefthalf.filled")
                        Text("Tema").font(DS.body).fixedSize().layoutPriority(1)
                        Spacer(minLength: 0)
                        Picker("Tema", selection: $appearanceThemeRaw) {
                            ForEach(PanelTheme.allCases) { theme in
                                Text(L(theme.title)).tag(theme.rawValue)
                            }
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 186)
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
            group(nil) {
                VStack(alignment: .leading, spacing: DS.md) {
                    row("cpu", "CPU alta", "Notifica após 20 s acima do limite", bm.cpuAlertEnabled)
                    if m.cpuAlertEnabled {
                        limit("Limite da CPU", bm.cpuThreshold, in: 0.5...0.99, step: 0.01) { Fmt.pct($0) }
                    }
                    row("thermometer.high", "Temperatura alta", "Máximo da CPU", bm.tempAlertEnabled)
                    if m.tempAlertEnabled {
                        limit("Limite da temperatura", bm.tempThreshold, in: 60...105, step: 1) { Fmt.num($0, 0) + "°" }
                    }
                    row("memorychip", "Memória alta", "Alerta após 20 s acima do limite", bm.memoryAlertEnabled)
                    if m.memoryAlertEnabled {
                        limit("Limite da memória", bm.memoryThreshold, in: 0.6...0.99, step: 0.01) { Fmt.pct($0) }
                    }
                    row("internaldrive", "Pouco espaço em disco", "Quando o espaço livre fica baixo", bm.diskAlertEnabled)
                    if m.diskAlertEnabled {
                        // Guarda-se a fração usada; aqui escolhe-se o espaço livre, que é como se pensa.
                        limit("Espaço livre mínimo", Binding(get: { 1 - m.diskThreshold }, set: { m.diskThreshold = 1 - $0 }),
                              in: 0.01...0.3, step: 0.01) { String(localized: "\(Fmt.pct($0)) livre") }
                    }
                    row("battery.25", "Bateria fraca", "Só sem carregador ligado", bm.batteryAlertEnabled)
                    if m.batteryAlertEnabled {
                        limit("Limite da bateria", bm.batteryThreshold, in: 0.05...0.5, step: 0.01) { Fmt.pct($0) }
                    }
                    row("gauge.with.dots.needle.67percent", "Limites do plano", "Claude e Codex: avisa também aos 90% e quando renova",
                        bm.limitAlertsEnabled)
                    if m.limitAlertsEnabled {
                        limit("Avisar aos", bm.limitAlertLevel, in: 50...95, step: 5) { Fmt.num($0, 0) + "%" }
                    }
                    row("dollarsign.circle", "Orçamento de custo", "Estimado a preços de API; avisa aos 80% e aos 100%", bm.budgetEnabled)
                    if m.budgetEnabled {
                        HStack(spacing: DS.md) {
                            Text("Período").font(DS.body)
                            Spacer()
                            Picker("Período", selection: bm.budgetPeriod) {
                                ForEach(Budget.Period.allCases) { Text(L($0.title)).tag($0) }
                            }
                            .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                        }
                        .padding(.leading, 28)
                        limit("Orçamento", bm.budgetAmount, in: 1...200, step: 1) { "$" + Fmt.num($0, 0) }
                    }
                    row("calendar", "Resumo semanal", "Tokens, custo e projetos da semana, numa notificação", bm.weeklySummaryEnabled)
                    row("hourglass", "Lembretes de espera", "Avisa se um agente continuar à espera", bm.waitingAlertEnabled)
                    if m.waitingAlertEnabled {
                        limit("Lembrar após", bm.waitingAlertMinutes, in: 1...60, step: 1) { Fmt.num($0, 0) + " min" }
                    }
                }
            }
        }
    }
}


