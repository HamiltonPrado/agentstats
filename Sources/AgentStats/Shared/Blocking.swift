import Darwin
import Foundation

/// Trabalho que bloqueia (processos, discos, Acessibilidade) corre numa thread do GCD e não no pool do Swift:
/// esse pool só tem tantas threads como núcleos, e algumas esperas longas ao mesmo tempo paravam a app toda.
enum Blocking {
    static func run<T: Sendable>(qos: DispatchQoS.QoSClass = .userInitiated, _ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { c in
            DispatchQueue.global(qos: qos).async { c.resume(returning: work()) }
        }
    }
}

/// Os descendentes de um processo, para um tempo limite parar também o que ele lançou
/// (um `zsh -lc` das regras, os filhos do `brew`, os netos do `claude`).
enum ProcessTree {
    static func children(of pid: pid_t) -> [pid_t] {
        let size = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(pid), nil, 0)
        guard size > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(size) / MemoryLayout<pid_t>.size + 16)
        let got = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(pid), $0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return [] }
        return Array(pids.prefix(Int(got) / MemoryLayout<pid_t>.size)).filter { $0 > 0 && $0 != pid }
    }

    /// Os netos primeiro, para nenhum ficar órfão a meio.
    static func descendants(of pid: pid_t, depth: Int = 0) -> [pid_t] {
        guard depth < 8 else { return [] }
        return children(of: pid).flatMap { descendants(of: $0, depth: depth + 1) + [$0] }
    }

    static func signal(_ pid: pid_t, _ sig: Int32) {
        for d in descendants(of: pid) { kill(d, sig) }
        kill(pid, sig)
    }
}

/// Corre um processo com pipes e um tempo limite, sem nunca ficar preso: a leitura não espera pelo fim do pipe
/// (que um neto vivo podia manter aberto para sempre), só pelo fim do processo.
enum ProcessRun {
    struct Result: Sendable {
        var status: Int32
        var out: Data
        var err: Data
        var timedOut: Bool
    }

    /// Um leitor por pipe, na ordem em que os dados chegam. Lê até ao fim do pipe ou, depois de `stop`,
    /// até não haver mais nada para ler: um neto que mantenha o pipe aberto já não prende ninguém.
    private final class Reader: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var stopped = false
        let finished = DispatchSemaphore(value: 0)

        init(_ fd: Int32) {
            DispatchQueue.global(qos: .utility).async { self.loop(fd) }
        }

        func stop() { lock.lock(); stopped = true; lock.unlock() }
        var value: Data { lock.lock(); defer { lock.unlock() }; return data }

        private func loop(_ fd: Int32) {
            var chunk = [UInt8](repeating: 0, count: 65_536)
            while true {
                var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&p, 1, 100)
                if ready > 0 {
                    let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                    if n <= 0 { break }
                    lock.lock(); data.append(contentsOf: chunk.prefix(n)); lock.unlock()
                } else if ready < 0 && errno != EINTR {
                    break
                } else {
                    lock.lock(); let stop = stopped; lock.unlock()
                    if stop { break }
                }
            }
            finished.signal()
        }
    }

    /// Bloqueia até ao fim do processo ou ao tempo limite: chamar fora do main thread (por `Blocking.run`).
    /// `afterLaunch` corre com o processo já lançado (para escrever no stdin).
    static func sync(_ process: Process, timeout: TimeInterval, afterLaunch: (() -> Void)? = nil) -> Result? {
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        if process.standardInput == nil { process.standardInput = FileHandle.nullDevice }
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        let readers = [Reader(out.fileHandleForReading.fileDescriptor), Reader(err.fileHandleForReading.fileDescriptor)]
        afterLaunch?()
        var timedOut = false
        if done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            ProcessTree.signal(process.processIdentifier, SIGTERM)
            if done.wait(timeout: .now() + 3) == .timedOut {
                ProcessTree.signal(process.processIdentifier, SIGKILL)
                _ = done.wait(timeout: .now() + 2)
            }
        }
        for r in readers { r.stop(); r.finished.wait() }
        try? out.fileHandleForReading.close()
        try? err.fileHandleForReading.close()
        return Result(status: process.isRunning ? -1 : process.terminationStatus,
                      out: readers[0].value, err: readers[1].value, timedOut: timedOut)
    }
}

extension Timer {
    /// Como `scheduledTimer`, mas também dispara com um menu aberto ou um slider a ser arrastado
    /// (o modo `.default` para nesses momentos: a contagem na barra de menus congelava).
    @discardableResult
    static func common(withTimeInterval interval: TimeInterval, repeats: Bool,
                       block: @escaping @Sendable (Timer) -> Void) -> Timer {
        let t = Timer(timeInterval: interval, repeats: repeats, block: block)
        RunLoop.main.add(t, forMode: .common)
        return t
    }
}
