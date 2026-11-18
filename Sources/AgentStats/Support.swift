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
    struct Entry { let name: String?; let icon: NSImage? }
    private static var cache: [Int: Entry] = [:]

    static func lookup(_ pid: Int) -> Entry {
        if let e = cache[pid] { return e }
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
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = force ? "Forçar a terminação de \(name)?" : "Terminar \(name)?"
        alert.informativeText = force
            ? "O processo (PID \(pid)) é terminado de imediato. O trabalho que não estiver guardado perde-se."
            : "É pedido ao processo (PID \(pid)) que termine. O trabalho que não estiver guardado pode perder-se."
        alert.addButton(withTitle: force ? "Forçar" : "Terminar")
        alert.addButton(withTitle: "Cancelar")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if kill(pid_t(pid), force ? SIGKILL : SIGTERM) != 0 {
            Log.readers.error("kill(\(pid), force: \(force)) falhou: errno \(errno)")
        }
    }
}
