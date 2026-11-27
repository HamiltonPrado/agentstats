import Foundation
import Testing
@testable import AgentStats

// Nada aqui capta o ecrã, pede permissões ou toca no clipboard: o screencapture é um script falso.

@MainActor private final class Sandbox {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cap-\(UUID().uuidString)")
    var copied: [URL] = []
    var requests = 0
    var closed = 0

    /// `body` é o script; `$out` é o último argumento, onde o screencapture escreveria.
    func store(_ body: String, access: Bool = true) throws -> CaptureStore {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let tool = root.appendingPathComponent("fake-screencapture")
        try "#!/bin/sh\nfor out; do :; done\n\(body)\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        var env = CaptureStore.Environment()
        env.tool = tool
        env.screenshots = root.appendingPathComponent("imagens")
        env.recordings = root.appendingPathComponent("filmes")
        env.hasAccess = { access }
        env.requestAccess = { [unowned self] in self.requests += 1 }
        env.delay = .zero
        env.copyImage = { [unowned self] url in
            self.copied.append(url)
            return true
        }
        env.defaults = nil
        env.stopGrace = 1.5
        return CaptureStore(environment: env)
    }

    /// O script cria este ficheiro quando já tem o trap posto: um sinal antes disso matava-o.
    var ready: Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path) }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

/// Espera sem bloquear o main actor, que recebe o fim do processo.
@MainActor private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}

@MainActor @Suite(.serialized) struct CaptureStoreTests {
    @Test func screenshotIsSavedAndCopiedWhenAsked() async throws {
        let box = Sandbox()
        defer { box.remove() }
        let s = try box.store(#"printf png > "$out""#)
        await s.screenshot(.area, copy: true, willCapture: { box.closed += 1 })?.value
        let file = try #require(s.last)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(box.copied == [file])
        #expect(box.closed == 1)
        #expect(s.phase == .idle && s.error == nil)
    }

    @Test func notCopiedUnlessAsked() async throws {
        let box = Sandbox()
        defer { box.remove() }
        let s = try box.store(#"printf png > "$out""#)
        await s.screenshot(.screen, copy: false)?.value
        #expect(s.last != nil)
        #expect(box.copied.isEmpty)
    }

    @Test func escapeIsNotAnError() async throws {
        let box = Sandbox()
        defer { box.remove() }
        let s = try box.store("exit 1")
        await s.screenshot(.window, copy: true)?.value
        #expect(s.last == nil && s.error == nil && box.copied.isEmpty)
        #expect(s.phase == .idle)
    }

    @Test func failedFullScreenShotIsAnError() async throws {
        let box = Sandbox()
        defer { box.remove() }
        let s = try box.store("exit 1")
        await s.screenshot(.screen, copy: false)?.value
        #expect(s.error != nil)
    }

    @Test func withoutPermissionNothingRunsAndThePanelStays() async throws {
        let box = Sandbox()
        defer { box.remove() }
        let s = try box.store(#"printf png > "$out""#, access: false)
        #expect(s.screenshot(.area, copy: false, willCapture: { box.closed += 1 }) == nil)
        #expect(s.record(microphone: false, clicks: false, willRecord: { box.closed += 1 }) == nil)
        #expect(s.needsPermission && box.requests == 2 && box.closed == 0)
        #expect(!FileManager.default.fileExists(atPath: box.root.appendingPathComponent("imagens").path))
    }

    @Test func recordingStopsWithInterruptAndKeepsTheVideo() async throws {
        let box = Sandbox()
        defer { box.remove() }
        let s = try box.store("""
        trap 'printf mov > "$out"; exit 0' INT
        touch "${0%/*}/ready"
        while :; do sleep 0.05; done
        """)
        await s.record(microphone: false, clicks: false)?.value
        #expect(s.isRecording)
        #expect(s.menuBarText?.hasPrefix("0:0") == true)
        #expect(s.record(microphone: false, clicks: false) == nil)   // nunca duas ao mesmo tempo
        try #require(await eventually { box.ready })
        s.stop()
        #expect(await eventually { s.phase == .idle })
        #expect(s.last?.pathExtension == "mov")
        #expect(s.error == nil && s.menuBarText == nil)
    }

    @Test func ifInterruptIsIgnoredAKeyStopsIt() async throws {
        let box = Sandbox()
        defer { box.remove() }
        let s = try box.store("""
        trap '' INT
        touch "${0%/*}/ready"
        read -n 1 key
        [ "$key" = q ] && printf mov > "$out"
        """)
        await s.record(microphone: false, clicks: false)?.value
        try #require(await eventually { box.ready })
        s.stop()
        #expect(await eventually { s.phase == .idle })
        #expect(s.last != nil && s.error == nil)
    }

    @Test func recordingThatFailsIsReportedAndDoesNotStayRecording() async throws {
        let box = Sandbox()
        defer { box.remove() }
        let s = try box.store("exit 1")
        await s.record(microphone: false, clicks: false)?.value
        #expect(await eventually { s.phase == .idle })
        #expect(s.last == nil && s.error != nil)
    }

    @Test func quittingWaitsForTheVideoToClose() async throws {
        let box = Sandbox()
        defer { box.remove() }
        let s = try box.store("""
        trap 'sleep 0.3; printf mov > "$out"; exit 0' INT
        touch "${0%/*}/ready"
        while :; do sleep 0.05; done
        """)
        await s.record(microphone: false, clicks: false)?.value
        try #require(await eventually { box.ready })
        s.shutdown()   // tem de só voltar com o ficheiro escrito
        let files = try FileManager.default.contentsOfDirectory(atPath: box.root.appendingPathComponent("filmes").path)
        #expect(files.count == 1)
    }

    @Test func quittingBeforeItStartsNeverRecords() async throws {
        let box = Sandbox()
        defer { box.remove() }
        let s = try box.store(#"printf mov > "$out""#)
        let task = s.record(microphone: false, clicks: false)
        s.shutdown()
        await task?.value
        #expect(s.phase == .idle)
        #expect(!FileManager.default.fileExists(atPath: box.root.appendingPathComponent("filmes").path))
    }
}

@Suite struct CaptureCommandTests {
    private let file = URL(fileURLWithPath: "/tmp/x.png")

    @Test func screenshotArguments() {
        #expect(CaptureCommand.screenshot(.area, display: 2, file: file) == ["-i", "-s", "/tmp/x.png"])
        #expect(CaptureCommand.screenshot(.window, display: 2, file: file) == ["-i", "-w", "/tmp/x.png"])
        #expect(CaptureCommand.screenshot(.screen, display: 2, file: file) == ["-D2", "/tmp/x.png"])
    }

    @Test func microphoneOnlyWhenAsked() {
        let plain = CaptureCommand.recording(display: 1, microphone: false, clicks: false, file: file)
        #expect(plain == ["-v", "-D1", "/tmp/x.png"])
        let full = CaptureCommand.recording(display: 1, microphone: true, clicks: true, file: file)
        #expect(full == ["-v", "-D1", "-g", "-k", "/tmp/x.png"])
    }

    @Test func namesNeverOverwrite() {
        let dir = URL(fileURLWithPath: "/tmp/d")
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let first = CaptureCommand.file(prefix: "Captura", ext: "png", in: dir, date: date, exists: { _ in false })
        let second = CaptureCommand.file(prefix: "Captura", ext: "png", in: dir, date: date, exists: { $0 == first })
        #expect(first != second)
        #expect(second.lastPathComponent.hasSuffix("(2).png"))
    }

    @Test func clock() {
        #expect(Fmt.clock(7) == "0:07")
        #expect(Fmt.clock(750) == "12:30")
        #expect(Fmt.clock(3723) == "1:02:03")
    }

    @Test func onlyOurOwnOrphanIsStopped() {
        let tool = CaptureCommand.tool.path
        let ours = "/Users/me/Movies/AgentStats/Gravação.mov"
        let args = "\(tool) -v -D1 \(ours)"
        #expect(CaptureCommand.isOrphan(executable: tool, parent: 1, arguments: args, file: ours))
        #expect(!CaptureCommand.isOrphan(executable: tool, parent: 500, arguments: args, file: ours))
        #expect(!CaptureCommand.isOrphan(executable: "/bin/sleep", parent: 1, arguments: args, file: ours))
        #expect(!CaptureCommand.isOrphan(executable: tool, parent: 1, arguments: "\(tool) -v outro.mov", file: ours))
        #expect(!CaptureCommand.isOrphan(executable: tool, parent: 1, arguments: args, file: ""))
    }

    /// A deteção de órfãs depende de ler o caminho, com acentos, dos argumentos de outro processo.
    @Test func accentedPathIsReadBackFromAnotherProcess() async throws {
        let path = "/tmp/Gravação 2026-01-01 às 10.00.00.mov"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 2; :", path]
        try p.run()
        defer { p.terminate() }
        try await Task.sleep(for: .milliseconds(300))
        let arguments = try #require(ProcessReader.arguments(of: Int(p.processIdentifier)))
        #expect(arguments.contains(path))
    }
}
