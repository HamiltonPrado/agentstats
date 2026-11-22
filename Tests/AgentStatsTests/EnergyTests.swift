import Foundation
import Testing
@testable import AgentStats

@Suite struct EnergyTests {
    private typealias Key = EnergyReader.ProcessKey

    @Test func helpersAddUpToTheirApp() {
        let a = Key(pid: 1, start: 10), b = Key(pid: 2, start: 20), c = Key(pid: 3, start: 30)
        let out = EnergyReader.rank(previous: [a: 0, b: 0, c: 0],
                                    current: [a: 4_000_000_000, b: 6_000_000_000, c: 2_000_000_000],
                                    seconds: 10, limit: 5) { $0.pid == 3 ? ("e", "Editor") : ("b", "Browser") }
        #expect(out.map(\.name) == ["Browser", "Editor"])
        #expect(out.map(\.watts).map { ($0 * 10).rounded() / 10 } == [1.0, 0.2])
    }

    @Test func reusedPidAndNewProcessesDoNotCount() {
        let old = Key(pid: 7, start: 1), reused = Key(pid: 7, start: 2)
        let out = EnergyReader.rank(previous: [old: 0], current: [reused: 9_000_000_000], seconds: 1, limit: 5) { _ in ("x", "X") }
        #expect(out.isEmpty)
    }

    @Test func tinyValuesAreHiddenAndTheListIsLimited() {
        let keys = (1...8).map { Key(pid: pid_t($0), start: 0) }
        let before = Dictionary(uniqueKeysWithValues: keys.map { ($0, UInt64(0)) })
        let after = Dictionary(uniqueKeysWithValues: keys.map { ($0, $0.pid == 8 ? UInt64(1) : UInt64($0.pid) * 1_000_000_000) })
        let out = EnergyReader.rank(previous: before, current: after, seconds: 1, limit: 3) { ("\($0.pid)", "\($0.pid)") }
        #expect(out.map(\.name) == ["7", "6", "5"])
    }

    @Test func batteryHealthOnOlderAndM5Macs() {
        func n(_ v: Int) -> NSNumber { NSNumber(value: v) }
        let older: [String: Any] = ["DesignCapacity": n(5000), "AppleRawMaxCapacity": n(4000), "NominalChargeCapacity": n(4500)]
        #expect(BatteryReader.health(properties: older) == 0.8)
        let m5: [String: Any] = ["BatteryData": ["DesignCapacity": n(5000), "AppleRawMaxCapacity": n(4000), "NominalChargeCapacity": n(4500)]]
        #expect(BatteryReader.health(properties: m5) == 0.9)
        #expect(BatteryReader.health(properties: [:]) == nil)
    }

    @Test func systemLoadIsInMilliwatts() {
        #expect(BatteryReader.systemWatts(telemetry: ["SystemLoad": NSNumber(value: 9500)]) == 9.5)
        #expect(BatteryReader.systemWatts(telemetry: ["SystemLoad": NSNumber(value: 0)]) == nil)
        #expect(BatteryReader.systemWatts(telemetry: ["SystemLoad": NSNumber(value: UInt64.max)]) == nil)
        #expect(BatteryReader.systemWatts(telemetry: nil) == nil)
    }
}

@MainActor @Suite struct SpeedTestStoreTests {
    @Test func oneTestAtATimeAndTheResultStays() async {
        let store = SpeedTestStore { SpeedTestResult(downloadMbps: 100, uploadMbps: 20, latencyMs: 9, measuredAt: .distantPast) }
        let task = store.start()
        #expect(store.running)
        #expect(store.start() == nil)
        await task?.value
        #expect(!store.running)
        #expect(store.result?.downloadMbps == 100)
    }

    @Test func failureShowsAnErrorAndFreesTheButton() async {
        let store = SpeedTestStore { throw URLError(.notConnectedToInternet) }
        await store.start()?.value
        #expect(!store.running)
        #expect(store.error != nil)
    }
}
