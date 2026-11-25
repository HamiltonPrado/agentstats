import AppKit
import Foundation

/// `agentstats://…`: ações para a app Atalhos ("Abrir URL"), para o Terminal (`open agentstats://…`) e para links.
enum URLCommand: Equatable {
    case open(Tab)
    case settings
    case timer(minutes: Double)
    case pomodoro
    case stopTimer
    case readText, readCode, pickColor
    case darkMode, desktopIcons
    case copyUsage
    case window(WindowAction)

    static func parse(_ url: URL) -> URLCommand? {
        guard url.scheme?.lowercased() == "agentstats" else { return nil }
        let host = (url.host ?? "").lowercased()
        let path = url.pathComponents.filter { $0 != "/" }.map { $0.lowercased() }
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .compactMap { item in item.value.map { (item.name.lowercased(), $0) } })
        switch host {
        case "open":
            guard let raw = path.first ?? query["tab"], let tab = Tab(rawValue: raw), Tab.main.contains(tab) else { return nil }
            return .open(tab)
        case "settings": return .settings
        case "timer":
            if path.first == "stop" { return .stopTimer }
            guard let m = Double(query["minutes"] ?? path.first ?? ""), m >= 1, m <= 600 else { return nil }
            return .timer(minutes: m)
        case "pomodoro": return .pomodoro
        case "read":
            switch path.first {
            case "text": return .readText
            case "qr": return .readCode
            case "color": return .pickColor
            default: return nil
            }
        case "toggle":
            switch path.first {
            case "dark-mode": return .darkMode
            case "desktop-icons": return .desktopIcons
            default: return nil
            }
        case "usage": return path.first == "copy" ? .copyUsage : nil
        case "window":
            // agentstats://window/leftHalf (sem distinguir maiúsculas)
            guard let raw = url.pathComponents.filter({ $0 != "/" }).first,
                  let action = WindowAction.allCases.first(where: { $0.rawValue.lowercased() == raw.lowercased() }) else { return nil }
            return .window(action)
        default: return nil
        }
    }

    /// "Hoje: 2,8M tokens, ~$3,39 · semana: 14M tokens, ~$21" — vai para o clipboard, onde um atalho o lê.
    static func usageText(_ u: UsageSnapshot) -> String {
        var today = String(localized: "Hoje: \(Fmt.tokens(u.todayTotal.total)) tokens")
        if u.todayCost >= 0.01 { today += ", ~" + Fmt.usd(u.todayCost) }
        var week = String(localized: "semana: \(Fmt.tokens(u.weekTotal.total)) tokens")
        if u.weekCost >= 0.01 { week += ", ~" + Fmt.usd(u.weekCost) }
        return today + " · " + week
    }

    @MainActor
    func run(monitor: Monitor) {
        let controller = AppState.controller
        switch self {
        case .open(let tab): controller?.show(tab)
        case .settings: controller?.openSettings()
        case .timer(let minutes): TimerStore.shared.startTimer(minutes: minutes)
        case .pomodoro: TimerStore.shared.startPomodoro()
        case .stopTimer: TimerStore.shared.stop()
        case .readText: Task { await ScreenToolsStore.shared.readText() }
        case .readCode: Task { await ScreenToolsStore.shared.readCode() }
        case .pickColor: ScreenToolsStore.shared.pickColor()
        case .darkMode: Task { await QuickTogglesStore.shared.toggleDarkMode() }
        case .desktopIcons: Task { await QuickTogglesStore.shared.toggleDesktopIcons() }
        case .window(let action): WindowMover.apply(action)
        case .copyUsage:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(Self.usageText(monitor.usage), forType: .string)
        }
    }
}
