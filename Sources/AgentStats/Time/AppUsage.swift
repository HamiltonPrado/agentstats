import AppKit
import SwiftUI

/// Tempo por app: só conta enquanto se usa o Mac (sem 5 minutos parado, sem ecrã bloqueado ou a dormir).
/// Fica num ficheiro só teu, com os últimos 7 dias, e nunca sai do Mac.
struct AppUsageDay: Codable, Equatable {
    var day: String
    var seconds: [String: Double] = [:]   // id da app → segundos
    var names: [String: String] = [:]
}

enum AppUsage {
    static let idleLimit: TimeInterval = 5 * 60
    static let keepDays = 7

    /// Quanto do intervalo conta: até ao momento em que se ficou parado, se foi o caso.
    static func credited(from start: Date, to end: Date, idleSeconds: TimeInterval) -> TimeInterval {
        let span = max(0, end.timeIntervalSince(start))
        guard idleSeconds >= idleLimit else { return span }
        return max(0, span - idleSeconds)
    }

    static func adding(_ seconds: TimeInterval, app id: String, name: String, day: String, to days: [AppUsageDay]) -> [AppUsageDay] {
        guard seconds > 0 else { return days }
        var out = days
        if let i = out.firstIndex(where: { $0.day == day }) {
            out[i].seconds[id, default: 0] += seconds
            out[i].names[id] = name
        } else {
            out.append(AppUsageDay(day: day, seconds: [id: seconds], names: [id: name]))
        }
        out.sort { $0.day < $1.day }
        return Array(out.suffix(keepDays))
    }

    static func top(_ day: AppUsageDay?, limit: Int = 8) -> [(id: String, name: String, seconds: Double)] {
        guard let day else { return [] }
        return day.seconds.sorted { $0.value > $1.value }.prefix(limit).map { ($0.key, day.names[$0.key] ?? $0.key, $0.value) }
    }
}

@MainActor
final class AppUsageStore: ObservableObject {
    static let shared = AppUsageStore(file: AppPaths.support("app-usage.json"))
    static let enabledKey = "appUsage.enabled"

    @Published private(set) var days: [AppUsageDay] = []
    @Published var enabled: Bool = Pref.bool(AppUsageStore.enabledKey, true) {
        didSet { Pref.set(enabled, Self.enabledKey); if enabled { restart() } else { flush(); current = nil } }
    }
    private let file: URL?
    private var current: (id: String, name: String, since: Date)?
    private var paused = false
    private var timer: Timer?
    private var demo = false

    init(file: URL?) {
        self.file = file
        if let file, case .value(let saved) = PrivateFile.load([AppUsageDay].self, from: file) { days = saved }
    }

    var today: AppUsageDay? { days.first { $0.day == Budget.day(Date(), .current) } }

    func start() {
        guard !demo else { return }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppUsageStore.shared.switched() }
        }
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated { AppUsageStore.shared.pause(true) } }
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated { AppUsageStore.shared.pause(false) } }
        }
        // De minuto a minuto: grava e corta o tempo parado.
        timer = Timer.common(withTimeInterval: 60, repeats: true) { _ in MainActor.assumeIsolated { AppUsageStore.shared.flush() } }
        restart()
    }

    private func restart() {
        guard enabled, !paused, let app = NSWorkspace.shared.frontmostApplication else { return }
        current = (app.bundleIdentifier ?? app.localizedName ?? "?", app.localizedName ?? "?", Date())
    }

    private func switched() {
        flush()
        restart()
    }

    private func pause(_ on: Bool) {
        if on { flush(); current = nil }
        paused = on
        if !on { restart() }
    }

    /// Junta o tempo da app atual e recomeça a contar a partir de agora.
    func flush() {
        guard enabled, let c = current else { return }
        let now = Date()
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        let secs = AppUsage.credited(from: c.since, to: now, idleSeconds: idle)
        days = AppUsage.adding(secs, app: c.id, name: c.name, day: Budget.day(now, .current), to: days)
        current = (c.id, c.name, now)
        if let file { _ = PrivateFile.save(days, to: file, backup: false) }
    }

    func clear() {
        days = []
        if let file { _ = PrivateFile.save(days, to: file, backup: false) }
    }

    func loadDemo(now: Date) {
        demo = true
        days = [AppUsageDay(day: Budget.day(now, .current),
                            seconds: ["com.apple.Terminal": 9_400, "com.apple.Safari": 6_100, "com.microsoft.VSCode": 5_200, "com.apple.mail": 1_300],
                            names: ["com.apple.Terminal": "Terminal", "com.apple.Safari": "Safari", "com.microsoft.VSCode": "Visual Studio Code", "com.apple.mail": "Mail"])]
    }
}

struct AppUsageCard: View {
    @ObservedObject var store: AppUsageStore

    var body: some View {
        let top = AppUsage.top(store.today)
        let total = store.today?.seconds.values.reduce(0, +) ?? 0
        let most = max(top.first?.seconds ?? 1, 1)
        return VStack(alignment: .leading, spacing: DS.sm) {
            HStack {
                Text("Hoje por app").font(DS.body.weight(.medium))
                Spacer()
                if total > 0 { Text(Fmt.minutes(Int(total / 60))).font(DS.body.monospacedDigit()).foregroundStyle(Color.text2) }
                Toggle("Hoje por app", isOn: $store.enabled).toggleStyle(.switch).controlSize(.mini).labelsHidden()
            }
            if store.enabled {
                if top.isEmpty { note("Começa a contar a partir de agora.") }
                ForEach(top, id: \.id) { a in
                    VStack(alignment: .leading, spacing: DS.xs) {
                        HStack {
                            Text(L(a.name)).font(DS.body).lineLimit(1)
                            Spacer()
                            Text(Fmt.minutes(Int(a.seconds / 60))).font(DS.body.monospacedDigit()).foregroundStyle(Color.text2)
                        }
                        Bar(value: a.seconds / most, color: .secondary.opacity(0.5), height: 2)
                    }
                }
                HStack {
                    note("Só conta enquanto usas o Mac. Fica neste Mac, 7 dias.")
                    Spacer()
                    if total > 0 { textLink("Apagar") { store.clear() } }
                }
            }
        }
        .cardStyle()
    }
}
