import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A janela com os atalhos da app da frente. Abre ao segurar ⌘ sozinho 1 s, ou com ⌃⌥/.
@MainActor
final class ShortcutsOverlay {
    static let shared = ShortcutsOverlay()
    static let holdKey = "shortcuts.holdCommand"
    static let hotkeyID: UInt32 = 4
    static let combo = GlobalHotKey.Combo(keyCode: UInt32(kVK_ANSI_Slash), modifiers: UInt32(controlKey | optionKey), label: "⌃⌥/")

    private var panel: NSPanel?
    /// O monitor do teclado vive sempre; o dos cliques só enquanto a janela está aberta.
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    /// A leitura dos menus da app (pode demorar): cancelada se se fechar antes de acabar.
    private var loading: Task<Void, Never>?
    private var holdTask: Task<Void, Never>?
    private let hotKey = GlobalHotKey(id: ShortcutsOverlay.hotkeyID)
    /// Aberta por segurar ⌘: fecha ao largar.
    private var openedByHold = false

    func start() {
        GlobalHotKey.handlers[Self.hotkeyID] = { ShortcutsOverlay.shared.toggle() }
        updateHotKey()
        // Segurar ⌘ sozinho. Os monitores globais de teclado precisam da Acessibilidade; sem ela fica só o atalho.
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { e in
            MainActor.assumeIsolated { ShortcutsOverlay.shared.event(e) }
        })
    }

    private func event(_ e: NSEvent) {
        let onlyCommand = e.type == .flagsChanged && e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
        if e.type == .keyDown || !onlyCommand {
            holdTask?.cancel()
            holdTask = nil
            if openedByHold || e.type == .keyDown { close() }
            return
        }
        guard Pref.bool(Self.holdKey, true), panel == nil, loading == nil else { return }
        holdTask?.cancel()
        holdTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1000))
            guard !Task.isCancelled, NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return }
            // O ⌘⇥ (trocar de app) é tratado pelo sistema e não chega aqui: confirma que não houve teclas no último segundo.
            let sinceKey = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
            guard ShortcutsOverlay.heldAlone(secondsSinceLastKey: sinceKey) else { return }
            self.show(byHold: true)
        }
    }

    /// Desligar nas Definições desliga as duas formas: segurar ⌘ e o ⌃⌥/.
    func updateHotKey() { hotKey.register(Pref.bool(Self.holdKey, true) ? Self.combo : nil) }

    /// A carregar conta como aberta: carregar outra vez fecha, em vez de lançar outra leitura.
    func toggle() { panel == nil && loading == nil ? show(byHold: false) : close() }

    /// ⌘ sozinho: nenhuma tecla carregada desde que se começou a segurar.
    nonisolated static func heldAlone(secondsSinceLastKey: Double) -> Bool { secondsSinceLastKey >= 0.95 }

    private func show(byHold: Bool) {
        let me = ProcessInfo.processInfo.processIdentifier
        guard let app = NSWorkspace.shared.frontmostApplication.flatMap({ $0.processIdentifier == me ? QuickPaste.previousApp : $0 }) else { return }
        guard AX.ensureTrusted() else { return }
        openedByHold = byHold
        let pid = app.processIdentifier
        let name = app.localizedName ?? ""
        let icon = app.icon
        loading?.cancel()
        loading = Task {
            let sections = await Blocking.run { AppShortcuts.read(pid: pid) }
            guard !Task.isCancelled else { return }
            self.loading = nil
            guard !byHold || NSEvent.modifierFlags.contains(.command) else { return }   // largou entretanto
            self.present(ShortcutsSheet(name: name, icon: icon, sections: sections) { ShortcutsOverlay.shared.close() })
        }
    }

    private func present(_ view: ShortcutsSheet) {
        close()
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let size = NSSize(width: min(screen.width * 0.82, 1100), height: min(screen.height * 0.8, 760))
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: view)
        p.setFrameOrigin(NSPoint(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2))
        p.orderFrontRegardless()
        panel = p
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            MainActor.assumeIsolated { ShortcutsOverlay.shared.close() }
        }
    }

    func close() {
        openedByHold = false
        loading?.cancel()
        loading = nil
        panel?.orderOut(nil)
        panel = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }
}

struct ShortcutsSheet: View {
    let name: String
    let icon: NSImage?
    let sections: [ShortcutSection]
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.md) {
            HStack(spacing: DS.sm) {
                if let icon { Image(nsImage: icon).resizable().frame(width: 28, height: 28) }
                Text(L(name)).font(.title3.weight(.semibold))
                Spacer()
                Text(String(localized: "Larga ⌘ ou carrega numa tecla para fechar")).font(DS.meta).foregroundStyle(Color.text3)
            }
            if sections.isEmpty {
                Text("Esta app não tem atalhos nos menus.").font(DS.body).foregroundStyle(Color.text2)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), alignment: .top)], alignment: .leading, spacing: DS.lg) {
                        ForEach(sections) { section in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(L(section.menu)).font(DS.body.weight(.semibold)).padding(.bottom, 2)
                                ForEach(section.items) { item in
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(L(item.title)).font(DS.meta).lineLimit(1)
                                        Spacer(minLength: DS.sm)
                                        Text(item.keys).font(DS.meta.monospaced()).foregroundStyle(Color.text2)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(DS.lg)
        .background(.regularMaterial)
    }
}
