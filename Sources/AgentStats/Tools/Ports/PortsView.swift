import SwiftUI
import AppKit

struct PortsView: View {
    @ObservedObject var store: PortsStore

    var body: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            HStack(spacing: DS.sm) {
                Text("À escuta").font(DS.body.weight(.medium))
                Spacer(minLength: DS.sm)
                IconButton(systemName: "arrow.clockwise", help: "Atualizar") { Task { await store.refresh() } }
                    .disabled(store.loading)
            }
            if !store.loaded {
                note("A ler as portas…")
            } else if store.listeners.isEmpty {
                note("Nenhum processo teu está à escuta.")
            }
            ForEach(store.listeners) { listener in row(listener) }
            if let message = store.message { note(message, color: .text2) }
            note("Só portas TCP dos teus processos. “Rede” quer dizer que outros aparelhos lhe podem chegar.")
        }
        .cardStyle()
        .task { await store.refresh() }
    }

    @ViewBuilder private func row(_ listener: Listener) -> some View {
        VStack(alignment: .leading, spacing: DS.xs) {
            HStack(spacing: DS.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(listener.name).font(DS.body).lineLimit(1).truncationMode(.middle)
                    Text(detail(listener)).font(DS.meta.monospacedDigit()).foregroundStyle(Color.text3).lineLimit(2)
                }
                Spacer(minLength: DS.sm)
                if store.stopping.contains(listener.pid) {
                    Text("A fechar…").font(DS.meta).foregroundStyle(Color.text2)
                } else if let identity = listener.identity, PortRules.canTerminate(identity) {
                    let force = store.stubborn.contains(listener.pid)
                    textLink(force ? "Forçar" : "Terminar", color: force ? .attentionText : .text2) {
                        store.confirming = listener.pid
                    }
                } else {
                    Text("macOS").font(DS.meta).foregroundStyle(Color.text3).help("É do sistema: não se termina por aqui")
                }
            }
            if store.confirming == listener.pid {
                let force = store.stubborn.contains(listener.pid)
                ConfirmBar(text: "\(force ? "Forçar o fim de" : "Terminar") \(listener.name) (PID \(String(listener.pid)))? O que não tiver gravado pode perder-se.",
                           confirm: force ? "Forçar" : "Terminar",
                           cancel: { store.confirming = nil },
                           action: { Task { await store.terminate(listener, force: force) } })
            }
        }
        .padding(.vertical, DS.xs)
    }

    private func detail(_ listener: Listener) -> String {
        let shown = listener.ports.prefix(4).map { ":\($0.port)" }.joined(separator: " ")
        let more = listener.ports.count > 4 ? " +\(listener.ports.count - 4)" : ""
        let scope = listener.ports.allSatisfy(\.local) ? "só este Mac" : "rede"
        return "\(shown)\(more) · \(scope)"
    }
}
