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

    private let cpuReader = CPUReader()
    private let netReader = NetworkReader()
    private let diskReader = DiskReader()
    private let agentReader = AgentReader()
    private let tempReader = TemperatureReader()
    private let codexReader = CodexReader()
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

        let cpuReader = cpuReader, netReader = netReader, diskReader = diskReader, agentReader = agentReader, tempReader = tempReader, codexReader = codexReader
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
            let sessions = (agentReader.sessions(processes: agents) + codexReader.sessions())
                .sorted { $0.lastActivity > $1.lastActivity }
            let top = Array(procs.sorted { $0.cpu > $1.cpu }.prefix(12))
            let topMem = Array(procs.sorted { $0.rssKB > $1.rssKB }.prefix(12))

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
                self.topMemory = topMem
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
