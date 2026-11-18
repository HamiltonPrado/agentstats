import Foundation
import SwiftUI
import AppKit
import UserNotifications

struct History {
    var values: [Double] = []
    var capacity = 60
    mutating func push(_ v: Double) {
        values.append(v)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }
}

struct SystemAlert: Identifiable {
    enum Kind: String { case cpu, temp }
    var id: String { kind.rawValue }
    let kind: Kind
    let value: String
    let since: Date
    let detail: String?
}

@MainActor
final class Monitor: ObservableObject {
    @Published var cpu = CPUSample()
    @Published var memory = MemorySample()
    @Published var network = NetworkSample()
    @Published var disk = DiskSample()
    @Published var gpu: Double?
    @Published var temps: TemperatureSample?
    @Published var battery: BatterySample?
    @Published var topProcesses: [ProcSample] = []
    @Published var topMemory: [ProcSample] = []
    @Published var agents: [AgentProcess] = []
    @Published var sessions: [AgentSession] = []
    @Published var thermal: ProcessInfo.ThermalState = .nominal
    @Published var uptime: TimeInterval = 0

    @Published var cpuHistory = History()
    @Published var memHistory = History()
    @Published var gpuHistory = History()
    @Published var downHistory = History()
    @Published var upHistory = History()
    @Published var tempHistory = History()

    let machine: String = Sys.sysctlString("machdep.cpu.brand_string") ?? "Mac"
    let model: String = Sys.sysctlString("hw.model") ?? ""
    let pCores = Sys.sysctlInt("hw.perflevel0.logicalcpu", Int32.self).map(Int.init)
    let eCores = Sys.sysctlInt("hw.perflevel1.logicalcpu", Int32.self).map(Int.init)

    @AppStorage("refreshInterval") var refreshInterval: Double = 2
    @AppStorage("notifyOnFinish") var notifyOnFinish = true

    // Alertas
    @AppStorage("alert.cpu.enabled") var cpuAlertEnabled = true
    @AppStorage("alert.cpu.threshold") var cpuThreshold: Double = 0.85
    @AppStorage("alert.temp.enabled") var tempAlertEnabled = true
    @AppStorage("alert.temp.threshold") var tempThreshold: Double = 85
    @Published var activeAlerts: [SystemAlert] = []
    @Published var usage = UsageSnapshot()
    /// Com o painel aberto tudo é atualizado a cada amostra; fechado, as partes caras abrandam.
    var panelOpen = false
    private var highSince: [SystemAlert.Kind: Date] = [:]
    private var lastNotified: [SystemAlert.Kind: Date] = [:]
    /// Tempo que o valor tem de ficar acima do limite antes de alertar (evita picos curtos).
    static let alertSustain: TimeInterval = 20
    static let alertCooldown: TimeInterval = 10 * 60

    private let cpuReader = CPUReader()
    private let netReader = NetworkReader()
    private let diskReader = DiskReader()
    private let agentReader = AgentReader()
    private let tempReader = TemperatureReader()
    private let codexReader = CodexReader()
    private let procSampler = ProcessSampler()
    private let usageTracker = UsageTracker()
    private var lastTemps: TemperatureSample?
    private let queue = DispatchQueue(label: "agentstats.sampler", qos: .utility)
    private var timer: Timer?
    private var tick = 0
    private var previousStates: [String: AgentState] = [:]

    /// Diagnóstico: AGENTSTATS_DISABLE=temps,procs,sessions,gpu,disk,icon desliga partes para medir custos.
    static let disabled = Set((ProcessInfo.processInfo.environment["AGENTSTATS_DISABLE"] ?? "").split(separator: ",").map(String.init))

    var workingCount: Int { sessions.filter { $0.state.isWorking }.count }
    var needsAttentionCount: Int { sessions.filter { $0.state.needsAttention }.count }
    var liveAgentCount: Int { agents.filter { !$0.isSubagent }.count }

    init() {
        sample()
        restart()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func restart() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: max(refreshInterval, 1), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    private var sampling = false

    func sample() {
        guard !sampling else { return }
        sampling = true
        tick += 1
        let slow = tick % 2 == 1 // bateria e temperaturas mudam devagar: metade da frequência

        let off = Self.disabled
        let needTemps = !off.contains("temps") && (tick % 3 == 1 || lastTemps == nil)  // temperaturas: de 6 em 6 s
        let cpuReader = cpuReader, netReader = netReader, diskReader = diskReader, agentReader = agentReader, tempReader = tempReader, codexReader = codexReader, procSampler = procSampler, usageTracker = usageTracker
        let needUsage = !off.contains("usage") && tick % 5 == 1   // tokens: de 10 em 10 s
        // Processos e agentes: a cada amostra com o painel aberto; com ele fechado, de 2 em 2 (4 s).
        let needAgents = panelOpen || tick % 2 == 1 || agents.isEmpty
        queue.async {
            let cpu = cpuReader.read()
            let mem = MemoryReader.read()
            let net = netReader.read()
            let disk = off.contains("disk") ? DiskSample() : diskReader.read()
            let gpu = off.contains("gpu") ? nil : GPUReader.read()
            let temps = needTemps ? tempReader.read() : nil
            let battery = slow ? BatteryReader.read() : nil
            let procs = !needAgents || off.contains("procs") ? nil : procSampler.read()
            let agents = procs.map { agentReader.agentProcesses(from: $0) }
            let sessions = agents.map { ag in
                off.contains("sessions") ? [] : (agentReader.sessions(processes: ag) + codexReader.sessions())
                    .sorted { $0.lastActivity > $1.lastActivity }
            }
            let usage = needUsage ? usageTracker.update() : nil
            let top = procs.map { Array($0.sorted { $0.cpu > $1.cpu }.prefix(12)) }
            let topMem = procs.map { Array($0.sorted { $0.rssKB > $1.rssKB }.prefix(12)) }

            DispatchQueue.main.async {
                self.cpu = cpu
                self.memory = mem
                self.network = net
                self.disk = disk
                self.gpu = gpu
                if let temps { self.temps = temps; self.lastTemps = temps }
                if let t = self.temps?.cpuMax { self.tempHistory.push(t) }
                if slow { self.battery = battery }
                if let usage { self.usage = usage }
                if let top, let topMem, let agents, let sessions {
                    self.topProcesses = top
                    self.topMemory = topMem
                    self.agents = agents
                    self.handleTransitions(sessions)
                    self.sessions = sessions
                }
                self.thermal = ProcessInfo.processInfo.thermalState
                self.uptime = Sys.uptime

                self.cpuHistory.push(cpu.total)
                self.memHistory.push(mem.usage)
                self.gpuHistory.push(gpu ?? 0)
                self.downHistory.push(net.downPerSec)
                self.upHistory.push(net.upPerSec)
                self.checkAlerts()
                self.sampling = false
            }
        }
    }

    private func handleTransitions(_ new: [AgentSession]) {
        defer { previousStates = Dictionary(new.map { ($0.id, $0.state) }, uniquingKeysWith: { a, _ in a }) }
        guard notifyOnFinish, !previousStates.isEmpty else { return }
        for s in new {
            guard let old = previousStates[s.id] else { continue }
            let content = UNMutableNotificationContent()
            if s.state.needsAttention && !old.needsAttention {
                content.title = s.state == .needsAnswer ? "Agente tem uma pergunta · \(s.project)" : "Agente precisa de aprovação · \(s.project)"
                content.body = s.detail ?? s.title
                content.interruptionLevel = .timeSensitive
            } else if (old.isWorking || old.needsAttention), s.state == .waitingUser {
                content.title = "Agente terminou · \(s.project)"
                content.body = s.detail ?? s.title
            } else { continue }
            content.sound = .default
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    // MARK: Alertas

    private func checkAlerts(now: Date = Date()) {
        let culprit = topProcesses.first.map { "\(NSRunningApplication(processIdentifier: pid_t($0.pid))?.localizedName ?? $0.name) (\(String(format: "%.0f%%", $0.cpu)))" }

        var alerts: [SystemAlert] = []
        // CPU: dispara acima do limite, só desliga 5 pontos abaixo (histerese)
        if let a = evaluate(.cpu, enabled: cpuAlertEnabled, value: cpu.total,
                            on: cpuThreshold, off: cpuThreshold - 0.05, now: now) {
            alerts.append(SystemAlert(kind: .cpu, value: Fmt.pct(cpu.total), since: a, detail: culprit))
        }
        if let t = temps?.cpuMax,
           let a = evaluate(.temp, enabled: tempAlertEnabled, value: t,
                            on: tempThreshold, off: tempThreshold - 5, now: now) {
            alerts.append(SystemAlert(kind: .temp, value: String(format: "%.0f ºC", t), since: a, detail: culprit))
        }
        if alerts.map(\.kind) != activeAlerts.map(\.kind) || alerts.map(\.value) != activeAlerts.map(\.value) {
            activeAlerts = alerts
        }

        for alert in alerts where now.timeIntervalSince(lastNotified[alert.kind] ?? .distantPast) > Self.alertCooldown {
            lastNotified[alert.kind] = now
            let content = UNMutableNotificationContent()
            content.title = alert.kind == .cpu ? "CPU alta: \(alert.value)" : "Temperatura alta: \(alert.value)"
            content.body = alert.detail.map { "Processo mais pesado: \($0)" } ?? "Há mais de \(Int(Self.alertSustain)) s acima do limite."
            content.sound = .default
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "alert-\(alert.kind.rawValue)", content: content, trigger: nil))
        }
    }

    /// Devolve desde quando o alerta está ativo, ou nil se não está.
    private func evaluate(_ kind: SystemAlert.Kind, enabled: Bool, value: Double, on: Double, off: Double, now: Date) -> Date? {
        guard enabled else { highSince[kind] = nil; return nil }
        let wasHigh = highSince[kind] != nil
        if value >= on || (wasHigh && value > off) {
            if highSince[kind] == nil { highSince[kind] = now }
        } else {
            highSince[kind] = nil
        }
        guard let since = highSince[kind], now.timeIntervalSince(since) >= Self.alertSustain else { return nil }
        return since
    }

    func terminate(pid: Int, force: Bool = false) {
        kill(pid_t(pid), force ? SIGKILL : SIGTERM)
    }
}

// MARK: - Formatação

enum Fmt {
    static func bytes(_ b: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .memory)
    }
    static func rate(_ bps: Double, short: Bool = false) -> String {
        let units = short ? ["B", "K", "M", "G"] : ["B/s", "KB/s", "MB/s", "GB/s"]
        var v = bps, i = 0
        while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
        let num = v >= 100 || i == 0 ? String(format: "%.0f", v) : String(format: "%.1f", v)
        return num + (short ? units[i] : " " + units[i])
    }
    static func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }
    /// 950 → "950"; 12 300 → "12,3k"; 4 560 000 → "4,6M"
    static func tokens(_ n: Int) -> String {
        let d = Double(n)
        let s: String
        switch d {
        case ..<1000: return "\(n)"
        case ..<1_000_000: s = String(format: d < 10_000 ? "%.1fk" : "%.0fk", d / 1000)
        case ..<1_000_000_000: s = String(format: d < 10_000_000 ? "%.1fM" : "%.0fM", d / 1_000_000)
        default: s = String(format: "%.1fB", d / 1_000_000_000)
        }
        return s.replacingOccurrences(of: ".", with: ",")
    }
    static func duration(_ t: TimeInterval) -> String {
        let s = Int(t)
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
    static func ago(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 5 { return "agora" }
        if s < 60 { return "há \(s)s" }
        if s < 3600 { return "há \(s / 60) min" }
        return "há \(s / 3600)h"
    }
    /// "claude-opus-5-5" → "Opus 5.5"; "claude-sonnet-4-5-20250929" → "Sonnet 4.5"
    static func model(_ m: String?) -> String? {
        guard let m else { return nil }
        let parts = m.replacingOccurrences(of: "claude-", with: "").components(separatedBy: "-")
            .filter { !($0.count >= 8 && $0.allSatisfy(\.isNumber)) }
        let words = parts.filter { !$0.allSatisfy(\.isNumber) }.map { $0.capitalized }
        let version = parts.filter { $0.allSatisfy(\.isNumber) }.joined(separator: ".")
        return (words + (version.isEmpty ? [] : [version])).joined(separator: " ")
    }
    static func minutes(_ m: Int) -> String { m >= 60 ? "\(m / 60)h \(m % 60)min" : "\(m) min" }
    /// "02-22:16:01" (formato etime do ps) → "2d 22h"
    static func etime(_ e: String) -> String {
        var days = 0, rest = Substring(e)
        if let dash = e.firstIndex(of: "-") { days = Int(e[..<dash]) ?? 0; rest = e[e.index(after: dash)...] }
        let f = rest.split(separator: ":").compactMap { Int($0) }
        let (h, m, s) = f.count == 3 ? (f[0], f[1], f[2]) : (0, f.first ?? 0, f.count > 1 ? f[1] : 0)
        if days > 0 { return "\(days)d \(h)h" }
        if h > 0 { return "\(h)h \(m)min" }
        if m > 0 { return "\(m)min" }
        return "\(s)s"
    }
}
