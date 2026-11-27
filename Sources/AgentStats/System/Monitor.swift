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

/// Estado observado pela interface. Com `@Observable`, cada vista só é redesenhada quando muda
/// uma propriedade que ela própria lê (com `ObservableObject`, qualquer mudança redesenhava todas).
@MainActor
@Observable
final class Monitor {
    var cpu = CPUSample()
    var memory = MemorySample()
    var network = NetworkSample()
    var disk = DiskSample()
    var gpu: Double?
    var temps: TemperatureSample?
    var battery: BatterySample?
    var topProcesses: [ProcSample] = []
    var topMemory: [ProcSample] = []
    var agents: [AgentProcess] = []
    var sessions: [AgentSession] = []
    var thermal: ProcessInfo.ThermalState = .nominal
    var uptime: TimeInterval = 0
    var activeAlerts: [SystemAlert] = []
    var usage = UsageSnapshot()
    /// As apps que mais gastaram energia na última leitura (nil até haver duas leituras).
    var energyApps: [AppEnergy]?
    var energySinceUnplug = EnergySinceUnplug()
    var batteryDays: [BatteryDay] = []
    @ObservationIgnored private var demoMode = false
    /// Limites do plano do Claude (pelo Claude Code ou, em alternativa, pela app Claude).
    var claudeLimits: PlanLimits?
    var claudeLimitsStatus: ClaudeLimitsFetcher.Outcome?
    var activityHistory: [AgentActivityRecord] = []

    var cpuHistory = History()
    var memHistory = History()
    var gpuHistory = History()
    var downHistory = History()
    var upHistory = History()
    var tempHistory = History()
    /// Últimas 24 h, um ponto por minuto (guardado em disco).
    var day: [MinuteSample] = []

    @ObservationIgnored var machine: String = Sys.sysctlString("machdep.cpu.brand_string") ?? "Mac"
    @ObservationIgnored var model: String = Sys.sysctlString("hw.model") ?? ""
    @ObservationIgnored var pCores = Sys.sysctlInt("hw.perflevel0.logicalcpu", Int32.self).map(Int.init)
    @ObservationIgnored var eCores = Sys.sysctlInt("hw.perflevel1.logicalcpu", Int32.self).map(Int.init)

    // MARK: Definições (guardadas em UserDefaults, mas observáveis: a interface atualiza logo)

    var refreshInterval: Double = Pref.double("refreshInterval", 2) {
        didSet { Pref.set(refreshInterval, "refreshInterval"); restart() }
    }
    var notifyOnFinish: Bool = Pref.bool("notifyOnFinish", true) { didSet { Pref.set(notifyOnFinish, "notifyOnFinish") } }
    /// Só avisa quando uma tarefa termina se tiver trabalhado pelo menos isto (0 = todas).
    var finishMinMinutes: Double = Pref.double("notify.finishMinMinutes", 2) { didSet { Pref.set(finishMinMinutes, "notify.finishMinMinutes") } }
    var cpuAlertEnabled: Bool = Pref.bool("alert.cpu.enabled", true) { didSet { Pref.set(cpuAlertEnabled, "alert.cpu.enabled") } }
    var cpuThreshold: Double = Pref.double("alert.cpu.threshold", 0.85) { didSet { Pref.set(cpuThreshold, "alert.cpu.threshold") } }
    var tempAlertEnabled: Bool = Pref.bool("alert.temp.enabled", true) { didSet { Pref.set(tempAlertEnabled, "alert.temp.enabled") } }
    var tempThreshold: Double = Pref.double("alert.temp.threshold", 85) { didSet { Pref.set(tempThreshold, "alert.temp.threshold") } }
    var memoryAlertEnabled: Bool = Pref.bool("alert.memory.enabled", true) { didSet { Pref.set(memoryAlertEnabled, "alert.memory.enabled") } }
    var memoryThreshold: Double = Pref.double("alert.memory.threshold", 0.9) { didSet { Pref.set(memoryThreshold, "alert.memory.threshold") } }
    var diskAlertEnabled: Bool = Pref.bool("alert.disk.enabled", true) { didSet { Pref.set(diskAlertEnabled, "alert.disk.enabled") } }
    var diskThreshold: Double = Pref.double("alert.disk.threshold", 0.9) { didSet { Pref.set(diskThreshold, "alert.disk.threshold") } }
    var batteryAlertEnabled: Bool = Pref.bool("alert.battery.enabled", true) { didSet { Pref.set(batteryAlertEnabled, "alert.battery.enabled") } }
    var batteryThreshold: Double = Pref.double("alert.battery.threshold", 0.2) { didSet { Pref.set(batteryThreshold, "alert.battery.threshold") } }
    var waitingAlertEnabled: Bool = Pref.bool("alert.waiting.enabled", true) { didSet { Pref.set(waitingAlertEnabled, "alert.waiting.enabled") } }
    var waitingAlertMinutes: Double = Pref.double("alert.waiting.minutes", 10) { didSet { Pref.set(waitingAlertMinutes, "alert.waiting.minutes") } }
    var keepAwake = false {
        didSet { keepAwakeController.setEnabled(keepAwake, minutes: keepAwakeMinutes) }
    }
    /// No manter acordado manual: também o ecrã ligado (o dos agentes deixa-o apagar-se).
    var keepDisplayOn: Bool = Pref.bool("power.keepDisplayOn", false) {
        didSet { Pref.set(keepDisplayOn, "power.keepDisplayOn"); keepAwakeController.keepDisplayOn = keepDisplayOn }
    }
    var keepAwakeForAgents: Bool = Pref.bool(AgentAwake.key, false) {
        didSet { Pref.set(keepAwakeForAgents, AgentAwake.key); updateAgentAwake() }
    }
    /// Está agora a impedir o Mac de adormecer por causa dos agentes.
    var holdingForAgents = false
    var limitAlertsEnabled: Bool = Pref.bool(LimitWatch.enabledKey, true) {
        didSet { Pref.set(limitAlertsEnabled, LimitWatch.enabledKey) }
    }
    var limitAlertLevel: Double = Pref.double(LimitWatch.levelKey, LimitWatch.defaultLevel) {
        didSet { Pref.set(limitAlertLevel, LimitWatch.levelKey) }
    }
    var keepAwakeMinutes: Double = Pref.double("power.keepAwake.minutes", 60) {
        didSet {
            Pref.set(keepAwakeMinutes, "power.keepAwake.minutes")
            if keepAwake { keepAwakeController.setEnabled(true, minutes: keepAwakeMinutes) }
        }
    }

    /// Com o painel aberto tudo é atualizado a cada amostra; fechado, as partes caras abrandam.
    @ObservationIgnored var panelOpen = false
    /// Chamado depois de aplicar cada amostra (o ícone da barra de menus usa-o).
    @ObservationIgnored var onUpdate: (() -> Void)?

    /// Tempo que o valor tem de ficar acima do limite antes de alertar (evita picos curtos).
    static let alertSustain: TimeInterval = 20
    static let alertCooldown: TimeInterval = 10 * 60
    /// Diagnóstico: AGENTSTATS_DISABLE=temps,procs,sessions,usage,energy,gpu,disk,icon desliga partes para medir custos.
    static let disabled = Set((ProcessInfo.processInfo.environment["AGENTSTATS_DISABLE"] ?? "").split(separator: ",").map(String.init))

    @ObservationIgnored private let sampler = Sampler()
    @ObservationIgnored let keepAwakeController = KeepAwakeController()
    @ObservationIgnored private let agentAwakeController = KeepAwakeController(reason: "AgentStats: agentes a trabalhar")
    @ObservationIgnored private var lastWorking: Date?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var tick = 0
    @ObservationIgnored private var sampling = false
    @ObservationIgnored private var previousStates: [String: AgentState] = [:]
    /// Usado também em Monitor+Alerts.swift (por isso não é private).
    @ObservationIgnored var highSince: [SystemAlert.Kind: Date] = [:]
    /// Usado também em Monitor+Alerts.swift (por isso não é private).
    @ObservationIgnored var lastNotified: [SystemAlert.Kind: Date] = [:]
    @ObservationIgnored private var minuteAcc = MinuteAccumulator()
    @ObservationIgnored private var lastHistorySave = Date()
    /// Usado também em Monitor+Alerts.swift (por isso não é private).
    @ObservationIgnored var lastAgentHistorySave = Date.distantPast

    var workingCount: Int { sessions.filter { $0.state.isWorking }.count }
    var needsAttentionCount: Int { sessions.filter { $0.state.needsAttention }.count }
    var liveAgentCount: Int { agents.filter { !$0.isSubagent }.count }
    /// Limites que ainda valem (as janelas que já renovaram saem).
    var planLimits: [PlanLimits] {
        let now = Date()
        return [claudeLimits, usage.codexLimits].compactMap { $0?.current(now: now) }
    }

    /// Porque é que o Claude não aparece nos limites, quando se sabe.
    var claudeLimitsHint: String? {
        guard !planLimits.contains(where: { $0.provider == .claude }) else { return nil }
        switch claudeLimitsStatus {
        case .signedOut?: return "Claude: sem sessão no Claude Code da linha de comandos. No Terminal, corre claude e depois /login."
        case .notInstalled?: return "Claude: precisa do Claude Code da linha de comandos instalado."
        default: return nil
        }
    }

    /// `demo`: não lê o Mac, não carrega nem grava históricos e não pede permissões (ver `DemoData`).
    init(demo: Bool = false) {
        demoMode = demo
        guard !demo else { return }
        batteryDays = BatteryHistory.load()
        day = History24h.load()
        activityHistory = AgentActivityHistoryStore.load()
        keepAwakeController.onTimeout = { [weak self] in self?.keepAwake = false }
        keepAwakeController.keepDisplayOn = keepDisplayOn
        sample()
        restart()
        // @Sendable: o sistema chama esta resposta numa fila de fundo. Sem isto, a closure herdava o
        // main actor do init e, compilada com o Swift do Xcode 16, a app rebentava ao arrancar (v1.16).
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { @Sendable _, _ in }
    }

    func restart() {
        timer?.invalidate()
        timer = Timer.common(withTimeInterval: max(refreshInterval, 1), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    func sample() {
        guard !sampling else { return }
        sampling = true
        tick += 1
        let off = Self.disabled
        let request = SampleRequest(
            temps: !off.contains("temps") && (tick % 3 == 1 || temps == nil),        // de 6 em 6 s
            battery: tick % 2 == 1,
            agents: panelOpen || tick % 2 == 1 || agents.isEmpty,                       // painel fechado: de 4 em 4 s
            usage: !off.contains("usage") && tick % 5 == 1,                             // de 10 em 10 s
            energy: !off.contains("energy") && (tick == 1 || tick % 5 == 3),           // de 10 em 10 s
            disabled: off)
        if !off.contains("limits") && Pref.bool(PrefKey.showLimits, true) { refreshClaudeLimits() }
        // O Task herda o main actor; o trabalho pesado corre no ator Sampler e volta como um valor.
        Task {
            let s = await sampler.sample(request)
            apply(s)
            sampling = false
        }
    }

    // MARK: Limites do Claude

    @ObservationIgnored private var nextClaudeCheck = Date.distantPast
    @ObservationIgnored private var claudeChecking = false

    /// Pergunta ao Claude Code de tempos a tempos (é um processo que arranca e sai em ~1 s).
    /// Sem sessão iniciada ou sem Claude Code, volta a tentar muito mais tarde.
    func refreshClaudeLimits(force: Bool = false) {
        guard !claudeChecking, force || Date() >= nextClaudeCheck else { return }
        claudeChecking = true
        Task {
            defer { claudeChecking = false }
            let outcome = await Blocking.run(qos: .utility) { ClaudeLimitsFetcher.fetch() }
            let now = Date()
            claudeLimitsStatus = outcome
            switch outcome {
            case .limits(let l):
                claudeLimits = l
                nextClaudeCheck = now.addingTimeInterval(panelOpen ? 5 * 60 : 15 * 60)
            case .signedOut, .notInstalled, .failed:
                claudeLimits = Self.claudeDesktopLimits(now: now)
                nextClaudeCheck = now.addingTimeInterval(Self.claudeRetry(after: outcome))
            }
        }
    }

    /// Sem Claude Code volta a ver daqui a 6 h; com erro daqui a 15 min; sem sessão daqui a 10 min.
    static func claudeRetry(after outcome: ClaudeLimitsFetcher.Outcome) -> TimeInterval {
        switch outcome {
        case .notInstalled: 6 * 3600
        case .failed: 15 * 60
        default: 10 * 60
        }
    }

    /// A app Claude guarda os limites que vai vendo; só vale se a leitura for recente (menos de 1 h).
    static func claudeDesktopLimits(now: Date) -> PlanLimits? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
        guard let data = try? Data(contentsOf: url), data.count < 4 << 20,
              let l = PlanLimitsParser.claudeDesktopHistory(data), now.timeIntervalSince(l.observedAt) < 3600 else { return nil }
        return l
    }

    /// Uma leitura por dia, gravada só quando muda.
    private func recordBatteryDay(_ b: BatterySample) {
        guard !demoMode, b.cycles > 0 || b.health != nil else { return }
        let next = BatteryHistory.recording(batteryDays, health: b.health.map { ($0 * 1000).rounded() / 1000 }, cycles: b.cycles, now: Date())
        guard next != batteryDays else { return }
        batteryDays = next
        BatteryHistory.save(next)
    }

    private func apply(_ s: Sample) {
        cpu = s.cpu
        memory = s.memory
        network = s.network
        disk = s.disk
        gpu = s.gpu
        if let t = s.temps { temps = t }
        if let t = temps?.cpuMax { tempHistory.push(t) }
        if let b = s.battery {
            battery = b
            recordBatteryDay(b)
            if !demoMode { RulesStore.shared.battery(percent: b.percent, externalPower: b.externalPower) }
        }
        if let u = s.usage { usage = u }
        if let e = s.energy {
            energyApps = e
            let onBattery = battery.map { !$0.externalPower && !$0.isCharging } ?? false
            energySinceUnplug.add(e, onBattery: onBattery, now: Date())
        }
        if let a = s.agents {
            topProcesses = a.topCPU
            topMemory = a.topMemory
            agents = a.agents
            handleTransitions(a.sessions)
            updateAgentHistory(a.sessions)
            checkWaitingReminders(a.sessions)
            if a.sessions.contains(where: { $0.state.isWorking }) { lastWorking = Date() }
            sessions = a.sessions
        }
        thermal = ProcessInfo.processInfo.thermalState
        uptime = Sys.uptime
        cpuHistory.push(s.cpu.total)
        memHistory.push(s.memory.usage)
        gpuHistory.push(s.gpu ?? 0)
        downHistory.push(s.network.downPerSec)
        upHistory.push(s.network.upPerSec)
        checkAlerts()
        checkLimitAlerts()
        checkBudgetAndSummary()
        updateAgentAwake()
        recordMinute()
        onUpdate?()
    }

    // MARK: Histórico de 24 h

    private func recordMinute(now: Date = Date()) {
        if let done = minuteAcc.add(cpu: cpu.total, mem: memory.usage, temp: temps?.cpuMax, battery: battery.map(\.percent),
                                    working: workingCount, attention: needsAttentionCount > 0, at: now) {
            day = History24h.pruned(day + [done], now: now)
        }
        if now.timeIntervalSince(lastHistorySave) > 5 * 60 { saveHistory() }
    }

    func saveHistory() {
        lastHistorySave = Date()
        History24h.save(day)
        AgentActivityHistoryStore.save(activityHistory)
        lastAgentHistorySave = lastHistorySave
    }

    private func updateAgentHistory(_ newSessions: [AgentSession], now: Date = Date()) {
        let update = AgentActivityHistoryStore.updating(activityHistory, sessions: newSessions, usage: usage, now: now)
        activityHistory = update.records
        if update.changed && now.timeIntervalSince(lastAgentHistorySave) >= 30 {
            AgentActivityHistoryStore.save(activityHistory)
            lastAgentHistorySave = now
        }
    }

    // MARK: Abrir o agente

    /// Traz para a frente a app onde o agente corre: sobe pela cadeia de processos até à primeira app
    /// com janela (Claude, Terminal, iTerm, VS Code…). O Codex corre dentro da app ChatGPT.
    /// Devolve false se não encontrar nenhuma app.
    @discardableResult
    func focus(_ session: AgentSession) -> Bool {
        if let p = session.process {
            for pid in [p.pid] + p.ancestors {
                if let app = NSRunningApplication(processIdentifier: pid_t(pid)), app.activationPolicy == .regular {
                    return app.activate(options: [.activateAllWindows])
                }
            }
        }
        if session.kind == "Codex",
           let app = NSWorkspace.shared.runningApplications.first(where: { ["ChatGPT", "Codex"].contains($0.localizedName ?? "") }) {
            return app.activate(options: [.activateAllWindows])
        }
        return false
    }

    func focus(sessionID: String) {
        if let s = sessions.first(where: { $0.id == sessionID }) { focus(s) }
    }

    /// Início da tarefa em curso de cada sessão e o custo da sessão nesse momento.
    @ObservationIgnored private var taskStart: [String: (date: Date, cost: Double)] = [:]

    private func handleTransitions(_ new: [AgentSession], now: Date = Date()) {
        defer { previousStates = Dictionary(new.map { ($0.id, $0.state) }, uniquingKeysWith: { a, _ in a }) }
        var finished: [String: (duration: TimeInterval, cost: Double?)] = [:]
        for s in new {
            if s.state.isWorking || s.state.needsAttention {
                if taskStart[s.id] == nil { taskStart[s.id] = (now, usage.perSessionCost[s.id] ?? 0) }
            } else if let start = taskStart.removeValue(forKey: s.id) {
                let cost = usage.perSessionCost[s.id].map { $0 - start.cost }
                finished[s.id] = (now.timeIntervalSince(start.date), cost.flatMap { $0 > 0.005 ? $0 : nil })
            }
        }
        let live = Set(new.map(\.id))
        taskStart = taskStart.filter { live.contains($0.key) }
        // As regras disparam mesmo com as notificações dos agentes desligadas.
        if !previousStates.isEmpty {
            for s in new {
                guard let old = previousStates[s.id] else { continue }
                if s.state.needsAttention && !old.needsAttention { RulesStore.shared.fire(.agentNeedsYou) }
                else if (old.isWorking || old.needsAttention), s.state == .waitingUser, finished[s.id] != nil { RulesStore.shared.fire(.agentFinished) }
            }
        }
        guard notifyOnFinish, !previousStates.isEmpty else { return }
        for s in new {
            guard let old = previousStates[s.id] else { continue }
            let content = UNMutableNotificationContent()
            if s.state.needsAttention && !old.needsAttention {
                content.title = L(s.state == .needsAnswer ? String(localized: "Agente tem uma pergunta · \(s.project)") : String(localized: "Agente precisa de aprovação · \(s.project)"))
                content.body = L(s.detail ?? s.title)
                content.interruptionLevel = .timeSensitive
            } else if (old.isWorking || old.needsAttention), s.state == .waitingUser,
                      let done = finished[s.id], done.duration >= finishMinMinutes * 60 {
                content.title = L(String(localized: "Agente terminou · \(s.project)"))
                let worked = done.duration < 60 ? "\(Int(done.duration)) s" : Fmt.duration(done.duration)
                var summary = String(localized: "Trabalhou \(worked)")
                if let c = done.cost { summary += " · ~" + Fmt.usd(c) }
                content.body = L(summary + "\n" + (s.detail ?? s.title))
            } else { continue }
            content.userInfo = ["session": s.id]   // clicar na notificação abre o agente
            content.sound = .default
            Notify.add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    // MARK: Limites e energia

    private func updateAgentAwake(now: Date = Date()) {
        let hold = keepAwakeForAgents && AgentAwake.shouldHold(working: workingCount, lastWorking: lastWorking, now: now)
        if hold != agentAwakeController.isHolding { agentAwakeController.setEnabled(hold, minutes: 0) }
        if holdingForAgents != hold { holdingForAgents = hold }
    }

    var budgetEnabled: Bool = Pref.bool(Budget.enabledKey, false) { didSet { Pref.set(budgetEnabled, Budget.enabledKey) } }
    var budgetAmount: Double = Pref.double(Budget.amountKey, 20) { didSet { Pref.set(budgetAmount, Budget.amountKey) } }
    var budgetPeriod: Budget.Period = Budget.Period(rawValue: Pref.string(Budget.periodKey) ?? "") ?? .day {
        didSet { Pref.set(budgetPeriod.rawValue, Budget.periodKey) }
    }
    var weeklySummaryEnabled: Bool = Pref.bool(WeeklySummary.enabledKey, true) { didSet { Pref.set(weeklySummaryEnabled, WeeklySummary.enabledKey) } }

    var budgetSpent: Double { Budget.spent(usage.week, period: budgetPeriod, now: Date()) }

    /// Depois de importar definições: as propriedades acima guardam uma cópia lida no arranque, e sem isto
    /// a importação só contava depois de reiniciar (e mexer num controlo voltava a escrever o valor antigo).
    func reloadFromDefaults() {
        func load<T: Equatable>(_ path: ReferenceWritableKeyPath<Monitor, T>, _ value: T) {
            if self[keyPath: path] != value { self[keyPath: path] = value }
        }
        load(\.refreshInterval, Pref.double("refreshInterval", 2))
        load(\.notifyOnFinish, Pref.bool("notifyOnFinish", true))
        load(\.finishMinMinutes, Pref.double("notify.finishMinMinutes", 2))
        load(\.cpuAlertEnabled, Pref.bool("alert.cpu.enabled", true))
        load(\.cpuThreshold, Pref.double("alert.cpu.threshold", 0.85))
        load(\.tempAlertEnabled, Pref.bool("alert.temp.enabled", true))
        load(\.tempThreshold, Pref.double("alert.temp.threshold", 85))
        load(\.memoryAlertEnabled, Pref.bool("alert.memory.enabled", true))
        load(\.memoryThreshold, Pref.double("alert.memory.threshold", 0.9))
        load(\.diskAlertEnabled, Pref.bool("alert.disk.enabled", true))
        load(\.diskThreshold, Pref.double("alert.disk.threshold", 0.9))
        load(\.batteryAlertEnabled, Pref.bool("alert.battery.enabled", true))
        load(\.batteryThreshold, Pref.double("alert.battery.threshold", 0.2))
        load(\.waitingAlertEnabled, Pref.bool("alert.waiting.enabled", true))
        load(\.waitingAlertMinutes, Pref.double("alert.waiting.minutes", 10))
        load(\.keepDisplayOn, Pref.bool("power.keepDisplayOn", false))
        load(\.keepAwakeForAgents, Pref.bool(AgentAwake.key, false))
        load(\.limitAlertsEnabled, Pref.bool(LimitWatch.enabledKey, true))
        load(\.limitAlertLevel, Pref.double(LimitWatch.levelKey, LimitWatch.defaultLevel))
        load(\.keepAwakeMinutes, Pref.double("power.keepAwake.minutes", 60))
        load(\.budgetEnabled, Pref.bool(Budget.enabledKey, false))
        load(\.budgetAmount, Pref.double(Budget.amountKey, 20))
        load(\.budgetPeriod, Budget.Period(rawValue: Pref.string(Budget.periodKey) ?? "") ?? .day)
        load(\.weeklySummaryEnabled, Pref.bool(WeeklySummary.enabledKey, true))
    }
}

