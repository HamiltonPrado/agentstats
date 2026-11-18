import SwiftUI
import AppKit
import ServiceManagement

enum Tab: String, CaseIterable, Identifiable {
    case agents = "Agentes", system = "Sistema", processes = "Processos", settings = "Definições"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .agents: return "sparkles"
        case .system: return "cpu"
        case .processes: return "list.bullet"
        case .settings: return "gearshape"
        }
    }
}

struct PanelView: View {
    @EnvironmentObject var m: Monitor
    @AppStorage("panel.tab") private var tab: Tab = .agents

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                Group {
                    switch tab {
                    case .agents: AgentsView()
                    case .system: SystemView()
                    case .processes: ProcessesView()
                    case .settings: SettingsView()
                    }
                }
                .padding(12)
            }
            .frame(height: 520)
            Divider()
            footer
        }
        .frame(width: 380)
    }

    private var header: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases) { t in
                Button { tab = t } label: {
                    Label(t.rawValue, systemImage: t.icon)
                        .labelStyle(.iconOnly)
                        .font(.system(size: 13))
                        .frame(width: 30, height: 24)
                        .background(tab == t ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(tab == t ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(t.rawValue)
            }
            Spacer()
            Text(tab.rawValue).font(.headline)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack {
            Text("\(m.model) · ativo há \(Fmt.duration(m.uptime))")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Monitor de Atividade") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            }
            .buttonStyle(.borderless).font(.caption)
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(.borderless).help("Sair")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

// MARK: - Componentes

struct Card<Content: View>: View {
    let title: String
    let icon: String
    var trailing: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: icon).font(.subheadline.weight(.semibold))
                Spacer()
                if let trailing { Text(trailing).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary) }
            }
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct Sparkline: View {
    let values: [Double]
    var maxValue: Double? = nil
    var color: Color = .accentColor

    var body: some View {
        GeometryReader { g in
            let mx = max(maxValue ?? (values.max() ?? 1), 0.0001)
            let pts = values.enumerated().map { i, v in
                CGPoint(x: g.size.width * CGFloat(i) / CGFloat(max(values.count - 1, 1)),
                        y: g.size.height * (1 - CGFloat(min(v / mx, 1))))
            }
            ZStack {
                Path { p in
                    guard let f = pts.first else { return }
                    p.move(to: CGPoint(x: f.x, y: g.size.height))
                    pts.forEach { p.addLine(to: $0) }
                    p.addLine(to: CGPoint(x: pts.last!.x, y: g.size.height))
                }
                .fill(color.opacity(0.18))
                Path { p in
                    guard let f = pts.first else { return }
                    p.move(to: f)
                    pts.dropFirst().forEach { p.addLine(to: $0) }
                }
                .stroke(color, lineWidth: 1.4)
            }
        }
    }
}

struct Bar: View {
    let value: Double
    var color: Color = .accentColor
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color).frame(width: g.size.width * CGFloat(min(max(value, 0), 1)))
            }
        }
        .frame(height: 6)
    }
}

struct StatRow: View {
    let label: String
    let value: String
    var color: Color? = nil
    var body: some View {
        HStack {
            if let color { Circle().fill(color).frame(width: 7, height: 7) }
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.caption)
    }
}

func usageColor(_ v: Double) -> Color {
    v > 0.85 ? .red : v > 0.6 ? .orange : .green
}

// MARK: - Agentes

struct AgentsView: View {
    @EnvironmentObject var m: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                summary("\(m.workingCount)", "a trabalhar", .green)
                summary("\(m.sessions.filter { $0.state == .waitingUser }.count)", "à espera", .orange)
                summary("\(m.liveAgentCount)", "processos", .blue)
            }

            if m.sessions.isEmpty && m.agents.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "moon.zzz").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Nenhum agente ativo").font(.headline)
                    Text("Sessões do Claude Code, Codex, Gemini CLI, Aider e outros aparecem aqui automaticamente.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 40)
            }

            ForEach(m.sessions) { SessionRow(session: $0) }

            let unlinked = m.agents.filter { a in !m.sessions.contains { $0.process?.pid == a.pid } }
            if !unlinked.isEmpty {
                Text("Outros processos de agentes").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
                ForEach(unlinked) { ProcessAgentRow(agent: $0) }
            }
        }
    }

    private func summary(_ n: String, _ label: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(n).font(.title2.weight(.bold).monospacedDigit()).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct StatusDot: View {
    let state: AgentState
    @StateObject private var anim = Box(false)
    private var pulse: Bool { anim.value }
    var color: Color {
        switch state {
        case .runningTool, .thinking: return .green
        case .waitingUser: return .orange
        case .finished: return .gray
        case .unknown: return .blue
        }
    }
    var body: some View {
        ZStack {
            if state.isWorking {
                Circle().fill(color.opacity(0.35)).frame(width: 16, height: 16)
                    .scaleEffect(pulse ? 1.2 : 0.6).opacity(pulse ? 0 : 1)
                    .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: pulse)
            }
            Circle().fill(color).frame(width: 9, height: 9)
        }
        .frame(width: 16, height: 16)
        .onAppear { anim.value = true }
    }
}

struct SessionRow: View {
    @EnvironmentObject var m: Monitor
    let session: AgentSession

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            StatusDot(state: session.state).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(session.title).font(.callout.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Text(Fmt.ago(session.lastActivity)).font(.caption2).foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Text(session.state.label).foregroundStyle(session.state.isWorking ? .green : .secondary)
                    if session.subagents > 0 {
                        Text("· \(session.subagents) subagente\(session.subagents == 1 ? "" : "s")").foregroundStyle(.purple)
                    }
                }
                .font(.caption.weight(.medium))
                if let d = session.detail {
                    Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 8) {
                    Label(session.project, systemImage: "folder").lineLimit(1)
                    if let model = Fmt.model(session.model) { Label(model, systemImage: "brain") }
                    if let p = session.process {
                        Label(String(format: "%.0f%%", p.cpu), systemImage: "cpu")
                        Label(Fmt.bytes(p.memKB * 1024), systemImage: "memorychip")
                    }
                }
                .font(.caption2).foregroundStyle(.secondary)
                if let p = session.process, !p.children.isEmpty, session.state.isWorking {
                    Text("↳ " + p.children.joined(separator: ", "))
                        .font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(session.state == .finished ? 0.25 : 0.5), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .contextMenu {
            if let cwd = session.cwd {
                Button("Abrir pasta no Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: cwd)) }
                Button("Copiar caminho") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(cwd, forType: .string)
                }
            }
            Button("Mostrar transcript") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.id)]) }
            if let p = session.process {
                Divider()
                Button("Terminar processo (PID \(p.pid))", role: .destructive) { m.terminate(pid: p.pid) }
            }
        }
    }
}

struct ProcessAgentRow: View {
    @EnvironmentObject var m: Monitor
    let agent: AgentProcess
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: agent.isSubagent ? "arrow.turn.down.right" : "terminal")
                .foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.kind + (agent.isSubagent ? " (subagente)" : "")).font(.callout.weight(.medium))
                Text(agent.cwd.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "PID \(agent.pid)")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "%.0f%% CPU", agent.cpu)).font(.caption.monospacedDigit())
                Text(agent.elapsed).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            Button("Terminar processo (PID \(agent.pid))", role: .destructive) { m.terminate(pid: agent.pid) }
        }
    }
}

// MARK: - Sistema

struct SystemView: View {
    @EnvironmentObject var m: Monitor

    var body: some View {
        VStack(spacing: 10) {
            Card(title: "CPU", icon: "cpu", trailing: Fmt.pct(m.cpu.total)) {
                Sparkline(values: m.cpuHistory.values, maxValue: 1, color: .blue).frame(height: 36)
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(Array(m.cpu.cores.enumerated()), id: \.offset) { _, v in
                        GeometryReader { g in
                            VStack { Spacer(minLength: 0); RoundedRectangle(cornerRadius: 1.5).fill(usageColor(v)).frame(height: max(2, g.size.height * v)) }
                        }
                    }
                }
                .frame(height: 22)
                StatRow(label: "Utilizador", value: Fmt.pct(m.cpu.user), color: .blue)
                StatRow(label: "Sistema", value: Fmt.pct(m.cpu.system), color: .red)
                StatRow(label: "Carga (1/5/15 min)", value: String(format: "%.2f · %.2f · %.2f", m.cpu.load.0, m.cpu.load.1, m.cpu.load.2))
                if let p = m.pCores, let e = m.eCores {
                    StatRow(label: "Núcleos", value: "\(p) performance + \(e) eficiência")
                }
                StatRow(label: "Estado térmico", value: thermalLabel, color: thermalColor)
            }

            Card(title: "Memória", icon: "memorychip", trailing: "\(Fmt.bytes(m.memory.used)) / \(Fmt.bytes(m.memory.total))") {
                Sparkline(values: m.memHistory.values, maxValue: 1, color: .purple).frame(height: 30)
                memoryBar
                StatRow(label: "Apps", value: Fmt.bytes(m.memory.app), color: .purple)
                StatRow(label: "Wired", value: Fmt.bytes(m.memory.wired), color: .orange)
                StatRow(label: "Comprimida", value: Fmt.bytes(m.memory.compressed), color: .pink)
                StatRow(label: "Em cache", value: Fmt.bytes(m.memory.cached), color: .gray)
                StatRow(label: "Swap", value: "\(Fmt.bytes(m.memory.swapUsed)) / \(Fmt.bytes(m.memory.swapTotal))")
                StatRow(label: "Pressão", value: pressureLabel, color: pressureColor)
            }

            if let g = m.gpu {
                Card(title: "GPU", icon: "cube.transparent", trailing: Fmt.pct(g)) {
                    Sparkline(values: m.gpuHistory.values, maxValue: 1, color: .teal).frame(height: 30)
                }
            }

            Card(title: "Rede", icon: "network", trailing: m.network.interface) {
                ZStack {
                    let mx = max((m.downHistory.values + m.upHistory.values).max() ?? 1, 1024)
                    Sparkline(values: m.downHistory.values, maxValue: mx, color: .blue)
                    Sparkline(values: m.upHistory.values, maxValue: mx, color: .red)
                }
                .frame(height: 34)
                StatRow(label: "↓ Download", value: Fmt.rate(m.network.downPerSec), color: .blue)
                StatRow(label: "↑ Upload", value: Fmt.rate(m.network.upPerSec), color: .red)
                StatRow(label: "Total desde o arranque da app", value: "↓ \(Fmt.bytes(m.network.totalDown))  ↑ \(Fmt.bytes(m.network.totalUp))")
                StatRow(label: "IP local", value: m.network.localIP)
            }

            Card(title: "Disco", icon: "internaldrive", trailing: Fmt.pct(m.disk.usage)) {
                Bar(value: m.disk.usage, color: usageColor(m.disk.usage))
                StatRow(label: "Usado", value: Fmt.bytes(m.disk.used))
                StatRow(label: "Livre", value: Fmt.bytes(m.disk.free))
                StatRow(label: "Leitura", value: Fmt.rate(m.disk.readPerSec), color: .green)
                StatRow(label: "Escrita", value: Fmt.rate(m.disk.writePerSec), color: .orange)
            }

            if let b = m.battery {
                Card(title: "Bateria", icon: batteryIcon(b), trailing: Fmt.pct(b.percent)) {
                    Bar(value: b.percent, color: b.percent < 0.2 ? .red : .green)
                    StatRow(label: "Estado", value: b.isCharging ? "A carregar" : b.externalPower ? "Ligada à corrente" : "Na bateria")
                    if let mins = b.minutesRemaining {
                        StatRow(label: b.isCharging ? "Até carga completa" : "Tempo restante", value: "\(mins / 60)h \(mins % 60)m")
                    }
                    if let w = b.watts, w > 0.1 { StatRow(label: "Potência", value: String(format: "%.1f W", w)) }
                    if let h = b.health { StatRow(label: "Saúde", value: Fmt.pct(h)) }
                    StatRow(label: "Ciclos", value: "\(b.cycles)")
                    if let t = b.temperature { StatRow(label: "Temperatura", value: String(format: "%.1f ºC", t)) }
                }
            }

            Text(m.machine).font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var memoryBar: some View {
        GeometryReader { g in
            let t = Double(max(m.memory.total, 1))
            HStack(spacing: 0) {
                Rectangle().fill(.purple).frame(width: g.size.width * Double(m.memory.app) / t)
                Rectangle().fill(.orange).frame(width: g.size.width * Double(m.memory.wired) / t)
                Rectangle().fill(.pink).frame(width: g.size.width * Double(m.memory.compressed) / t)
                Rectangle().fill(.gray.opacity(0.5)).frame(width: max(0, g.size.width * Double(m.memory.cached) / t))
                Spacer(minLength: 0)
            }
            .background(.quaternary)
            .clipShape(Capsule())
        }
        .frame(height: 8)
    }

    private var thermalLabel: String {
        switch m.thermal {
        case .nominal: return "Normal"
        case .fair: return "Morno"
        case .serious: return "Quente"
        case .critical: return "Crítico"
        @unknown default: return "—"
        }
    }
    private var thermalColor: Color {
        switch m.thermal {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        default: return .red
        }
    }
    private var pressureLabel: String { m.memory.pressure >= 4 ? "Crítica" : m.memory.pressure >= 2 ? "Elevada" : "Normal" }
    private var pressureColor: Color { m.memory.pressure >= 4 ? .red : m.memory.pressure >= 2 ? .orange : .green }

    private func batteryIcon(_ b: BatterySample) -> String {
        if b.isCharging { return "battery.100.bolt" }
        switch b.percent {
        case ..<0.15: return "battery.0"
        case ..<0.4: return "battery.25"
        case ..<0.65: return "battery.50"
        case ..<0.9: return "battery.75"
        default: return "battery.100"
        }
    }
}

// MARK: - Processos

struct ProcessesView: View {
    @EnvironmentObject var m: Monitor
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Processo").frame(maxWidth: .infinity, alignment: .leading)
                Text("CPU").frame(width: 50, alignment: .trailing)
                Text("Memória").frame(width: 70, alignment: .trailing)
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(m.topProcesses) { p in
                HStack {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(p.name).lineLimit(1)
                        Text("PID \(p.pid) · \(p.elapsed)").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(String(format: "%.1f%%", p.cpu)).frame(width: 50, alignment: .trailing)
                        .foregroundStyle(p.cpu > 80 ? .red : .primary)
                    Text(Fmt.bytes(p.rssKB * 1024)).frame(width: 70, alignment: .trailing)
                }
                .font(.caption.monospacedDigit())
                .padding(.vertical, 3)
                Divider()
            }
        }
    }
}

// MARK: - Definições

struct SettingsView: View {
    @EnvironmentObject var m: Monitor
    @AppStorage("bar.agents") var showAgents = true
    @AppStorage("bar.cpu") var showCPU = true
    @AppStorage("bar.ram") var showRAM = true
    @AppStorage("bar.gpu") var showGPU = false
    @AppStorage("bar.net") var showNet = true
    @AppStorage("bar.battery") var showBattery = false
    @StateObject private var login = Box(SMAppService.mainApp.status == .enabled)
    @StateObject private var loginErr = Box<String?>(nil)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Card(title: "Mostrar na barra de menus", icon: "menubar.rectangle") {
                Toggle("Agentes (a trabalhar / total)", isOn: $showAgents)
                Toggle("CPU", isOn: $showCPU)
                Toggle("RAM", isOn: $showRAM)
                Toggle("GPU", isOn: $showGPU)
                Toggle("Rede", isOn: $showNet)
                Toggle("Bateria", isOn: $showBattery)
            }
            Card(title: "Geral", icon: "slider.horizontal.3") {
                Picker("Atualizar a cada", selection: Binding(
                    get: { m.refreshInterval },
                    set: { m.refreshInterval = $0; m.restart() })) {
                    Text("1 s").tag(1.0); Text("2 s").tag(2.0); Text("3 s").tag(3.0); Text("5 s").tag(5.0)
                }
                Toggle("Notificar quando um agente termina", isOn: $m.notifyOnFinish)
                Toggle("Abrir ao iniciar sessão", isOn: Binding(
                    get: { login.value },
                    set: { on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            login.value = on; loginErr.value = nil
                        } catch { loginErr.value = error.localizedDescription }
                    }))
                if let e = loginErr.value { Text(e).font(.caption).foregroundStyle(.red) }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

/// Substituto de @State (as Command Line Tools não incluem o plugin de macros do SwiftUI).
final class Box<T>: ObservableObject {
    @Published var value: T
    init(_ v: T) { value = v }
}
