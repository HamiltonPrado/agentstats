import CoreGraphics
import Foundation
import Testing
@testable import AgentStats

// Nenhum teste cria um filtro de eventos, bloqueia teclas ou mostra o ecrã preto: o bloqueio é falso.

@Suite struct CleaningRulesTests {
    private let both = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x08 | 0x10)
    private let left = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x08)
    private let right = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10)
    private let flagsChanged = CGEventType.flagsChanged.rawValue

    @Test func blocksKeysMediaKeysScrollAndGestures() {
        var types: [UInt32] = [CGEventType.keyDown.rawValue, CGEventType.keyUp.rawValue, CGEventType.flagsChanged.rawValue]
        types.append(CGEventType.scrollWheel.rawValue)
        types.append(CGEventType.rightMouseDown.rawValue)
        types.append(14)   // brilho, som, play
        types += [29, 30, 31, 32]
        for type in types {
            #expect(CleaningRules.blocked.contains(type))
            #expect(CleaningRules.mask & (CGEventMask(1) << CGEventMask(type)) != 0)
        }
    }

    @Test func theWayOutIsNeverBlocked() {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged]
        for type in types {
            #expect(!CleaningRules.blocked.contains(type.rawValue))
            // Nem passam pelo filtro: o botão funciona mesmo que o filtro se atrase.
            #expect(CleaningRules.mask & (CGEventMask(1) << CGEventMask(type.rawValue)) == 0)
        }
    }

    @Test func bothCommandKeysMeansBothSides() {
        #expect(CleaningRules.bothCommands(both))
        #expect(!CleaningRules.bothCommands(left))
        #expect(!CleaningRules.bothCommands(right))
        #expect(!CleaningRules.bothCommands(.maskCommand))
    }

    @Test func holdingBothCommandsForThreeSecondsExits() {
        var watch = CleaningWatch(deadline: 1000)
        let swallowed = watch.handle(type: flagsChanged, flags: both, at: 10)
        #expect(swallowed)
        #expect(watch.end(at: 12.9, trusted: true) == nil)
        #expect(watch.end(at: 13, trusted: true) == .keys)
    }

    @Test func releasingEitherCommandStartsOver() {
        var watch = CleaningWatch(deadline: 1000)
        _ = watch.handle(type: flagsChanged, flags: both, at: 10)
        _ = watch.handle(type: flagsChanged, flags: left, at: 12)
        #expect(watch.end(at: 14, trusted: true) == nil)
        _ = watch.handle(type: flagsChanged, flags: both, at: 20)
        #expect(watch.end(at: 22, trusted: true) == nil)
        #expect(watch.end(at: 23, trusted: true) == .keys)
    }

    @Test func wipingOverOtherKeysDoesNotResetTheHold() {
        var watch = CleaningWatch(deadline: 1000)
        _ = watch.handle(type: flagsChanged, flags: both, at: 10)
        let swallowed = watch.handle(type: CGEventType.keyDown.rawValue, flags: both, at: 11)
        #expect(swallowed)
        #expect(watch.end(at: 13, trusted: true) == .keys)
    }

    @Test func timeAlwaysEndsIt() {
        var watch = CleaningWatch(deadline: 120)
        _ = watch.handle(type: CGEventType.keyDown.rawValue, flags: [], at: 119)
        #expect(watch.end(at: 119.9, trusted: true) == nil)
        #expect(watch.end(at: 120, trusted: true) == .timeUp)
    }

    @Test func losingPermissionEndsItAtOnce() {
        #expect(CleaningWatch(deadline: 1000).end(at: 1, trusted: false) == .permission)
    }

    @Test func countdownText() {
        #expect(Fmt.clock(120) == "2:00")
        #expect(Fmt.clock(59.2) == "1:00")
        #expect(Fmt.clock(5) == "0:05")
        #expect(Fmt.clock(-3) == "0:00")
    }
}

private final class FakeKeyboard: KeyboardLocking {
    let works: Bool
    private(set) var seconds: TimeInterval?
    private(set) var stops = 0
    private(set) var onEnd: (@Sendable (CleaningEnd) -> Void)?

    init(works: Bool) {
        self.works = works
    }

    func start(seconds: TimeInterval, onEnd: @escaping @Sendable (CleaningEnd) -> Void) -> Bool {
        guard works else { return false }
        self.seconds = seconds
        self.onEnd = onEnd
        return true
    }

    func stop() { stops += 1 }
}

@MainActor private final class Desk {
    var trusted = true
    var secure = false
    var recording = false
    var lockWorks = true
    var locks: [FakeKeyboard] = []
    var overlay = false
    var asked = 0

    func store() -> CleaningModeStore {
        var env = CleaningModeStore.Environment()
        env.trusted = { self.trusted }
        env.requestAccess = { self.asked += 1 }
        env.secureInput = { self.secure }
        env.recording = { self.recording }
        env.makeLock = {
            let lock = FakeKeyboard(works: self.lockWorks)
            self.locks.append(lock)
            return lock
        }
        env.showOverlay = { _ in self.overlay = true }
        env.hideOverlay = { self.overlay = false }
        env.keepDisplayAwake = { nil }
        env.observesSystem = false
        return CleaningModeStore(environment: env)
    }
}

@MainActor @Suite struct CleaningModeStoreTests {
    /// O fim vem da thread do filtro: espera-se pelo estado, sem pausas fixas.
    private func waitUntilInactive(_ store: CleaningModeStore) async {
        for _ in 0..<10_000 where store.active {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test func startsAndStopsWithTheButton() {
        let desk = Desk()
        let store = desk.store()
        store.start(minutes: 2)
        #expect(store.active)
        #expect(desk.overlay)
        #expect(desk.locks.first?.seconds == 120)
        store.stop()
        #expect(!store.active)
        #expect(!desk.overlay)
        #expect(desk.locks.first?.stops == 1)
        #expect(store.message == nil)
    }

    @Test func lookingAtTheCardNeverLocksOrAsks() {
        let desk = Desk()
        let store = desk.store()
        store.refresh()
        #expect(desk.locks.isEmpty)
        #expect(desk.asked == 0)
        #expect(!desk.overlay)
    }

    @Test func withoutPermissionNothingLocks() {
        let desk = Desk()
        desk.trusted = false
        let store = desk.store()
        store.start(minutes: 2)
        #expect(desk.locks.isEmpty)
        #expect(!desk.overlay)
        #expect(store.message != nil)
    }

    @Test func aLockThatFailsNeverShowsTheBlackScreen() {
        let desk = Desk()
        desk.lockWorks = false
        let store = desk.store()
        store.start(minutes: 2)
        #expect(!store.active)
        #expect(!desk.overlay)
        #expect(store.message != nil)
    }

    @Test func secureInputRefusesToStart() {
        let desk = Desk()
        desk.secure = true
        let store = desk.store()
        store.start(minutes: 2)
        #expect(desk.locks.isEmpty)
        #expect(!desk.overlay)
    }

    @Test func recordingRefusesToStart() {
        let desk = Desk()
        desk.recording = true
        let store = desk.store()
        store.start(minutes: 2)
        #expect(desk.locks.isEmpty)
        #expect(!desk.overlay)
    }

    @Test func secureInputMidwayReleases() {
        let desk = Desk()
        let store = desk.store()
        store.start(minutes: 1)
        desk.secure = true
        store.check()
        #expect(!store.active)
        #expect(!desk.overlay)
        #expect(desk.locks.first?.stops == 1)
        #expect(store.message == CleaningEnd.secureInput.message)
    }

    @Test func losingPermissionMidwayReleases() {
        let desk = Desk()
        let store = desk.store()
        store.start(minutes: 1)
        desk.trusted = false
        store.check()
        #expect(!store.active)
        #expect(!desk.overlay)
        #expect(desk.locks.first?.stops == 1)
    }

    @Test func theLockEndingRemovesTheBlackScreen() async {
        let desk = Desk()
        let store = desk.store()
        store.start(minutes: 1)
        desk.locks.first?.onEnd?(.timeUp)
        await waitUntilInactive(store)
        #expect(!store.active)
        #expect(!desk.overlay)
    }

    @Test func anOldLockCannotEndANewSession() async {
        let desk = Desk()
        let store = desk.store()
        store.start(minutes: 1)
        let old = desk.locks.first
        store.stop()
        store.start(minutes: 1)
        old?.onEnd?(.button)
        for _ in 0..<50 { await Task.yield() }
        #expect(store.active)
        #expect(desk.overlay)
        store.stop()
    }

    @Test func asksOnlyOnceRunningAndOnlyOneLock() {
        let desk = Desk()
        let store = desk.store()
        store.start(minutes: 1)
        store.start(minutes: 1)
        #expect(desk.locks.count == 1)
        store.stop()
    }

    @Test func aStrangeDurationCannotLockForHours() {
        let desk = Desk()
        let store = desk.store()
        store.start(minutes: 9999)
        #expect(desk.locks.first?.seconds == 120)
        store.stop()
    }

    @Test func demoNeverLocks() {
        let desk = Desk()
        let store = desk.store()
        store.loadDemo()
        store.start(minutes: 1)
        store.requestAccess()
        #expect(desk.locks.isEmpty)
        #expect(desk.asked == 0)
    }
}
