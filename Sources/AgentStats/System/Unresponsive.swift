import AppKit
import ApplicationServices
import SwiftUI
import UserNotifications

/// Apps que deixaram de responder. Sem API pública para isto, pergunta-se o papel da app pela Acessibilidade
/// com 1 s de limite: duas falhas seguidas (a 10 s de distância) contam como bloqueada.
enum UnresponsiveRules {
    static let strikes = 2

    /// Junta o resultado desta volta ao das anteriores. Devolve as contagens novas e os pids bloqueados.
    static func update(strikes old: [pid_t: Int], failed: Set<pid_t>, alive: Set<pid_t>) -> (strikes: [pid_t: Int], stuck: Set<pid_t>) {
        var new: [pid_t: Int] = [:]
        for pid in failed where alive.contains(pid) { new[pid] = (old[pid] ?? 0) + 1 }
        return (new, Set(new.filter { $0.value >= strikes }.keys))
    }
}

@MainActor
final class UnresponsiveStore: ObservableObject {
    static let shared = UnresponsiveStore()

    struct StuckApp: Identifiable, Equatable {
        var id: pid_t { pid }
        let pid: pid_t
        let name: String
    }

    @Published private(set) var stuck: [StuckApp] = []
    @Published var confirming: pid_t?
    private var strikes: [pid_t: Int] = [:]
    private var notified = Set<pid_t>()
    private var timer: Timer?
    private var checking = false
    private var demo = false
    private let queue = DispatchQueue(label: "agentstats.unresponsive")

    func start() {
        guard !demo else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in MainActor.assumeIsolated { UnresponsiveStore.shared.check() } }
    }

    private func check() {
        guard !checking, AXIsProcessTrusted() else { return }
        checking = true
        let me = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != me && !$0.isTerminated }
        let pids = apps.map(\.processIdentifier)
        let names = Dictionary(apps.map { ($0.processIdentifier, $0.localizedName ?? "?") }, uniquingKeysWith: { a, _ in a })
        queue.async {
            var failed = Set<pid_t>()
            for pid in pids {
                let el = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(el, 1.0)
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &value) == .cannotComplete { failed.insert(pid) }
            }
            Task { @MainActor in UnresponsiveStore.shared.apply(failed: failed, alive: Set(pids), names: names) }
        }
    }

    private func apply(failed: Set<pid_t>, alive: Set<pid_t>, names: [pid_t: String]) {
        checking = false
        let r = UnresponsiveRules.update(strikes: strikes, failed: failed, alive: alive)
        strikes = r.strikes
        stuck = r.stuck.sorted().map { StuckApp(pid: $0, name: names[$0] ?? "?") }
        notified.formIntersection(r.stuck)
        for app in stuck where !notified.contains(app.pid) {
            notified.insert(app.pid)
            let c = UNMutableNotificationContent()
            c.title = String(localized: "\(app.name) não responde")
            c.body = L("Abre o AgentStats para forçar a saída, ou espera um pouco.")
            Notify.add(UNNotificationRequest(identifier: "stuck-\(app.pid)", content: c, trigger: nil))
        }
    }

    func forceQuit(_ app: StuckApp) {
        confirming = nil
        NSRunningApplication(processIdentifier: app.pid)?.forceTerminate()
        stuck.removeAll { $0.pid == app.pid }
    }

    func loadDemo() { demo = true }
}

struct UnresponsiveBanner: View {
    @ObservedObject var store: UnresponsiveStore

    var body: some View {
        VStack(alignment: .leading, spacing: DS.xs) {
            ForEach(store.stuck) { app in
                HStack(spacing: DS.sm) {
                    Image(systemName: "hourglass").font(DS.body).foregroundStyle(Color.attentionText).frame(width: 16)
                    Text(String(localized: "\(app.name) não responde")).font(DS.body.weight(.medium)).lineLimit(1)
                    Spacer(minLength: DS.xs)
                    textLink("Forçar saída…", color: .attentionText) { store.confirming = app.pid }
                }
                if store.confirming == app.pid {
                    ConfirmBar(text: String(localized: "Forçar a saída de \(app.name)? O que não estiver gravado perde-se."), confirm: "Forçar saída",
                               cancel: { store.confirming = nil }, action: { store.forceQuit(app) })
                }
            }
        }
    }
}
