import SwiftUI
import AppKit
import ServiceManagement
import Combine

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
        if CommandLine.arguments.contains("--dump") { Self.dump(); exit(0) }
        if CommandLine.arguments.contains("--bench") { Self.bench(); exit(0) }
        if CommandLine.arguments.contains("--register-login") {
            do { try SMAppService.mainApp.register(); print("login: \(SMAppService.mainApp.status.rawValue)") }
            catch { print("erro: \(error)") }
            exit(0)
        }
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            MainActor.assumeIsolated { Self.snapshot(to: args[i + 1]) }
            exit(0)
        }
    }

    /// Renderiza cada separador do painel em PNG (claro e escuro) para rever a interface.
    @MainActor static func snapshot(to dir: String) {
        let m = Monitor()
        RunLoop.main.run(until: Date().addingTimeInterval(7))
        if ProcessInfo.processInfo.environment["AGENTSTATS_FAKE_ALERT"] != nil {
            m.activeAlerts = [
                SystemAlert(kind: .cpu, value: "92%", since: Date().addingTimeInterval(-45), detail: "WindowServer (74%)"),
                SystemAlert(kind: .temp, value: "91 ºC", since: Date().addingTimeInterval(-30), detail: "WindowServer (74%)"),
            ]
            m.sessions.insert(AgentSession(id: "fake", kind: "Claude Code", title: "Migrar base de dados", cwd: "/Users/demo/api",
                                           model: "claude-opus-5-5", state: .needsApproval("Bash"),
                                           detail: "rm -rf build && npm run migrate", lastActivity: Date().addingTimeInterval(-12),
                                           subagents: 0, process: nil), at: 0)
        }
        for scheme in [ColorScheme.light, .dark] {
            for tab in Tab.allCases {
                let view = PanelView(forcedTab: tab, scrollable: false)
                    .environment(m)
                    .environment(\.colorScheme, scheme)
                    .background(scheme == .dark ? Color(white: 0.17) : Color(white: 0.95))
                let r = ImageRenderer(content: view)
                r.scale = 2
                guard let img = r.nsImage, let tiff = img.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else { continue }
                let name = "\(tab.rawValue)-\(scheme == .dark ? "dark" : "light").png"
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
            }
        }
        // barra de menus
        let bar = ImageRenderer(content: MenuBarLabel().environment(m).padding(4).background(Color.white))
        bar.scale = 3
        if let tiff = bar.nsImage?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("menubar.png"))
        }
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
        print("Disco \(Fmt.bytes(d.used))/\(Fmt.bytes(d.total)) R \(Fmt.rate(d.readPerSec)) W \(Fmt.rate(d.writePerSec))")
        if let b = BatteryReader.read() {
            print("Bateria \(Fmt.pct(b.percent)) carregar=\(b.isCharging) ciclos \(b.cycles) saúde \(b.health.map(Fmt.pct) ?? "-") temp \(b.temperature ?? 0) W \(b.watts ?? 0)")
        } else { print("Bateria n/d") }
        let sampler = ProcessSampler()
        _ = sampler.read(); Thread.sleep(forTimeInterval: 2)
        let procs = sampler.read()
        let agents = agentR.agentProcesses(from: procs)
        print("Top CPU (libproc+ps):", procs.sorted { $0.cpu > $1.cpu }.prefix(5).map { "\($0.name) \(String(format: "%.1f", $0.cpu))%" }.joined(separator: ", "))
        print("Processos: \(procs.count) · agentes: \(agents.count)")
        for a in agents { print("  [\(a.kind)] pid \(a.pid) cpu \(a.cpu) sub=\(a.isSubagent) cwd \(a.cwd ?? "-") filhos \(a.children)") }
        for s in agentR.sessions(processes: agents) + CodexReader().sessions(recentWindow: 7 * 86400) {
            print("  • [\(s.kind)] \(s.title) | \(s.state.label) | \(s.detail ?? "") | \(s.project) | \(s.model ?? "-") | pid \(s.process?.pid ?? 0)")
        }
    }

}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            controller = StatusController(monitor: Monitor())
            // Diagnóstico: abre o painel ao arrancar (para medir o consumo com o painel aberto)
            if ProcessInfo.processInfo.environment["AGENTSTATS_OPEN_PANEL"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.controller?.openPanel() }
            }
        }
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

    init(monitor: Monitor) {
        self.monitor = monitor
        super.init()

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
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(60), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)
    }

    /// Texto que a barra de menus mostraria: só se volta a desenhar o ícone quando muda.
    private func iconSignature() -> String {
        let d = UserDefaults.standard
        func on(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }
        let m = monitor
        return [
            m.activeAlerts.isEmpty ? "" : "!",
            "\(m.needsAttentionCount)",
            on("bar.agents", true) ? "\(m.workingCount)/\(m.liveAgentCount)" : "",
            on("bar.cpu", true) ? Fmt.pct(m.cpu.total) : "",
            on("bar.ram", true) ? Fmt.pct(m.memory.usage) : "",
            on("bar.gpu", false) ? (m.gpu.map(Fmt.pct) ?? "") : "",
            on("bar.temp", true) ? (m.temps?.cpuMax.map { String(format: "%.0f", $0) } ?? "") : "",
            on("bar.net", true) ? Fmt.rate(m.network.upPerSec, short: true) + Fmt.rate(m.network.downPerSec, short: true) : "",
            on("bar.battery", false) ? (m.battery.map { Fmt.pct($0.percent) + ($0.isCharging ? "c" : "") } ?? "") : "",
        ].joined(separator: "|")
    }

    private func updateIcon() {
        if Monitor.disabled.contains("icon") { return }
        let sig = iconSignature()
        guard sig != lastIconSignature else { return }
        // Estado dos agentes e alertas mudam o ícone logo; os números (CPU, rede…) no máximo de 4 em 4 s.
        let urgent = sig.split(separator: "|").prefix(3) != lastIconSignature.split(separator: "|").prefix(3)
        guard urgent || Date().timeIntervalSince(lastIconUpdate) >= 3.9 else { return }
        lastIconSignature = sig
        lastIconUpdate = Date()
        item.button?.image = MenuBarDrawer.image(monitor)
    }

    func openPanel() {
        popover.behavior = .applicationDefined   // diagnóstico: fica aberto mesmo ao clicar noutro sítio
        if !popover.isShown { toggle(nil) }
    }

    @objc private func toggle(_ sender: Any?) {
        guard let button = item.button else { return }
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
