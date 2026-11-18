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
        }
        for scheme in [ColorScheme.light, .dark] {
            for tab in Tab.allCases {
                let view = PanelView(forcedTab: tab, scrollable: false)
                    .environmentObject(m)
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
        let bar = ImageRenderer(content: MenuBarLabel().environmentObject(m).padding(4).background(Color.white))
        bar.scale = 3
        if let tiff = bar.nsImage?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("menubar.png"))
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
        let procs = ProcessReader.read()
        let agents = agentR.agentProcesses(from: procs)
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
        }
    }
}

@MainActor
final class StatusController: NSObject, NSPopoverDelegate {
    private let monitor: Monitor
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()

    init(monitor: Monitor) {
        self.monitor = monitor
        super.init()

        let host = NSHostingController(rootView: PanelView().environmentObject(monitor))
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
        monitor.objectWillChange
            .debounce(for: .milliseconds(60), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(60), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)
    }

    private func updateIcon() {
        let r = ImageRenderer(content: MenuBarLabel().environmentObject(monitor))
        r.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let img = r.nsImage else { return }
        img.isTemplate = true
        item.button?.image = img
    }

    @objc private func toggle(_ sender: Any?) {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

// MARK: - Etiqueta na barra de menus (desenhada como imagem, estilo Stats)

struct MenuBarLabel: View {
    @EnvironmentObject var m: Monitor
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
    private func render() -> NSImage {
        let content = HStack(spacing: 7) {
            if !m.activeAlerts.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11, weight: .bold))
            }
            if showAgents {
                HStack(spacing: 2) {
                    Image(systemName: m.workingCount > 0 ? "sparkles" : "sparkle")
                        .font(.system(size: 11, weight: .semibold))
                    Text("\(m.workingCount)/\(m.liveAgentCount)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                }
            }
            if showCPU { cell("CPU", Fmt.pct(m.cpu.total)) }
            if showRAM { cell("RAM", Fmt.pct(m.memory.usage)) }
            if showGPU, let g = m.gpu { cell("GPU", Fmt.pct(g)) }
            if showTemp, let t = m.temps?.cpuMax { cell("TEMP", String(format: "%.0f°", t)) }
            if showNet {
                VStack(alignment: .trailing, spacing: -1) {
                    Text("↑ " + Fmt.rate(m.network.upPerSec, short: true))
                    Text("↓ " + Fmt.rate(m.network.downPerSec, short: true))
                }
                .font(.system(size: 8.5, weight: .medium).monospacedDigit())
                .frame(minWidth: 40, alignment: .trailing)
            }
            if showBattery, let b = m.battery { cell(b.isCharging ? "BAT ⚡︎" : "BAT", Fmt.pct(b.percent)) }
            if !(showAgents || showCPU || showRAM || showGPU || showNet || showBattery || showTemp) {
                Image(systemName: "gauge.with.dots.needle.33percent").font(.system(size: 12))
            }
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 1)
        .frame(height: 18)

        let r = ImageRenderer(content: content)
        r.scale = NSScreen.main?.backingScaleFactor ?? 2
        let img = r.nsImage ?? NSImage()
        img.isTemplate = true
        return img
    }

    private func cell(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: -2) {
            Text(title).font(.system(size: 7, weight: .semibold))
            Text(value).font(.system(size: 10, weight: .semibold).monospacedDigit())
        }
        .frame(minWidth: 24, alignment: .leading)
    }
}
