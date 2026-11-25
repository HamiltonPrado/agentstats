import AppKit
import IOKit.pwr_mgt
import UserNotifications

/// Todas as notificações da app passam por aqui: no modo apresentação ficam caladas.
@MainActor
enum Notify {
    static func add(_ request: UNNotificationRequest) {
        guard !PresentationMode.shared.active else { return }
        UNUserNotificationCenter.current().add(request)
    }
}

/// Modo apresentação: esconde os ícones da secretária, não deixa o ecrã apagar-se, pausa o histórico do
/// Clipboard e cala as notificações da app. Ao desligar, só desfaz o que ele próprio mudou.
@MainActor
final class PresentationMode: ObservableObject {
    static let shared = PresentationMode()
    private static let activeKey = "presentation.active"
    private static let hidIconsKey = "presentation.hidIcons"

    @Published private(set) var active = false
    var onChange: (() -> Void)?
    private var assertion: IOPMAssertionID = 0

    /// Se a app fechou com o modo ligado, volta a pô-lo como estava (os ícones podem ter ficado escondidos).
    func restoreAfterLaunch() {
        guard UserDefaults.standard.bool(forKey: Self.activeKey) else { return }
        Task { await set(false) }
    }

    func toggle() async { await set(!active) }

    func set(_ on: Bool) async {
        let d = UserDefaults.standard
        if on {
            guard !active else { return }
            active = true
            d.set(true, forKey: Self.activeKey)
            let hide = QuickToggles.desktopIconsShown
            d.set(hide, forKey: Self.hidIconsKey)
            if hide { await QuickTogglesStore.shared.toggleDesktopIcons() }
            if assertion == 0 {
                _ = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                IOPMAssertionLevel(kIOPMAssertionLevelOn), "AgentStats: modo apresentação" as CFString, &assertion)
            }
            ClipboardStore.shared.paused = true
        } else {
            let hid = d.bool(forKey: Self.hidIconsKey)
            active = false
            d.set(false, forKey: Self.activeKey)
            d.set(false, forKey: Self.hidIconsKey)
            if hid && !QuickToggles.desktopIconsShown { await QuickTogglesStore.shared.toggleDesktopIcons() }
            if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
            ClipboardStore.shared.paused = false
        }
        onChange?()
    }
}
