import Foundation

/// O ritmo a que uma janela de limite está a ser gasta e quando acaba, se continuar assim.
enum LimitForecast {
    /// Quando chega aos 100% ao ritmo médio desde o início da janela, se for antes de renovar.
    /// nil se não acaba antes, ou se ainda não há dados para uma previsão que valha alguma coisa
    /// (menos de 10% gasto ou de 10% da janela passada).
    static func runsOut(_ w: LimitWindow, now: Date) -> Date? {
        guard let resets = w.resetsAt, let duration = w.duration, duration > 0, resets > now else { return nil }
        let elapsed = duration - resets.timeIntervalSince(now)
        guard elapsed >= duration * 0.1, w.usedPercent >= 10, w.usedPercent < 100 else { return nil }
        let perSecond = w.usedPercent / elapsed
        let end = now.addingTimeInterval((100 - w.usedPercent) / perSecond)
        return end < resets ? end : nil
    }
}

/// Avisos de limite: um por nível em cada janela, e outro quando a janela renova.
enum LimitWatch {
    static let enabledKey = "alert.limits.enabled"
    static let levelKey = "alert.limits.level"
    static let stateKey = "alert.limits.notified"
    static let defaultLevel = 75.0
    /// O segundo aviso, sempre: perto do fim já não é cedo de mais.
    static let lastLevel = 90.0

    enum Event: Equatable, Sendable {
        case reached(provider: PlanLimits.Provider, window: LimitWindow, level: Double, runsOut: Date?)
        case renewed(provider: PlanLimits.Provider, label: String)
    }

    static func levels(_ first: Double) -> [Double] {
        first < lastLevel ? [first, lastLevel] : [first]
    }

    /// A mesma janela até renovar. Sem hora de renovação (a app Claude não a dá), conta a janela.
    static func episode(_ provider: PlanLimits.Provider, _ w: LimitWindow) -> String {
        let reset = w.resetsAt.map { String(Int(($0.timeIntervalSince1970 / 60).rounded())) } ?? "?"
        return "\(provider.rawValue)|\(w.id)|\(reset)"
    }

    /// `notified`: episódio → nível mais alto já avisado. Devolve os avisos a dar e o estado novo.
    static func evaluate(_ limits: [PlanLimits], notified: [String: Double], first: Double,
                         now: Date) -> (events: [Event], notified: [String: Double]) {
        var state = notified
        var events: [Event] = []
        var seen = Set<String>()
        for l in limits {
            for w in l.windows {
                let key = episode(l.provider, w)
                seen.insert(key)
                if let r = w.resetsAt, r <= now {
                    if state.removeValue(forKey: key) != nil { events.append(.renewed(provider: l.provider, label: w.label)) }
                    continue
                }
                // Sem hora de renovação: quando volta a descer bem abaixo, conta como janela nova.
                if w.resetsAt == nil, let last = state[key], w.usedPercent < first - 10 && w.usedPercent < last - 10 {
                    state[key] = nil
                }
                guard let level = levels(first).last(where: { w.usedPercent >= $0 }), level > (state[key] ?? -1) else { continue }
                state[key] = level
                events.append(.reached(provider: l.provider, window: w, level: level, runsOut: LimitForecast.runsOut(w, now: now)))
            }
        }
        // Episódios que deixaram de aparecer (renovaram e a leitura já é da janela seguinte).
        for key in state.keys where !seen.contains(key) {
            let parts = key.split(separator: "|", maxSplits: 2).map(String.init)
            if parts.count == 3, let minutes = Double(parts[2]), Date(timeIntervalSince1970: minutes * 60) <= now {
                state[key] = nil
            }
        }
        return (events, state)
    }
}
