import Darwin
import SwiftUI

/// Um processo numa altura concreta: o pid sozinho pode já ser de outro quando se confirma.
struct ProcessIdentity: Sendable, Equatable {
    let pid: Int32
    let uid: UInt32
    let started: UInt64
    let executable: String

    static func read(_ pid: Int32) -> ProcessIdentity? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return nil }
        return ProcessIdentity(pid: pid, uid: info.pbi_uid,
                               started: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec,
                               executable: MixerDiscovery.executable(pid))
    }
}

struct ListeningPort: Sendable, Hashable {
    let port: Int
    /// Só este Mac lhe chega (127.0.0.1 ou ::1).
    let local: Bool
}

struct Listener: Identifiable, Sendable, Equatable {
    var id: Int32 { pid }
    let pid: Int32
    var name: String
    var ports: [ListeningPort]
    var identity: ProcessIdentity?
}

enum PortRules {
    /// Saída de `lsof -F`: uma letra de campo por linha (p pid, c comando, n endereço).
    static func parse(_ output: String) -> [Listener] {
        var byPID: [Int32: Listener] = [:]
        var pid: Int32?
        for line in output.split(separator: "\n") {
            let value = line.dropFirst()
            switch line.first {
            case "p":
                pid = Int32(value)
                if let pid { byPID[pid] = byPID[pid] ?? Listener(pid: pid, name: "", ports: []) }
            case "c":
                if let pid { byPID[pid]?.name = value.replacingOccurrences(of: "\\x20", with: " ") }
            case "n":
                guard let pid, let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) else { continue }
                let host = String(value[..<colon])
                let local = host.hasPrefix("127.") || host == "[::1]" || host == "localhost" || host.hasPrefix("[::ffff:127.")
                var ports = byPID[pid]?.ports ?? []
                if let i = ports.firstIndex(where: { $0.port == port }) {
                    // Em IPv4 e IPv6: basta um estar aberto à rede para a porta estar.
                    ports[i] = ListeningPort(port: port, local: ports[i].local && local)
                } else {
                    ports.append(ListeningPort(port: port, local: local))
                }
                byPID[pid]?.ports = ports.sorted { $0.port < $1.port }
            default:
                continue
            }
        }
        return byPID.values.filter { !$0.ports.isEmpty }
            .sorted { ($0.ports[0].port, $0.pid) < ($1.ports[0].port, $1.pid) }
    }

    static func canTerminate(_ process: ProcessIdentity, uid: UInt32 = getuid(), ownPID: Int32 = getpid()) -> Bool {
        // Igual à app: terminar a AgentStats por aqui deixava gravações e taps por fechar.
        guard process.pid > 1, process.pid != ownPID, process.uid == uid, !process.executable.isEmpty else { return false }
        // Do macOS: o launchd voltava a abri-los, ou a sessão ia abaixo.
        return !["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/"].contains { process.executable.hasPrefix($0) }
    }
}

@MainActor
final class PortsStore: ObservableObject {
    static let shared = PortsStore()

    @Published private(set) var listeners: [Listener] = []
    @Published private(set) var loaded = false
    @Published private(set) var loading = false
    @Published private(set) var message: String?
    /// À espera de confirmação.
    @Published var confirming: Int32?
    /// Não fechou a bem: oferece-se forçar.
    @Published private(set) var stubborn = Set<Int32>()
    @Published private(set) var stopping = Set<Int32>()

    private let grace: Duration
    private var demo = false

    init(grace: Duration = .seconds(3)) {
        self.grace = grace
    }

    func refresh() async {
        guard !demo, !loading else { return }
        loading = true
        defer { loading = false }
        let result = await ToolRunner.run("/usr/sbin/lsof", ["-nP", "+c", "0", "-iTCP", "-sTCP:LISTEN", "-Fpcn"], timeout: 15)
        loaded = true
        // O lsof sai com 1 quando não encontra nada: não é erro.
        guard !result.timedOut, result.status == 0 || (result.status == 1 && result.err.isEmpty) else {
            message = "Não consegui ler as portas. \(result.summary)"
            return
        }
        listeners = PortRules.parse(result.out).map { listener in
            var listener = listener
            listener.identity = ProcessIdentity.read(listener.pid)
            return listener
        }
        stubborn.formIntersection(listeners.map(\.pid))
    }

    /// Sinaliza só se ainda for o mesmo processo que se mostrou: mesmo pid, início e programa.
    @discardableResult
    func terminate(_ listener: Listener, force: Bool = false) async -> Bool {
        confirming = nil
        guard !demo, let expected = listener.identity, PortRules.canTerminate(expected) else { return false }
        guard ProcessIdentity.read(listener.pid) == expected else {
            message = "\(listener.name) já não é o mesmo processo. Não terminei nada."
            stubborn.remove(listener.pid)
            await refresh()
            return false
        }
        guard kill(listener.pid, force ? SIGKILL : SIGTERM) == 0 else {
            message = "O macOS não deixou terminar \(listener.name)."
            return false
        }
        message = nil
        stopping.insert(listener.pid)
        try? await Task.sleep(for: grace)
        stopping.remove(listener.pid)
        let gone = ProcessIdentity.read(listener.pid) != expected
        if gone {
            stubborn.remove(listener.pid)
            message = "\(listener.name) terminou."
        } else {
            stubborn.insert(listener.pid)
            message = "\(listener.name) não fechou a bem. Podes forçar, mas perde o que não gravou."
        }
        await refresh()
        return gone
    }

    func loadDemo() {
        demo = true
        loaded = true
        let me = getuid()
        listeners = [
            Listener(pid: 4100, name: "node", ports: [ListeningPort(port: 3000, local: true)],
                     identity: ProcessIdentity(pid: 4100, uid: me, started: 1, executable: "/opt/homebrew/bin/node")),
            Listener(pid: 4200, name: "python3", ports: [ListeningPort(port: 8000, local: false)],
                     identity: ProcessIdentity(pid: 4200, uid: me, started: 1, executable: "/opt/homebrew/bin/python3")),
            Listener(pid: 600, name: "ControlCenter", ports: [ListeningPort(port: 5000, local: false), ListeningPort(port: 7000, local: false)],
                     identity: ProcessIdentity(pid: 600, uid: me, started: 1, executable: "/System/Library/CoreServices/ControlCenter")),
        ]
    }
}
