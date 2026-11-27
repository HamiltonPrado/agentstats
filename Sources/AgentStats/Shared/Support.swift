import AppKit
import os

/// Registo de diagnóstico (ver na app Consola, subsistema "local.agentstats").
enum Log {
    static let readers = Logger(subsystem: "local.agentstats", category: "readers")
}

/// Nome e ícone de apps por PID. `NSRunningApplication` é uma consulta ao sistema: fazê-la em cada
/// redesenho de cada linha da lista de processos é desperdício, por isso fica em cache.
@MainActor
enum AppInfo {
    struct Entry { let name: String?; let icon: NSImage?; var seen = Date() }
    /// Cada entrada vale um minuto: um PID reutilizado por outra app não fica com o nome da anterior.
    private static var cache: [Int: Entry] = [:]
    private static let maxAge: TimeInterval = 60
    private static var demo: [Int: Entry]?

    static func loadDemo(_ entries: [Int: Entry]) { demo = entries }

    static func lookup(_ pid: Int) -> Entry {
        // Os PIDs inventados podem existir neste Mac: nunca se perguntam ao sistema.
        if let demo { return demo[pid] ?? Entry(name: nil, icon: nil) }
        if let e = cache[pid], Date().timeIntervalSince(e.seen) < maxAge { return e }
        if cache.count > 300 { cache.removeAll(keepingCapacity: true) }   // PIDs antigos não ficam para sempre
        let app = NSRunningApplication(processIdentifier: pid_t(pid))
        let e = Entry(name: app?.localizedName, icon: app?.icon)
        cache[pid] = e
        return e
    }
}

/// Termina um processo depois de pedir confirmação (ação destrutiva).
@MainActor
enum ProcessKiller {
    static func confirmAndTerminate(pid: Int, name: String, force: Bool = false) {
        // O processo tal como estava quando se pediu: o diálogo pode ficar aberto muito tempo, e o PID ser reutilizado.
        guard let expected = ProcessIdentity.read(pid_t(pid)) else { return }
        guard PortRules.canTerminate(expected) else {
            inform(L("Este processo é do macOS, de outro utilizador ou da própria AgentStats: não o termino daqui."))
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L(force ? String(localized: "Forçar a terminação de \(name)?") : String(localized: "Terminar \(name)?"))
        alert.informativeText = force
            ? String(localized: "O processo (PID \(pid)) é terminado de imediato. O trabalho que não estiver guardado perde-se.")
            : String(localized: "É pedido ao processo (PID \(pid)) que termine. O trabalho que não estiver guardado pode perder-se.")
        alert.addButton(withTitle: L(force ? "Forçar" : "Terminar"))
        alert.addButton(withTitle: L("Cancelar"))
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard ProcessIdentity.read(pid_t(pid)) == expected else {
            inform(L("O processo já tinha terminado. Não mexi em nada."))
            return
        }
        if kill(pid_t(pid), force ? SIGKILL : SIGTERM) != 0 {
            Log.readers.error("kill(\(pid), force: \(force)) falhou: errno \(errno)")
        }
    }

    private static func inform(_ text: String) {
        let alert = NSAlert()
        alert.messageText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
