import Foundation
import Testing
@testable import AgentStats

@Suite("Discos")
struct DisksTests {
    @Test func onlyWhatTheFinderWouldEject() {
        #expect(!DiskRules.isEjectable(path: "/", ejectable: false, removable: false, onInternalDisk: true, local: true))
        #expect(!DiskRules.isEjectable(path: "/System/Volumes/Data", ejectable: false, removable: false, onInternalDisk: true, local: true))
        #expect(!DiskRules.isEjectable(path: "/Volumes/Interno", ejectable: false, removable: false, onInternalDisk: true, local: true))
        #expect(DiskRules.isEjectable(path: "/Volumes/PEN", ejectable: true, removable: true, onInternalDisk: false, local: true))
        #expect(DiskRules.isEjectable(path: "/Volumes/SSD", ejectable: false, removable: false, onInternalDisk: false, local: true))
        #expect(DiskRules.isEjectable(path: "/Volumes/NAS", ejectable: false, removable: false, onInternalDisk: true, local: false))
    }

    @Test func namesWhoIsUsingTheDisk() {
        let out = "p100\ncPreview\nn/Volumes/PEN/a.pdf\np200\ncFinder\np300\ncPreview\np400\ncMicrosoft\\x20Word\n"
        #expect(DiskRules.blockers(lsofOutput: out) == ["Finder", "Microsoft Word", "Preview"])
        #expect(DiskRules.blockedMessage(["Preview"]).contains("Preview"))
        #expect(DiskRules.blockedMessage([]).contains("em uso"))
    }
}

@Suite("Arranque")
struct StartupTests {
    @Test func readsAPlist() {
        let plist: [String: Any] = ["Label": "com.lwouis.alt-tab-macos", "RunAtLoad": true,
                                    "ProgramArguments": ["/Applications/AltTab.app/Contents/MacOS/AltTab", "--x"]]
        let item = StartupRules.item(plist: plist, path: "/p.plist", scope: .user)
        #expect(item?.appName == "AltTab")
        #expect(item?.runAtLoad == true && item?.keepAlive == false)
        #expect(item?.canToggle == true)
        #expect(StartupRules.item(plist: ["Program": "/x"], path: "/p", scope: .user) == nil)   // sem label
        let daemon = StartupRules.item(plist: ["Label": "d", "Program": "/usr/local/bin/d", "KeepAlive": ["SuccessfulExit": false]],
                                       path: "/d.plist", scope: .daemon)
        #expect(daemon?.keepAlive == true && daemon?.appName == nil && daemon?.canToggle == false)
    }

    @Test func disabledAndRunningStates() {
        let printed = """
            disabled services = {
                "com.docker.helper" => enabled
                "com.apple.ManagedClientAgent.enrollagent" => disabled
                "org.old" => true
            }
            """
        let s = StartupRules.disabledLabels(printed)
        #expect(s.disabled == ["com.apple.ManagedClientAgent.enrollagent", "org.old"])
        #expect(s.enabled == ["com.docker.helper"])
        let list = "PID\tStatus\tLabel\n-\t0\tcom.a\n5730\t0\tcom.b\n"
        #expect(StartupRules.runningLabels(list) == ["com.b"])
    }

    @Test func yoursComeFirst() {
        let items = [LaunchItem(label: "z", plist: "1", scope: .daemon), LaunchItem(label: "b", plist: "2", scope: .user),
                     LaunchItem(label: "a", plist: "3", scope: .agent), LaunchItem(label: "a", plist: "4", scope: .user)]
        #expect(StartupRules.sorted(items).map(\.plist) == ["4", "2", "3", "1"])
    }
}

@Suite("Cache de DNS")
struct DNSFlushTests {
    @Test func outcomes() {
        #expect(DNSFlush.outcome(status: 0, error: "") == .done)
        #expect(DNSFlush.outcome(status: 1, error: "execution error: User canceled. (-128)") == .cancelled)
        #expect(DNSFlush.outcome(status: 1, error: "other") == .failed)
        #expect(DNSFlush.script.contains("with administrator privileges"))
    }
}

@Suite("Ficheiros grandes")
struct LargeFilesTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func file(_ name: String, _ size: UInt64, daysAgo: Double, usedDaysAgo: Double? = nil) -> BigFile {
        BigFile(path: "/x/" + name, size: size, modified: now - daysAgo * 86_400, lastUsed: usedDaysAgo.map { now - $0 * 86_400 })
    }

    @Test func filtersBySizeAndAge() {
        let files = [file("a", 200_000_000, daysAgo: 400), file("b", 2_000_000_000, daysAgo: 400, usedDaysAgo: 10),
                     file("c", 700_000_000, daysAgo: 5)]
        #expect(LargeFilesRules.shown(files, minSize: 500_000_000, onlyOld: false, now: now).map(\.name) == ["b", "c"])
        // "b" foi aberto há 10 dias: não é antigo, mesmo modificado há mais de um ano.
        #expect(LargeFilesRules.shown(files, minSize: 100_000_000, onlyOld: true, now: now).map(\.name) == ["a"])
    }

    @Test func ages() {
        #expect(LargeFilesRules.age(now, now: now) == "hoje")
        #expect(LargeFilesRules.age(now - 86_400, now: now) == "ontem")
        #expect(LargeFilesRules.age(now - 10 * 86_400, now: now) == "há 10 dias")
        #expect(LargeFilesRules.age(now - 100 * 86_400, now: now).hasSuffix("meses"))
        #expect(LargeFilesRules.age(now - 800 * 86_400, now: now) == "há 2 anos")
    }

    @Test func scanSkipsLibraryHiddenAndPackages() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agentstats-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let big = Data(repeating: 7, count: 300_000)
        for rel in ["Downloads/grande.bin", "Library/cache.bin", ".escondida/x.bin", "Apps/Coisa.app/Contents/x.bin",
                    "projeto/node_modules/pkg/x.bin", "Documents/pequeno.txt"] {
            let url = home.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (rel.hasSuffix("pequeno.txt") ? Data("oi".utf8) : big).write(to: url)
        }
        let found = LargeFilesRules.scan(home: home, minSize: 100_000)
        #expect(found.map(\.name) == ["grande.bin"])
    }
}
