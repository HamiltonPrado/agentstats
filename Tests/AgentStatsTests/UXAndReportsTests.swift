import Foundation
import Testing
@testable import AgentStats

@Suite("Separadores e boas-vindas")
struct UXTests {
    @Test func dragMovesATab() {
        let order = TabLayout.encode(Tab.main)
        let moved = TabLayout.order(TabLayout.moving(order: order, .tools, to: .agents))
        #expect(moved.first == .tools && moved[1] == .agents)
        #expect(TabLayout.moving(order: order, .agents, to: .agents) == order)
    }

    @Test func timeTabIsAppendedForOldOrders() {
        let old = "agents,system,processes,audio,clipboard,capture,tools"
        #expect(TabLayout.order(old).last == .time)
    }

    @Test func welcomeOnlyForNewPeople() {
        let d = UserDefaults(suiteName: "agentstats-welcome-\(UUID().uuidString)")!
        #expect(Welcome.shouldShow(d))
        d.set("system", forKey: "panel.tab2")
        #expect(!Welcome.shouldShow(d))
        let fresh = UserDefaults(suiteName: "agentstats-welcome-\(UUID().uuidString)")!
        fresh.set(true, forKey: Welcome.shownKey)
        #expect(!Welcome.shouldShow(fresh))
    }
}

@Suite("Tempo")
struct TimeTests {
    @Test func pomodoroCycle() {
        var p = TimerPlan(phase: .focus, duration: TimerPlan.focus)
        var phases: [TimerPlan.Phase] = []
        for _ in 0..<8 { p = p.next()!; phases.append(p.phase) }
        #expect(phases == [.shortBreak, .focus, .shortBreak, .focus, .shortBreak, .focus, .longBreak, .focus])
        #expect(TimerPlan(phase: .timer, duration: 60).next() == nil)
    }

    @Test func clockText() {
        #expect(Fmt.clock(0) == "0:00")
        #expect(Fmt.clock(59.2) == "1:00")
        #expect(Fmt.clock(25 * 60) == "25:00")
        #expect(Fmt.clock(3725) == "1:02:05")
    }

    @Test func worldClock() {
        let lisbon = TimeZone(identifier: "Europe/Lisbon")!, tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let kolkata = TimeZone(identifier: "Asia/Kolkata")!
        let winter = ISO8601DateFormatter().date(from: "2026-01-15T20:00:00Z")!
        #expect(WorldClock.offset(tokyo, from: lisbon, at: winter) == "+9 h")
        #expect(WorldClock.offset(kolkata, from: lisbon, at: winter) == "+5 h 30")
        #expect(WorldClock.offset(lisbon, from: lisbon, at: winter) == "mesma hora")
        #expect(WorldClock.dayNote(tokyo, local: lisbon, at: winter) == "amanhã")
        #expect(WorldClock.dayNote(TimeZone(identifier: "America/Los_Angeles")!, local: tokyo, at: winter) == "ontem")
        #expect(WorldClock.city(TimeZone(identifier: "America/Sao_Paulo")!) == "Sao Paulo")
        #expect(WorldClock.search("tok").contains(tokyo))
        #expect(WorldClock.search("x").isEmpty)
        #expect(WorldClock.zones("Europe/Lisbon,Nada/Isto,Asia/Tokyo") == [lisbon, tokyo])
    }
}

@Suite("Orçamento, resumo e CSV")
struct ReportsTests {
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Lisbon")!; return c }
    private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    private func day(_ d: String, cost: Double, tokens: Int = 1000) -> DayUsage {
        DayUsage(day: d, claude: TokenUsage(input: tokens), cost: cost)
    }

    @Test func budgetSpentPerDayAndWeek() {
        let week = [day("2026-11-17", cost: 5), day("2026-11-22", cost: 4), day("2026-11-23", cost: 3), day("2026-11-24", cost: 2)]
        let tuesday = date("2026-11-24T12:00:00Z")   // terça; a semana começa na segunda 23
        #expect(Budget.spent(week, period: .day, now: tuesday, calendar: cal) == 2)
        #expect(Budget.spent(week, period: .week, now: tuesday, calendar: cal) == 5)
    }

    @Test func budgetWarnsOncePerLevelAndPeriod() {
        var r = Budget.evaluate(spent: 7, amount: 10, period: "d1", notified: nil)
        #expect(r.level == nil)
        r = Budget.evaluate(spent: 8.5, amount: 10, period: "d1", notified: nil)
        #expect(r.level == 80 && r.notified == "d1|80")
        #expect(Budget.evaluate(spent: 9, amount: 10, period: "d1", notified: r.notified).level == nil)
        #expect(Budget.evaluate(spent: 10, amount: 10, period: "d1", notified: r.notified).level == 100)
        #expect(Budget.evaluate(spent: 8.5, amount: 10, period: "d2", notified: "d1|100").level == 80)   // dia novo
    }

    @Test func weeklySummaryOncePerWeekAfterNine() {
        let early = date("2026-11-23T07:00:00Z"), later = date("2026-11-23T10:00:00Z")
        #expect(WeeklySummary.due(now: early, last: nil, calendar: cal) == nil)
        let id = WeeklySummary.due(now: later, last: nil, calendar: cal)
        #expect(id != nil)
        #expect(WeeklySummary.due(now: later, last: id, calendar: cal) == nil)
        var u = UsageSnapshot()
        #expect(WeeklySummary.text(u) == nil)
        u.week = [day("2026-11-17", cost: 2, tokens: 2_000_000)]
        u.projects = [ProjectUsage(name: "loja", usage: TokenUsage(input: 1_000_000), cost: 1)]
        #expect(WeeklySummary.text(u)?.body.contains("loja (50%)") == true)
    }

    @Test func csv() {
        var u = UsageSnapshot()
        u.week = [day("2026-11-24", cost: 1.5)]
        u.projects = [ProjectUsage(name: "a, \"b\"", usage: TokenUsage(input: 10), cost: 0.25), ProjectUsage(name: "=SOMA(1)", usage: TokenUsage(), cost: 0)]
        let lines = UsageCSV.make(u).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines[0] == "dia,claude_tokens,codex_tokens,outros_tokens,total_tokens,custo_usd")
        #expect(lines[1] == "2026-11-24,1000,0,0,1000,1.5000")
        #expect(lines.contains("\"a, \"\"b\"\"\",10,0.2500"))
        #expect(lines.contains("'=SOMA(1),0,0.0000"))
    }

    @Test func settingsTransferKeepsOnlyChoices() {
        let all: [String: Any] = ["bar.cpu": true, "appearance.accentHex": "#fff", "alert.limits.notified": ["a": 1],
                                  "welcome.shown": true, "NSWindow Frame x": "1", "clock.zones": "Asia/Tokyo", "panel.tab2": "agents"]
        let kept = SettingsTransfer.filtered(all)
        #expect(Set(kept.keys) == ["bar.cpu", "appearance.accentHex", "clock.zones"])
        let round = SettingsTransfer.read(try! SettingsTransfer.data(all))
        #expect(round?["clock.zones"] as? String == "Asia/Tokyo")
    }
}

@Suite("Comandos agentstats://")
struct URLCommandTests {
    private func cmd(_ s: String) -> URLCommand? { URLCommand.parse(URL(string: s)!) }

    @Test func parses() {
        #expect(cmd("agentstats://open/system") == .open(.system))
        #expect(cmd("agentstats://open?tab=time") == .open(.time))
        #expect(cmd("agentstats://open/settings") == nil)
        #expect(cmd("agentstats://timer?minutes=25") == .timer(minutes: 25))
        #expect(cmd("agentstats://timer/10") == .timer(minutes: 10))
        #expect(cmd("agentstats://timer?minutes=0") == nil)
        #expect(cmd("agentstats://timer/stop") == .stopTimer)
        #expect(cmd("agentstats://pomodoro") == .pomodoro)
        #expect(cmd("agentstats://read/qr") == .readCode)
        #expect(cmd("agentstats://toggle/dark-mode") == .darkMode)
        #expect(cmd("agentstats://usage/copy") == .copyUsage)
        #expect(cmd("agentstats://apagar/tudo") == nil)
        #expect(cmd("https://open/system") == nil)
    }

    /// Um link de uma página qualquer com chaves repetidas não pode deitar a app abaixo.
    @Test func repeatedKeysKeepTheFirst() {
        #expect(cmd("agentstats://timer?minutes=5&minutes=6") == .timer(minutes: 5))
        #expect(cmd("agentstats://open?Tab=time&tab=system") == .open(.time))
    }

    @Test func usageText() {
        var u = UsageSnapshot()
        u.week = [DayUsage(day: "2026-11-24", claude: TokenUsage(input: 2_800_000), cost: 3.39)]
        u.todayClaude = TokenUsage(input: 2_800_000)
        #expect(URLCommand.usageText(u).hasPrefix("Hoje: 2,8M tokens, ~$3,39"))
    }
}
