import Foundation
import Testing
@testable import AgentStats

struct DiskStorageTests {
    private func measure(_ category: DiskStorage.Category, _ bytes: UInt64, complete: Bool = true) -> DiskStorage.Measure {
        DiskStorage.Measure(root: DiskStorage.Root(category: category, path: "/x/\(bytes)"), bytes: bytes, complete: complete)
    }

    private func bytes(_ parts: [DiskStorage.Part], _ category: DiskStorage.Category) -> UInt64? {
        parts.first { $0.category == category }?.bytes
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agentstats-disk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func beforeScanningOnlyUsedAndFree() {
        let parts = DiskStorage.parts(total: 1000, free: 400, measures: nil)
        #expect(parts.map(\.category) == [.used, .free])
        #expect(bytes(parts, .used) == 600)
    }

    @Test func whatIsNotMeasuredIsSystemAndOther() {
        let found: [DiskStorage.Measure] = [measure(.apps, 200), measure(.documents, 50), measure(.documents, 30)]
        let parts = DiskStorage.parts(total: 1000, free: 400, measures: found)
        #expect(bytes(parts, .documents) == 80)
        #expect(bytes(parts, .other) == 320)
        #expect(bytes(parts, .free) == 400)
        #expect(bytes(parts, .music) == nil)
    }

    @Test func sharedBlocksNeverPassWhatIsUsed() {
        let found: [DiskStorage.Measure] = [measure(.apps, 500), measure(.documents, 300)]
        let parts = DiskStorage.parts(total: 1000, free: 400, measures: found)
        #expect(parts.reduce(UInt64(0)) { $0 + $1.bytes } == 1000)
        #expect(bytes(parts, .free) == 400)
        #expect(bytes(parts, .other) == nil)
    }

    @Test func inconsistentOrMissingTotalsDoNotCrash() {
        #expect(DiskStorage.parts(total: 0, free: 0, measures: nil).isEmpty)
        #expect(DiskStorage.parts(total: 100, free: 500, measures: []).map(\.category) == [.free])
    }

    @Test func widthsFillTheBarAndKeepTinyPartsVisible() {
        let found: [DiskStorage.Measure] = [measure(.apps, 900), measure(.music, 2), measure(.photos, 1)]
        let parts = DiskStorage.parts(total: 1000, free: 5, measures: found)
        for width in [280.0, 300.0, 360.0] {
            let widths = DiskStorage.widths(parts, width: width, gap: 1)
            let used: Double = widths.reduce(0, +) + Double(parts.count - 1)
            #expect(abs(used - width) < 0.001)
            #expect(widths.allSatisfy { $0 >= 3 })
        }
        #expect(DiskStorage.widths(parts, width: 0, gap: 1).allSatisfy { $0 >= 0 })
    }

    @Test func diskSizesUseTheUnitsOfMacOSSettings() {
        #expect(Fmt.disk(250_790_000_000) == "250,79 GB")
        #expect(Fmt.diskShort(123_650_000_000) == "124 GB")
        #expect(Fmt.diskShort(4_130_000_000) == "4,1 GB")
        #expect(Fmt.diskShort(512_000_000) == "512 MB")
        #expect(Fmt.diskShort(999_700_000_000) == "1,0 TB")
        #expect(Fmt.diskShort(1_500_000_000_000) == "1,5 TB")
    }

    @Test func memoryStaysInBinaryUnits() {
        #expect(Fmt.bytes(17_179_869_184) == "16 GB")
    }

    @Test func parsesDuOutput() {
        #expect(DiskStorage.bytes(duOutput: "2048\t/Users/demo/My Music\n") == 2_097_152)
        #expect(DiskStorage.bytes(duOutput: "") == nil)
        #expect(DiskStorage.bytes(duOutput: "du: erro\n") == nil)
    }

    @Test func rootsNeverOverlap() {
        let paths = DiskStorage.roots(home: "/Users/demo").map(\.path)
        for a in paths {
            for b in paths where a != b {
                #expect(!b.hasPrefix(a + "/"))
            }
        }
    }

    @Test func countsInsidePackagesAndHiddenFoldersButNotLinks() async throws {
        let base = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("medida")
        let outside = base.appendingPathComponent("fora")
        let package = folder.appendingPathComponent("Fototeca.photoslibrary")
        let hidden = folder.appendingPathComponent(".oculta")
        for dir in [outside, package, hidden] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Dados que o APFS não comprime nem guarda como esparsos.
        let block = Data((0..<1_048_576).map { _ in UInt8.random(in: 0...255) })
        try block.write(to: package.appendingPathComponent("a"))
        try block.write(to: hidden.appendingPathComponent("b"))
        try (block + block + block).write(to: outside.appendingPathComponent("c"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("ligacao"), withDestinationURL: outside)

        let result = await DiskStorage.measure(DiskStorage.Root(category: .photos, path: folder.path))
        let found = try #require(result)
        #expect(found.complete)
        #expect(found.bytes >= 2_097_152)
        #expect(found.bytes < 3_000_000)
    }

    @Test func unreadableFoldersAreReported() async throws {
        let base = try temporaryFolder()
        let locked = base.appendingPathComponent("fechada")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        chmod(locked.path, 0)
        defer {
            chmod(locked.path, 0o700)
            try? FileManager.default.removeItem(at: base)
        }
        let result = await DiskStorage.measure(DiskStorage.Root(category: .music, path: base.path))
        #expect(result?.complete == false)
    }

    @Test func missingRootsAndLinksAreSkipped() async throws {
        let base = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let link = base.appendingPathComponent("ligacao")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: base)
        let viaLink = await DiskStorage.measure(DiskStorage.Root(category: .apps, path: link.path))
        let missing = await DiskStorage.measure(DiskStorage.Root(category: .apps, path: base.path + "/nao-existe"))
        #expect(viaLink == nil)
        #expect(missing == nil)
    }

    @Test func untilTheFirstScanEndsTheRestIsStillToMeasure() {
        let parts = DiskStorage.parts(total: 1000, free: 400, measures: [measure(.apps, 200)], finished: false)
        #expect(parts.map(\.category) == [.apps, .pending, .free])
        #expect(bytes(parts, .pending) == 400)
    }

    @MainActor private func store(cache: URL?, size: UInt64 = 10) -> DiskScanStore {
        let roots: [DiskStorage.Root] = [DiskStorage.Root(category: .apps, path: "/a"),
                                         DiskStorage.Root(category: .music, path: "/b", listed: "Music")]
        return DiskScanStore(roots: roots, cacheFile: cache) { root in
            DiskStorage.Measure(root: root, bytes: size, complete: true)
        }
    }

    @MainActor @Test func appearingMeasuresWithoutAClickAndOnlyAgainWhenOld() async {
        let store = store(cache: nil)
        let now = Date()
        let first = store.refreshIfNeeded(now: now)
        #expect(first != nil)
        #expect(store.refreshIfNeeded(now: now) == nil)   // já está a medir
        await first?.value
        #expect(store.measures?.count == 2)
        #expect(store.refreshIfNeeded(now: now.addingTimeInterval(3600)) == nil)
        let later = store.refreshIfNeeded(now: now.addingTimeInterval(DiskScanStore.maxAge + 1))
        #expect(later != nil)
        await later?.value
    }

    @MainActor @Test func aClockSetBackMeasuresAgain() async {
        let store = store(cache: nil)
        let now = Date()
        await store.start(now: now)?.value
        let again = store.refreshIfNeeded(now: now.addingTimeInterval(-3600))
        #expect(again != nil)
        await again?.value
    }

    @MainActor @Test func theLastResultShowsStraightAwayAfterRelaunch() async throws {
        let base = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("disk.json")
        let now = Date()
        await store(cache: file, size: 10).start(now: now)?.value

        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)

        let relaunched = store(cache: file, size: 99)
        #expect(relaunched.refreshIfNeeded(now: now.addingTimeInterval(60)) == nil)
        #expect(relaunched.measures?.map(\.bytes) == [10, 10])

        let old = store(cache: file, size: 99)
        let refresh = old.refreshIfNeeded(now: now.addingTimeInterval(DiskScanStore.maxAge + 1))
        #expect(old.measures?.map(\.bytes) == [10, 10])   // a anterior fica à vista enquanto atualiza
        await refresh?.value
        #expect(old.measures?.map(\.bytes) == [99, 99])
    }

    @MainActor @Test func aDamagedCacheJustMeasuresAgain() async throws {
        let base = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("disk.json")
        try Data("lixo".utf8).write(to: file)
        let store = store(cache: file)
        let task = store.refreshIfNeeded()
        #expect(task != nil)
        await task?.value
        #expect(store.measures?.count == 2)
    }

    @MainActor @Test func demoNeverReadsTheCacheNorMeasures() async throws {
        let base = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("disk.json")
        await store(cache: file, size: 12_345).start()?.value
        let demo = store(cache: file)
        demo.loadDemo()
        #expect(demo.refreshIfNeeded() == nil)
        #expect(demo.measures?.contains { $0.bytes == 12_345 } == false)
    }

    @MainActor @Test func oneScanAtATimeAndPartialReadsAreShown() async {
        let roots: [DiskStorage.Root] = [DiskStorage.Root(category: .documents, path: "/a", listed: "Documents"),
                                         DiskStorage.Root(category: .photos, path: "/b", listed: "Pictures")]
        let store = DiskScanStore(roots: roots) { root in
            DiskStorage.Measure(root: root, bytes: root.path == "/a" ? 10 : 20, complete: root.path == "/a")
        }
        let task = store.start()
        #expect(task != nil)
        #expect(store.start() == nil)
        await task?.value
        #expect(!store.running)
        #expect(store.folders.map(\.root.path) == ["/b", "/a"])
        #expect(store.incomplete == [.photos])
    }
}
