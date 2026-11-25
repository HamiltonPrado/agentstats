import CoreGraphics
import Foundation
import Testing
@testable import AgentStats

@Suite("Janelas")
struct WindowLayoutTests {
    // Ecrã com barra de menus e Dock: área útil a começar em y = 80.
    let v = CGRect(x: 0, y: 80, width: 1500, height: 900)
    let win = CGRect(x: 100, y: 200, width: 600, height: 400)

    @Test func halvesThirdsAndCorners() {
        #expect(WindowLayout.frame(.leftHalf, in: v, window: win) == CGRect(x: 0, y: 80, width: 750, height: 900))
        #expect(WindowLayout.frame(.rightHalf, in: v, window: win) == CGRect(x: 750, y: 80, width: 750, height: 900))
        #expect(WindowLayout.frame(.topHalf, in: v, window: win) == CGRect(x: 0, y: 530, width: 1500, height: 450))
        #expect(WindowLayout.frame(.bottomRight, in: v, window: win) == CGRect(x: 750, y: 80, width: 750, height: 450))
        #expect(WindowLayout.frame(.centerThird, in: v, window: win) == CGRect(x: 500, y: 80, width: 500, height: 900))
        #expect(WindowLayout.frame(.lastTwoThirds, in: v, window: win) == CGRect(x: 500, y: 80, width: 1000, height: 900))
        #expect(WindowLayout.frame(.maximize, in: v, window: win) == v)
        #expect(WindowLayout.frame(.center, in: v, window: win) == CGRect(x: 450, y: 330, width: 600, height: 400))
    }

    @Test func centerNeverOverflows() {
        let huge = CGRect(x: 0, y: 0, width: 4000, height: 3000)
        #expect(WindowLayout.frame(.center, in: v, window: huge) == v)
    }

    @Test func pressingAgainCycles() {
        let half = WindowLayout.frame(.leftHalf, in: v, window: win)
        #expect(WindowLayout.cycled(.leftHalf, current: win, in: v) == .leftHalf)
        #expect(WindowLayout.cycled(.leftHalf, current: half, in: v) == .firstTwoThirds)
        let twoThirds = WindowLayout.frame(.firstTwoThirds, in: v, window: win)
        #expect(WindowLayout.cycled(.leftHalf, current: twoThirds, in: v) == .firstThird)
        let third = WindowLayout.frame(.firstThird, in: v, window: win)
        #expect(WindowLayout.cycled(.leftHalf, current: third, in: v) == .leftHalf)
        #expect(WindowLayout.cycled(.maximize, current: v, in: v) == .maximize)
    }

    @Test func movingToAnotherDisplayKeepsProportions() {
        let a = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let b = CGRect(x: 1000, y: 0, width: 2000, height: 1600)
        let w = CGRect(x: 0, y: 0, width: 500, height: 400)
        #expect(WindowLayout.moved(w, from: a, to: b) == CGRect(x: 1000, y: 0, width: 1000, height: 800))
        // Para um ecrã mais pequeno, nunca sai dele.
        let big = CGRect(x: 500, y: 400, width: 500, height: 400)
        let small = CGRect(x: -800, y: 0, width: 800, height: 600)
        let r = WindowLayout.moved(big, from: a, to: small)
        #expect(small.contains(r))
    }

    @Test func displays() {
        let screens = [CGRect(x: 0, y: 0, width: 1500, height: 900), CGRect(x: -1920, y: 0, width: 1920, height: 1080), CGRect(x: 1500, y: 0, width: 1000, height: 800)]
        #expect(WindowLayout.neighbour(of: 0, in: screens, forward: true) == 2)
        #expect(WindowLayout.neighbour(of: 0, in: screens, forward: false) == 1)
        #expect(WindowLayout.neighbour(of: 2, in: screens, forward: true) == 1)   // dá a volta
        #expect(WindowLayout.neighbour(of: 0, in: [screens[0]], forward: true) == nil)
        #expect(WindowLayout.screenIndex(for: CGRect(x: 1400, y: 10, width: 400, height: 300), in: screens) == 2)
    }

    @Test func flippingIsItsOwnInverse() {
        let r = CGRect(x: 10, y: 20, width: 300, height: 200)
        #expect(WindowLayout.flipped(r, primaryHeight: 1000) == CGRect(x: 10, y: 780, width: 300, height: 200))
        #expect(WindowLayout.flipped(WindowLayout.flipped(r, primaryHeight: 1000), primaryHeight: 1000) == r)
    }

    @MainActor @Test func shortcutsAreUniqueAndCoverEveryAction() {
        let combos = WindowShortcuts.map.map { "\($0.combo.keyCode)-\($0.combo.modifiers)" }
        #expect(Set(combos).count == combos.count)
        #expect(Set(WindowShortcuts.map.map(\.action)) == Set(WindowAction.allCases))
        // Não chocam com o atalho do microfone (⌃⌥M) nem com os ids dos outros atalhos.
        #expect(!WindowShortcuts.map.contains { $0.combo.label == "⌃⌥M" })
        #expect(WindowShortcuts.firstID > TabHotKeys.firstID + 9)
    }

    @Test func urlCommands() {
        #expect(URLCommand.parse(URL(string: "agentstats://window/leftHalf")!) == .window(.leftHalf))
        #expect(URLCommand.parse(URL(string: "agentstats://window/NEXTDISPLAY")!) == .window(.nextDisplay))
        #expect(URLCommand.parse(URL(string: "agentstats://window/sideways")!) == nil)
    }
}
