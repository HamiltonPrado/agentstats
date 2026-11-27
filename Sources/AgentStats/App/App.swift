import SwiftUI
import AppKit
import ServiceManagement
import UserNotifications

@main
enum AgentStatsApp {
    /// Arranque em AppKit puro: só existe o ícone na barra de menus (sem janelas SwiftUI).
    static func main() {
        handleCommandLine()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    static func handleCommandLine() {
        if CommandLine.arguments.contains("--hook") {
            // Chamado pelo hook de Notification do Claude Code: grava o evento e sai, sem escrever nada.
            HookEvents.record(stdin: FileHandle.standardInput.readDataToEndOfFile())
            exit(0)
        }
        if CommandLine.arguments.contains("--dump") { Self.dump(); exit(0) }
        if CommandLine.arguments.contains("--bench") { Self.bench(); exit(0) }
        if CommandLine.arguments.contains("--register-login") {
            do { try SMAppService.mainApp.register(); print("login: \(SMAppService.mainApp.status.rawValue)") }
            catch { print("erro: \(error)") }
            exit(0)
        }
        if CommandLine.arguments.contains("--smoke") {
            MainActor.assumeIsolated { Self.smoke() }
            exit(0)
        }
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            MainActor.assumeIsolated { Snapshot.write(to: args[i + 1]) }
            exit(0)
        }
    }
}

/// Referência ao controlador para quem não está no main actor (o delegate das notificações).
@MainActor enum AppState {
    static weak var controller: StatusController?
}

/// O `NSApplicationDelegate` já é do main actor; dito aqui, sem `assumeIsolated` em cada método.
/// Os dois métodos do centro de notificações ficam `nonisolated`: o sistema chama-os noutra fila.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var controller: StatusController?

    /// `agentstats://…` (app Atalhos, Terminal, links).
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let monitor = AppState.controller?.monitorForCommands else { return }
        for url in urls { URLCommand.parse(url)?.run(monitor: monitor) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        NSApp.mainMenu = EditMenu.make()
        controller = StatusController(monitor: Monitor())
        ClipboardStore.shared.start()
        UpdateStore.shared.start()
        MicMuteStore.shared.start()
        WindowShortcuts.update()
        AppUsageStore.shared.start()
        PresentationMode.shared.restoreAfterLaunch()
        UnresponsiveStore.shared.start()
        ShortcutsOverlay.shared.start()
        RulesStore.shared.start()
        MeetingsStore.shared.start()
        CaptureStore.shared.stopOrphan()
        AppState.controller = controller
        HookEvents.prune()
        ClaudeHookStore.shared.refresh()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                CaptureStore.shared.shutdown()
                CleaningModeStore.shared.stop(.system)
                AppState.controller?.saveHistory()
            }
        }
        if Welcome.shouldShow() { WelcomeWindow.show() }
        // Diagnóstico: abre o painel ao arrancar (para medir o consumo com o painel aberto)
        if ProcessInfo.processInfo.environment["AGENTSTATS_OPEN_PANEL"] != nil {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.controller?.openPanel()
            }
        }
    }

    // Clicar numa notificação de um agente traz para a frente a app onde ele corre.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["session"] as? String else { return }
        await MainActor.run { AppState.controller?.focusSession(id: id) }
    }

    // Mostra as notificações mesmo quando a AgentStats está ativa (por exemplo, com o painel aberto).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
