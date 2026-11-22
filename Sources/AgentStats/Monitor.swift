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

struct SystemAlert: Identifiable, Sendable {
    enum Kind: String { case cpu, temp, memory, disk, battery }
    var id: String { kind.rawValue }
    let kind: Kind
    let value: String
    let since: Date
    let detail: String?
}

extension SystemAlert.Kind {
    var label: String {
        switch self {
        case .cpu: "CPU alta"
        case .temp: "Temperatura alta"
        case .memory: "Memória alta"
        case .disk: "Pouco espaço em disco"
        case .battery: "Bateria fraca"
        }
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
    /// Limites do plano do Claude (pelo Claude Code ou, em alternativa, pela app Claude).
    var claudeLimits: PlanLimits?
    var claudeLimitsStatus: ClaudeLimitsFetcher.Outcome?
    var activityHistory: [AgentActivityRecord] = AgentActivityHistoryStore.load()

    var cpuHistory = History()
    var memHistory = History()
    var gpuHistory = History()
    var downHistory = History()
    var upHistory = History()
    var tempHistory = History()
    /// Últimas 24 h, um ponto por minuto (guardado em disco).
    var day: [MinuteSample] = History24h.load()

    @ObservationIgnored let machine: String = Sys.sysctlString("machdep.cpu.brand_string") ?? "Mac"
    @ObservationIgnored let model: String = Sys.sysctlString("hw.model") ?? ""
    @ObservationIgnored let pCores = Sys.sysctlInt("hw.perflevel0.logicalcpu", Int32.self).map(Int.init)
    @ObservationIgnored let eCores = Sys.sysctlInt("hw.perflevel1.logicalcpu", Int32.self).map(Int.init)

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
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var tick = 0
    @ObservationIgnored private var sampling = false
    @ObservationIgnored private var previousStates: [String: AgentState] = [:]
    @ObservationIgnored private var highSince: [SystemAlert.Kind: Date] = [:]
    @ObservationIgnored private var lastNotified: [SystemAlert.Kind: Date] = [:]
    @ObservationIgnored private var minuteAcc = MinuteAccumulator()
    @ObservationIgnored private var lastHistorySave = Date()
    @ObservationIgnored private var lastAgentHistorySave = Date.distantPast

    var workingCount: Int { sessions.filter { $0.state.isWorking }.count }
    var needsAttentionCount: Int { sessions.filter { $0.state.needsAttention }.count }
    var liveAgentCount: Int { agents.filter { !$0.isSubagent }.count }
    /// Limites que ainda valem (as janelas que já renovaram saem).
    var planLimits: [PlanLimits] {
        let now = Date()
        return [claudeLimits, usage.codexLimits].compactMap { $0?.current(now: now) }
    }

    init() {
        keepAwakeController.onTimeout = { [weak self] in self?.keepAwake = false }
        sample()
        restart()
        // @Sendable: o sistema chama esta resposta numa fila de fundo. Sem isto, a closure herdava o
        // main actor do init e, compilada com o Swift do Xcode 16, a app rebentava ao arrancar (v1.16).
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { @Sendable _, _ in }
    }

    func restart() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: max(refreshInterval, 1), repeats: true) { [weak self] _ in
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
        if !off.contains("limits") && Pref.bool("panel.showLimits", true) { refreshClaudeLimits() }
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
            let outcome = await Task.detached(priority: .utility) { ClaudeLimitsFetcher.fetch() }.value
            let now = Date()
            claudeLimitsStatus = outcome
            switch outcome {
            case .limits(let l):
                claudeLimits = l
                nextClaudeCheck = now.addingTimeInterval(panelOpen ? 5 * 60 : 15 * 60)
            case .signedOut, .notInstalled, .failed:
                claudeLimits = Self.claudeDesktopLimits(now: now)
                nextClaudeCheck = now.addingTimeInterval(outcome == .notInstalled ? 6 * 3600 : outcome == .failed ? 15 * 60 : 30 * 60)
            }
            claudeChecking = false
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

    private func apply(_ s: Sample) {
        cpu = s.cpu
        memory = s.memory
        network = s.network
        disk = s.disk
        gpu = s.gpu
        if let t = s.temps { temps = t }
        if let t = temps?.cpuMax { tempHistory.push(t) }
        if let b = s.battery { battery = b }
        if let u = s.usage { usage = u }
        if let e = s.energy { energyApps = e }
        if let a = s.agents {
            topProcesses = a.topCPU
            topMemory = a.topMemory
            agents = a.agents
            handleTransitions(a.sessions)
            updateAgentHistory(a.sessions)
            checkWaitingReminders(a.sessions)
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
        guard notifyOnFinish, !previousStates.isEmpty else { return }
        for s in new {
            guard let old = previousStates[s.id] else { continue }
            let content = UNMutableNotificationContent()
            if s.state.needsAttention && !old.needsAttention {
                content.title = s.state == .needsAnswer ? "Agente tem uma pergunta · \(s.project)" : "Agente precisa de aprovação · \(s.project)"
                content.body = s.detail ?? s.title
                content.interruptionLevel = .timeSensitive
            } else if (old.isWorking || old.needsAttention), s.state == .waitingUser,
                      let done = finished[s.id], done.duration >= finishMinMinutes * 60 {
                content.title = "Agente terminou · \(s.project)"
                var summary = "Trabalhou " + (done.duration < 60 ? "\(Int(done.duration)) s" : Fmt.duration(done.duration))
                if let c = done.cost { summary += " · ~" + Fmt.usd(c) }
                content.body = summary + "\n" + (s.detail ?? s.title)
            } else { continue }
            content.userInfo = ["session": s.id]   // clicar na notificação abre o agente
            content.sound = .default
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    // MARK: Alertas

    /// Envia um único lembrete por episódio de espera, depois do intervalo escolhido.
    private func checkWaitingReminders(_ currentSessions: [AgentSession], now: Date = Date()) {
        guard waitingAlertEnabled else { return }
        let delay = waitingAlertMinutes * 60
        for session in currentSessions where AgentActivityPhase(session.state).shouldRemind {
            guard let index = activityHistory.firstIndex(where: { $0.id == session.id }),
                  !activityHistory[index].reminderSent,
                  now.timeIntervalSince(activityHistory[index].phaseSince) >= delay else { continue }

            let content = UNMutableNotificationContent()
            content.title = session.state.needsAttention
                ? "Agente continua a precisar de ti · \(session.project)"
                : "Agente continua à tua espera · \(session.project)"
            content.body = session.state.needsAttention
                ? (session.detail ?? "O pedido continua pendente há \(Int(waitingAlertMinutes)) min.")
                : "Sem nova atividade há \(Int(waitingAlertMinutes)) min. \(session.detail ?? session.title)"
            content.userInfo = ["session": session.id]
            content.sound = .default
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "waiting-\(UUID().uuidString)", content: content, trigger: nil))
            activityHistory[index].reminderSent = true
            AgentActivityHistoryStore.save(activityHistory)
            lastAgentHistorySave = now
        }
    }

    private func checkAlerts(now: Date = Date()) {
        let culprit = topProcesses.first.map { "\(AppInfo.lookup($0.pid).name ?? $0.name) (\(String(format: "%.0f%%", $0.cpu)))" }

        var alerts: [SystemAlert] = []
        // CPU: dispara acima do limite, só desliga 5 pontos abaixo (histerese)
        if let a = evaluate(.cpu, enabled: cpuAlertEnabled, value: cpu.total,
                            on: cpuThreshold, off: cpuThreshold - 0.05, now: now) {
            alerts.append(SystemAlert(kind: .cpu, value: Fmt.pct(cpu.total), since: a, detail: culprit))
        }
        if let t = temps?.cpuMax,
           let a = evaluate(.temp, enabled: tempAlertEnabled, value: t,
                            on: tempThreshold, off: tempThreshold - 5, now: now) {
            alerts.append(SystemAlert(kind: .temp, value: String(format: "%.0f °C", t), since: a, detail: culprit))
        }
        // Memória: no macOS a "memória usada" passa muitas vezes dos 90% sem problema nenhum.
        // Só alerta quando, além do limite, o sistema indica pressão de memória (elevada ou crítica).
        if let a = evaluate(.memory, enabled: memoryAlertEnabled && memory.pressure >= 2, value: memory.usage,
                            on: memoryThreshold, off: memoryThreshold - 0.05, now: now) {
            alerts.append(SystemAlert(kind: .memory, value: Fmt.pct(memory.usage), since: a,
                                      detail: memory.pressure >= 4 ? "pressão crítica" : "pressão elevada"))
        }
        if let a = evaluate(.disk, enabled: diskAlertEnabled, value: disk.usage,
                            on: diskThreshold, off: diskThreshold - 0.02, now: now) {
            alerts.append(SystemAlert(kind: .disk, value: Fmt.bytesShort(disk.free) + " livres", since: a, detail: nil))
        }
        // Bateria: só conta na bateria. Ligado à corrente, a contagem recomeça. (Enquanto se espera
        // pelos 20 s, `evaluate` devolve nil e não se pode apagar a contagem, senão nunca chega lá.)
        if let b = battery, !b.isCharging, !b.externalPower {
            if let a = evaluate(.battery, enabled: batteryAlertEnabled, value: 1 - b.percent,
                                on: 1 - batteryThreshold, off: 1 - batteryThreshold - 0.05, now: now) {
                alerts.append(SystemAlert(kind: .battery, value: Fmt.pct(b.percent), since: a, detail: nil))
            }
        } else { highSince[.battery] = nil }
        if alerts.map(\.kind) != activeAlerts.map(\.kind) || alerts.map(\.value) != activeAlerts.map(\.value) {
            activeAlerts = alerts
        }

        for alert in alerts where now.timeIntervalSince(lastNotified[alert.kind] ?? .distantPast) > Self.alertCooldown {
            lastNotified[alert.kind] = now
            let content = UNMutableNotificationContent()
            content.title = switch alert.kind {
            case .cpu: "CPU alta: \(alert.value)"
            case .temp: "Temperatura alta: \(alert.value)"
            case .memory: "Memória alta: \(alert.value)"
            case .disk: "Pouco espaço em disco: \(alert.value)"
            case .battery: "Bateria fraca: \(alert.value)"
            }
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
}

/// Leitura/escrita das definições em UserDefaults (com valor por omissão).
enum Pref {
    static func double(_ key: String, _ def: Double) -> Double { UserDefaults.standard.object(forKey: key) as? Double ?? def }
    static func bool(_ key: String, _ def: Bool) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? def }
    static func set(_ value: Any, _ key: String) { UserDefaults.standard.set(value, forKey: key) }
}

// MARK: - Formatação

enum Fmt {
    /// Bytes com vírgula decimal (pt-PT), igual ao resto da app: 10,24 GB
    static func bytes(_ b: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .memory).replacingOccurrences(of: ".", with: ",")
    }
    /// Versão curta para espaços pequenos: 193 GB, 10 GB, 512 MB
    static func bytesShort(_ b: UInt64) -> String {
        let gb = Double(b) / 1_073_741_824
        if gb >= 1 { return num(gb, gb < 10 ? 1 : 0) + " GB" }
        return num(Double(b) / 1_048_576, 0) + " MB"
    }
    static func rate(_ bps: Double, short: Bool = false) -> String {
        let units = short ? ["B", "K", "M", "G"] : ["B/s", "KB/s", "MB/s", "GB/s"]
        var v = bps, i = 0
        while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
        let n = v >= 100 || i == 0 ? Fmt.num(v, 0) : Fmt.num(v, 1)
        return n + (short ? units[i] : " " + units[i])
    }
    /// Número com vírgula decimal (pt-PT), igual em todo o lado: 46,9 · 1,2 · 0,85
    static func num(_ v: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f", v).replacingOccurrences(of: ".", with: ",")
    }
    /// Temperatura com o símbolo de grau correto: 46,9 °C
    static func temp(_ c: Double, _ digits: Int = 1) -> String { num(c, digits) + " °C" }
    static func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }
    /// 950 → "950"; 12 300 → "12,3k"; 4 560 000 → "4,6M"
    /// Dólares com vírgula decimal: "$0,42", "$12,40", "$1 234".
    static func usd(_ v: Double) -> String {
        if v < 0.01 { return "<$0,01" }
        let f = NumberFormatter()
        f.locale = Locale(identifier: "pt_PT")
        f.numberStyle = .decimal
        f.minimumFractionDigits = v < 100 ? 2 : 0
        f.maximumFractionDigits = v < 100 ? 2 : 0
        return "$" + (f.string(from: NSNumber(value: v)) ?? String(format: "%.2f", v))
    }

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
