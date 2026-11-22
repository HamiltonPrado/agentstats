import Foundation
import Combine
import IOKit.pwr_mgt
import CoreAudio

@MainActor
final class KeepAwakeController {
    private var assertion: IOPMAssertionID = 0
    private var timeout: Timer?
    var onTimeout: (() -> Void)?

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
                "AgentStats: manter o Mac acordado" as CFString,
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
