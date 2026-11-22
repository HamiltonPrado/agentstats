import SwiftUI
import AppKit
import ServiceManagement
import Combine
import UserNotifications

@main
enum AgentStatsApp {
    /// Arranque em AppKit puro: só existe o ícone na barra de menus (sem janelas SwiftUI).
    static func main() {
        handleCommandLine()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    static func handleCommandLine() {
        if CommandLine.arguments.contains("--hook") {
            // Chamado pelo hook de Notification do Claude Code: grava o evento e sai, sem escrever nada.
            HookEvents.record(stdin: FileHandle.standardInput.readDataToEndOfFile())
            exit(0)
        }
        if CommandLine.arguments.contains("--dump") { Self.dump(); exit(0) }
        if CommandLine.arguments.contains("--bench") { Self.bench(); exit(0) }
        if CommandLine.arguments.contains("--register-login") {
            do { try SMAppService.mainApp.register(); print("login: \(SMAppService.mainApp.status.rawValue)") }
            catch { print("erro: \(error)") }
            exit(0)
        }
        if CommandLine.arguments.contains("--smoke") {
            MainActor.assumeIsolated { Self.smoke() }
            exit(0)
        }
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            MainActor.assumeIsolated { Snapshot.write(to: args[i + 1]) }
            exit(0)
        }
    }

    /// Teste de arranque do CI: a app a sério durante 7 s, para apanhar os crashes que os testes não veem
    /// (a v1.16 rebentava na resposta ao pedido de notificações). O `--snapshot` não serve: usa dados inventados.
    @MainActor static func smoke() {
        let m = Monitor()
        AppMixer.shared.refresh()   // só lê a lista de apps com som; não capta nada
        RunLoop.main.run(until: Date().addingTimeInterval(7))
        _ = MenuBarDrawer.image(m)
        print("arranque ok")
    }

    /// Mede o custo médio de cada leitor (ms por chamada).
    static func bench() {
        func time(_ name: String, _ n: Int = 20, _ f: () -> Void) {
            let t0 = Date(); for _ in 0..<n { f() }
            print(String(format: "%-22@ %7.2f ms", name as NSString, Date().timeIntervalSince(t0) * 1000 / Double(n)))
        }
        let cpu = CPUReader(), net = NetworkReader(), disk = DiskReader(), temp = TemperatureReader()
        let sampler = ProcessSampler(), agents = AgentReader(), codex = CodexReader()
        time("CPU") { _ = cpu.read() }
        time("Memória") { _ = MemoryReader.read() }
        time("Rede") { _ = net.read() }
        time("Disco") { _ = disk.read() }
        time("GPU") { _ = GPUReader.read() }
        time("Bateria") { _ = BatteryReader.read() }
        time("Temperaturas") { _ = temp.read() }
        time("ps (completo)", 5) { _ = ProcessReader.read() }
        let procs = sampler.read()
        time("libproc (sampler)") { _ = sampler.read() }
        let ag = agents.agentProcesses(from: procs)
        time("Agentes (processos)") { _ = agents.agentProcesses(from: procs) }
        time("Sessões Claude") { _ = agents.sessions(processes: ag) }
        time("Sessões Codex") { _ = codex.sessions() }
        let usage = UsageTracker()
        time("Tokens (1.ª leitura)", 1) { _ = usage.update() }
        time("Tokens (incremental)") { _ = usage.update() }
        let u = usage.update()
        print("Hoje: Claude \(Fmt.tokens(u.todayClaude.total)) (saída \(Fmt.tokens(u.todayClaude.output))) · Codex \(Fmt.tokens(u.todayCodex.total)) · sessões com uso: \(u.perSession.filter { !$0.value.isEmpty }.count)")
        print("Semana:", u.week.map { "\($0.day.suffix(5)) \(Fmt.tokens($0.total.total))" }.joined(separator: " · "))
        print("Projetos:", u.projects.prefix(5).map { "\($0.name) \(Fmt.tokens($0.usage.total))" }.joined(separator: " · "))
        MainActor.assumeIsolated {
            let m = Monitor()
            RunLoop.main.run(until: Date().addingTimeInterval(3))
            time("Ícone da barra") { _ = MenuBarDrawer.image(m) }
        }
    }

    /// Diagnóstico: `AgentStats --dump` imprime as métricas e os agentes e sai.
    static func dump() {
        let cpuR = CPUReader(), netR = NetworkReader(), diskR = DiskReader(), agentR = AgentReader()
        _ = cpuR.read(); _ = netR.read(); _ = diskR.read()
        Thread.sleep(forTimeInterval: 1)
        let c = cpuR.read(), mem = MemoryReader.read(), n = netR.read(), d = diskR.read()
        print("CPU \(Fmt.pct(c.total)) (\(c.cores.count) núcleos) load \(c.load)")
        print("RAM \(Fmt.bytes(mem.used))/\(Fmt.bytes(mem.total)) app \(Fmt.bytes(mem.app)) wired \(Fmt.bytes(mem.wired)) comp \(Fmt.bytes(mem.compressed)) swap \(Fmt.bytes(mem.swapUsed)) pressão \(mem.pressure)")
        if let t = TemperatureReader().read() { print("Temp CPU média \(t.cpuAvg ?? 0) máx \(t.cpuMax ?? 0) chip \(t.chipAvg ?? 0) SSD \(t.ssd ?? 0) bateria \(t.battery ?? 0) · \(t.sensors.count) sensores") } else { print("Temp n/d") }
        print("GPU \(GPUReader.read().map(Fmt.pct) ?? "n/d")")
        print("Rede ↓\(Fmt.rate(n.downPerSec)) ↑\(Fmt.rate(n.upPerSec)) \(n.interface) \(n.localIP)")
        print("Disco \(Fmt.disk(d.used))/\(Fmt.disk(d.total)) R \(Fmt.rate(d.readPerSec)) W \(Fmt.rate(d.writePerSec))")
        if let b = BatteryReader.read() {
            print("Bateria \(Fmt.pct(b.percent)) carregar=\(b.isCharging) ciclos \(b.cycles) saúde \(b.health.map(Fmt.pct) ?? "-") temp \(b.temperature ?? 0) W \(b.watts ?? 0)")
        } else { print("Bateria n/d") }
        let sampler = ProcessSampler()
        _ = sampler.read(); Thread.sleep(forTimeInterval: 2)
        let procs = sampler.read()
        let agents = agentR.agentProcesses(from: procs)
        print("Top CPU (libproc+ps):", procs.sorted { $0.cpu > $1.cpu }.prefix(5).map { "\($0.name) \(String(format: "%.1f", $0.cpu))%" }.joined(separator: ", "))
        print("Processos: \(procs.count) · agentes: \(agents.count)")
        for a in agents {
            let host = ([a.pid] + a.ancestors).lazy.compactMap { NSRunningApplication(processIdentifier: pid_t($0)) }
                .first { $0.activationPolicy == .regular }?.localizedName ?? "—"
            print("  [\(a.kind)] pid \(a.pid) app \(host) sub=\(a.isSubagent) cwd \(a.cwd ?? "-")")
        }
        print("Hook ativo: \(HookEvents.isActive)")
        let base = agentR.sessions(processes: agents) + CodexReader().sessions(recentWindow: 7 * 86400) + AntigravityReader().sessions(processes: agents, recentWindow: 7 * 86400)
        let all = base + OtherAIsReader().sessions(processes: agents, existingSessions: base)
        for s in all {
            print("  • [\(s.kind)] \(s.title) | \(s.state.label) | \(s.detail ?? "") | \(s.project) | \(s.model ?? "-") | pid \(s.process?.pid ?? 0)")
        }
    }

}

/// Referência ao controlador para quem não está no main actor (o delegate das notificações).
@MainActor enum AppState {
    static weak var controller: StatusController?
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var controller: StatusController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        MainActor.assumeIsolated {
            NSApp.mainMenu = EditMenu.make()
            controller = StatusController(monitor: Monitor())
            ClipboardStore.shared.start()
            CaptureStore.shared.stopOrphan()
            AppState.controller = controller
            HookEvents.prune()
            NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    CaptureStore.shared.shutdown()
                    AppState.controller?.saveHistory()
                }
            }
            // Diagnóstico: abre o painel ao arrancar (para medir o consumo com o painel aberto)
            if ProcessInfo.processInfo.environment["AGENTSTATS_OPEN_PANEL"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.controller?.openPanel() }
            }
        }
    }

    // Clicar numa notificação de um agente traz para a frente a app onde ele corre.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["session"] as? String else { return }
        await MainActor.run { AppState.controller?.focusSession(id: id) }
    }

    // Mostra as notificações mesmo quando a AgentStats está ativa (por exemplo, com o painel aberto).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
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

// MARK: - Etiqueta na barra de menus (desenhada como imagem, estilo Stats)

struct MenuBarLabel: View {
    @Environment(Monitor.self) private var m
    @AppStorage("bar.agents") var showAgents = true
    @AppStorage("bar.cpu") var showCPU = true
    @AppStorage("bar.ram") var showRAM = true
    @AppStorage("bar.gpu") var showGPU = false
    @AppStorage("bar.net") var showNet = true
    @AppStorage("bar.battery") var showBattery = false
    @AppStorage("bar.temp") var showTemp = true

    var body: some View {
        Image(nsImage: render())
    }

    @MainActor
    private func render() -> NSImage { MenuBarDrawer.image(m) }

    private func cell(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: -2) {
            Text(title).font(.system(size: 7, weight: .semibold))
            Text(value).font(.system(size: 10, weight: .semibold).monospacedDigit())
        }
        .frame(minWidth: 24, alignment: .leading)
    }
}
