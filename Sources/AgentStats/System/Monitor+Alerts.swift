import Foundation
import UserNotifications

// Os avisos do Monitor: orçamento e resumo semanal, limites do plano, lembretes de espera e alertas do sistema.
// Separados do modelo observável para o ficheiro principal ficar só com o estado e a amostragem.
extension Monitor {
    func checkBudgetAndSummary(now: Date = Date()) {
        guard !usage.week.isEmpty else { return }   // ainda sem a primeira leitura dos tokens
        let d = UserDefaults.standard
        if budgetEnabled {
            let id = Budget.periodID(budgetPeriod, now: now)
            let r = Budget.evaluate(spent: budgetSpent, amount: budgetAmount, period: id, notified: d.string(forKey: Budget.notifiedKey))
            if let level = r.level {
                d.set(r.notified, forKey: Budget.notifiedKey)
                let c = UNMutableNotificationContent()
                c.title = L(level >= 100 ? "Orçamento esgotado" : String(localized: "Orçamento a \(Int(level))%"))
                c.body = L(String(localized: "~\(Fmt.usd(budgetSpent)) de \(Fmt.usd(budgetAmount)) \(budgetPeriod.short), estimado a preços de API."))
                c.sound = .default
                Notify.add(UNNotificationRequest(identifier: "budget-\(UUID().uuidString)", content: c, trigger: nil))
            }
        }
        if weeklySummaryEnabled, let week = WeeklySummary.due(now: now, last: d.string(forKey: WeeklySummary.lastKey)) {
            d.set(week, forKey: WeeklySummary.lastKey)
            if let t = WeeklySummary.text(usage) {
                let c = UNMutableNotificationContent()
                c.title = t.title
                c.body = t.body
                Notify.add(UNNotificationRequest(identifier: "summary-\(week)", content: c, trigger: nil))
            }
        }
    }

    func checkLimitAlerts(now: Date = Date()) {
        guard limitAlertsEnabled else { return }
        let limits = [claudeLimits, usage.codexLimits].compactMap { $0 }
        guard !limits.isEmpty else { return }
        let saved = UserDefaults.standard.dictionary(forKey: LimitWatch.stateKey) as? [String: Double] ?? [:]
        let result = LimitWatch.evaluate(limits, notified: saved, first: limitAlertLevel, now: now)
        if result.notified != saved { UserDefaults.standard.set(result.notified, forKey: LimitWatch.stateKey) }
        for event in result.events {
            let content = UNMutableNotificationContent()
            switch event {
            case .reached(let provider, let w, _, let runsOut):
                content.title = L("\(provider.rawValue) · \(w.label) a \(Fmt.num(w.usedPercent, 0))%")
                var lines: [String] = []
                if let r = w.resetsAt { lines.append(String(localized: "Renova \(PlanLimitsCard.resetText(r, now: now)).")) }
                if let end = runsOut { lines.append(String(localized: "A este ritmo acaba \(PlanLimitsCard.resetText(end, now: now)).")) }
                content.body = L(lines.isEmpty ? "Limite do plano" : lines.joined(separator: " "))
                if w.usedPercent >= LimitWatch.lastLevel { content.interruptionLevel = .timeSensitive }
            case .renewed(let provider, let label):
                content.title = L(String(localized: "\(provider.rawValue) · \(label) renovou"))
                content.body = L("Podes voltar a usar à vontade.")
            }
            content.sound = .default
            Notify.add(
                UNNotificationRequest(identifier: "limit-\(UUID().uuidString)", content: content, trigger: nil))
        }
    }

    // MARK: Alertas

    /// Envia um único lembrete por episódio de espera, depois do intervalo escolhido.
    func checkWaitingReminders(_ currentSessions: [AgentSession], now: Date = Date()) {
        guard waitingAlertEnabled else { return }
        let delay = waitingAlertMinutes * 60
        for session in currentSessions where AgentActivityPhase(session.state).shouldRemind {
            guard let index = activityHistory.firstIndex(where: { $0.id == session.id }),
                  !activityHistory[index].reminderSent,
                  now.timeIntervalSince(activityHistory[index].phaseSince) >= delay else { continue }

            let content = UNMutableNotificationContent()
            content.title = session.state.needsAttention
                ? String(localized: "Agente continua a precisar de ti · \(session.project)")
                : String(localized: "Agente continua à tua espera · \(session.project)")
            content.body = session.state.needsAttention
                ? (session.detail ?? String(localized: "O pedido continua pendente há \(Int(waitingAlertMinutes)) min."))
                : String(localized: "Sem nova atividade há \(Int(waitingAlertMinutes)) min. \(session.detail ?? session.title)")
            content.userInfo = ["session": session.id]
            content.sound = .default
            Notify.add(
                UNNotificationRequest(identifier: "waiting-\(UUID().uuidString)", content: content, trigger: nil))
            activityHistory[index].reminderSent = true
            AgentActivityHistoryStore.save(activityHistory)
            lastAgentHistorySave = now
        }
    }

    func checkAlerts(now: Date = Date()) {
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
            alerts.append(SystemAlert(kind: .disk, value: String(localized: "\(Fmt.diskShort(disk.free)) livres"), since: a, detail: nil))
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
            case .cpu: String(localized: "CPU alta: \(alert.value)")
            case .temp: String(localized: "Temperatura alta: \(alert.value)")
            case .memory: String(localized: "Memória alta: \(alert.value)")
            case .disk: String(localized: "Pouco espaço em disco: \(alert.value)")
            case .battery: String(localized: "Bateria fraca: \(alert.value)")
            }
            content.body = L(alert.detail.map { String(localized: "Processo mais pesado: \($0)") } ?? String(localized: "Há mais de \(Int(Self.alertSustain)) s acima do limite."))
            content.sound = .default
            Notify.add(
                UNNotificationRequest(identifier: "alert-\(alert.kind.rawValue)", content: content, trigger: nil))
        }
    }

    /// Devolve desde quando o alerta está ativo, ou nil se não está.
    func evaluate(_ kind: SystemAlert.Kind, enabled: Bool, value: Double, on: Double, off: Double, now: Date) -> Date? {
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
