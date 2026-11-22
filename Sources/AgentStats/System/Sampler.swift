import Foundation

/// O que ler numa volta de amostragem (as partes caras não precisam de correr sempre).
struct SampleRequest: Sendable {
    var temps: Bool
    var battery: Bool
    var agents: Bool
    var usage: Bool
    var energy: Bool
    var disabled: Set<String>
}

/// Processos e agentes de uma volta.
struct AgentsSample: Sendable {
    var topCPU: [ProcSample]
    var topMemory: [ProcSample]
    var agents: [AgentProcess]
    var sessions: [AgentSession]
}

/// Resultado imutável de uma volta: atravessa do `Sampler` para o main actor como valor.
struct Sample: Sendable {
    var cpu: CPUSample
    var memory: MemorySample
    var network: NetworkSample
    var disk: DiskSample
    var gpu: Double?
    var temps: TemperatureSample?
    var battery: BatterySample?
    var agents: AgentsSample?
    var usage: UsageSnapshot?
    var energy: [AppEnergy]?
}

/// Dono de todos os leitores. Os leitores são classes com estado (valores anteriores para calcular
/// taxas, caches), por isso vivem isolados neste ator: só uma volta corre de cada vez, fora do main thread,
/// e o compilador garante que nada mais lhes toca.
actor Sampler {
    private let cpuReader = CPUReader()
    private let netReader = NetworkReader()
    private let diskReader = DiskReader()
    private let tempReader = TemperatureReader()
    private let procSampler = ProcessSampler()
    private let agentReader = AgentReader()
    private let codexReader = CodexReader()
    private let antigravityReader = AntigravityReader()
    private let otherAIsReader = OtherAIsReader()
    private let copilotReader = CopilotReader()
    private let cursorReader = CursorReader()
    private let openCodeReader = OpenCodeReader()
    private let usageTracker = UsageTracker()
    private let energyReader = EnergyReader()

    func sample(_ r: SampleRequest) -> Sample {
        let off = r.disabled
        var s = Sample(
            cpu: cpuReader.read(),
            memory: MemoryReader.read(),
            network: netReader.read(),
            disk: off.contains("disk") ? DiskSample() : diskReader.read(),
            gpu: off.contains("gpu") ? nil : GPUReader.read(),
            temps: r.temps ? tempReader.read() : nil,
            battery: r.battery ? BatteryReader.read() : nil
        )
        if r.agents && !off.contains("procs") {
            let procs = procSampler.read()
            let agents = agentReader.agentProcesses(from: procs)
            let baseSessions = agentReader.sessions(processes: agents) +
                               codexReader.sessions() +
                               antigravityReader.sessions(processes: agents) +
                               copilotReader.sessions() + cursorReader.sessions() + openCodeReader.sessions()
            // Copilot, OpenCode e Cursor já têm sessões vindas dos ficheiros: o processo vivo na mesma
            // pasta não aparece outra vez como sessão genérica.
            let fileKinds = ["Copilot": "Copilot", "OpenCode": "OpenCode", "Cursor Agent": "Cursor"]
            let otherSessions = otherAIsReader.sessions(processes: agents, existingSessions: baseSessions).filter { o in
                guard let k = fileKinds[o.kind] else { return true }
                return !baseSessions.contains { $0.kind == k && $0.cwd == o.cwd }
            }
            let sessions = off.contains("sessions") ? [] :
                (baseSessions + otherSessions).sorted { $0.lastActivity > $1.lastActivity }
            s.agents = AgentsSample(
                topCPU: Array(procs.sorted { $0.cpu > $1.cpu }.prefix(12)),
                topMemory: Array(procs.sorted { $0.rssKB > $1.rssKB }.prefix(12)),
                agents: agents,
                sessions: sessions)
        }
        if r.usage { s.usage = usageTracker.update() }
        if r.energy { s.energy = energyReader.read() }
        return s
    }
}
