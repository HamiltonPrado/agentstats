import AppKit
import SwiftUI
import Testing
@testable import AgentStats

struct ContrastTests {
    @Test func everyTextToneReadsOnEverySurface() {
        let tones: [Tone] = [Contrast.text2, Contrast.text3, Contrast.working, Contrast.waiting, Contrast.attention]
        for tone in tones {
            for surface in [Contrast.panel, Contrast.backdrop] {
                #expect(tone.light.contrast(with: surface.light) >= Contrast.minimum)
                #expect(tone.dark.contrast(with: surface.dark) >= Contrast.minimum)
            }
        }
    }

    @Test func anyAccentBecomesReadable() {
        let levels: [UInt32] = [0x00, 0x33, 0x66, 0x99, 0xCC, 0xFF]
        for r in levels {
            for g in levels {
                for b in levels {
                    let hex: UInt32 = (r << 16) | (g << 8) | b
                    let tone = Contrast.readable(RGB(hex))
                    #expect(tone.light.contrast(with: Contrast.backdrop.light) >= Contrast.minimum)
                    #expect(tone.dark.contrast(with: Contrast.backdrop.dark) >= Contrast.minimum)
                }
            }
        }
    }

    /// O sistema pode resolver as cores fora do main actor (a armadilha do crash da v1.16).
    @Test func colorsResolveOffTheMainThread() async {
        let resolved = await Task.detached {
            NSColor(Contrast.text2.color).usingColorSpace(.sRGB) != nil
        }.value
        #expect(resolved)
    }

    @Test func secondaryStaysStrongerThanTertiary() {
        let back = Contrast.backdrop
        #expect(Contrast.text2.light.contrast(with: back.light) > Contrast.text3.light.contrast(with: back.light))
        #expect(Contrast.text2.dark.contrast(with: back.dark) > Contrast.text3.dark.contrast(with: back.dark))
    }
}
