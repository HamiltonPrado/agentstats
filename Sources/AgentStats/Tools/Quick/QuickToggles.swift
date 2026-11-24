import AppKit
import SwiftUI

/// Interruptores rápidos do macOS: modo escuro, ícones da secretária e Não incomodar.
enum QuickToggles {
    static let darkModeScript = "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"
    /// O atalho que o utilizador cria na app Atalhos: o macOS não deixa mudar o Foco de outra forma.
    static let focusShortcutNames = ["Não incomodar", "Nao incomodar", "Do Not Disturb"]

    static var isDark: Bool {
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleInterfaceStyle"] as? String == "Dark"
    }

    /// Sem a chave, os ícones aparecem (é o normal).
    static func desktopIconsShown(_ value: Any?) -> Bool { (value as? Bool) ?? (value as? NSNumber)?.boolValue ?? true }
    static var desktopIconsShown: Bool {
        desktopIconsShown(CFPreferencesCopyAppValue("CreateDesktop" as CFString, "com.apple.finder" as CFString))
    }

    /// O nome do atalho de Foco, se existir (`shortcuts list`, um por linha).
    static func focusShortcut(in list: String) -> String? {
        let names = list.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        return focusShortcutNames.first { wanted in names.contains { $0.caseInsensitiveCompare(wanted) == .orderedSame } }
            .flatMap { wanted in names.first { $0.caseInsensitiveCompare(wanted) == .orderedSame } }
    }
}

@MainActor
final class QuickTogglesStore: ObservableObject {
    static let shared = QuickTogglesStore()

    @Published private(set) var dark = QuickToggles.isDark
    @Published private(set) var iconsShown = QuickToggles.desktopIconsShown
    @Published private(set) var focusShortcut: String?
    @Published private(set) var checkedShortcuts = false
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published var explainFocus = false
    private var demo = false

    func refresh() async {
        guard !demo else { return }
        dark = QuickToggles.isDark
        iconsShown = QuickToggles.desktopIconsShown
        let list = await ToolRunner.run("/usr/bin/shortcuts", ["list"], timeout: 15)
        focusShortcut = QuickToggles.focusShortcut(in: list.out)
        checkedShortcuts = true
    }

    /// Pede autorização para controlar o System Events na primeira vez.
    func toggleDarkMode() async {
        guard !demo, !busy else { return }
        busy = true
        message = nil
        let r = await ToolRunner.run("/usr/bin/osascript", ["-e", QuickToggles.darkModeScript], timeout: 30)
        if !r.ok {
            message = r.err.contains("-1743")
                ? "Falta autorização: Definições do Sistema → Privacidade e Segurança → Automação → AgentStats → System Events."
                : "Não consegui mudar o modo escuro."
        }
        try? await Task.sleep(for: .milliseconds(300))
        dark = QuickToggles.isDark
        busy = false
    }

    /// Escreve a preferência do Finder e reinicia-o: as janelas do Finder fecham e voltam.
    func toggleDesktopIcons() async {
        guard !demo, !busy else { return }
        busy = true
        message = nil
        let show = !iconsShown
        let w = await ToolRunner.run("/usr/bin/defaults", ["write", "com.apple.finder", "CreateDesktop", "-bool", show ? "true" : "false"], timeout: 10)
        if w.ok {
            _ = await ToolRunner.run("/usr/bin/killall", ["Finder"], timeout: 10)
            iconsShown = show
        } else {
            message = "Não consegui mudar os ícones da secretária."
        }
        busy = false
    }

    func toggleFocus() async {
        guard !demo, !busy else { return }
        guard let name = focusShortcut else {
            explainFocus = true
            return
        }
        busy = true
        message = nil
        let r = await ToolRunner.run("/usr/bin/shortcuts", ["run", name], timeout: 30)
        if !r.ok { message = "O atalho “\(name)” não correu. Abre-o na app Atalhos para ver o que falta." }
        busy = false
    }

    func openShortcuts() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app"))
    }

    func loadDemo() {
        demo = true
        dark = false
        iconsShown = true
        focusShortcut = "Não incomodar"
        checkedShortcuts = true
    }
}

struct QuickTogglesView: View {
    @ObservedObject var store: QuickTogglesStore

    var body: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            Text("Atalhos rápidos").font(DS.body.weight(.medium))
            HStack(spacing: DS.sm) {
                tile(store.dark ? "Modo claro" : "Modo escuro", store.dark ? "sun.max" : "moon", on: store.dark) {
                    Task { await store.toggleDarkMode() }
                }
                tile(store.iconsShown ? "Esconder ícones" : "Mostrar ícones", store.iconsShown ? "eye.slash" : "eye", on: !store.iconsShown) {
                    Task { await store.toggleDesktopIcons() }
                }
                .help("Esconde os ficheiros da secretária, para partilhar o ecrã. O Finder reinicia.")
                tile("Não incomodar", "moon.zzz", on: false) { Task { await store.toggleFocus() } }
                    .help(store.focusShortcut.map { "Corre o atalho “\($0)”" } ?? "Precisa de um atalho na app Atalhos")
            }
            .disabled(store.busy)
            if store.explainFocus && store.focusShortcut == nil {
                VStack(alignment: .leading, spacing: DS.xs) {
                    note("O macOS só deixa mudar o Foco pela app Atalhos. Cria lá um atalho chamado “Não incomodar” com a ação “Definir Foco” → Não incomodar → Alternar. Depois volta aqui.", color: .text2)
                    HStack(spacing: DS.md) {
                        textLink("Abrir Atalhos") { store.openShortcuts() }
                        textLink("Já criei") { Task { await store.refresh(); if store.focusShortcut != nil { store.explainFocus = false } } }
                    }
                }
            }
            if let m = store.message { note(m, color: .attentionText) }
        }
        .cardStyle()
        .task { await store.refresh() }
    }

    private func tile(_ title: String, _ symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: DS.xs) {
                Image(systemName: symbol).font(.system(size: 15 * TextSize.current.scale, weight: .medium))
                    .foregroundStyle(on ? Color.accentColor : Color.primary).frame(height: 20)
                Text(title).font(DS.meta).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity).frame(height: 52)
            .background(RoundedRectangle(cornerRadius: DS.rControl, style: .continuous).fill(DS.raised))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
