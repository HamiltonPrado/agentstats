import AppKit
import SwiftUI

/// O cartão em Ferramentas → Limpeza.
struct CleaningModeCard: View {
    @ObservedObject var store: CleaningModeStore
    @AppStorage("cleaning.minutes") private var minutes = 2

    var body: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            Text("Teclado e ecrã").font(DS.body.weight(.medium))
            note("Ecrã preto e teclado bloqueado, para limpares os dois.")
            if store.trusted {
                // O seletor vai por baixo: ao lado do texto passava a margem do cartão.
                Text("Sair sozinho após").font(DS.body)
                Picker("Sair sozinho após", selection: $minutes) {
                    ForEach(CleaningRules.durations, id: \.self) { value in Text("\(value) min").tag(value) }
                }
                .pickerStyle(.segmented).labelsHidden()
                note("Para sair antes: segura o botão do ecrã 2 s, ou as duas teclas ⌘ 3 s. O botão de ligar e o Touch ID não se bloqueiam.")
                Button("Começar a limpar") {
                    AppState.controller?.closePanel()
                    store.start(minutes: minutes)
                }
                .controlSize(.small)
            } else {
                note("Precisa de Acessibilidade para segurar as teclas. Não lê nem guarda o que escreves.")
                Button("Dar permissão…") { store.requestAccess() }.controlSize(.small)
                if store.asked {
                    note("Se o AgentStats já aparece ligado, é de uma versão anterior: tira-o da lista com − e volta a juntá-lo.",
                         color: .waitingText)
                }
            }
            if let message = store.message { note(message, color: .waitingText) }
        }
        .cardStyle()
        .task {
            // A permissão dá-se nas Definições: vê-se quando muda.
            while !Task.isCancelled {
                store.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

}

/// Uma janela preta por ecrã, por cima de tudo, cada uma com o seu botão de sair.
@MainActor
final class CleaningOverlay {
    static let shared = CleaningOverlay()

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        // O AppKit empurrava a janela para baixo da barra de menus.
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    /// O primeiro clique já conta, mesmo com outra app à frente.
    private final class Host: NSHostingView<CleaningScreen> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private var panels: [NSPanel] = []
    private var screensToken: NSObjectProtocol?
    private weak var store: CleaningModeStore?

    func show(_ store: CleaningModeStore) {
        self.store = store
        rebuild()
        screensToken = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                              object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        if let screensToken { NotificationCenter.default.removeObserver(screensToken) }
        screensToken = nil
        store = nil
        for panel in panels { panel.orderOut(nil) }
        panels = []
    }

    private func rebuild() {
        guard let store else { return }
        let old = panels
        panels = NSScreen.screens.map { screen in Self.panel(for: screen, store: store) }
        for panel in panels { panel.orderFrontRegardless() }
        panels.first?.makeKey()
        for panel in old { panel.orderOut(nil) }
    }

    private static func panel(for screen: NSScreen, store: CleaningModeStore) -> NSPanel {
        let panel = Panel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .black
        panel.isOpaque = true
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.contentView = Host(rootView: CleaningScreen(store: store))
        panel.setFrame(screen.frame, display: false)
        return panel
    }
}

/// O ecrã preto, onde as dedadas se veem, com o mínimo de texto.
struct CleaningScreen: View {
    @ObservedObject var store: CleaningModeStore

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black
            VStack(spacing: DS.lg) {
                Text("Teclado bloqueado")
                    .font(.system(size: 22, weight: .medium)).foregroundStyle(Color(white: 0.8))
                if let end = store.endsAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("Sai sozinho em " + Self.clock(end.timeIntervalSince(context.date)))
                            .font(.system(size: 14).monospacedDigit()).foregroundStyle(Color(white: 0.6))
                    }
                }
                HoldToExitButton { store.stop() }
                Text("ou segura as duas teclas ⌘ durante 3 segundos")
                    .font(.system(size: 13)).foregroundStyle(Color(white: 0.6))
            }
            .padding(.bottom, 96)
        }
        .ignoresSafeArea()
    }

    nonisolated static func clock(_ seconds: TimeInterval) -> String {
        let left = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", left / 60, left % 60)
    }
}

/// Tem de se segurar: um pano a passar no trackpad não sai sem querer.
private struct HoldToExitButton: View {
    let action: () -> Void
    @StateObject private var since = Box<Date?>(nil)
    @StateObject private var pending = Box<Task<Void, Never>?>(nil)

    private static let width: CGFloat = 280

    var body: some View {
        TimelineView(.animation(paused: since.value == nil)) { context in
            let held: Double = since.value.map { context.date.timeIntervalSince($0) } ?? 0
            let fraction: Double = min(max(held / CleaningRules.holdButton, 0), 1)
            ZStack(alignment: .leading) {
                Color(white: 0.14)
                Rectangle().fill(Color(white: 0.3)).frame(width: Self.width * CGFloat(fraction))
                Text("Segura 2 segundos para sair")
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(Color(white: 0.92))
                    .frame(maxWidth: .infinity)
            }
            .frame(width: Self.width, height: 56)
            .clipShape(Capsule(style: .circular))
            .overlay(Capsule(style: .circular).inset(by: 0.5).stroke(Color(white: 0.4), lineWidth: 1))
        }
        .contentShape(Capsule(style: .circular))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    // Arrastar para fora cancela, como um botão normal.
                    let area = CGRect(x: -16, y: -16, width: Self.width + 32, height: 88)
                    if area.contains(value.location) { begin() } else { cancel() }
                }
                .onEnded { _ in cancel() }
        )
        .onDisappear { cancel() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sair da limpeza")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }

    private func begin() {
        guard since.value == nil else { return }
        since.value = Date()
        let action = action
        pending.value = Task { @MainActor in
            try? await Task.sleep(for: .seconds(CleaningRules.holdButton))
            if !Task.isCancelled { action() }
        }
    }

    private func cancel() {
        pending.value?.cancel()
        pending.value = nil
        since.value = nil
    }
}
