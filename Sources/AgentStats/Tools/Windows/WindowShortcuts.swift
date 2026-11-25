import AppKit
import Carbon.HIToolbox

/// Atalhos globais das janelas (⌃⌥ com setas e letras, como no Rectangle). Ids a partir de 100.
@MainActor
enum WindowShortcuts {
    static let enabledKey = "windows.shortcuts"
    static let firstID: UInt32 = 100

    private static let ctrlOpt = UInt32(controlKey | optionKey)
    private static let ctrlOptCmd = UInt32(controlKey | optionKey | cmdKey)

    static let map: [(action: WindowAction, combo: GlobalHotKey.Combo)] = [
        (.leftHalf, .init(keyCode: UInt32(kVK_LeftArrow), modifiers: ctrlOpt, label: "⌃⌥←")),
        (.rightHalf, .init(keyCode: UInt32(kVK_RightArrow), modifiers: ctrlOpt, label: "⌃⌥→")),
        (.topHalf, .init(keyCode: UInt32(kVK_UpArrow), modifiers: ctrlOpt, label: "⌃⌥↑")),
        (.bottomHalf, .init(keyCode: UInt32(kVK_DownArrow), modifiers: ctrlOpt, label: "⌃⌥↓")),
        (.topLeft, .init(keyCode: UInt32(kVK_ANSI_U), modifiers: ctrlOpt, label: "⌃⌥U")),
        (.topRight, .init(keyCode: UInt32(kVK_ANSI_I), modifiers: ctrlOpt, label: "⌃⌥I")),
        (.bottomLeft, .init(keyCode: UInt32(kVK_ANSI_J), modifiers: ctrlOpt, label: "⌃⌥J")),
        (.bottomRight, .init(keyCode: UInt32(kVK_ANSI_K), modifiers: ctrlOpt, label: "⌃⌥K")),
        (.firstThird, .init(keyCode: UInt32(kVK_ANSI_D), modifiers: ctrlOpt, label: "⌃⌥D")),
        (.centerThird, .init(keyCode: UInt32(kVK_ANSI_F), modifiers: ctrlOpt, label: "⌃⌥F")),
        (.lastThird, .init(keyCode: UInt32(kVK_ANSI_G), modifiers: ctrlOpt, label: "⌃⌥G")),
        (.firstTwoThirds, .init(keyCode: UInt32(kVK_ANSI_E), modifiers: ctrlOpt, label: "⌃⌥E")),
        (.lastTwoThirds, .init(keyCode: UInt32(kVK_ANSI_T), modifiers: ctrlOpt, label: "⌃⌥T")),
        (.maximize, .init(keyCode: UInt32(kVK_Return), modifiers: ctrlOpt, label: "⌃⌥↩")),
        (.center, .init(keyCode: UInt32(kVK_ANSI_C), modifiers: ctrlOpt, label: "⌃⌥C")),
        (.nextDisplay, .init(keyCode: UInt32(kVK_RightArrow), modifiers: ctrlOptCmd, label: "⌃⌥⌘→")),
        (.previousDisplay, .init(keyCode: UInt32(kVK_LeftArrow), modifiers: ctrlOptCmd, label: "⌃⌥⌘←")),
    ]

    static func label(_ action: WindowAction) -> String? { map.first { $0.action == action }?.combo.label }

    static var enabled: Bool { Pref.bool(enabledKey, true) }

    private static var keys: [GlobalHotKey] = []

    /// Regista ou tira todos, conforme a preferência. Os que outra app já usa ficam por registar.
    static func update() {
        if keys.isEmpty {
            for (i, entry) in map.enumerated() {
                let id = firstID + UInt32(i)
                keys.append(GlobalHotKey(id: id))
                let action = entry.action
                GlobalHotKey.handlers[id] = { WindowMover.apply(action) }
            }
        }
        let on = enabled
        for (i, entry) in map.enumerated() { keys[i].register(on ? entry.combo : nil) }
    }
}
