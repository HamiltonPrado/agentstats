import Foundation
import Testing
@testable import AgentStats

@MainActor @Suite("Notas rápidas", .serialized)
struct QuickNotesTests {
    @Test func survivesARestartPrivately() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("notes.json")
        let a = QuickNotesStore(file: file)
        a.text = "comprar café\nligar à Ana"
        a.saveNow()
        #expect(QuickNotesStore(file: file).text == "comprar café\nligar à Ana")
        let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }
}

@Suite("Tempo por app")
struct AppUsageTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func idleTimeDoesNotCount() {
        #expect(AppUsage.credited(from: t0, to: t0 + 600, idleSeconds: 30) == 600)
        #expect(AppUsage.credited(from: t0, to: t0 + 600, idleSeconds: 400) == 200)   // parado há mais de 5 min
        #expect(AppUsage.credited(from: t0, to: t0 + 200, idleSeconds: 900) == 0)
    }

    @Test func addsPerDayAndKeepsAWeek() {
        var days: [AppUsageDay] = []
        days = AppUsage.adding(60, app: "a", name: "A", day: "2026-11-01", to: days)
        days = AppUsage.adding(30, app: "a", name: "A", day: "2026-11-01", to: days)
        days = AppUsage.adding(90, app: "b", name: "B", day: "2026-11-01", to: days)
        #expect(days.count == 1 && days[0].seconds["a"] == 90)
        #expect(AppUsage.top(days[0]).map(\.id) == ["a", "b"] || AppUsage.top(days[0]).map(\.id) == ["b", "a"])
        for d in 2...10 { days = AppUsage.adding(1, app: "a", name: "A", day: String(format: "2026-11-%02d", d), to: days) }
        #expect(days.count == AppUsage.keepDays && days.last?.day == "2026-11-10")
        #expect(AppUsage.adding(0, app: "x", name: "X", day: "2026-12-01", to: days) == days)
    }
}

@Suite("Reuniões")
struct MeetingsTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func findsTheJoinLink() {
        #expect(Meetings.joinLink(in: [nil, "Sala 2", "Entrar: https://meet.google.com/abc-defg-hij obrigado"])?.host == "meet.google.com")
        #expect(Meetings.joinLink(in: ["https://us02web.zoom.us/j/123?pwd=x"])?.host == "us02web.zoom.us")
        #expect(Meetings.joinLink(in: ["https://teams.microsoft.com/l/meetup-join/xyz"]) != nil)
        #expect(Meetings.joinLink(in: ["https://example.com/agenda", "sem link"]) == nil)
    }

    @Test func countdownOnlyNearTheStart() {
        #expect(Meetings.menuBarText(start: now + 10 * 60, end: now + 40 * 60, now: now) == "10 min")
        #expect(Meetings.menuBarText(start: now + 40 * 60, end: now + 70 * 60, now: now) == nil)
        #expect(Meetings.menuBarText(start: now - 60, end: now + 60, now: now) == "agora")
        #expect(Meetings.when(start: now + 5 * 60, end: now + 35 * 60, now: now) == "em 5 min")
    }
}

@Suite("Apps que não respondem")
struct UnresponsiveTests {
    @Test func twoStrikesAndForgetsRecoveredOrClosedApps() {
        var r = UnresponsiveRules.update(strikes: [:], failed: [10, 20], alive: [10, 20, 30])
        #expect(r.stuck.isEmpty)
        r = UnresponsiveRules.update(strikes: r.strikes, failed: [10], alive: [10, 20, 30])
        #expect(r.stuck == [10])          // 20 voltou a responder
        r = UnresponsiveRules.update(strikes: r.strikes, failed: [10], alive: [20, 30])
        #expect(r.stuck.isEmpty)          // 10 fechou
    }
}

@Suite("Atalhos da app")
struct AppShortcutsTests {
    @Test func labels() {
        #expect(AppShortcuts.label(char: "s", modifiers: 0, virtualKey: nil) == "⌘S")
        #expect(AppShortcuts.label(char: "z", modifiers: AppShortcuts.shiftBit, virtualKey: nil) == "⇧⌘Z")
        #expect(AppShortcuts.label(char: "f", modifiers: AppShortcuts.controlBit, virtualKey: nil) == "⌃⌘F")
        #expect(AppShortcuts.label(char: nil, modifiers: AppShortcuts.optionBit, virtualKey: 0x7B) == "⌥⌘←")
        #expect(AppShortcuts.label(char: "k", modifiers: AppShortcuts.noCommandBit | AppShortcuts.controlBit, virtualKey: nil) == "⌃K")
        #expect(AppShortcuts.label(char: nil, modifiers: 0, virtualKey: nil) == nil)
        #expect(AppShortcuts.label(char: "\u{8}", modifiers: 0, virtualKey: 0x33) == "⌘⌫")
    }
}

@Suite("Regras")
struct RulesTests {
    @Test func batteryFiresOnceOnTheWayDown() {
        let t = Rule.Trigger.batteryBelow(20)
        #expect(RuleMatching.matches(t, .battery(previous: 0.21, now: 0.19)))
        #expect(!RuleMatching.matches(t, .battery(previous: 0.19, now: 0.18)))   // já estava abaixo
        #expect(!RuleMatching.matches(t, .battery(previous: nil, now: 0.10)))    // primeira leitura não conta
        #expect(!RuleMatching.matches(t, .battery(previous: 0.18, now: 0.25)))
    }

    @Test func otherTriggers() {
        #expect(RuleMatching.matches(.powerConnected, .power(connected: true)))
        #expect(!RuleMatching.matches(.powerConnected, .power(connected: false)))
        #expect(RuleMatching.matches(.displayConnected, .displays(previous: 1, now: 2)))
        #expect(RuleMatching.matches(.displayDisconnected, .displays(previous: 2, now: 1)))
        #expect(RuleMatching.matches(.agentFinished, .agentFinished))
        #expect(!RuleMatching.matches(.agentFinished, .agentNeedsYou))
    }

    @MainActor @Test func savedAndNeverExported() throws {
        let rules = [Rule(trigger: .batteryBelow(15), action: .command("say olá")), Rule(trigger: .displayConnected, action: .arrangeWindow("maximize"))]
        let back = try JSONDecoder().decode([Rule].self, from: JSONEncoder().encode(rules))
        #expect(back == rules)
        // Um ficheiro de definições nunca traz regras (podiam correr comandos).
        let exported = SettingsTransfer.filtered([RulesStore.key: Data([1]), "bar.cpu": true])
        #expect(exported[RulesStore.key] == nil && exported["bar.cpu"] != nil)
    }
}

@Suite("Correções da revisão")
struct ReviewFixTests {
    @Test func commandHeldAloneOnly() {
        #expect(ShortcutsOverlay.heldAlone(secondsSinceLastKey: 1.2))
        #expect(!ShortcutsOverlay.heldAlone(secondsSinceLastKey: 0.3))   // carregou noutra tecla (ex.: ⌘⇥)
    }

    @Test func appsStillLaunchingAreNotStuck() {
        let now = Date()
        #expect(!UnresponsiveRules.oldEnough(launched: now.addingTimeInterval(-5), now: now))
        #expect(UnresponsiveRules.oldEnough(launched: now.addingTimeInterval(-60), now: now))
        #expect(UnresponsiveRules.oldEnough(launched: nil, now: now))
    }
}

@Suite("Manter acordado")
struct KeepAwakeTests {
    @Test func assertionTypes() {
        #expect(KeepAwakeController.assertionType(display: true) == "PreventUserIdleDisplaySleep")
        #expect(KeepAwakeController.assertionType(display: false) == "PreventUserIdleSystemSleep")
    }
}
