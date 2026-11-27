import AppKit

/// Os modos de diagnóstico da linha de comandos (`--smoke`, `--bench`, `--dump`). Ficam na versão de produção
/// de propósito: estão no README para quem quer ver o que a app lê, e o CI corre o `--smoke` na build final.
/// Só escrevem no stdout de quem os chamou; nunca correm no arranque normal.
extension AgentStatsApp {
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
            print("  • [\(s.kind)] \(s.title) | \(L(s.state.label)) | \(s.detail ?? "") | \(s.project) | \(s.model ?? "-") | pid \(s.process?.pid ?? 0)")
        }
    }
}
