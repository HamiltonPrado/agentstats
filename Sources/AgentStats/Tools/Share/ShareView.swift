import AppKit
import SwiftUI

@MainActor
final class ShareStore: ObservableObject {
    static let shared = ShareStore()

    enum State: Equatable {
        case idle
        case serving(url: URL, name: String, until: Date)
        case done(String)
    }

    @Published private(set) var state: State = .idle
    // Wi-Fi: fica aqui e não na vista, porque o painel fecha quando o diálogo do macOS aparece.
    // Só em memória, e esquecida ao fim de 10 minutos.
    @Published var wifiSSID = ""
    @Published var wifiPassword = "" { didSet { scheduleForget() } }
    @Published var wifiSecurity = WiFiQR.Security.wpa
    @Published private(set) var wifiFetching = false
    @Published private(set) var wifiNote: String?
    private var forget: Task<Void, Never>?
    private var server: FileDropServer?
    private var demo = false
    var isDemo: Bool { demo }

    func send(_ file: URL) async {
        guard !demo else { return }
        stop()
        guard let host = FileDrop.localAddress() else {
            state = .done(L("Não estás ligado a nenhuma rede local. Liga o Mac ao mesmo Wi-Fi do telemóvel."))
            return
        }
        let server = FileDropServer(file: file) { end in
            Task { @MainActor in ShareStore.shared.ended(end) }
        }
        self.server = server
        guard let port = await server.start(), let url = FileDrop.url(host: host, port: port, token: server.token, fileName: file.lastPathComponent) else {
            self.server = nil
            state = .done(L("Não consegui partilhar o ficheiro na rede local."))
            return
        }
        state = .serving(url: url, name: file.lastPathComponent, until: Date().addingTimeInterval(FileDrop.lifetime))
    }

    func pick() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await send(url)
    }

    func stop() {
        server?.stop()
        server = nil
        if case .serving = state { state = .idle }
    }

    private func ended(_ end: FileDropServer.End) {
        server = nil
        switch end {
        case .delivered: state = .done(L("Enviado. O link já não funciona."))
        case .expired: state = .done(L("Passaram 10 minutos: o link expirou."))
        case .stopped: state = .idle
        case .failed: state = .done(L("O envio falhou. Tenta outra vez."))
        }
    }

    private func scheduleForget() {
        forget?.cancel()
        guard !wifiPassword.isEmpty else { return }
        forget = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10 * 60))
            guard !Task.isCancelled else { return }
            self?.wifiPassword = ""
        }
    }

    func forgetWiFiPassword() { wifiPassword = "" }

    /// Lê do porta-chaves a password que o Mac já tem para esta rede. Depois reabre o painel no QR,
    /// porque o diálogo do macOS fecha-o.
    func fetchWiFiPassword() async {
        wifiFetching = true
        wifiNote = nil
        switch await WiFiPassword.fetch(ssid: wifiSSID) {
        case .found(let p):
            wifiPassword = p
            wifiSecurity = .wpa
            UserDefaults.standard.set(ToolSection.share.rawValue, forKey: "tools.section")
            AppState.controller?.reveal(.tools)
        case .notSaved: wifiNote = String(localized: "O Mac não tem guardada a password de “\(wifiSSID)”. Confirma o nome da rede.")
        case .cancelled: break
        case .failed: wifiNote = L("Não consegui ler a password guardada.")
        }
        wifiFetching = false
    }

    func loadDemo(now: Date) {
        demo = true
        wifiSSID = "Casa"
        state = .serving(url: URL(string: "http://192.168.1.20:52114/3f9a1c7e2b4d6a8f0e1c3b5d7f9a2c4e/apresentação.pdf")!,
                         name: "apresentação.pdf", until: now.addingTimeInterval(8 * 60 + 12))
    }
}

struct ShareView: View {
    @ObservedObject var store: ShareStore
    @StateObject private var targeted = Box(false)
    @ObservedObject private var location = LocationAccess.shared

    var body: some View {
        VStack(alignment: .leading, spacing: DS.md) {
            fileCard
            wifiCard
        }
    }

    // MARK: Ficheiro

    private var fileCard: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            Text("Enviar para o telemóvel").font(DS.body.weight(.medium))
            switch store.state {
            case .serving(let url, let name, let until):
                serving(url: url, name: name, until: until)
            case .idle, .done:
                if case .done(let m) = store.state { note(m, color: .text2) }
                dropZone
            }
            note("O telemóvel tem de estar no mesmo Wi-Fi. O link tem um código secreto, serve uma vez e expira em 10 minutos.")
        }
        .cardStyle()
    }

    private var dropZone: some View {
        Button { Task { await store.pick() } } label: {
            VStack(spacing: DS.xs) {
                Image(systemName: "iphone.and.arrow.forward").font(.system(size: 20 * TextSize.current.scale))
                Text("Larga aqui um ficheiro, ou clica para escolher").font(DS.meta)
            }
            .foregroundStyle(targeted.value ? Color.accentColor : Color.text2)
            .frame(maxWidth: .infinity).frame(height: 76)
            .background(RoundedRectangle(cornerRadius: DS.rControl, style: .continuous)
                .strokeBorder(targeted.value ? Color.accentColor : Color.text3.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dropDestination(for: URL.self) { urls, _ in
            guard let file = urls.first(where: { !$0.hasDirectoryPath }) else { return false }
            Task { await store.send(file) }
            return true
        } isTargeted: { targeted.value = $0 }
    }

    private func serving(url: URL, name: String, until: Date) -> some View {
        HStack(alignment: .top, spacing: DS.md) {
            if let qr = QRMaker.image(url.absoluteString) {
                Image(decorative: qr, scale: 1).interpolation(.none).resizable()
                    .frame(width: 132, height: 132).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: DS.sm) {
                Text(L(name)).font(DS.body).lineLimit(2).truncationMode(.middle)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(String(localized: "Expira em \(TimerPlan.clock(until.timeIntervalSince(context.date)))"))
                        .font(DS.meta.monospacedDigit()).foregroundStyle(Color.text2)
                }
                note("Aponta a câmara do telemóvel ao código.", color: .text2)
                Button("Parar") { store.stop() }.controlSize(.small)
            }
        }
    }

    // MARK: Wi-Fi

    private var wifiCard: some View {
        let payload = WiFiQR.payload(ssid: store.wifiSSID, password: store.wifiPassword, security: store.wifiSecurity)
        return VStack(alignment: .leading, spacing: DS.sm) {
            Text("Partilhar o Wi-Fi").font(DS.body.weight(.medium))
            TextField("Nome da rede", text: $store.wifiSSID).textFieldStyle(.roundedBorder).font(DS.body)
            if store.wifiSSID.isEmpty && !location.allowed && !store.isDemo {
                // Sem Localização, o macOS não diz o nome da rede atual.
                textLink("Usar a rede atual (pede acesso à Localização)", color: .accentColor) {
                    location.undecided ? location.request() : location.openSettings()
                }
            }
            Picker("Segurança", selection: $store.wifiSecurity) {
                ForEach(WiFiQR.Security.allCases) { Text(L($0.title)).tag($0) }
            }
            .labelsHidden()
            if store.wifiSecurity != .open {
                SecureField("Password da rede", text: $store.wifiPassword).textFieldStyle(.roundedBorder).font(DS.body)
                HStack(spacing: DS.sm) {
                    if store.wifiFetching { ProgressView().controlSize(.small) }
                    Button("Usar a password guardada no Mac") { Task { await store.fetchWiFiPassword() } }
                        .controlSize(.small)
                        .disabled(store.wifiFetching || store.wifiSSID.trimmingCharacters(in: .whitespaces).isEmpty)
                        .help("O macOS pede a tua password de administrador ou o Touch ID, no diálogo dele")
                    Spacer()
                }
                if let n = store.wifiNote { note(n, color: .text2) }
                if !store.wifiPassword.isEmpty {
                    HStack { Spacer(); textLink("Esquecer a password") { store.forgetWiFiPassword() } }
                }
            }
            if let payload, let qr = QRMaker.image(payload) {
                HStack {
                    Spacer()
                    Image(decorative: qr, scale: 1).interpolation(.none).resizable()
                        .frame(width: 150, height: 150).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 6))
                    Spacer()
                }
            }
            note("Os convidados apontam a câmara e entram, sem escrever a password. A password fica só em memória e é esquecida ao fim de 10 minutos.")
        }
        .cardStyle()
        .onAppear {
            // Nas capturas (README e site), nunca o nome da rede real.
            if store.wifiSSID.isEmpty { store.wifiSSID = store.isDemo ? "Casa" : (WiFiReader.read()?.ssid ?? "") }
        }
        .onChange(of: location.status) { _, _ in
            if store.wifiSSID.isEmpty, !store.isDemo { store.wifiSSID = WiFiReader.read()?.ssid ?? "" }
        }

    }
}
