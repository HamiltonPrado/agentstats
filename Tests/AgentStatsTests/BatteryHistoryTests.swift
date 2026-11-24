import Foundation
import Testing
@testable import AgentStats

@Suite("Bateria ao longo do tempo")
struct BatteryHistoryTests {
    private func app(_ id: String, _ joules: Double) -> AppEnergy { AppEnergy(id: id, name: id, watts: 0, joules: joules) }
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func countsOnlyOnBatteryAndRestartsAfterCharging() {
        var e = EnergySinceUnplug()
        e.add([app("a", 100)], onBattery: false, now: t0)
        #expect(e.since == nil && e.top().isEmpty)

        e.add([app("a", 100)], onBattery: true, now: t0)
        e.add([app("a", 50), app("b", 400)], onBattery: true, now: t0.addingTimeInterval(10))
        #expect(e.since == t0)
        #expect(e.top().map(\.id) == ["b", "a"])
        #expect(e.top().first?.joules == 400)

        // Ligado à corrente: fica como estava.
        e.add([app("a", 999)], onBattery: false, now: t0.addingTimeInterval(20))
        #expect(e.top().map(\.joules) == [400, 150])
        #expect(!e.onBattery)

        // De volta à bateria: recomeça.
        e.add([app("c", 80)], onBattery: true, now: t0.addingTimeInterval(30))
        #expect(e.since == t0.addingTimeInterval(30))
        #expect(e.top().map(\.id) == ["c"])
    }

    @Test func tinyAmountsAreLeftOut() {
        var e = EnergySinceUnplug()
        e.add([app("a", 10), app("b", 40)], onBattery: true, now: t0)
        #expect(e.top().map(\.id) == ["b"])
    }

    @Test func oneReadingPerDayAndOldDaysDrop() {
        var days: [BatteryDay] = []
        days = BatteryHistory.recording(days, health: 0.98, cycles: 10, now: t0)
        days = BatteryHistory.recording(days, health: 0.97, cycles: 11, now: t0.addingTimeInterval(3600))
        #expect(days.count == 1 && days[0].cycles == 11)
        for i in 1...(BatteryHistory.keepDays + 5) {
            days = BatteryHistory.recording(days, health: 0.9, cycles: 11 + i, now: t0.addingTimeInterval(Double(i) * 86_400))
        }
        #expect(days.count == BatteryHistory.keepDays)
        #expect(days.last?.cycles == 11 + BatteryHistory.keepDays + 5)
    }

    @Test func changeNeedsAWeek() {
        let a = BatteryDay(day: BatteryHistory.dayString(t0), health: 0.98, cycles: 100)
        let soon = BatteryDay(day: BatteryHistory.dayString(t0.addingTimeInterval(3 * 86_400)), health: 0.98, cycles: 102)
        let later = BatteryDay(day: BatteryHistory.dayString(t0.addingTimeInterval(30 * 86_400)), health: 0.96, cycles: 112)
        #expect(BatteryHistory.change([a, soon]) == nil)
        let c = try! #require(BatteryHistory.change([a, soon, later]))
        #expect(c.days == 30)
        #expect(c.from.health == 0.98 && c.to.cycles - c.from.cycles == 12)
    }

    @Test func historySurvivesASaveAndLoad() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agentstats-\(UUID().uuidString)/b.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let days = [BatteryDay(day: "2026-01-02", health: nil, cycles: 5), BatteryDay(day: "2026-01-01", health: 0.9, cycles: 4)]
        BatteryHistory.save(days, to: url)
        #expect(BatteryHistory.load(from: url).map(\.day) == ["2026-01-01", "2026-01-02"])
    }

    @Test func energyRankKeepsJoules() {
        let k = EnergyReader.ProcessKey(pid: 1, start: 1)
        let r = EnergyReader.rank(previous: [k: 1_000_000_000], current: [k: 21_000_000_000], seconds: 10, limit: 5) { _ in ("x", "X") }
        #expect(r.first?.joules == 20)
        #expect(r.first?.watts == 2)
    }

    @Test func wattHoursFormat() {
        #expect(SystemView.wattHours(14_400) == "4,0 Wh" || SystemView.wattHours(14_400) == "4.0 Wh")
        #expect(SystemView.wattHours(1_800).hasPrefix("0"))
    }
}
