import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class TimerStore: ObservableObject {
    static let shared = TimerStore()

    @Published private(set) var plan: TimerPlan?
    @Published private(set) var endsAt: Date?
    /// Em pausa: quanto faltava.
    @Published private(set) var pausedLeft: TimeInterval?
    @Published private(set) var now = Date()
    var onChange: (() -> Void)?
    private var ticker: Timer?
    private var demo = false

    var running: Bool { endsAt != nil }
    var left: TimeInterval {
        if let pausedLeft { return pausedLeft }
        guard let endsAt else { return 0 }
        return max(0, endsAt.timeIntervalSince(now))
    }

    /// O que aparece na barra de menus enquanto corre.
    var menuBarText: String? { plan == nil ? nil : TimerPlan.clock(left) + (pausedLeft != nil ? " ❚❚" : "") }

    func start(_ plan: TimerPlan) {
        self.plan = plan
        pausedLeft = nil
        endsAt = Date().addingTimeInterval(plan.duration)
        tick()
        ensureTicker()
    }

    func startTimer(minutes: Double) { start(TimerPlan(phase: .timer, duration: minutes * 60)) }
    func startPomodoro() { start(TimerPlan(phase: .focus, duration: TimerPlan.focus)) }

    func pauseOrResume() {
        guard plan != nil else { return }
        if let p = pausedLeft {
            endsAt = Date().addingTimeInterval(p)
            pausedLeft = nil
            ensureTicker()
        } else {
            pausedLeft = left
            endsAt = nil
        }
        onChange?()
    }

    func stop() {
        plan = nil
        endsAt = nil
        pausedLeft = nil
        ticker?.invalidate()
        ticker = nil
        onChange?()
    }

    private func ensureTicker() {
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { TimerStore.shared.tick() }
        }
    }

    private func tick() {
        now = Date()
        if let endsAt, endsAt <= now, let plan { finished(plan) }
        onChange?()
    }

    private func finished(_ plan: TimerPlan) {
        NSSound(named: "Glass")?.play()
        let next = plan.next()
        let c = UNMutableNotificationContent()
        c.title = plan.phase == .timer ? "Tempo!" : "\(plan.title) terminou"
        c.body = next.map { "A seguir: \($0.title.lowercased()), \(Int($0.duration / 60)) min." } ?? "O temporizador chegou ao fim."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "timer-\(UUID().uuidString)", content: c, trigger: nil))
        if let next { start(next) } else { stop() }
    }

    func loadDemo(now: Date) {
        demo = true
        self.now = now
        plan = TimerPlan(phase: .focus, duration: TimerPlan.focus, completedFocus: 1)
        endsAt = now.addingTimeInterval(17 * 60 + 42)
    }
}

@MainActor
final class WorldClockStore: ObservableObject {
    static let shared = WorldClockStore()
    @Published var zones: [TimeZone] = WorldClock.zones(UserDefaults.standard.string(forKey: WorldClock.key)) {
        didSet { if !demo { UserDefaults.standard.set(WorldClock.encode(zones), forKey: WorldClock.key) } }
    }
    private var demo = false

    func add(_ z: TimeZone) { if !zones.contains(z) { zones.append(z) } }
    func remove(_ z: TimeZone) { zones.removeAll { $0 == z } }
    func move(_ z: TimeZone, by offset: Int) {
        guard let i = zones.firstIndex(of: z), zones.indices.contains(i + offset) else { return }
        zones.swapAt(i, i + offset)
    }

    func loadDemo() {
        demo = true
        zones = ["America/New_York", "America/Sao_Paulo", "Asia/Tokyo"].compactMap(TimeZone.init(identifier:))
    }
}
