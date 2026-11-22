import AppKit
import Darwin
import SwiftUI

/// Capturas e gravações com o `screencapture` do macOS. Vive fora da vista, porque o painel fecha-se
/// antes de cada captura. Só capta por clique.
@MainActor
final class CaptureStore: ObservableObject {
    enum Phase: Equatable {
        case idle
        case capturing
        case recording(since: Date)
        case stopping
    }

    /// O que muda fora dos testes: o programa, a permissão e as pastas.
    struct Environment {
        var tool = CaptureCommand.tool
        var screenshots = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/AgentStats")
        var recordings = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/AgentStats")
        var hasAccess: () -> Bool = { CGPreflightScreenCaptureAccess() }
        var requestAccess: () -> Void = { _ = CGRequestScreenCaptureAccess() }
        /// Tempo para o painel desaparecer do ecrã antes de captar.
        var delay: Duration = .milliseconds(400)
        var copyImage: (URL) -> Bool = CaptureStore.copyToPasteboard
        var defaults: UserDefaults? = .standard
        /// Quanto esperar por cada forma de parar antes de passar à seguinte.
        var stopGrace: TimeInterval = 4
    }

    private enum Key {
        static let pid = "capture.recording.pid"
        static let file = "capture.recording.file"
    }

    static let shared = CaptureStore(environment: Environment())

    @Published private(set) var phase: Phase = .idle {
        didSet { onChange?() }
    }
    @Published private(set) var needsPermission = false
    @Published private(set) var error: String?
    @Published private(set) var last: URL?

    /// A barra de menus redesenha-se com isto (mudança de fase e cada segundo a gravar).
    var onChange: (() -> Void)?

    private let environment: Environment
    private var process: Process?
    private var input: Pipe?
    private var clock: Timer?
    private var cancelled = false

    init(environment: Environment) {
        self.environment = environment
    }

    var isRecording: Bool {
        switch phase {
        case .recording, .stopping: true
        case .idle, .capturing: false
        }
    }

    /// O texto da barra de menus enquanto grava.
    var menuBarText: String? {
        switch phase {
        case .recording(let since): CaptureCommand.clock(Int(Date().timeIntervalSince(since)))
        case .stopping: "A guardar…"
        case .idle, .capturing: nil
        }
    }

    // MARK: Permissão

    private func authorized() -> Bool {
        if environment.hasAccess() {
            needsPermission = false
            return true
        }
        needsPermission = true
        environment.requestAccess()
        return false
    }

    // MARK: Captura

    /// `willCapture` fecha o painel; só é chamado se houver mesmo captura.
    @discardableResult
    func screenshot(_ kind: ShotKind, copy: Bool, willCapture: @escaping () -> Void = {}) -> Task<Void, Never>? {
        guard phase == .idle, authorized() else { return nil }
        let display = Self.displayUnderPointer()
        error = nil
        phase = .capturing
        willCapture()
        return Task {
            try? await Task.sleep(for: environment.delay)
            do {
                let file = try newFile(prefix: "Captura", ext: "png", in: environment.screenshots)
                let status = try await run(CaptureCommand.screenshot(kind, display: display, file: file))
                if FileManager.default.fileExists(atPath: file.path) {
                    last = file
                    if copy && !environment.copyImage(file) { error = "Guardei a captura, mas não consegui copiá-la." }
                } else if kind == .screen {
                    error = "O macOS não devolveu a captura (código \(status))."
                }
                // Área e janela sem ficheiro: foi o Esc, não é um erro.
            } catch {
                self.error = "Não consegui captar: \(error.localizedDescription)"
            }
            phase = .idle
        }
    }

    private func run(_ arguments: [String]) async throws -> Int32 {
        let p = Process()
        p.executableURL = environment.tool
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        return try await withCheckedThrowingContinuation { (done: CheckedContinuation<Int32, Error>) in
            p.terminationHandler = { @Sendable finished in done.resume(returning: finished.terminationStatus) }
            do {
                try p.run()
            } catch {
                p.terminationHandler = nil
                done.resume(throwing: error)
            }
        }
    }

    // MARK: Gravação

    @discardableResult
    func record(microphone: Bool, clicks: Bool, willRecord: @escaping () -> Void = {}) -> Task<Void, Never>? {
        guard phase == .idle, authorized() else { return nil }
        let display = Self.displayUnderPointer()
        error = nil
        cancelled = false
        phase = .capturing
        willRecord()
        return Task {
            try? await Task.sleep(for: environment.delay)
            guard !cancelled else {
                phase = .idle
                return
            }
            do {
                let file = try newFile(prefix: "Gravação", ext: "mov", in: environment.recordings)
                try launch(CaptureCommand.recording(display: display, microphone: microphone, clicks: clicks, file: file), file: file)
            } catch {
                self.error = "Não consegui gravar: \(error.localizedDescription)"
                phase = .idle
            }
        }
    }

    private func launch(_ arguments: [String], file: URL) throws {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = environment.tool
        p.arguments = arguments
        // Fica aberto: o screencapture trata a entrada como "para de gravar", e um fim de ficheiro também conta.
        p.standardInput = pipe
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { @Sendable [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor [weak self] in self?.recordingEnded(file: file, status: status) }
        }
        try p.run()
        process = p
        input = pipe
        environment.defaults?.set(Int(p.processIdentifier), forKey: Key.pid)
        environment.defaults?.set(file.path, forKey: Key.file)
        phase = .recording(since: Date())

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onChange?() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    /// Ctrl-C, que deixa o macOS fechar o vídeo. Se não chegar, uma tecla na entrada, e só no fim SIGTERM.
    func stop() {
        guard case .recording = phase, let running = process else { return }
        phase = .stopping
        running.interrupt()
        Task {
            try? await Task.sleep(for: .seconds(environment.stopGrace))
            guard process === running, running.isRunning else { return }
            pressKey()
            try? await Task.sleep(for: .seconds(environment.stopGrace))
            guard process === running, running.isRunning else { return }
            running.terminate()
            error = "A gravação não parou a bem; o vídeo pode ter ficado incompleto."
        }
    }

    private func pressKey() {
        guard let handle = input?.fileHandleForWriting, fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else { return }
        try? handle.write(contentsOf: Data("q".utf8))
        try? handle.close()
    }

    private func recordingEnded(file: URL, status: Int32) {
        clock?.invalidate()
        clock = nil
        process = nil
        input = nil
        forgetSavedRecording()
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        if size > 0 {
            last = file
        } else if error == nil {
            error = "A gravação terminou sem vídeo (código \(status))."
        }
        phase = .idle
    }

    /// Ao sair da app espera até o vídeo estar fechado: nunca deixa uma gravação a correr sozinha.
    func shutdown() {
        cancelled = true
        guard let p = process, p.isRunning else { return }
        p.interrupt()
        if !Self.wait(for: p, seconds: environment.stopGrace) {
            pressKey()
            if !Self.wait(for: p, seconds: environment.stopGrace) {
                p.terminate()
                return
            }
        }
        forgetSavedRecording()
    }

    private static func wait(for process: Process, seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning, Date() < deadline { usleep(50_000) }
        return !process.isRunning
    }

    /// No arranque: para uma gravação que tenha ficado de uma AgentStats que morreu a gravar.
    func stopOrphan() {
        guard let defaults = environment.defaults else { return }
        let pid = pid_t(exactly: defaults.integer(forKey: Key.pid)) ?? 0
        let file = defaults.string(forKey: Key.file) ?? ""
        guard pid > 1 else { return }
        var info = proc_bsdinfo()
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0,
           CaptureCommand.isOrphan(executable: MixerDiscovery.executable(pid), parent: Int32(info.pbi_ppid),
                                   arguments: ProcessReader.arguments(of: Int(pid)), file: file) {
            kill(pid, SIGINT)
            error = "Parei uma gravação que tinha ficado a correr."
            last = URL(fileURLWithPath: file)
        }
        forgetSavedRecording()
    }

    private func forgetSavedRecording() {
        environment.defaults?.removeObject(forKey: Key.pid)
        environment.defaults?.removeObject(forKey: Key.file)
    }

    // MARK: Auxiliares

    private func newFile(prefix: String, ext: String, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return CaptureCommand.file(prefix: prefix, ext: ext, in: directory, date: Date())
    }

    /// O ecrã onde está o rato, contado como o `screencapture` conta (1 é o principal).
    private static func displayUnderPointer() -> Int {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }),
              let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return 1 }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success,
              let index = ids.prefix(Int(count)).firstIndex(of: id) else { return 1 }
        return index + 1
    }

    nonisolated static func copyToPasteboard(_ file: URL) -> Bool {
        guard let data = try? Data(contentsOf: file) else { return false }
        let board = NSPasteboard.general
        board.clearContents()
        return board.setData(data, forType: .png)
    }

    func copyLast() {
        guard let last, !environment.copyImage(last) else { return }
        error = "Não consegui copiar a captura."
    }

    /// Para as capturas do README: sem os ficheiros reais.
    func loadDemo() {
        needsPermission = false
        error = nil
        last = URL(fileURLWithPath: "/Users/Shared/Captura 2026-01-01 às 10.00.00.png")
    }
}
