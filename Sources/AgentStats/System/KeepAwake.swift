import Foundation
import Combine
import IOKit.pwr_mgt
import CoreAudio

@MainActor
final class KeepAwakeController {
    private let reason: String
    private var assertion: IOPMAssertionID = 0
    private var timeout: Timer?
    var onTimeout: (() -> Void)?

    init(reason: String = "AgentStats: manter o Mac acordado") {
        self.reason = reason
    }

    var isHolding: Bool { assertion != 0 }

    func setEnabled(_ enabled: Bool, minutes: Double) {
        timeout?.invalidate()
        timeout = nil
        if enabled {
            guard assertion == 0 else {
                if minutes > 0 { schedule(minutes: minutes) }
                return
            }
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &assertion)
            if result != kIOReturnSuccess { assertion = 0; return }
            if minutes > 0 { schedule(minutes: minutes) }
        } else if assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }

    private func schedule(minutes: Double) {
        timeout = Timer.scheduledTimer(withTimeInterval: minutes * 60, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.setEnabled(false, minutes: 0)
                self?.onTimeout?()
            }
        }
    }
}

/// Manter acordado enquanto há agentes a trabalhar, e mais um pouco: entre dois passos de um agente há
/// pausas curtas, e o Mac não deve adormecer nelas.
enum AgentAwake {
    static let key = "power.keepAwakeForAgents"
    static let grace: TimeInterval = 3 * 60

    static func shouldHold(working: Int, lastWorking: Date?, now: Date) -> Bool {
        if working > 0 { return true }
        guard let lastWorking else { return false }
        return now.timeIntervalSince(lastWorking) < grace
    }
}
