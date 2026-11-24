import SwiftUI

/// O conteúdo da janela das Definições: o mesmo SettingsView, com o tema e a cor escolhidos.
struct SettingsWindowContent: View {
    @AppStorage("appearance.theme") private var themeRawValue = PanelTheme.system.rawValue
    @AppStorage("appearance.accentHex") private var accentHex = "#0A84FF"
    @AppStorage(TextSize.defaultsKey) private var textSizeRaw = TextSize.normal.rawValue

    var body: some View {
        ScrollView {
            SettingsView().padding(DS.lg)
        }
        .id(textSizeRaw)
        .frame(minWidth: 420, minHeight: 420)
        .background(Color.panel)
        .tint(Color(hexRGB: accentHex))
        .preferredColorScheme((PanelTheme(rawValue: themeRawValue) ?? .system).colorScheme)
        .background {
            // ⌘W fecha, como em qualquer janela.
            Button("") { NSApp.keyWindow?.performClose(nil) }.keyboardShortcut("w", modifiers: .command)
                .buttonStyle(.plain).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        }
    }
}
