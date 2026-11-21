import SwiftUI
import CoreAudio

struct AudioView: View {
    @StateObject private var audio = AudioControlStore()

    var body: some View {
        AudioControlsCard(audio: audio)
    }
}

/// Saída e microfone, cada um com: aparelho, e por baixo volume com o botão de silenciar.
/// Uma só coluna de ícones de 16 pt (o próprio botão de silenciar), para tudo alinhar.
struct AudioControlsCard: View {
    @ObservedObject var audio: AudioControlStore

    var body: some View {
        VStack(alignment: .leading, spacing: DS.md) {
            section(title: "Saída", devices: audio.outputs,
                    selection: Binding(get: { audio.outputID }, set: { audio.selectOutput($0) }),
                    volume: Binding(get: { audio.outputVolume }, set: { audio.setOutputVolume($0) }),
                    canSet: audio.canSetOutputVolume,
                    muted: Binding(get: { audio.outputMuted }, set: { audio.setOutputMuted($0) }),
                    canMute: audio.canMuteOutput,
                    activeIcon: "speaker.wave.2", mutedIcon: "speaker.slash", volumeLabel: "Volume de saída")
            Divider().opacity(0.5)
            section(title: "Microfone", devices: audio.inputs,
                    selection: Binding(get: { audio.inputID }, set: { audio.selectInput($0) }),
                    volume: Binding(get: { audio.inputVolume }, set: { audio.setInputVolume($0) }),
                    canSet: audio.canSetInputVolume,
                    muted: Binding(get: { audio.inputMuted }, set: { audio.setInputMuted($0) }),
                    canMute: audio.canMuteInput,
                    activeIcon: "mic", mutedIcon: "mic.slash", volumeLabel: "Nível do microfone")
            Text("Os controlos variam por aparelho. Silenciar o microfone pode não afetar todas as apps.")
                .font(DS.meta).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .cardStyle()
    }

    @ViewBuilder
    private func section(title: String, devices: [SystemAudioDevice], selection: Binding<AudioDeviceID>,
                         volume: Binding<Double>, canSet: Bool, muted: Binding<Bool>, canMute: Bool,
                         activeIcon: String, mutedIcon: String, volumeLabel: String) -> some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            // Linha 1: nome + aparelho
            HStack(spacing: DS.sm) {
                Text(title).font(DS.body.weight(.medium))
                Spacer(minLength: DS.sm)
                if devices.isEmpty {
                    Text("Indisponível").font(DS.meta).foregroundStyle(.tertiary)
                } else {
                    Picker(title, selection: selection) {
                        ForEach(devices) { device in Text(device.name).tag(device.id) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            // Linha 2: silenciar (na coluna do ícone) + volume + percentagem
            HStack(spacing: DS.sm) {
                Button { muted.wrappedValue.toggle() } label: {
                    Image(systemName: muted.wrappedValue ? mutedIcon : activeIcon)
                        .font(DS.body)
                        .foregroundStyle(muted.wrappedValue ? AnyShapeStyle(Palette.attention) : AnyShapeStyle(.secondary))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(!canMute)
                .help(muted.wrappedValue ? "Ativar som" : "Silenciar")
                .accessibilityLabel(muted.wrappedValue ? "Ativar som" : "Silenciar")
                Slider(value: volume, in: 0...1)
                    .controlSize(.small)
                    .disabled(!canSet).accessibilityLabel(volumeLabel)
                Text("\(Int((volume.wrappedValue * 100).rounded()))%")
                    .font(DS.meta.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .trailing)
            }
        }
    }
}
