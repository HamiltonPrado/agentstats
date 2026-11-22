import Foundation

struct ToolOutput: Sendable {
    var status: Int32
    var out: String
    var err: String
    var timedOut = false
    var ok: Bool { status == 0 && !timedOut }
    /// O fim do que o comando disse, para mostrar no painel.
    var summary: String {
        let lines = (out + "\n" + err).split(separator: "\n").map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return lines.suffix(12).joined(separator: "\n")
    }
}

/// Corre um comando sem terminal. A saída vai para ficheiros privados e não para pipes: com dois pipes,
/// um que enchesse bloqueava o comando, e um neto que ficasse vivo prendia a leitura para sempre.
enum ToolRunner {
    static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
                    timeout: TimeInterval) async -> ToolOutput {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("agentstats-tool-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            return ToolOutput(status: -1, out: "", err: error.localizedDescription)
        }
        defer { try? fm.removeItem(at: dir) }

        let outURL = dir.appendingPathComponent("out"), errURL = dir.appendingPathComponent("err")
        fm.createFile(atPath: outURL.path, contents: nil)
        fm.createFile(atPath: errURL.path, contents: nil)
        guard let out = try? FileHandle(forWritingTo: outURL), let err = try? FileHandle(forWritingTo: errURL) else {
            return ToolOutput(status: -1, out: "", err: "Não consegui criar os ficheiros temporários.")
        }
        defer {
            try? out.close()
            try? err.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.currentDirectoryURL = fm.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return ToolOutput(status: -1, out: "", err: error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning {
            if !timedOut, Date() >= deadline {
                timedOut = true
                process.terminate()
            } else if timedOut, Date() >= deadline.addingTimeInterval(5) {
                kill(process.processIdentifier, SIGKILL)
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return ToolOutput(status: process.terminationStatus, out: read(outURL), err: read(errURL), timedOut: timedOut)
    }

    private static func read(_ url: URL) -> String {
        String(decoding: (try? Data(contentsOf: url)) ?? Data(), as: UTF8.self)
    }
}
