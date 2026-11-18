import Foundation
import SwiftUI
import UserNotifications

struct History {
    var values: [Double] = []
    var capacity = 60
    mutating func push(_ v: Double) {
        values.append(v)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }
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

    private let cpuReader = CPUReader()
    private let netReader = NetworkReader()
    private let diskReader = DiskReader()
    private let agentReader = AgentReader()
    private let tempReader = TemperatureReader()
    private let queue = DispatchQueue(label: "agentstats.sampler", qos: .utility)
    private var timer: Timer?
    private var tick = 0
    private var previousStates: [String: AgentState] = [:]

    var workingCount: Int { sessions.filter { $0.state.isWorking }.count }
    var liveAgentCount: Int { agents.filter { !$0.isSubagent }.count }

    init() {
        sample()
        restart()
        if notifyOnFinish {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
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
        let slow = tick % 3 == 1 // bateria e disco não precisam de tanta frequência

        let cpuReader = cpuReader, netReader = netReader, diskReader = diskReader, agentReader = agentReader, tempReader = tempReader
        queue.async {
            let cpu = cpuReader.read()
            let mem = MemoryReader.read()
            let net = netReader.read()
            let disk = diskReader.read()
            let gpu = GPUReader.read()
            let temps = tempReader.read()
            let battery = slow ? BatteryReader.read() : nil
            let procs = ProcessReader.read()
            let agents = agentReader.agentProcesses(from: procs)
            let sessions = agentReader.sessions(processes: agents)
            let top = Array(procs.sorted { $0.cpu > $1.cpu }.prefix(8))

            DispatchQueue.main.async {
                self.cpu = cpu
                self.memory = mem
                self.network = net
                self.disk = disk
                self.gpu = gpu
                self.temps = temps
                if let t = temps?.cpuMax { self.tempHistory.push(t) }
                if slow { self.battery = battery }
                self.topProcesses = top
                self.agents = agents
                self.handleTransitions(sessions)
                self.sessions = sessions
                self.thermal = ProcessInfo.processInfo.thermalState
                self.uptime = Sys.uptime

                self.cpuHistory.push(cpu.total)
                self.memHistory.push(mem.usage)
                self.gpuHistory.push(gpu ?? 0)
                self.downHistory.push(net.downPerSec)
                self.upHistory.push(net.upPerSec)
                self.sampling = false
            }
        }
    }

    private func handleTransitions(_ new: [AgentSession]) {
        defer { previousStates = Dictionary(new.map { ($0.id, $0.state) }, uniquingKeysWith: { a, _ in a }) }
        guard notifyOnFinish, !previousStates.isEmpty else { return }
        for s in new {
            guard let old = previousStates[s.id], old.isWorking, s.state == .waitingUser else { continue }
            let content = UNMutableNotificationContent()
            content.title = "Agente terminou · \(s.project)"
            content.body = s.detail ?? s.title
            content.sound = .default
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    func terminate(pid: Int) {
        kill(pid_t(pid), SIGTERM)
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
    static func model(_ m: String?) -> String? {
        guard let m else { return nil }
        return m.replacingOccurrences(of: "claude-", with: "").replacingOccurrences(of: "-", with: " ").capitalized
    }
}
