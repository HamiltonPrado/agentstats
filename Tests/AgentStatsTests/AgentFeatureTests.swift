import Foundation
import Testing
@testable import AgentStats

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private func window(_ used: Double, resetsIn: TimeInterval?, duration: TimeInterval? = 5 * 3600, id: String = "claude.five_hour") -> LimitWindow {
    LimitWindow(id: id, label: "5 horas", usedPercent: used, resetsAt: resetsIn.map { now.addingTimeInterval($0) }, duration: duration)
}
private func limits(_ w: LimitWindow...) -> [PlanLimits] {
    [PlanLimits(provider: .claude, plan: "Max", windows: w, observedAt: now)]
}

@Suite struct LimitForecastTests {
    @Test func runsOutBeforeResetAtTheCurrentPace() {
        // 2 h de 5 h passadas com 60%: 30%/h, os 40% que faltam acabam em 1 h 20 min, antes das 3 h que faltam.
        let end = LimitForecast.runsOut(window(60, resetsIn: 3 * 3600), now: now)
        #expect(end.map { abs($0.timeIntervalSince(now) - 80 * 60) < 1 } == true)
    }

    @Test func noForecastWhenItLastsOrThereIsTooLittleData() {
        #expect(LimitForecast.runsOut(window(20, resetsIn: 3 * 3600), now: now) == nil)      // chega com folga
        #expect(LimitForecast.runsOut(window(30, resetsIn: 4.8 * 3600), now: now) == nil)    // 4% da janela passada
        #expect(LimitForecast.runsOut(window(5, resetsIn: 1 * 3600), now: now) == nil)       // pouco gasto
        #expect(LimitForecast.runsOut(window(100, resetsIn: 1 * 3600), now: now) == nil)     // já acabou
        #expect(LimitForecast.runsOut(window(60, resetsIn: 3 * 3600, duration: nil), now: now) == nil)
        #expect(LimitForecast.runsOut(window(60, resetsIn: nil), now: now) == nil)
    }
}

@Suite struct LimitWatchTests {
    @Test func warnsOncePerLevel() {
        var state: [String: Double] = [:]
        var r = LimitWatch.evaluate(limits(window(60, resetsIn: 3600)), notified: state, first: 75, now: now)
        #expect(r.events.isEmpty)
        r = LimitWatch.evaluate(limits(window(78, resetsIn: 3600)), notified: r.notified, first: 75, now: now)
        #expect(r.events.count == 1)
        state = r.notified
        r = LimitWatch.evaluate(limits(window(80, resetsIn: 3600)), notified: state, first: 75, now: now)
        #expect(r.events.isEmpty)
        r = LimitWatch.evaluate(limits(window(91, resetsIn: 3600)), notified: r.notified, first: 75, now: now)
        guard case .reached(_, _, let level, _)? = r.events.first else { Issue.record("sem aviso"); return }
        #expect(level == 90)
        r = LimitWatch.evaluate(limits(window(99, resetsIn: 3600)), notified: r.notified, first: 75, now: now)
        #expect(r.events.isEmpty)
    }

    @Test func jumpingStraightPastBothWarnsOnceAtTheHighest() {
        let r = LimitWatch.evaluate(limits(window(95, resetsIn: 3600)), notified: [:], first: 75, now: now)
        #expect(r.events.count == 1)
        guard case .reached(_, _, let level, _)? = r.events.first else { Issue.record("sem aviso"); return }
        #expect(level == 90)
    }

    @Test func tellsWhenItRenewsAndStartsAgain() {
        let w = window(80, resetsIn: 600)
        var r = LimitWatch.evaluate(limits(w), notified: [:], first: 75, now: now)
        let later = now.addingTimeInterval(601)
        r = LimitWatch.evaluate(limits(w), notified: r.notified, first: 75, now: later)
        #expect(r.events == [.renewed(provider: .claude, label: "5 horas")])
        #expect(r.notified.isEmpty)
        // a janela seguinte volta a avisar
        let next = LimitWindow(id: w.id, label: w.label, usedPercent: 76, resetsAt: later.addingTimeInterval(5 * 3600), duration: w.duration)
        r = LimitWatch.evaluate(limits(next), notified: r.notified, first: 75, now: later)
        #expect(r.events.count == 1)
    }

    @Test func oldEpisodesAreForgottenWithoutNotifying() {
        let gone = LimitWatch.episode(.claude, window(80, resetsIn: -60))
        let r = LimitWatch.evaluate(limits(window(10, resetsIn: 3600)), notified: [gone: 75], first: 75, now: now)
        #expect(r.notified[gone] == nil)
        #expect(r.events.isEmpty)
    }

    @Test func withoutResetTimeADropStartsANewWindow() {
        var r = LimitWatch.evaluate(limits(window(80, resetsIn: nil)), notified: [:], first: 75, now: now)
        #expect(r.events.count == 1)
        r = LimitWatch.evaluate(limits(window(20, resetsIn: nil)), notified: r.notified, first: 75, now: now)
        r = LimitWatch.evaluate(limits(window(78, resetsIn: nil)), notified: r.notified, first: 75, now: now)
        #expect(r.events.count == 1)
    }

    @Test func aHighFirstLevelHasNoSecond() {
        #expect(LimitWatch.levels(75) == [75, 90])
        #expect(LimitWatch.levels(95) == [95])
    }
}

@Suite struct AgentAwakeTests {
    @Test func holdsWhileWorkingAndAShortWhileAfter() {
        #expect(AgentAwake.shouldHold(working: 2, lastWorking: nil, now: now))
        #expect(AgentAwake.shouldHold(working: 0, lastWorking: now.addingTimeInterval(-60), now: now))
        #expect(!AgentAwake.shouldHold(working: 0, lastWorking: now.addingTimeInterval(-AgentAwake.grace - 1), now: now))
        #expect(!AgentAwake.shouldHold(working: 0, lastWorking: nil, now: now))
    }
}

@Suite struct ClaudeHookTests {
    private let exe = "/Applications/AgentStats.app/Contents/MacOS/AgentStats"
    private func exists(_ p: String) -> Bool { p == "/Applications/AgentStats.app/Contents/MacOS/AgentStats" }

    @Test func recognisesTheCommandWithOrWithoutQuotes() {
        #expect(ClaudeHook.executable(in: ClaudeHook.command(executable: exe)) == exe)
        #expect(ClaudeHook.executable(in: exe + " --hook 2>/dev/null || true") == exe)
        let odd = "/Users/x/Apps/Agent's Stats/AgentStats.app/Contents/MacOS/AgentStats"
        #expect(ClaudeHook.executable(in: ClaudeHook.command(executable: odd)) == odd)
    }

    @Test func installingKeepsEverythingElse() {
        let other: [String: Any] = ["type": "command", "command": "say pronto"]
        let settings: [String: Any] = ["theme": "dark", "model": "opus",
                                       "hooks": ["Notification": [["hooks": [other]]], "Stop": [["hooks": [other]]]]]
        let after = ClaudeHook.installing(settings, executable: exe)
        #expect(after["theme"] as? String == "dark")
        #expect(after["model"] as? String == "opus")
        let hooks = after["hooks"] as? [String: Any]
        #expect((hooks?["Stop"] as? [Any])?.count == 1)
        #expect((hooks?["Notification"] as? [Any])?.count == 2)
        #expect(ClaudeHook.state(settings: after, claudeExists: true, exists: exists) == .on)
    }

    @Test func installingTwiceDoesNotDuplicateAndRepairsAStalePath() {
        let stale = ClaudeHook.installing([:], executable: "/Volumes/velho/AgentStats.app/Contents/MacOS/AgentStats")
        #expect(ClaudeHook.state(settings: stale, claudeExists: true, exists: exists) == .stale)
        let once = ClaudeHook.installing(stale, executable: exe)
        let twice = ClaudeHook.installing(once, executable: exe)
        #expect(ClaudeHook.ourCommands(twice).count == 1)
        #expect(ClaudeHook.state(settings: twice, claudeExists: true, exists: exists) == .on)
    }

    @Test func removingTakesOnlyOursAndCleansEmptyKeys() {
        let other: [String: Any] = ["type": "command", "command": "say pronto"]
        let mixed: [String: Any] = ["hooks": ["Notification": [["hooks": [other, ["type": "command", "command": ClaudeHook.command(executable: exe)]]]]]]
        let removed = ClaudeHook.removing(mixed)
        let left = ((removed["hooks"] as? [String: Any])?["Notification"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]]
        #expect(left?.count == 1)
        #expect(left?.first?["command"] as? String == "say pronto")
        let onlyOurs = ClaudeHook.installing(["theme": "dark"], executable: exe)
        let clean = ClaudeHook.removing(onlyOurs)
        #expect(clean["hooks"] == nil)
        #expect(clean["theme"] as? String == "dark")
    }

    @Test func states() {
        #expect(ClaudeHook.state(settings: nil, claudeExists: false, exists: exists) == .noClaude)
        #expect(ClaudeHook.state(settings: nil, claudeExists: true, exists: exists) == .off)
        #expect(ClaudeHook.state(settings: ["theme": "dark"], claudeExists: true, exists: exists) == .off)
    }

    @MainActor @Test func theStoreWritesABackupAndRefusesBrokenJSON() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hook-\(UUID().uuidString)/.claude")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let file = dir.appendingPathComponent("settings.json")
        let original = Data("{\n  \"theme\" : \"dark\"\n}\n".utf8)
        try original.write(to: file)
        var env = ClaudeHookStore.Environment()
        env.claudeDir = dir
        env.executable = exe
        env.exists = { $0 == "/Applications/AgentStats.app/Contents/MacOS/AgentStats" }
        let store = ClaudeHookStore(environment: env)
        store.refresh()
        #expect(store.state == .off)
        store.set(true)
        #expect(store.state == .on)
        #expect(try Data(contentsOf: dir.appendingPathComponent("settings.json.agentstats-backup")) == original)
        store.set(false)
        #expect(store.state == .off)
        let back = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        #expect(back?["theme"] as? String == "dark")
        #expect(back?["hooks"] == nil)

        let broken = Data("{ isto não é json".utf8)
        try broken.write(to: file)
        store.refresh()
        #expect(store.state == .unreadable)
        store.set(true)
        #expect(try Data(contentsOf: file) == broken)
    }
}
