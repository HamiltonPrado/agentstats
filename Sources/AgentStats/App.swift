import SwiftUI
import AppKit
import ServiceManagement

@main
struct AgentStatsApp: App {
    @StateObject private var monitor = Monitor()

    init() {
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

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environmentObject(monitor)
        } label: {
            MenuBarLabel()
                .environmentObject(monitor)
        }
        .menuBarExtraStyle(.window)
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
