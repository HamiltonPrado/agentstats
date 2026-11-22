import SwiftUI
import AppKit

struct CaptureView: View {
    @ObservedObject var store: CaptureStore
    @AppStorage("capture.copy") private var copyAfter = true
    @AppStorage("capture.microphone") private var microphone = false
    @AppStorage("capture.clicks") private var clicks = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.md) {
            if store.needsPermission { permissionCard }
            screenshotCard
            recordingCard
            if let error = store.error {
                Text(error).font(DS.meta).foregroundStyle(Color.waitingText).fixedSize(horizontal: false, vertical: true)
            }
            if let last = store.last { lastCard(last) }
        }
    }

    private func closePanel() { AppState.controller?.closePanel() }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            Text("Falta a permissão").font(DS.body.weight(.medium))
            note("Autoriza o AgentStats em Privacidade e Segurança → Gravação de ecrã e áudio do sistema (a lista de cima; a do mixer é outra). Depois fecha e volta a abrir o AgentStats.")
            Button("Abrir Definições do Sistema") {
                open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            }
            .controlSize(.small)
        }
        .cardStyle()
    }

    private var screenshotCard: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            Text("Captura").font(DS.body.weight(.medium))
            HStack(spacing: DS.sm) {
                ForEach(ShotKind.allCases, id: \.self) { kind in
                    action(kind.title, kind.symbol) { store.screenshot(kind, copy: copyAfter, willCapture: closePanel) }
                        .disabled(store.phase != .idle)
                }
            }
            option("Copiar também para o clipboard", $copyAfter)
            note("Guarda em Imagens → AgentStats. Esc cancela.")
        }
        .cardStyle()
    }

    private var recordingCard: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            Text("Gravação").font(DS.body.weight(.medium))
            if store.isRecording {
                action("Parar e guardar", "stop.circle.fill", tint: Palette.attention) { store.stop() }
                    .disabled(store.phase == .stopping)
            } else {
                HStack(spacing: DS.sm) {
                    action("Ecrã inteiro", "record.circle", tint: Palette.attention) {
                        store.record(microphone: microphone, clicks: clicks, willRecord: closePanel)
                    }
                    action("Área…", "rectangle.dashed") {
                        // Gravar uma área fica com a ferramenta do macOS, que tem a seleção e o botão de parar.
                        closePanel()
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app"))
                    }
                }
                .disabled(store.phase != .idle)
                option("Gravar o microfone", $microphone)
                option("Mostrar os cliques", $clicks)
            }
            note("O ecrã inteiro guarda em Filmes → AgentStats; para parar, clica no AgentStats na barra de menus. A área abre a ferramenta do macOS, que guarda onde estiver configurada.")
        }
        .cardStyle()
    }

    private func lastCard(_ file: URL) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Última").font(DS.meta).foregroundStyle(Color.text2)
                Text(file.lastPathComponent).font(DS.body).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: DS.sm)
            IconButton(systemName: "eye", help: "Abrir") { NSWorkspace.shared.open(file) }
            if file.pathExtension == "png" {
                IconButton(systemName: "doc.on.doc", help: "Copiar") { store.copyLast() }
            }
            IconButton(systemName: "folder", help: "Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
        }
        .cardStyle()
    }

    // MARK: Peças

    private func action(_ title: String, _ symbol: String, tint: Color = .primary, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            VStack(spacing: DS.xs) {
                Image(systemName: symbol)
                    .font(.system(size: 16 * TextSize.current.scale, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(height: 20)
                Text(title).font(DS.meta).lineLimit(1)
            }
            .frame(maxWidth: .infinity).frame(height: 56)
            .background(RoundedRectangle(cornerRadius: DS.rControl, style: .continuous).fill(DS.raised))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func option(_ title: String, _ value: Binding<Bool>) -> some View {
        HStack(spacing: DS.sm) {
            Text(title).font(DS.body)
            Spacer(minLength: DS.sm)
            Toggle(title, isOn: value).toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
    }

    private func open(_ address: String) {
        if let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }
}
