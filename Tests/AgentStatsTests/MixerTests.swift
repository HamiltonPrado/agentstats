import CoreAudio
import Foundation
import Testing
@testable import AgentStats

// Nenhum destes testes cria taps, pede permissões ou toca som: só buffers em memória.

/// Corre o renderer com buffers intercalados inventados.
private func render(_ renderer: MixerRenderer, inputs: [(samples: [Float], channels: Int)],
                    outputs: [(count: Int, channels: Int)]) -> [[Float]] {
    let inList = AudioBufferList.allocate(maximumBuffers: max(inputs.count, 1))
    let outList = AudioBufferList.allocate(maximumBuffers: max(outputs.count, 1))
    inList.count = inputs.count
    outList.count = outputs.count
    let inMemory = inputs.map { input in
        let p = UnsafeMutableBufferPointer<Float>.allocate(capacity: input.samples.count)
        _ = p.initialize(from: input.samples)
        return p
    }
    // 9 = lixo: o renderer tem de escrever todas as amostras de saída.
    let outMemory = outputs.map { output in
        let p = UnsafeMutableBufferPointer<Float>.allocate(capacity: output.count)
        p.initialize(repeating: 9)
        return p
    }
    defer {
        inMemory.forEach { $0.deallocate() }
        outMemory.forEach { $0.deallocate() }
        free(inList.unsafeMutablePointer)
        free(outList.unsafeMutablePointer)
    }
    for (i, p) in inMemory.enumerated() {
        inList[i] = AudioBuffer(mNumberChannels: UInt32(inputs[i].channels), mDataByteSize: UInt32(p.count * 4),
                                mData: UnsafeMutableRawPointer(p.baseAddress))
    }
    for (i, p) in outMemory.enumerated() {
        outList[i] = AudioBuffer(mNumberChannels: UInt32(outputs[i].channels), mDataByteSize: UInt32(p.count * 4),
                                 mData: UnsafeMutableRawPointer(p.baseAddress))
    }
    renderer.render(input: inList.unsafePointer, output: outList.unsafeMutablePointer)
    return outMemory.map { Array($0) }
}

@Suite struct MixerRendererTests {
    @Test func probingNeverPlaysButNoticesSound() {
        let r = MixerRenderer(target: 0.5, live: false)
        let out = render(r, inputs: [([0.4, 0.4, 0.4, 0.4], 2)], outputs: [(4, 2)])
        #expect(out == [[0, 0, 0, 0]])   // a app ainda se ouve pelo caminho normal: tocar aqui duplicava
        #expect(r.heard)
    }

    @Test func pureSilenceIsNotProofOfPermission() {
        let r = MixerRenderer(target: 0.5, live: false)
        _ = render(r, inputs: [([0, 0, 0, 0], 2)], outputs: [(4, 2)])
        #expect(!r.heard)
    }

    @Test func appliesGainAndKeepsLeftAndRight() {
        let out = render(MixerRenderer(target: 0.5, live: true), inputs: [([0.8, 0.2, 0.8, 0.2], 2)], outputs: [(4, 2)])
        #expect(out == [[0.4, 0.1, 0.4, 0.1]])
    }

    @Test func muteIsExactSilence() {
        let out = render(MixerRenderer(target: 0, live: true), inputs: [([0.8, 0.2], 2)], outputs: [(2, 2)])
        #expect(out == [[0, 0]])
    }

    @Test func theMicrophoneBufferIsNeverPlayed() {
        let out = render(MixerRenderer(target: 1, live: true),
                         inputs: [([0.7, 0.7], 1), ([0.25, 0.5, 0.25, 0.5], 2)], outputs: [(4, 2)])
        #expect(out == [[0.25, 0.5, 0.25, 0.5]])
    }

    @Test func separateChannelBuffers() {
        let out = render(MixerRenderer(target: 1, live: true), inputs: [([0.25, 0.5], 2)], outputs: [(1, 1), (1, 1)])
        #expect(out == [[0.25], [0.5]])
    }

    @Test func monoDeviceGetsBothSides() {
        let out = render(MixerRenderer(target: 1, live: true), inputs: [([0.25, 0.75], 2)], outputs: [(1, 1)])
        #expect(out == [[0.5]])
    }

    @Test func extraChannelsStaySilent() {
        let out = render(MixerRenderer(target: 1, live: true), inputs: [([0.25, 0.5], 2)], outputs: [(6, 6)])
        #expect(out == [[0.25, 0.5, 0, 0, 0, 0]])
    }

    @Test func shortOrMissingInputLeavesNoGarbage() {
        let r = MixerRenderer(target: 1, live: true)
        #expect(render(r, inputs: [([0.25, 0.5], 2)], outputs: [(6, 2)]) == [[0.25, 0.5, 0, 0, 0, 0]])
        #expect(render(r, inputs: [], outputs: [(2, 2)]) == [[0, 0]])
    }

    @Test func takingOverStartsAtFullVolumeAndRamps() {
        let r = MixerRenderer(target: 0, live: false)
        r.goLive()
        let out = render(r, inputs: [([1, 1, 1, 1, 1, 1, 1, 1], 2)], outputs: [(8, 2)])
        #expect(out == [[0.75, 0.75, 0.5, 0.5, 0.25, 0.25, 0, 0]])
    }

    @Test func boostNeverClips() {
        let out = render(MixerRenderer(target: 1.5, live: true), inputs: [([1, -1], 2)], outputs: [(2, 2)])
        #expect(out[0][0] > 0.95 && out[0][0] <= 1)
        #expect(out[0][1] < -0.95 && out[0][1] >= -1)
    }

    /// O Core Audio chama o bloco na sua thread: criado no main actor, tem de correr fora dele (crash da v1.16).
    @MainActor @Test func ioBlockRunsOffTheMainActor() async {
        let r = MixerRenderer(target: 1, live: true)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            Self.callOnBackground(r.makeIOBlock(), then: done)
        }
        #expect(!r.heard)
    }

    nonisolated private static func callOnBackground(_ block: @escaping AudioDeviceIOBlock,
                                                     then done: CheckedContinuation<Void, Never>) {
        nonisolated(unsafe) let block = block
        DispatchQueue.global().async {
            var time = AudioTimeStamp()
            var input = AudioBufferList()
            var output = AudioBufferList()
            withUnsafePointer(to: &time) { t in
                withUnsafePointer(to: &input) { i in
                    withUnsafeMutablePointer(to: &output) { o in block(t, i, t, o, t) }
                }
            }
            done.resume()
        }
    }
}

@Suite struct MixerGroupingTests {
    private func process(_ object: AudioObjectID, pid: pid_t, owner: pid_t? = nil, path: String,
                         ownerPath: String? = nil, playing: Bool = false) -> AudioProcessInfo {
        AudioProcessInfo(object: object, pid: pid, owner: owner ?? pid, executable: path,
                         ownerExecutable: ownerPath ?? path, playing: playing)
    }

    private func group(_ list: [AudioProcessInfo]) -> [MixerSource] {
        MixerDiscovery.group(list, ownPID: 999) { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
    }

    @Test func helpersJoinTheirApp() {
        let helper = "/Applications/Browser.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"
        let out = group([process(7, pid: 2, path: helper, playing: true),
                         process(3, pid: 1, path: "/Applications/Browser.app/Contents/MacOS/Browser")])
        #expect(out == [MixerSource(key: "/Applications/Browser.app", name: "Browser",
                                    appPath: "/Applications/Browser.app", objects: [3, 7], playing: true)])
    }

    @Test func systemHelperBelongsToTheResponsibleApp() {
        let out = group([process(4, pid: 5, owner: 6,
                                 path: "/System/Library/Frameworks/WebKit.framework/XPCServices/GPU",
                                 ownerPath: "/Applications/Safari.app/Contents/MacOS/Safari", playing: true)])
        #expect(out.map(\.name) == ["Safari"])
    }

    @Test func agentStatsIsNeverTapped() {
        let out = group([process(1, pid: 999, path: "/Applications/AgentStats.app/Contents/MacOS/AgentStats"),
                         process(2, pid: 12, owner: 999, path: "/usr/bin/afplay")])
        #expect(out.isEmpty)
    }

    @Test func commandLineToolsKeepTheirName() {
        #expect(group([process(1, pid: 3, path: "/opt/homebrew/bin/mpv")]).map(\.name) == ["mpv"])
    }

    @Test func sliderSticksAtOneHundred() {
        #expect(MixerMath.snapped(0.98) == 1)
        #expect(MixerMath.snapped(1.02) == 1)
        #expect(MixerMath.snapped(0.5) == 0.5)
        #expect(MixerMath.snapped(9) == 1.5)
        #expect(MixerMath.snapped(-1) == 0)
    }
}
