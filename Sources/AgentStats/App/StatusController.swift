import SwiftUI
import AppKit
import ServiceManagement
import Combine
import UserNotifications

@MainActor
final class StatusController: NSObject, NSPopoverDelegate {
    private let monitor: Monitor
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    /// O painel só existe enquanto está aberto: fechado, o SwiftUI não o recalcula a cada amostra.
    private let host = NSHostingController(rootView: AnyView(EmptyView()))
    private var lastIconSignature = ""
    private var lastIconUpdate = Date.distantPast
    private var cancellables = Set<AnyCancellable>()
    private let hotKey = GlobalHotKey()
    private let tabKeys = TabHotKeys()
    /// Cliques noutras apps ou na secretária: fecham o painel, como nos menus do macOS.
    private var outsideClicks: Any?

    init(monitor: Monitor) {
        self.monitor = monitor
        super.init()

        // A altura acompanha o conteúdo (até ao máximo do PanelView), em passos de 8 pt.
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
        }
        updateIcon()

        // Atualiza o ícone quando há novas amostras ou quando as definições mudam
        monitor.onUpdate = { [weak self] in self?.updateIcon() }
        CaptureStore.shared.onChange = { [weak self] in self?.updateIcon() }
        TimerStore.shared.onChange = { [weak self] in self?.updateIcon() }
        MicMuteStore.shared.onChange = { [weak self] in self?.updateIcon() }
        MeetingsStore.shared.onChange = { [weak self] in self?.updateIcon() }
        PresentationMode.shared.onChange = { [weak self] in self?.updateIcon() }
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(60), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateIcon()
                self?.hotKey.register(GlobalHotKey.configured)   // só re-regista se a escolha mudou
                self?.updateTabKeys()
                MicMuteStore.shared.registerHotKey()
                WindowShortcuts.update()
            }
            .store(in: &cancellables)

        // Atalho global para abrir e fechar o painel
        GlobalHotKey.handler = { [weak self] in self?.toggle(nil) }
        hotKey.register(GlobalHotKey.configured)
        TabHotKeys.install { [weak self] number in
            if let tab = TabLayout.shortcutTab(number, visible: TabLayout.currentVisible) { self?.show(tab) }
        }
        updateTabKeys()
    }

    private func updateTabKeys() {
        let on = UserDefaults.standard.bool(forKey: TabLayout.shortcutsKey)
        tabKeys.update(count: on ? TabLayout.currentVisible.count : 0)
    }

    private static let tabKey = "panel.tab2"

    /// Atalho de um separador: abre o painel nele; se já estava aberto nele, fecha.
    func show(_ tab: Tab) {
        if CaptureStore.shared.isRecording {
            CaptureStore.shared.stop()
            return
        }
        let current = UserDefaults.standard.string(forKey: Self.tabKey)
        if popover.isShown {
            if current == tab.rawValue { popover.performClose(nil) } else { UserDefaults.standard.set(tab.rawValue, forKey: Self.tabKey) }
            return
        }
        UserDefaults.standard.set(tab.rawValue, forKey: Self.tabKey)
        present()
    }

    /// O que o VoiceOver diz sobre o ícone da barra de menus.
    private func spokenSummary() -> String {
        let m = monitor
        if let recording = CaptureStore.shared.menuBarText { return String(localized: "AgentStats, a gravar o ecrã, \(recording). Clicar para parar") }
        var parts = ["AgentStats"]
        if m.needsAttentionCount > 0 { parts.append(String(localized: "\(m.needsAttentionCount) agente\(m.needsAttentionCount == 1 ? "" : "s") precisa\(m.needsAttentionCount == 1 ? "" : "m") de ti")) }
        parts.append(String(localized: "\(m.workingCount) de \(m.liveAgentCount) agentes a trabalhar"))
        if !m.activeAlerts.isEmpty { parts.append(m.activeAlerts.map(\.kind.label).joined(separator: " e ")) }
        parts.append(String(localized: "CPU \(Fmt.pct(m.cpu.total))"))
        parts.append(String(localized: "memória \(Fmt.pct(m.memory.usage))"))
        if let t = m.temps?.cpuMax { parts.append(String(localized: "temperatura \(Fmt.num(t, 0)) graus")) }
        return parts.joined(separator: ", ")
    }

    /// Texto que a barra de menus mostraria: só se volta a desenhar o ícone quando muda.
    private func iconSignature() -> String {
        let d = UserDefaults.standard
        func on(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }
        let m = monitor
        // Os 3 primeiros campos são "urgentes" (redesenham logo); os restantes no máximo de 4 em 4 s.
        // Construída passo a passo, com tipos explícitos: um único array literal com tantas expressões
        // condicionais fazia o compilador do Xcode 16 desistir da verificação de tipos.
        var parts: [String] = []
        if let recording = CaptureStore.shared.menuBarText { return "gravar:" + recording }
        // O temporizador muda a cada segundo: fica nos campos "urgentes" para se ver logo.
        parts.append((m.activeAlerts.isEmpty ? "" : "!") + (TimerStore.shared.menuBarText ?? "") + (MicMuteStore.shared.muted ? "mic" : "") + (MeetingsStore.shared.menuBarText ?? "") + (PresentationMode.shared.active ? "apr" : ""))
        parts.append(String(m.needsAttentionCount))
        parts.append(on("bar.agents", true) ? "\(m.workingCount)/\(m.liveAgentCount)" : "")
        // configuração e aparência da barra: mudar qualquer uma redesenha o ícone
        parts.append(d.string(forKey: MenuBarDrawer.metricOrderKey) ?? "")
        parts.append(MenuBarStyle.current.rawValue)
        parts.append(on(MenuBarDrawer.colorDotKey, false) ? "cor" : "")
        parts.append(item.button?.effectiveAppearance.name.rawValue ?? "")
        if MenuBarStyle.current == .graphs { parts.append("\(m.cpuHistory.values.count)-\(m.cpu.total)") }
        if on("bar.cpu", true) { parts.append(Fmt.pct(m.cpu.total)) }
        if on("bar.ram", true) { parts.append(Fmt.pct(m.memory.usage)) }
        if on("bar.gpu", false), let g = m.gpu { parts.append(Fmt.pct(g)) }
        if on("bar.temp", true), let t = m.temps?.cpuMax { parts.append(String(format: "%.0f", t)) }
        if on("bar.net", true) {
            let up: String = Fmt.rate(m.network.upPerSec, short: true)
            let down: String = Fmt.rate(m.network.downPerSec, short: true)
            parts.append(up + down)
        }
        if on("bar.battery", false), let b = m.battery { parts.append(Fmt.pct(b.percent) + (b.isCharging ? "c" : "")) }
        return parts.joined(separator: "|")
    }

    private func updateIcon() {
        if Monitor.disabled.contains("icon") { return }
        let sig = iconSignature()
        item.button?.setAccessibilityLabel(spokenSummary())
        guard sig != lastIconSignature else { return }
        // Estado dos agentes e alertas mudam o ícone logo; os números (CPU, rede…) no máximo de 4 em 4 s.
        let urgent = sig.split(separator: "|").prefix(3) != lastIconSignature.split(separator: "|").prefix(3)
        guard urgent || Date().timeIntervalSince(lastIconUpdate) >= 3.9 else { return }
        lastIconSignature = sig
        lastIconUpdate = Date()
        item.button?.image = MenuBarDrawer.image(monitor, appearance: item.button?.effectiveAppearance,
                                                recording: CaptureStore.shared.menuBarText, timer: TimerStore.shared.menuBarText,
                                                micMuted: MicMuteStore.shared.muted, meeting: MeetingsStore.shared.menuBarText,
                                                presenting: PresentationMode.shared.active)
    }

    func saveHistory() { monitor.saveHistory() }

    func focusSession(id: String) {
        popover.performClose(nil)
        monitor.focus(sessionID: id)
    }

    /// Fecha o painel e traz para a frente a app do agente.
    func open(_ session: AgentSession) {
        popover.performClose(nil)
        if !monitor.focus(session), let cwd = session.cwd {
            NSWorkspace.shared.open(URL(fileURLWithPath: cwd))   // sem app encontrada: abre a pasta
        }
    }

    func closePanel() { popover.performClose(nil) }

    func togglePanel() { toggle(nil) }

    var monitorForCommands: Monitor { monitor }

    private var settingsWindow: NSWindow?

    /// As Definições numa janela, como nas apps do macOS (⌘, ou a roda dentada).
    func openSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 680),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = L("Definições do AgentStats")
            w.isReleasedWhenClosed = false
            w.contentMinSize = NSSize(width: 420, height: 420)
            w.contentViewController = NSHostingController(rootView: SettingsWindowContent().environment(monitor))
            w.setFrameAutosaveName("AgentStatsSettings")
            if !w.setFrameUsingName("AgentStatsSettings") { w.center() }
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func openPanel() {
        popover.behavior = .applicationDefined   // diagnóstico: fica aberto mesmo ao clicar noutro sítio
        if !popover.isShown { toggle(nil) }
    }

    /// Botão direito (ou Control+clique, ou clique secundário no trackpad): o menu da app, como nos outros ícones.
    @objc private func clicked(_ sender: Any?) {
        if let e = NSApp.currentEvent, e.type == .rightMouseUp || e.modifierFlags.contains(.control) {
            showMenu()
        } else {
            toggle(sender)
        }
    }

    private func showMenu() {
        guard let button = item.button else { return }
        if popover.isShown { popover.performClose(nil) }
        let menu = NSMenu()
        func add(_ title: String, _ key: String = "", _ action: @escaping () -> Void) {
            let i = NSMenuItem(title: L(title), action: #selector(MenuAction.run), keyEquivalent: key)
            let target = MenuAction(action)
            i.target = target
            i.representedObject = target   // o NSMenuItem não guarda o target: fica vivo assim
            menu.addItem(i)
        }
        add("Abrir AgentStats") { [weak self] in self?.toggle(nil) }
        menu.addItem(.separator())
        for tab in TabLayout.currentVisible where tab != .settings {
            add(tab.title) { [weak self] in self?.show(tab) }
        }
        menu.addItem(.separator())
        let quick = QuickTogglesStore.shared
        add(PresentationMode.shared.active ? "Sair do modo apresentação" : "Modo apresentação") { Task { await PresentationMode.shared.toggle() } }
        add(QuickToggles.isDark ? "Modo claro" : "Modo escuro") { Task { await quick.toggleDarkMode() } }
        add(QuickToggles.desktopIconsShown ? "Esconder ícones da secretária" : "Mostrar ícones da secretária") {
            Task { await quick.toggleDesktopIcons() }
        }
        let mic = MicMuteStore.shared
        add(mic.muted ? "Ligar o microfone" : "Silenciar o microfone") { mic.toggle() }
        menu.addItem(.separator())
        add("Definições…", ",") { [weak self] in self?.openSettings() }
        add("Abrir Monitor de Atividade") {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
        }
        menu.addItem(.separator())
        add("Sair do AgentStats", "q") { NSApp.terminate(nil) }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
    }

    @objc private func toggle(_ sender: Any?) {
        // A gravar, clicar no ícone (ou o atalho) para logo, sem abrir o painel para dentro do vídeo.
        if CaptureStore.shared.isRecording {
            CaptureStore.shared.stop()
            return
        }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            let d = UserDefaults.standard
            let stored = Tab(rawValue: d.string(forKey: Self.tabKey) ?? "") ?? .agents
            var tab = TabLayout.tabOnOpen(stored: stored, start: d.string(forKey: TabLayout.startKey), visible: TabLayout.currentVisible)
            // As Definições têm janela própria: o painel abre sempre num separador.
            if tab == .settings { tab = TabLayout.currentVisible[0] }
            if tab != stored { d.set(tab.rawValue, forKey: Self.tabKey) }
            present()
        }
    }

    private func present() {
        guard let button = item.button else { return }
        QuickPaste.rememberFrontApp()
        host.rootView = AnyView(PanelView().environment(monitor))
        monitor.panelOpen = true
        monitor.sample()   // dados frescos ao abrir
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        // O .transient às vezes deixa-o aberto (clique na secretária, noutro ecrã): isto garante que fecha.
        if outsideClicks == nil, popover.behavior == .transient {
            outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.popover.performClose(nil) }
            }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
        host.rootView = AnyView(EmptyView())
        monitor.panelOpen = false
    }
}

/// Liga um item de menu a um bloco.
private final class MenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}
