import CoreAudio
import os

// A parte do mixer que não depende de aparelhos: ganho, limitador, agrupamento e o callback de áudio.

enum MixerMath {
    static let maxGain: Float = 1.5

    /// Perto de 100% cola a 100%, onde o som volta ao caminho normal do macOS.
    static func snapped(_ value: Double) -> Float {
        abs(value - 1) < 0.03 ? 1 : Float(min(max(value, 0), Double(maxGain)))
    }

    /// Acima de 0,8 comprime suavemente, para amplificar sem passar de 1.
    static func limited(_ x: Float) -> Float {
        let knee: Float = 0.8
        let a = abs(x)
        guard a > knee else { return x }
        let y = knee + (1 - knee) * tanh((a - knee) / (1 - knee))
        return x < 0 ? -y : y
    }

    /// A app de fora de um executável: ".../Google Chrome.app/.../Helper.app/..." → ".../Google Chrome.app".
    static func appPath(executable: String) -> String? {
        guard let r = executable.range(of: ".app/") else { return nil }
        return String(executable[..<r.lowerBound]) + ".app"
    }
}

/// Estado partilhado com a thread de áudio.
///
/// A thread de áudio nunca espera: usa `withLockIfAvailable` e, se o lock estiver ocupado, repete o
/// último valor. `gain` e `wasLive` pertencem só a essa thread, daí o `@unchecked Sendable`.
final class MixerRenderer: @unchecked Sendable {
    struct Shared: Sendable {
        var target: Float
        /// Falso enquanto se confirma que chega áudio: a saída fica a zero e a app continua a ouvir-se normalmente.
        var live: Bool
        var heard = false
    }

    private let shared: OSAllocatedUnfairLock<Shared>
    private var gain: Float
    private var wasLive: Bool

    init(target: Float, live: Bool) {
        shared = OSAllocatedUnfairLock(initialState: Shared(target: target, live: live))
        gain = live ? target : 1
        wasLive = live
    }

    var heard: Bool { shared.withLock { $0.heard } }
    func setTarget(_ value: Float) { shared.withLock { $0.target = value } }
    func goLive() { shared.withLock { $0.live = true } }

    /// Criado num contexto sem ator: o Core Audio chama-o na sua thread de tempo real. Um bloco criado
    /// no main actor rebentaria com o Swift do Xcode 16, como aconteceu na v1.16.
    nonisolated func makeIOBlock() -> AudioDeviceIOBlock {
        { @Sendable [self] _, input, _, output, _ in
            render(input: input, output: output)
        }
    }

    /// Sem alocações, sem esperas e sem chamadas ao sistema.
    /// O tap é o último buffer de entrada (antes dele vêm as entradas do próprio aparelho, desligadas).
    func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let outs = UnsafeMutableAudioBufferListPointer(output)
        for buffer in outs {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }

        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard ins.count > 0 else { return }
        let source = ins[ins.count - 1]
        let sourceChannels = Int(source.mNumberChannels)
        guard let raw = source.mData, sourceChannels > 0 else { return }
        let samples = raw.assumingMemoryBound(to: Float.self)
        let count = Int(source.mDataByteSize) / MemoryLayout<Float>.size
        let frames = count / sourceChannels
        guard frames > 0 else { return }

        // Zeros exatos é o que o macOS entrega quando não há permissão.
        var signal = false
        for i in 0..<count where samples[i] != 0 {
            signal = true
            break
        }
        let sawSignal = signal
        let state = shared.withLockIfAvailable { s -> (Float, Bool) in
            if sawSignal { s.heard = true }
            return (s.target, s.live)
        }
        let live = state?.1 ?? wasLive
        let target = state?.0 ?? gain
        wasLive = live
        guard live else { return }

        // Rampa ao longo do buffer, para mexer no slider não dar estalidos.
        let start = gain
        let step = (target - start) / Float(frames)
        let amplifies = max(start, target) > 1
        var channel = 0
        for buffer in outs {
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0 else { continue }
            defer { channel += channels }
            guard channel < 2, let data = buffer.mData else { continue }
            let out = data.assumingMemoryBound(to: Float.self)
            let n = min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels)
            let monoDevice = outs.count == 1 && channels == 1
            for frame in 0..<n {
                let g = start + step * Float(frame + 1)
                let left = samples[frame * sourceChannels]
                let right = sourceChannels > 1 ? samples[frame * sourceChannels + 1] : left
                for local in 0..<min(channels, 2 - channel) {
                    let value = (monoDevice ? (left + right) / 2 : channel + local == 0 ? left : right) * g
                    out[frame * channels + local] = amplifies ? MixerMath.limited(value) : value
                }
            }
        }
        gain = target
    }
}
