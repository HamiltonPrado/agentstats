import Darwin
import Foundation
import Testing
@testable import AgentStats

// Nada real é tocado: os processos terminados são criados pelo próprio teste, o brew é um script falso
// e o "Lixo" é uma pasta temporária.

private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("tools-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - Portas

@Suite struct PortRulesTests {
    @Test func parsesLsofFields() {
        let found = PortRules.parse("""
        p300
        cGoogle\\x20Chrome
        f4
        n127.0.0.1:9222
        p100
        cnode
        f9
        n127.0.0.1:3000
        f10
        n*:3000
        f11
        n[::1]:24678
        p200
        csem-portas
        """)
        #expect(found.map(\.name) == ["node", "Google Chrome"])
        #expect(found.first?.ports == [ListeningPort(port: 3000, local: false), ListeningPort(port: 24678, local: true)])
        #expect(found.last?.ports == [ListeningPort(port: 9222, local: true)])
    }

    @Test func onlyYourOwnOrdinaryProcesses() {
        func process(_ pid: Int32, uid: UInt32 = 501, path: String = "/opt/homebrew/bin/node") -> ProcessIdentity {
            ProcessIdentity(pid: pid, uid: uid, started: 1, executable: path)
        }
        func allowed(_ p: ProcessIdentity) -> Bool { PortRules.canTerminate(p, uid: 501, ownPID: 999) }
        #expect(allowed(process(4000)))
        #expect(!allowed(process(4000, uid: 0)))
        #expect(!allowed(process(4000, uid: 502)))
        #expect(!allowed(process(1)))
        #expect(!allowed(process(999)))
        #expect(!allowed(process(4000, path: "")))
        #expect(!allowed(process(4000, path: "/System/Library/CoreServices/ControlCenter")))
        #expect(!allowed(process(4000, path: "/usr/libexec/rapportd")))
    }
}

@MainActor @Suite(.serialized) struct PortsStoreTests {
    private func child(_ script: String) async throws -> (Process, Listener) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Espera que o script esteja mesmo a correr: antes disso o trap não está posto, e o /bin/sh
        // ainda troca de executável para o bash, o que mudava a identidade do processo.
        let ready = FileManager.default.temporaryDirectory.appendingPathComponent("ready-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: ready) }
        p.arguments = ["-c", script.replacingOccurrences(of: "while :", with: "touch \"$0\"; while :"), ready.path]
        try p.run()
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: ready.path) {
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(FileManager.default.fileExists(atPath: ready.path))
        let identity = try #require(ProcessIdentity.read(p.processIdentifier))
        return (p, Listener(pid: p.processIdentifier, name: "filho-do-teste", ports: [], identity: identity))
    }

    @Test func terminatesTheConfirmedProcess() async throws {
        let (p, listener) = try await child("while :; do sleep 0.05; done")
        defer { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        let store = PortsStore(grace: .milliseconds(600))
        #expect(await store.terminate(listener))
        #expect(!p.isRunning)
    }

    @Test func aReusedPidIsNeverSignalled() async throws {
        let (p, listener) = try await child("while :; do sleep 0.05; done")
        defer { kill(p.processIdentifier, SIGKILL) }
        var stale = listener
        let real = try #require(listener.identity)
        // O mesmo pid, mas de um processo que arrancou noutra altura.
        stale.identity = ProcessIdentity(pid: real.pid, uid: real.uid, started: real.started - 1, executable: real.executable)
        let store = PortsStore(grace: .milliseconds(300))
        #expect(await !store.terminate(stale))
        #expect(p.isRunning)
        #expect(await !store.terminate(stale, force: true))
        #expect(p.isRunning)
    }

    @Test func forcingIsASecondStep() async throws {
        let (p, listener) = try await child("trap '' TERM; while :; do sleep 0.05; done")
        defer { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        let store = PortsStore(grace: .milliseconds(700))
        #expect(await !store.terminate(listener))
        #expect(p.isRunning)
        #expect(await store.terminate(listener, force: true))
        #expect(!p.isRunning)
    }
}

// MARK: - Homebrew

@Suite struct BrewRulesTests {
    @Test func parsesFormulaeAndCasks() throws {
        let json = Data("""
        {"formulae":[
          {"name":"zlib","full_name":"zlib","installed":[{"version":"1.3","installed_on_request":false}],"versions":{"stable":"1.3"},"outdated":false,"pinned":false},
          {"name":"tool","full_name":"me/tap/tool","installed":[{"version":"1.0","installed_on_request":true}],"versions":{"stable":"2.0"},"outdated":true,"pinned":false},
          {"name":"mau","full_name":"--force","installed":[{"version":"1"}]}],
         "casks":[{"token":"editor","full_token":"editor","name":["Editor"],"installed":"1","version":"1","outdated":false}]}
        """.utf8)
        let found = try #require(BrewRules.packages(json: json))
        #expect(found.map(\.token) == ["me/tap/tool", "editor", "zlib"])
        #expect(found[0].outdated && found[0].requested)
        #expect(found[1].kind == .cask)
        #expect(!found[2].requested)
        #expect(BrewRules.packages(json: Data("Error".utf8)) == nil)
    }

    @Test(arguments: ["--force", "-f", "../../etc", "a b", "a;rm", "", "nome\n"])
    func dangerousNamesAreRefused(token: String) {
        #expect(!BrewRules.validToken(token))
    }

    @Test(arguments: ["node@22", "gcc", "me/tap/tool", "libc++", "python-tk@3.13"])
    func realNamesAreAccepted(token: String) {
        #expect(BrewRules.validToken(token))
    }

    @Test func removingNeverEscalates() {
        let package = BrewPackage(kind: .cask, token: "editor", name: "Editor", installed: "1", latest: "1",
                                  outdated: false, pinned: false, requested: true)
        #expect(BrewRules.arguments(.uninstall(package)) == ["uninstall", "--cask", "editor"])
        #expect(BrewRules.arguments(.upgrade(package)) == ["upgrade", "--cask", "editor"])
        let env = BrewRules.environment(base: ["HOME": "/Users/me"], brew: "/opt/homebrew/bin/brew")
        #expect(env["HOMEBREW_NO_AUTOREMOVE"] == "1")
        #expect(env["HOMEBREW_NO_INSTALL_CLEANUP"] == "1")
        #expect(env["HOMEBREW_NO_AUTO_UPDATE"] == "1")
        #expect(env["SUDO_ASKPASS"] == "/usr/bin/false")
        #expect(env["HOME"] == "/Users/me")
    }
}

@MainActor @Suite struct BrewStoreTests {
    private let package = BrewPackage(kind: .formula, token: "tool", name: "tool", installed: "1", latest: "1",
                                      outdated: false, pinned: false, requested: true)

    private func fakeBrew(in dir: URL, uninstall: String) throws -> String {
        let url = dir.appendingPathComponent("brew")
        try """
        #!/bin/sh
        echo "$*|$HOMEBREW_NO_AUTOREMOVE|$SUDO_ASKPASS" >> "\(dir.path)/log"
        case "$1" in
          info) echo '{"formulae":[],"casks":[]}' ;;
          uninstall) \(uninstall) ;;
        esac
        """.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    @Test func runsExactlyWhatWasConfirmed() async throws {
        let dir = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BrewStore(brew: try fakeBrew(in: dir, uninstall: "echo removido"))
        await store.perform(.uninstall(package))
        let log = try String(contentsOf: dir.appendingPathComponent("log"), encoding: .utf8)
        #expect(log.split(separator: "\n").map(String.init) == [
            "uninstall --formula tool|1|/usr/bin/false",
            "info --json=v2 --installed|1|/usr/bin/false",
        ])
        #expect(store.message == "Feito." && store.output == "removido")
    }

    @Test func refusalShowsWhatBrewSaid() async throws {
        let dir = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BrewStore(brew: try fakeBrew(in: dir, uninstall: "echo 'required by other' >&2; exit 1"))
        await store.perform(.uninstall(package))
        #expect(store.message != "Feito.")
        #expect(store.output?.contains("required by other") == true)
        #expect(store.running == nil)
    }
}

@Suite struct ToolRunnerTests {
    @Test func bigOutputOnBothStreamsDoesNotBlock() async {
        let script = "i=0; while [ $i -lt 5000 ]; do echo linha-de-saida-$i; echo linha-de-erro-$i >&2; i=$((i+1)); done"
        let result = await ToolRunner.run("/bin/sh", ["-c", script], timeout: 20)
        #expect(result.ok)
        #expect(result.out.split(separator: "\n").count == 5000)
        #expect(result.err.split(separator: "\n").count == 5000)
    }

    @Test func timeoutStopsTheCommand() async {
        let start = Date()
        let result = await ToolRunner.run("/bin/sleep", ["30"], timeout: 0.4)
        #expect(result.timedOut && !result.ok)
        #expect(Date().timeIntervalSince(start) < 10)
    }

    /// Um neto que fica com o stdout aberto já não prende a leitura (era o que podia parar os limites do Claude).
    @Test func grandchildHoldingThePipeDoesNotBlock() async {
        let start = Date()
        let r = await Blocking.run { () -> ProcessRun.Result? in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "sleep 20 & echo ola"]
            return ProcessRun.sync(p, timeout: 10)
        }
        #expect(String(decoding: r?.out ?? Data(), as: UTF8.self) == "ola\n")
        #expect(r?.timedOut == false)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    /// No fim do prazo param o comando e os filhos dele.
    @Test func timeoutStopsTheWholeTree() async throws {
        let marker = "agentstats-tree-\(UUID().uuidString.prefix(8))"
        let r = await Blocking.run { () -> ProcessRun.Result? in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "sh -c 'sleep 40; echo \(marker)' & wait"]
            return ProcessRun.sync(p, timeout: 0.5)
        }
        #expect(r?.timedOut == true)
        let left = await ToolRunner.run("/bin/ps", ["-axo", "command"], timeout: 5)
        #expect(!left.out.contains(marker))
    }

    /// Fechar o painel cancela a tarefa: o comando acaba logo, sem o ciclo girar sem pausa.
    @Test func cancellingStopsTheCommand() async {
        let start = Date()
        let task = Task { await ToolRunner.run("/bin/sleep", ["30"], timeout: 60) }
        try? await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let result = await task.value
        #expect(result.timedOut && !result.ok)
        #expect(Date().timeIntervalSince(start) < 10)
    }
}

// MARK: - Desinstalar

@MainActor private final class FakeMac {
    let root: URL
    var home: URL { root.appendingPathComponent("home") }
    var appsFolder: URL { root.appendingPathComponent("Applications") }
    var trashed: [String] = []
    var failing = Set<String>()
    var running = false
    var otherCopies: [String] = []

    init() throws {
        root = try temporaryFolder()
        try FileManager.default.createDirectory(at: appsFolder, withIntermediateDirectories: true)
    }

    @discardableResult
    func addApp(_ name: String, id: String) throws -> String {
        let contents = appsFolder.appendingPathComponent("\(name).app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return appsFolder.appendingPathComponent("\(name).app").path
    }

    @discardableResult
    func addFolder(_ relative: String) throws -> String {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    func store() -> UninstallStore {
        var env = UninstallStore.Environment()
        env.home = home.path
        env.roots = [appsFolder.path]
        env.isRunning = { [unowned self] _ in self.running }
        env.knownCopies = { [unowned self] _ in self.otherCopies }
        env.trash = { [unowned self] url in
            if self.failing.contains(url.path) { throw CocoaError(.fileWriteNoPermission) }
            let bin = self.root.appendingPathComponent("lixo/\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: bin.appendingPathComponent(url.lastPathComponent))
            self.trashed.append(url.path)
        }
        return UninstallStore(environment: env)
    }

    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

@MainActor @Suite struct UninstallTests {
    private let id = "com.example.editor"

    private func chosen(_ mac: FakeMac) async throws -> UninstallStore {
        let store = mac.store()
        await store.refresh()
        store.choose(try #require(store.apps.first { $0.name == "Editor" }))
        return store
    }

    @Test func onlyExactIdentifierMatchesAreOffered() async throws {
        let mac = try FakeMac()
        defer { mac.remove() }
        try mac.addApp("Editor", id: id)
        let cache = try mac.addFolder("Library/Caches/\(id)")
        try mac.addFolder("Library/Caches/\(id)2")
        try mac.addFolder("Library/Caches/Editor")
        try mac.addFolder("Library/Application Support/Editor")
        try mac.addFolder("Library/Group Containers/\(id)")
        let store = try await chosen(mac)
        #expect(store.plan?.leftovers.map(\.path) == [cache])
        #expect(store.selected.isEmpty)
    }

    @Test func onlyTickedLeftoversGoToTheTrash() async throws {
        let mac = try FakeMac()
        defer { mac.remove() }
        let app = try mac.addApp("Editor", id: id)
        let cache = try mac.addFolder("Library/Caches/\(id)")
        let documents = try mac.addFolder("Library/Containers/\(id)")
        let store = try await chosen(mac)
        store.selected = [cache, mac.home.path]   // um caminho fora do plano é ignorado
        store.moveToTrash()
        #expect(mac.trashed == [app, cache])
        #expect(mac.exists(documents) && mac.exists(mac.home.path))
        #expect(store.plan == nil && store.apps.isEmpty)
    }

    @Test func ifTheAppStaysItsDataStays() async throws {
        let mac = try FakeMac()
        defer { mac.remove() }
        let app = try mac.addApp("Editor", id: id)
        let cache = try mac.addFolder("Library/Caches/\(id)")
        mac.failing = [app]
        let store = try await chosen(mac)
        store.selected = [cache]
        store.moveToTrash()
        #expect(mac.trashed.isEmpty && mac.exists(cache))
    }

    @Test func runningAppIsNotRemoved() async throws {
        let mac = try FakeMac()
        defer { mac.remove() }
        let app = try mac.addApp("Editor", id: id)
        mac.running = true
        let store = try await chosen(mac)
        store.moveToTrash()
        #expect(mac.trashed.isEmpty && mac.exists(app))
    }

    @Test func replacedAppIsNotRemoved() async throws {
        let mac = try FakeMac()
        defer { mac.remove() }
        let app = try mac.addApp("Editor", id: id)
        let store = try await chosen(mac)
        try FileManager.default.moveItem(atPath: app, toPath: app + ".antiga")
        try mac.addApp("Editor", id: id)
        store.moveToTrash()
        #expect(mac.trashed.isEmpty && mac.exists(app))
    }

    @Test func replacedLeftoverIsLeftAlone() async throws {
        let mac = try FakeMac()
        defer { mac.remove() }
        let app = try mac.addApp("Editor", id: id)
        let cache = try mac.addFolder("Library/Caches/\(id)")
        let store = try await chosen(mac)
        store.selected = [cache]
        try FileManager.default.moveItem(atPath: cache, toPath: cache + ".antiga")
        try mac.addFolder("Library/Caches/\(id)")
        store.moveToTrash()
        #expect(mac.trashed == [app] && mac.exists(cache))
    }

    @Test func aSecondCopyKeepsTheData() async throws {
        let mac = try FakeMac()
        defer { mac.remove() }
        try mac.addApp("Editor", id: id)
        try mac.addApp("Editor Beta", id: id)
        try mac.addFolder("Library/Caches/\(id)")
        let store = try await chosen(mac)
        #expect(store.plan?.sharedWithCopy == true)
        #expect(store.plan?.leftovers.isEmpty == true)
    }

    @Test func aCopyOutsideApplicationsAlsoKeepsTheData() async throws {
        let mac = try FakeMac()
        defer { mac.remove() }
        try mac.addApp("Editor", id: id)
        try mac.addFolder("Library/Caches/\(id)")
        mac.otherCopies = ["/Volumes/Outro/Editor.app"]
        let store = try await chosen(mac)
        #expect(store.plan?.leftovers.isEmpty == true)
    }

    @Test func symbolicLinksAreNeverOffered() async throws {
        let mac = try FakeMac()
        defer { mac.remove() }
        try mac.addApp("Editor", id: id)
        let documents = try mac.addFolder("Documents")
        try mac.addFolder("Library/Caches")
        try FileManager.default.createSymbolicLink(atPath: "\(mac.home.path)/Library/Caches/\(id)", withDestinationPath: documents)
        let store = try await chosen(mac)
        #expect(store.plan?.leftovers.isEmpty == true)
    }

    @Test func appleAndAgentStatsAreNotListed() async throws {
        let mac = try FakeMac()
        defer { mac.remove() }
        try mac.addApp("Safari", id: "com.apple.Safari")
        try mac.addApp("AgentStats", id: "local.agentstats")
        try mac.addApp("Editor", id: id)
        let store = mac.store()
        await store.refresh()
        #expect(store.apps.map(\.name) == ["Editor"])
    }

    @Test(arguments: ["../../Documents", "com.example/../..", "..", ".", "", "com", "com.example.app\n", "com..app", "*.app"])
    func hostileIdentifiersGiveNoPaths(hostile: String) {
        #expect(UninstallRules.candidates(bundleID: hostile, home: "/Users/me").isEmpty)
        #expect(!UninstallRules.removable(bundleID: hostile))
    }
}
