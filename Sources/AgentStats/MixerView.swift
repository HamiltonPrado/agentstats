import SwiftUI
import AppKit

struct MixerRow: Identifiable, Equatable {
    let id: String
    let name: String
    let appPath: String?
    var level: Double
    var muted: Bool
    var status: MixerStatus
    var adjusted: Bool { muted || level != 1 }
}

/// O que a interface vê do mixer. É único e vive enquanto a app corre: mudar de separador ou fechar o
/// painel não pode parar o som que está a ser ajustado.
/// Os ajustes não ficam guardados: ao reabrir o AgentStats tudo começa a 100% e sem captar nada.
@MainActor
final class AppMixer: ObservableObject {
    static let shared = AppMixer()

    @Published private(set) var rows: [MixerRow] = []
    let supported: Bool

    private var snapshot = MixerSnapshot()
    private var levels: [String: Double] = [:]
    private var muted = Set<String>()
    private var known: [String: MixerSource] = [:]
    /// O motor só existe no macOS 14.2+, e uma propriedade guardada não pode ter `@available`.
    private var engineStorage: AnyObject?
    private var demo = false

    private init() {
        if #available(macOS 14.2, *) {
            supported = true
            engineStorage = MixerEngine { [weak self] snapshot in
                Task { @MainActor [weak self] in self?.apply(snapshot) }
            }
        } else {
            supported = false
        }
    }

    func refresh() {
        guard !demo else { return }
        if #available(macOS 14.2, *) { (engineStorage as? MixerEngine)?.refresh() }
    }

    func setLevel(_ id: String, _ value: Double) {
        let snapped = MixerMath.snapped(value)
        levels[id] = snapped == 1 ? nil : Double(snapped)
        muted.remove(id)
        send(id)
    }

    func toggleMute(_ id: String) {
        if muted.remove(id) == nil { muted.insert(id) }
        send(id)
    }

    func resetAll() {
        let ids = Set(levels.keys).union(muted)
        levels.removeAll()
        muted.removeAll()
        ids.forEach(send)
    }

    private func send(_ id: String) {
        guard !demo else { return }
        let gain: Float = muted.contains(id) ? 0 : Float(levels[id] ?? 1)
        if #available(macOS 14.2, *) { (engineStorage as? MixerEngine)?.set(id, gain: gain) }
        rebuild()
    }

    /// Para as capturas: sem as apps que estão mesmo a tocar.
    func loadDemo(safari: String, music: String) {
        demo = true
        rows = [
            MixerRow(id: "music", name: "Music", appPath: music, level: 0.7, muted: false, status: .active),
            MixerRow(id: "safari", name: "Safari", appPath: safari, level: 1, muted: false, status: .normal),
        ]
    }

    private func apply(_ new: MixerSnapshot) {
        guard !demo else { return }
        snapshot = new
        for source in new.sources { known[source.key] = source }
        rebuild()
    }

    /// Aparecem as apps que estão a tocar e as que ajustaste (mesmo paradas, para as poderes repor).
    private func rebuild() {
        let playing = snapshot.sources.filter(\.playing).map(\.key)
        let shown = Set(playing).union(levels.keys).union(muted).union(snapshot.status.keys)
        let new = shown.compactMap { known[$0] }
            .map { source in
                MixerRow(id: source.key, name: source.name, appPath: source.appPath,
                         level: levels[source.key] ?? 1, muted: muted.contains(source.key),
                         status: snapshot.status[source.key] ?? .normal)
            }
            .sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
        if new != rows { rows = new }
    }
}

struct MixerCard: View {
    @Environment(Monitor.self) private var m
    @ObservedObject var mixer: AppMixer

    var body: some View {
        VStack(alignment: .leading, spacing: DS.md) {
            HStack(spacing: DS.sm) {
                Text("Apps").font(DS.body.weight(.medium))
                Spacer(minLength: DS.sm)
                if mixer.rows.contains(where: \.adjusted) {
                    Button("Repor tudo") { mixer.resetAll() }
                        .buttonStyle(.plain).font(DS.meta).foregroundStyle(Color.text2)
                        .help("Todas as apps voltam a 100%")
                }
            }
            if !mixer.supported {
                note("O volume por app precisa do macOS 14.2 ou mais recente.")
            } else if mixer.rows.isEmpty {
                note("Nenhuma app está a usar o som. Põe algo a tocar e aparece aqui.")
            } else {
                ForEach(mixer.rows) { row in
                    MixerRowView(row: row, mixer: mixer)
                }
                if mixer.rows.contains(where: { $0.status == .noSignal }) {
                    permissionHelp
                } else {
                    note("Ajustar uma app pede permissão para gravar o áudio do sistema; nada é gravado nem enviado. Ao fechar o AgentStats, tudo volta a 100%.")
                }
            }
        }
        .cardStyle()
        .task {
            mixer.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                if m.panelOpen { mixer.refresh() }
            }
        }
    }

    private var permissionHelp: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            note("Só chega silêncio, por isso não mexi no som dessa app. Se ela está mesmo a tocar, autoriza o AgentStats em Privacidade e Segurança → Gravação de ecrã e áudio do sistema. Vídeo protegido (DRM) pode não deixar ajustar.")
            Button("Abrir Definições do Sistema") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.small)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(DS.meta).foregroundStyle(Color.text3).fixedSize(horizontal: false, vertical: true)
    }
}

/// Mesma grelha do cartão de cima: coluna de 16 pt para os ícones, slider e percentagem de 36 pt.
private struct MixerRowView: View {
    let row: MixerRow
    let mixer: AppMixer

    var body: some View {
        VStack(alignment: .leading, spacing: DS.xs) {
            HStack(spacing: DS.sm) {
                appIcon.frame(width: 16, height: 16).accessibilityHidden(true)
                Text(row.name).font(DS.body).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: DS.sm)
                if let state = stateText {
                    Text(state).font(DS.meta).lineLimit(1).help(state)
                        .foregroundStyle(isProblem ? AnyShapeStyle(Color.waitingText) : AnyShapeStyle(Color.text3))
                }
            }
            HStack(spacing: DS.sm) {
                Button { mixer.toggleMute(row.id) } label: {
                    Image(systemName: row.muted ? "speaker.slash" : "speaker.wave.2")
                        .font(DS.body)
                        .foregroundStyle(row.muted ? AnyShapeStyle(Color.attentionText) : AnyShapeStyle(Color.text2))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(row.muted ? "Ativar som" : "Silenciar")
                .accessibilityLabel("\(row.muted ? "Ativar som de" : "Silenciar") \(row.name)")
                Slider(value: Binding(get: { row.level }, set: { mixer.setLevel(row.id, $0) }),
                       in: 0...Double(MixerMath.maxGain))
                    .controlSize(.small)
                    .accessibilityLabel("Volume de \(row.name)")
                    .accessibilityValue("\(percent)%")
                Text("\(percent)%")
                    .font(DS.meta.monospacedDigit())
                    .foregroundStyle(row.level > 1 && !row.muted ? AnyShapeStyle(Color.waitingText) : AnyShapeStyle(Color.text2))
                    .frame(width: 36, alignment: .trailing)
            }
        }
    }

    private var percent: Int { row.muted ? 0 : Int((row.level * 100).rounded()) }

    private var isProblem: Bool {
        switch row.status {
        case .noSignal, .failed: true
        default: false
        }
    }

    private var stateText: String? {
        guard row.adjusted else { return nil }
        switch row.status {
        case .checking: return "À espera de som"
        case .noSignal: return "Sem áudio"
        case .failed(let message): return message
        case .normal, .active: return nil
        }
    }

    @ViewBuilder private var appIcon: some View {
        if let path = row.appPath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().interpolation(.high)
        } else {
            Image(systemName: "waveform").font(DS.body).foregroundStyle(Color.text2)
        }
    }
}
