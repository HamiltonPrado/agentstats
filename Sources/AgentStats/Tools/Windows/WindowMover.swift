import AppKit
import ApplicationServices

/// Mexe na janela da frente pela Acessibilidade. O AgentStats nunca é o alvo: com o painel aberto,
/// a janela é a da app que estava à frente antes de o abrir.
@MainActor
enum WindowMover {
    enum Outcome: Equatable { case moved, noPermission, noWindow, refused }

    @discardableResult
    static func apply(_ action: WindowAction) -> Outcome {
        guard AXIsProcessTrusted() else {
            // A constante kAXTrustedCheckOptionPrompt é uma var global, que o Swift 6 não deixa usar.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            return .noPermission
        }
        guard let app = targetApp(), let window = focusedWindow(of: app),
              let axFrame = frame(of: window) else { return .noWindow }

        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let current = WindowLayout.flipped(axFrame, primaryHeight: primaryHeight)
        let screens = NSScreen.screens.map(\.visibleFrame)
        guard let index = WindowLayout.screenIndex(for: current, in: screens) else { return .noWindow }

        let target: CGRect
        if action.changesDisplay {
            guard let other = WindowLayout.neighbour(of: index, in: screens, forward: action == .nextDisplay) else { return .noWindow }
            target = WindowLayout.moved(current, from: screens[index], to: screens[other])
        } else {
            let step = WindowLayout.cycled(action, current: current, in: screens[index])
            target = WindowLayout.frame(step, in: screens[index], window: current)
        }
        return set(window, to: WindowLayout.flipped(target, primaryHeight: primaryHeight)) ? .moved : .refused
    }

    /// A app da frente, ou a de antes do painel se o AgentStats estiver à frente.
    private static func targetApp() -> NSRunningApplication? {
        let me = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != me { return front }
        if let previous = QuickPaste.previousApp, !previous.isTerminated { return previous }
        return nil
    }

    private static func focusedWindow(of app: NSRunningApplication) -> AXUIElement? {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            // Só se confia no tipo depois de o confirmar: uma app pode devolver outra coisa.
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value,
               CFGetTypeID(value) == AXUIElementGetTypeID() {
                return (value as! AXUIElement)
            }
        }
        return nil
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let pos, let size, CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pos as! AXValue, .cgPoint, &p)
        AXValueGetValue(size as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    /// Tamanho, posição e outra vez tamanho: ao mudar de ecrã, algumas apps limitam o tamanho ao ecrã antigo.
    private static func set(_ window: AXUIElement, to r: CGRect) -> Bool {
        var size = r.size, origin = r.origin
        guard let s = AXValueCreate(.cgSize, &size), let p = AXValueCreate(.cgPoint, &origin) else { return false }
        _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, s)
        let moved = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, p)
        let resized = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, s)
        return moved == .success || resized == .success
    }
}
