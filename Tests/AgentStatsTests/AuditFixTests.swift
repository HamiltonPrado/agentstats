import Foundation
import Testing
@testable import AgentStats

/// As correções da auditoria (CODE_AUDIT.md).
@Suite("Correções da auditoria")
struct AuditFixTests {
    @Test func dayKeyIsGregorianAndASCII() {
        let utc = TimeZone(identifier: "UTC")!
        let d = Date(timeIntervalSince1970: 1_794_873_600 + 36_000)   // 2026-11-17 10:00 UTC
        #expect(DayKey.string(d, timeZone: utc) == "2026-11-17")
        #expect(DayKey.date("2026-11-17", timeZone: utc) == Date(timeIntervalSince1970: 1_794_873_600))
        #expect(DayKey.date("ontem") == nil)
        // Depois de mudar de fuso, o mesmo instante pode ser outro dia.
        #expect(DayKey.string(Date(timeIntervalSince1970: 1_794_873_600 + 43_200), timeZone: TimeZone(identifier: "Pacific/Auckland")!) == "2026-11-18")
        #expect(Budget.day(d, { var c = Calendar(identifier: .buddhist); c.timeZone = utc; return c }()) == "2026-11-17")
    }

    @Test func isoDatesWithAndWithoutFractions() {
        #expect(ISODate.shared.parse("2026-11-17T10:00:00Z") != nil)
        #expect(ISODate.shared.parse("2026-11-17T10:00:00.123Z") != nil)
        #expect(ISODate.shared.parse("ontem") == nil)
    }

    @Test func antigravityDatesThatDoNotParseAreSkipped() {
        let r = AntigravityReader()
        #expect(r.parseDate("2026-11-17 10:00:00Z") != nil)
        #expect(r.parseDate("1795000000") == Date(timeIntervalSince1970: 1_795_000_000))
        #expect(r.parseDate("1795000000000") == Date(timeIntervalSince1970: 1_795_000_000))
        #expect(r.parseDate("") == nil && r.parseDate("lixo") == nil)
    }

    @Test func onlyAgentStatsExecutablesAreOurHook() {
        #expect(ClaudeHook.isOurs(ClaudeHook.command(executable: "/Applications/AgentStats.app/Contents/MacOS/AgentStats")))
        #expect(ClaudeHook.isOurs(ClaudeHook.command(executable: "/Applications/Outro Nome.app/Contents/MacOS/AgentStats")))
        #expect(!ClaudeHook.isOurs("echo AgentStats --hook >> ~/log.txt"))
    }

    @Test func gifFramesFitTheMemoryBudget() {
        let s = GifMaker.frameSize(maxWidth: 720, frames: 300)
        #expect(s.width == 720 && s.width * s.height * 4 * 300 <= CGFloat(GifMaker.memoryBudget))
        #expect(GifMaker.frameSize(maxWidth: 480, frames: 20).height == CGFloat(1920))
    }

    @Test func clock() {
        #expect(Fmt.clock(0) == "0:00" && Fmt.clock(59.2) == "1:00" && Fmt.clock(3723) == "1:02:03" && Fmt.clock(-5) == "0:00")
    }

    @Test func sideEffectLinksAreRateLimited() {
        #expect(URLCommand.darkMode.hasSideEffects && URLCommand.copyUsage.hasSideEffects && URLCommand.desktopIcons.hasSideEffects)
        #expect(!URLCommand.pomodoro.hasSideEffects && !URLCommand.open(.time).hasSideEffects)
    }

    @Test func sqlValuesAreBoundNotPasted() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sql-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("t.db").path
        let made = Process()
        made.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        made.arguments = [db, "CREATE TABLE m(id TEXT, v TEXT); INSERT INTO m VALUES('a''b','1'); INSERT INTO m VALUES('x','2');"]
        try made.run(); made.waitUntilExit()
        var got: [String] = []
        SQLiteRead.query(db, "SELECT v FROM m WHERE id = ?", bind: ["a'b"]) { s in got.append(SQLiteRead.text(s, 0) ?? "") }
        #expect(got == ["1"])
        got = []
        SQLiteRead.query(db, "SELECT v FROM m WHERE id = ?", bind: ["x' OR '1'='1"]) { s in got.append(SQLiteRead.text(s, 0) ?? "") }
        #expect(got.isEmpty)
    }

    @MainActor @Test func importedSettingsReachTheMonitor() {
        let m = Monitor(demo: true)
        let key = "alert.cpu.threshold", old = UserDefaults.standard.object(forKey: key)
        defer { if let old { UserDefaults.standard.set(old, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        UserDefaults.standard.set(0.42, forKey: key)
        m.reloadFromDefaults()
        #expect(m.cpuThreshold == 0.42)
    }
}
