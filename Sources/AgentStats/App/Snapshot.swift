import AppKit
import SwiftUI

/// `--snapshot <pasta>`: cada separador em PNG (claro e escuro), sempre com os dados do `DemoData`.
@MainActor
enum Snapshot {
    /// Fora do ecrã, mas a dizer-se ativa: senão os interruptores e os seletores saem apagados.
    private final class Window: NSWindow {
        override var isKeyWindow: Bool { true }
        override var isMainWindow: Bool { true }
    }

    static func write(to dir: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let folder = URL(fileURLWithPath: dir)
        let m = DemoData.load()
        if ProcessInfo.processInfo.environment["AGENTSTATS_FAKE_ALERT"] != nil {
            m.activeAlerts = [
                SystemAlert(kind: .cpu, value: "92%", since: Date().addingTimeInterval(-45), detail: "node (74%)"),
                SystemAlert(kind: .temp, value: "91 °C", since: Date().addingTimeInterval(-30), detail: "node (74%)"),
            ]
        }
        UpdateStore.shared.loadDemo(ProcessInfo.processInfo.environment["AGENTSTATS_FAKE_UPDATE"] != nil
            ? Release(version: "1.19", page: URL(string: "https://github.com/HamiltonPrado/agentstats/releases")!) : nil)
        var failed = false
        for scheme in [ColorScheme.light, .dark] {
            let dark = scheme == .dark
            for tab in Tab.allCases {
                let view = PanelView(forcedTab: tab, scrollable: false)
                    .fixedSize(horizontal: false, vertical: true)
                    .environment(m)
                    .environment(\.colorScheme, scheme)
                    .environment(\.controlActiveState, .key)
                    .background(Color.panel)   // os cantos, que no popover são recortados
                let file = folder.appendingPathComponent("\(tab.rawValue)-\(dark ? "dark" : "light").png")
                if !render(AnyView(view), dark: dark, scale: 2, to: file) { failed = true }
            }
        }
        let bar = MenuBarLabel().environment(m).padding(4).background(Color.white)
        if !render(AnyView(bar), dark: false, scale: 3, to: folder.appendingPathComponent("menubar.png")) { failed = true }
        if failed {
            print("não consegui gravar todas as capturas em \(dir)")
            exit(1)
        }
    }

    /// Com uma janela a sério, e não com o ImageRenderer, que desenha os controlos do AppKit como blocos amarelos.
    /// Só desenha a própria vista: não capta o ecrã.
    private static func render(_ view: AnyView, dark: Bool, scale: CGFloat, to file: URL) -> Bool {
        let host = NSHostingView(rootView: view)
        let window = Window(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        // As animações e os onAppear podem mudar a altura.
        let size = host.fittingSize
        window.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        defer { window.close() }

        guard size.width > 0, size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        rep.size = size
        host.cacheDisplay(in: NSRect(origin: .zero, size: size), to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        do { try png.write(to: file) } catch { return false }
        return true
    }
}
