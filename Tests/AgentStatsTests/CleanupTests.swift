import Darwin
import Foundation
import Testing
@testable import AgentStats

// Nada real é tocado: a "pasta pessoal" e o "Lixo" são pastas temporárias criadas por cada teste.

/// O que os processos e as apps "estão a fazer", mutável entre a procura e o movimento.
private final class Situation: @unchecked Sendable {
    private let lock = NSLock()
    private var _usage: CleanupUsage? = CleanupUsage(openPaths: [], commands: [])
    private var _running = Set<String>()
    private var _trashed: [String] = []

    var usage: CleanupUsage? {
        get { lock.withLock { _usage } }
        set { lock.withLock { _usage = newValue } }
    }
    var running: Set<String> {
        get { lock.withLock { _running } }
        set { lock.withLock { _running = newValue } }
    }
    var trashed: [String] { lock.withLock { _trashed } }
    func didTrash(_ path: String) { lock.withLock { _trashed.append(path) } }
}

private struct FakeHome {
    let root: URL
    let home: URL
    let bin: URL
    let situation = Situation()

    init(name: String = "pessoa") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-\(UUID().uuidString)")
        home = root.appendingPathComponent(name)
        bin = root.appendingPathComponent("Lixo")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    }

    @discardableResult
    func add(_ relative: String) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url.appendingPathComponent("ficheiro"))
        return url
    }

    func addAll() throws {
        for target in CleanupRules.targets { try add(target.path) }
    }

    func real(_ relative: String) throws -> String {
        let resolved = try #require(realpath(home.appendingPathComponent(relative).path, nil))
        defer { free(resolved) }
        return String(cString: resolved)
    }

    @MainActor func store(bytes: UInt64 = 50_000_000, trashWorks: Bool = true) -> CleanupStore {
        var env = CleanupStore.Environment()
        let situation = situation, bin = bin
        env.home = home.path
        env.usage = { situation.usage }
        env.isRunning = { situation.running.contains($0) }
        env.measure = { _ in (bytes, true) }
        env.trash = { url in
            guard trashWorks else { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.moveItem(at: url, to: bin.appendingPathComponent(UUID().uuidString))
            situation.didTrash(url.path)
        }
        return CleanupStore(environment: env)
    }

    func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: home.appendingPathComponent(relative).path)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Suite struct CleanupRulesTests {
    private let target = CleanupTarget(path: "cache/x", name: "X", detail: "", recommended: true)

    private func usage(open: [String] = [], commands: [String] = []) -> CleanupUsage {
        CleanupUsage(openPaths: open, commands: commands)
    }

    @Test func theListIsClosed() {
        var expected: [String] = ["Library/Caches/Homebrew", "Library/Caches/pip", ".npm/_cacache"]
        expected.append("Library/Caches/BraveSoftware/Brave-Browser")
        expected.append("Library/Caches/ms-playwright")
        expected.append(".cache/huggingface/hub")
        expected.append(".npm/_npx")
        #expect(CleanupRules.targets.map(\.path) == expected)
        #expect(CleanupRules.targets.filter(\.recommended).map(\.name) == ["Homebrew", "pip", "npm"])
    }

    @Test func neverCoversHistoryCredentialsOrRuntimes() {
        var precious: [String] = [".claude/projects", ".codex/sessions", ".copilot/session-state", ".gemini"]
        precious.append(".cache/codex-runtimes")
        precious.append(".cache/huggingface/token")
        precious.append(".cache/huggingface/stored_tokens")
        precious.append("Library/Caches/com.spotify.client")
        precious.append("Library/Application Support/AgentStats")
        precious.append("Documents")
        precious.append(".Trash")
        for target in CleanupRules.targets {
            for path in precious {
                #expect(path != target.path)
                #expect(!path.hasPrefix(target.path + "/"))
                #expect(!target.path.hasPrefix(path + "/"))
            }
            #expect(!target.path.hasPrefix("/"))
            #expect(!target.path.contains(".."))
            #expect(target.path.contains("/"))
        }
    }

    @Test func noReliableReadingMeansNoTouching() {
        #expect(CleanupRules.block(target, path: "/h/cache/x", usage: nil, appRunning: false) == .unknown)
    }

    @Test func openFilesInsideBlockButNeighboursDoNot() {
        func block(_ open: String) -> CleanupBlock? {
            CleanupRules.block(target, path: "/h/cache/x", usage: usage(open: [open]), appRunning: false)
        }
        #expect(block("/h/cache/x") == .inUse)
        #expect(block("/h/cache/x/a/b") == .inUse)
        #expect(block("/H/Cache/X/a") == .inUse)
        #expect(block("/h/cache/x2/a") == nil)
        #expect(block("/h/cache") == nil)
    }

    @Test func aServerStartedFromTheFolderBlocksIt() {
        func block(_ command: String) -> CleanupBlock? {
            CleanupRules.block(target, path: "/h/cache/x", usage: usage(commands: [command]), appRunning: false)
        }
        #expect(block("node /h/cache/x/node_modules/.bin/server --stdio") == .inUse)
        #expect(block("node /h/cache/x2/server") == nil)
        #expect(block("/usr/bin/du -skxP /h/cache/x") == nil)
    }

    @Test func recognisesEachToolRunning() {
        #expect(CleanupRules.runs(.brew, command: "/bin/bash -p /opt/homebrew/bin/brew upgrade"))
        #expect(CleanupRules.runs(.brew, command: "ruby -W1 -- /opt/homebrew/Library/Homebrew/brew.rb install x"))
        #expect(!CleanupRules.runs(.brew, command: "/opt/homebrew/bin/node servidor.js"))
        #expect(CleanupRules.runs(.pip, command: "/usr/bin/python3 -m pip install x"))
        #expect(CleanupRules.runs(.pip, command: "python /v/bin/pip3.12 install x"))
        #expect(!CleanupRules.runs(.pip, command: "python pipeline.py"))
        #expect(CleanupRules.runs(.npm, command: "npm exec @x/mcp-server"))
        #expect(CleanupRules.runs(.npm, command: "node /opt/homebrew/bin/npx servidor"))
        #expect(!CleanupRules.runs(.npm, command: "node /p/server.js"))
    }

    /// Tal como o ps as mostrou num Mac a sério.
    @Test func recognisesRealCommandLines() {
        let brew = "/opt/homebrew/Library/Homebrew/vendor/portable-ruby/current/bin/ruby -W1 --disable=gems,rubyopt"
            + " /opt/homebrew/Library/Homebrew/brew.rb info --json=v2 --installed"
        let pip = "/Library/Frameworks/Python.framework/Versions/3.13/Resources/Python.app/Contents/MacOS/Python"
            + " /Library/Frameworks/Python.framework/Versions/3.13/bin/pip3 --disable-pip-version-check list"
        #expect(CleanupRules.runs(.brew, command: brew))
        #expect(CleanupRules.runs(.pip, command: pip))
        #expect(CleanupRules.runs(.npm, command: "/usr/bin/env node /opt/homebrew/bin/npm config list"))
        #expect(CleanupRules.runs(.npm, command: "node /opt/homebrew/bin/npm config list"))
        #expect(CleanupRules.runs(.npm, command: "node --no-warnings /x/bin/npx-cli.js servidor"))
    }

    @Test func namingAToolIsNotRunningIt() {
        #expect(!CleanupRules.runs(.brew, command: "/bin/zsh -c grep x /opt/homebrew/Library/Homebrew/brew.rb info"))
        #expect(!CleanupRules.runs(.brew, command: "vim notas.txt /opt/homebrew/Library/Homebrew/brew.rb"))
        #expect(!CleanupRules.runs(.brew, command: "/opt/homebrew/bin/node /opt/homebrew/bin/servidor mcp"))
    }

    @Test func parsesBothReadings() {
        let files = CleanupRules.openPaths(lsofOutput: "p10\nfcwd\nn/h/com espaço\nf4\nnlocalhost:80\np20\n")
        #expect(files.paths == ["/h/com espaço"])
        #expect(files.pids == [10, 20])
        let processes = CleanupRules.commands(psOutput: "    7 /bin/a --x\n 1234 node b.js\n")
        #expect(processes.commands == ["/bin/a --x", "node b.js"])
        #expect(processes.pids == [7, 1234])
    }
}

@MainActor @Suite struct CleanupStoreTests {
    @Test func scanningMovesNothingAndOnlyTicksTheSafeOnes() async throws {
        let mac = try FakeHome()
        defer { mac.remove() }
        try mac.addAll()
        let store = mac.store()
        await store.refresh()
        #expect(store.entries.count == 7)
        #expect(store.selected.map(\.target.name) == ["Homebrew", "pip", "npm"])
        #expect(mac.situation.trashed.isEmpty)
    }

    @Test func nothingMovesWithoutConfirmation() async throws {
        let mac = try FakeHome()
        defer { mac.remove() }
        try mac.addAll()
        let store = mac.store()
        await store.refresh()
        await store.moveToTrash()
        store.askToConfirm()
        store.cancel()
        await store.moveToTrash()
        #expect(mac.situation.trashed.isEmpty)
    }

    @Test func movesOnlyWhatWasConfirmed() async throws {
        let mac = try FakeHome()
        defer { mac.remove() }
        try mac.addAll()
        let token = mac.home.appendingPathComponent(".cache/huggingface/token")
        try Data("segredo".utf8).write(to: token)
        try mac.add(".claude/projects")
        let store = mac.store()
        await store.refresh()
        store.toggle(try #require(store.entries.first { $0.target.name == "Hugging Face" }))
        store.toggle(try #require(store.entries.first { $0.target.name == "pip" }))
        store.askToConfirm()
        await store.moveToTrash()

        #expect(mac.situation.trashed.count == 3)
        #expect(!mac.exists("Library/Caches/Homebrew"))
        #expect(!mac.exists(".npm/_cacache"))
        #expect(!mac.exists(".cache/huggingface/hub"))
        #expect(mac.exists(".cache/huggingface/token"))
        #expect(mac.exists(".claude/projects/ficheiro"))
        #expect(mac.exists("Library/Caches/pip"))
        #expect(mac.exists(".npm/_npx"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: mac.bin.path).count == 3)
        #expect(store.message?.contains("Lixo") == true)
    }

    @Test func changingTheSelectionCancelsTheConfirmation() async throws {
        let mac = try FakeHome()
        defer { mac.remove() }
        try mac.addAll()
        let store = mac.store()
        await store.refresh()
        store.askToConfirm()
        #expect(store.pending != nil)
        store.toggle(try #require(store.entries.first))
        #expect(store.pending == nil)
    }

    @Test func whatStartedBeingUsedAfterConfirmingStays() async throws {
        let mac = try FakeHome()
        defer { mac.remove() }
        try mac.add("Library/Caches/pip")
        let store = mac.store()
        await store.refresh()
        store.askToConfirm()
        mac.situation.usage = CleanupUsage(openPaths: [try mac.real("Library/Caches/pip") + "/ficheiro"], commands: [])
        await store.moveToTrash()
        #expect(mac.exists("Library/Caches/pip"))
        #expect(store.problems.count == 1)
    }

    @Test func aReadingThatFailsAtTheLastMomentMovesNothing() async throws {
        let mac = try FakeHome()
        defer { mac.remove() }
        try mac.addAll()
        let store = mac.store()
        await store.refresh()
        store.askToConfirm()
        mac.situation.usage = nil
        await store.moveToTrash()
        #expect(mac.situation.trashed.isEmpty)
        #expect(store.problems.count == 3)
    }

    @Test func anOpenAppKeepsItsCache() async throws {
        let mac = try FakeHome()
        defer { mac.remove() }
        try mac.add("Library/Caches/BraveSoftware/Brave-Browser")
        let store = mac.store()
        await store.refresh()
        store.toggle(try #require(store.entries.first))
        store.askToConfirm()
        mac.situation.running = ["com.brave.Browser"]
        await store.moveToTrash()
        #expect(mac.situation.trashed.isEmpty)

        await store.refresh()
        #expect(store.entries.first?.block == .app("Brave"))
        #expect(store.selected.isEmpty)
    }

    @Test func aReplacedFolderStays() async throws {
        let mac = try FakeHome()
        defer { mac.remove() }
        let folder = try mac.add("Library/Caches/pip")
        let store = mac.store()
        await store.refresh()
        store.askToConfirm()
        try FileManager.default.moveItem(at: folder, to: mac.root.appendingPathComponent("antiga"))
        try mac.add("Library/Caches/pip")
        await store.moveToTrash()
        #expect(mac.exists("Library/Caches/pip"))
        #expect(mac.situation.trashed.isEmpty)
    }

    @Test func linksAreNeverOffered() async throws {
        let mac = try FakeHome()
        defer { mac.remove() }
        let precious = try mac.add("Documents/importante")
        let caches = mac.home.appendingPathComponent("Library/Caches")
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: caches.appendingPathComponent("pip"), withDestinationURL: precious)
        let elsewhere = try mac.add("outra")
        try mac.add("outra/_cacache")
        try FileManager.default.createSymbolicLink(at: mac.home.appendingPathComponent(".npm"), withDestinationURL: elsewhere)
        let store = mac.store()
        await store.refresh()
        #expect(store.entries.isEmpty)
    }

    @Test func aLinkPutThereAfterConfirmingIsNotFollowed() async throws {
        let mac = try FakeHome()
        defer { mac.remove() }
        let folder = try mac.add("Library/Caches/pip")
        let precious = try mac.add("Documents/importante")
        let store = mac.store()
        await store.refresh()
        store.askToConfirm()
        try FileManager.default.moveItem(at: folder, to: mac.root.appendingPathComponent("antiga"))
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: precious)
        await store.moveToTrash()
        #expect(mac.situation.trashed.isEmpty)
        #expect(mac.exists("Documents/importante/ficheiro"))
    }

    @Test func aRefusalFromMacOSDeletesNothing() async throws {
        let mac = try FakeHome()
        defer { mac.remove() }
        try mac.addAll()
        let store = mac.store(trashWorks: false)
        await store.refresh()
        store.askToConfirm()
        await store.moveToTrash()
        for target in CleanupRules.targets { #expect(mac.exists(target.path)) }
        #expect(store.problems.count == 3)
    }

    @Test func almostEmptyCachesAreNotOffered() async throws {
        let mac = try FakeHome()
        defer { mac.remove() }
        try mac.addAll()
        let store = mac.store(bytes: 4096)
        await store.refresh()
        #expect(store.entries.isEmpty)
        #expect(store.loaded)
    }

    @Test func demoNeverMoves() async throws {
        let mac = try FakeHome()
        defer { mac.remove() }
        let store = mac.store()
        store.loadDemo()
        store.askToConfirm()
        await store.moveToTrash()
        #expect(mac.situation.trashed.isEmpty)
    }
}

/// Com o lsof e o ps verdadeiros, sobre pastas temporárias e processos criados pelo próprio teste.
@Suite(.serialized) struct CleanupUsageTests {
    private let target = CleanupTarget(path: "cache/x", name: "X", detail: "", recommended: true)

    /// Espera que a leitura dê o esperado, sem pausas fixas.
    private func waitForBlock(path: String) async throws -> CleanupBlock? {
        for _ in 0..<100 {
            let usage = try #require(await CleanupRules.readUsage())
            if let block = CleanupRules.block(target, path: path, usage: usage, appRunning: false) { return block }
            try await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    @Test func seesAnOpenFileEvenWithAccentsAndSpaces() async throws {
        let mac = try FakeHome(name: "João Sá")
        defer { mac.remove() }
        let folder = try mac.add("cache/x")
        let path = try mac.real("cache/x")
        let before = try #require(await CleanupRules.readUsage())
        #expect(CleanupRules.block(target, path: path, usage: before, appRunning: false) == nil)

        // O nome do ficheiro não vai nos argumentos: só o lsof o pode ver.
        let handle = try FileHandle(forReadingFrom: folder.appendingPathComponent("ficheiro"))
        defer { try? handle.close() }
        #expect(try await waitForBlock(path: path) == .inUse)
    }

    @Test func seesAProcessThatOnlyNamesTheFolderInItsArguments() async throws {
        let mac = try FakeHome(name: "João Sá")
        defer { mac.remove() }
        try mac.add("cache/x")
        let path = try mac.real("cache/x")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while :; do sleep 1; done", path + "/servidor.js"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { process.terminate() }
        #expect(try await waitForBlock(path: path) == .inUse)
    }

    @Test func seesAProcessWorkingInsideTheFolder() async throws {
        let mac = try FakeHome()
        defer { mac.remove() }
        let folder = try mac.add("cache/x")
        let path = try mac.real("cache/x")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        process.currentDirectoryURL = folder
        try process.run()
        defer { process.terminate() }
        #expect(try await waitForBlock(path: path) == .inUse)
    }
}
