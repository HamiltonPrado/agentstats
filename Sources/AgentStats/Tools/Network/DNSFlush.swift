import SwiftUI

/// Limpa a cache de DNS. Precisa de administrador: a password vai para o diálogo do macOS, nunca para a app.
enum DNSFlush {
    static let shellCommand = "/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder"
    static var script: String {
        "do shell script \"\(shellCommand)\" with administrator privileges with prompt \"O AgentStats quer limpar a cache de DNS.\""
    }

    enum Outcome: Equatable { case done, cancelled, failed }

    /// -128 é o "Cancelar" do diálogo.
    static func outcome(status: Int32, error: String) -> Outcome {
        if status == 0 { return .done }
        return error.contains("-128") ? .cancelled : .failed
    }
}

@MainActor
final class DNSFlushStore: ObservableObject {
    static let shared = DNSFlushStore()
    @Published private(set) var running = false
    @Published private(set) var message: String?
    @Published private(set) var lastDone: Date?
    private var demo = false

    func flush() async {
        guard !demo, !running else { return }
        running = true
        message = nil
        let r = await ToolRunner.run("/usr/bin/osascript", ["-e", DNSFlush.script], timeout: 180)
        switch DNSFlush.outcome(status: r.timedOut ? -1 : r.status, error: r.err) {
        case .done: lastDone = Date(); message = "Cache de DNS limpa."
        case .cancelled: message = nil
        case .failed: message = "Não consegui limpar a cache de DNS."
        }
        running = false
    }

    func loadDemo() { demo = true }
}

struct DNSFlushView: View {
    @ObservedObject var store: DNSFlushStore

    var body: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            HStack(spacing: DS.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cache de DNS").font(DS.body.weight(.medium))
                    Text("Quando um site não abre depois de mudar de rede ou de servidor").font(DS.meta).foregroundStyle(Color.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: DS.sm)
                if store.running {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Limpar…") { Task { await store.flush() } }.controlSize(.small)
                        .help("Pede a password de administrador no diálogo do macOS")
                }
            }
            if let m = store.message { note(m, color: .text2) }
        }
        .cardStyle()
    }
}
