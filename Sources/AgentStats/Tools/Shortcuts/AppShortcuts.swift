import AppKit
import ApplicationServices

/// Os atalhos de teclado de uma app, lidos dos menus dela pela Acessibilidade.
struct ShortcutSection: Identifiable, Equatable, Sendable {
    var id: String { menu }
    let menu: String
    var items: [ShortcutItem]
}

struct ShortcutItem: Identifiable, Equatable, Sendable {
    var id: String { title + keys }
    let title: String
    let keys: String
}

enum AppShortcuts {
    // kAXMenuItemModifiers: sem nada é ⌘; os bits acrescentam ⇧ ⌥ ⌃ ou tiram o ⌘.
    static let shiftBit = 1, optionBit = 2, controlBit = 4, noCommandBit = 8

    private static let specialKeys: [Int: String] = [
        0x24: "↩", 0x30: "⇥", 0x31: L("Espaço"), 0x33: "⌫", 0x35: "⎋", 0x75: "⌦", 0x73: "↖", 0x77: "↘", 0x74: "⇞", 0x79: "⇟",
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑", 0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6",
        0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
    ]

    /// "⌃⌥⇧⌘K", pela ordem do macOS. nil se o item não tiver atalho.
    static func label(char: String?, modifiers: Int, virtualKey: Int?) -> String? {
        let key: String
        if let c = char?.trimmingCharacters(in: .whitespaces), !c.isEmpty, c.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) {
            key = c.uppercased()
        } else if let v = virtualKey, let special = specialKeys[v] {
            key = special
        } else {
            return nil
        }
        var s = ""
        if modifiers & controlBit != 0 { s += "⌃" }
        if modifiers & optionBit != 0 { s += "⌥" }
        if modifiers & shiftBit != 0 { s += "⇧" }
        if modifiers & noCommandBit == 0 { s += "⌘" }
        return s + key
    }

    /// Lê os menus da app (sem o menu da Apple). Bloqueia: chamar fora do main thread.
    static func read(pid: pid_t) -> [ShortcutSection] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.5)
        guard let bar: AXUIElement = attribute(app, kAXMenuBarAttribute) else { return [] }
        let tops: [AXUIElement] = attribute(bar, kAXChildrenAttribute) ?? []
        var out: [ShortcutSection] = []
        for top in tops.dropFirst() {   // o primeiro é o menu da Apple
            let title: String = attribute(top, kAXTitleAttribute) ?? ""
            var items: [ShortcutItem] = []
            collect(top, into: &items, depth: 0)
            if !title.isEmpty, !items.isEmpty { out.append(ShortcutSection(menu: title, items: items)) }
        }
        return out
    }

    private static func collect(_ element: AXUIElement, into items: inout [ShortcutItem], depth: Int) {
        guard depth < 4 else { return }
        let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) ?? []
        for child in children {
            let title: String = attribute(child, kAXTitleAttribute) ?? ""
            let char: String? = attribute(child, kAXMenuItemCmdCharAttribute)
            let mods: Int = attribute(child, kAXMenuItemCmdModifiersAttribute) ?? 0
            let vkey: Int? = attribute(child, kAXMenuItemCmdVirtualKeyAttribute)
            if !title.isEmpty, let keys = label(char: char, modifiers: mods, virtualKey: vkey),
               !items.contains(where: { $0.keys == keys }) {
                items.append(ShortcutItem(title: title, keys: keys))
            }
            collect(child, into: &items, depth: depth + 1)
        }
    }

    private static func attribute<T>(_ el: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success, let value else { return nil }
        if T.self == Int.self, let n = value as? NSNumber { return n.intValue as? T }
        return value as? T
    }
}
