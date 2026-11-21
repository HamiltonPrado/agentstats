import Foundation

enum AgentActivityPhase: String, Codable, Sendable {
    case working, attention, waiting, finished, active

    init(_ state: AgentState) {
        if state.isWorking { self = .working }
        else if state.needsAttention { self = .attention }
        else if state == .waitingUser { self = .waiting }
        else if state == .finished { self = .finished }
        else { self = .active }
    }

    var title: String {
        switch self {
        case .working: "A trabalhar"
        case .attention: "Precisa de ti"
        case .waiting: "À tua espera"
        case .finished: "Terminada"
        case .active: "Ativa"
        }
    }

    var shouldRemind: Bool { self == .attention || self == .waiting }
}

struct AgentActivityEvent: Codable, Identifiable, Sendable, Equatable {
    var id: String
    var phase: AgentActivityPhase
    var date: Date
    var detail: String?

    init(phase: AgentActivityPhase, date: Date, detail: String?) {
        self.id = UUID().uuidString
        self.phase = phase
        self.date = date
        self.detail = detail
    }
}

struct AgentActivityRecord: Codable, Identifiable, Sendable, Equatable {
    var id: String                       // transcript/rollout ou id de processo
    var kind: String
    var title: String
    var project: String
    var cwd: String?
    var firstSeen: Date
    var lastSeen: Date
    var lastActivity: Date
    var endedAt: Date?
    var phase: AgentActivityPhase
    var phaseSince: Date
    var tokens: Int
    var events: [AgentActivityEvent]
    var reminderSent: Bool

    var isActive: Bool { endedAt == nil }

    func duration(at now: Date = Date()) -> TimeInterval {
        max(0, (endedAt ?? now).timeIntervalSince(firstSeen))
    }

    init(session: AgentSession, tokens: Int, now: Date = Date()) {
        id = session.id
        kind = session.kind
        title = session.title
        project = session.project
        cwd = session.cwd
        firstSeen = now
        lastSeen = now
        lastActivity = session.lastActivity
        phase = AgentActivityPhase(session.state)
        phaseSince = now
        endedAt = phase == .finished ? now : nil
        self.tokens = tokens
        events = [AgentActivityEvent(phase: phase, date: now, detail: session.detail)]
        reminderSent = false
    }

    mutating func update(session: AgentSession, tokens: Int, now: Date) {
        let newPhase = AgentActivityPhase(session.state)
        kind = session.kind
        title = session.title
        project = session.project
        cwd = session.cwd
        lastSeen = now
        lastActivity = session.lastActivity
        self.tokens = tokens

        if newPhase != phase {
            phase = newPhase
            phaseSince = now
            endedAt = newPhase == .finished ? now : nil
            reminderSent = false
            events.append(AgentActivityEvent(phase: newPhase, date: now, detail: session.detail))
            if events.count > 30 { events.removeFirst(events.count - 30) }
        } else if newPhase == .finished, endedAt == nil {
            endedAt = now
        }
    }

    mutating func finish(at date: Date) {
        guard endedAt == nil else { return }
        phase = .finished
        phaseSince = date
        endedAt = date
        reminderSent = false
        events.append(AgentActivityEvent(phase: .finished, date: date, detail: nil))
        if events.count > 30 { events.removeFirst(events.count - 30) }
    }
}

enum AgentActivityHistoryStore {
    static let retention: TimeInterval = 30 * 24 * 3600
    static let limit = 500

    static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentStats/agent-activity.json")
    }

    static func load(from url: URL = file, now: Date = Date()) -> [AgentActivityRecord] {
        guard let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([AgentActivityRecord].self, from: data) else { return [] }
        return pruned(records, now: now)
    }

    static func save(_ records: [AgentActivityRecord], to url: URL = file) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(records).write(to: url, options: .atomic)
        } catch {
            Log.readers.error("Não foi possível gravar o histórico dos agentes: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func pruned(_ records: [AgentActivityRecord], now: Date = Date()) -> [AgentActivityRecord] {
        let cutoff = now.addingTimeInterval(-retention)
        return Array(records
            .filter { $0.isActive || $0.lastSeen >= cutoff }
            .sorted { $0.lastSeen > $1.lastSeen }
            .prefix(limit))
    }

    /// Atualiza sessões observadas e fecha as que desapareceram por mais de um minuto.
    static func updating(_ original: [AgentActivityRecord], sessions: [AgentSession],
                         usage: UsageSnapshot, now: Date = Date()) -> (records: [AgentActivityRecord], changed: Bool) {
        var records = original
        var changed = false
        let ids = Set(sessions.map(\.id))

        for session in sessions {
            let tokens = usage.perSession[session.id]?.total ?? 0
            if let i = records.firstIndex(where: { $0.id == session.id }) {
                let before = records[i]
                records[i].update(session: session, tokens: tokens, now: now)
                if before != records[i] { changed = true }
            } else {
                records.append(AgentActivityRecord(session: session, tokens: tokens, now: now))
                changed = true
            }
        }

        for i in records.indices where records[i].isActive && !ids.contains(records[i].id)
            && now.timeIntervalSince(records[i].lastSeen) >= 60 {
            records[i].finish(at: records[i].lastSeen)
            changed = true
        }

        let kept = pruned(records, now: now)
        if kept != records { changed = true }
        return (kept, changed)
    }
}
