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
            button.action = #selector(toggle(_:))
            button.imagePosition = .imageOnly
        }
        updateIcon()

        // Atualiza o ícone quando há novas amostras ou quando as definições mudam
        monitor.onUpdate = { [weak self] in self?.updateIcon() }
        CaptureStore.shared.onChange = { [weak self] in self?.updateIcon() }
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(60), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateIcon()
                self?.hotKey.register(GlobalHotKey.configured)   // só re-regista se a escolha mudou
            }
            .store(in: &cancellables)

        // Atalho global para abrir e fechar o painel
        GlobalHotKey.handler = { [weak self] in self?.toggle(nil) }
        hotKey.register(GlobalHotKey.configured)
    }

    /// O que o VoiceOver diz sobre o ícone da barra de menus.
    private func spokenSummary() -> String {
        let m = monitor
        if let recording = CaptureStore.shared.menuBarText { return "AgentStats, a gravar o ecrã, \(recording). Clicar para parar" }
        var parts = ["AgentStats"]
        if m.needsAttentionCount > 0 { parts.append("\(m.needsAttentionCount) agente\(m.needsAttentionCount == 1 ? "" : "s") precisa\(m.needsAttentionCount == 1 ? "" : "m") de ti") }
        parts.append("\(m.workingCount) de \(m.liveAgentCount) agentes a trabalhar")
        if !m.activeAlerts.isEmpty { parts.append(m.activeAlerts.map(\.kind.label).joined(separator: " e ")) }
        parts.append("CPU \(Fmt.pct(m.cpu.total))")
        parts.append("memória \(Fmt.pct(m.memory.usage))")
        if let t = m.temps?.cpuMax { parts.append("temperatura \(Fmt.num(t, 0)) graus") }
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
        parts.append(m.activeAlerts.isEmpty ? "" : "!")
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
                                                recording: CaptureStore.shared.menuBarText)
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

    func openPanel() {
        popover.behavior = .applicationDefined   // diagnóstico: fica aberto mesmo ao clicar noutro sítio
        if !popover.isShown { toggle(nil) }
    }

    @objc private func toggle(_ sender: Any?) {
        guard let button = item.button else { return }
        // A gravar, clicar no ícone (ou o atalho) para logo, sem abrir o painel para dentro do vídeo.
        if CaptureStore.shared.isRecording {
            CaptureStore.shared.stop()
            return
        }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            host.rootView = AnyView(PanelView().environment(monitor))
            monitor.panelOpen = true
            monitor.sample()   // dados frescos ao abrir
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        host.rootView = AnyView(EmptyView())
        monitor.panelOpen = false
    }
}
