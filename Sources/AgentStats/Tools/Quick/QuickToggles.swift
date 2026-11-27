import AppKit
import SwiftUI

/// Interruptores rápidos do macOS: modo escuro e ícones da secretária.
enum QuickToggles {
    static let darkModeScript = "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"

    static var isDark: Bool {
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleInterfaceStyle"] as? String == "Dark"
    }

    /// Sem a chave, os ícones aparecem (é o normal).
    static func desktopIconsShown(_ value: Any?) -> Bool { (value as? Bool) ?? (value as? NSNumber)?.boolValue ?? true }
    static var desktopIconsShown: Bool {
        desktopIconsShown(CFPreferencesCopyAppValue("CreateDesktop" as CFString, "com.apple.finder" as CFString))
    }
}

@MainActor
final class QuickTogglesStore: ObservableObject {
    static let shared = QuickTogglesStore()

    @Published private(set) var dark = QuickToggles.isDark
    @Published private(set) var iconsShown = QuickToggles.desktopIconsShown
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    private var demo = false

    func refresh() async {
        guard !demo else { return }
        dark = QuickToggles.isDark
        iconsShown = QuickToggles.desktopIconsShown
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
    /// Lê o estado na hora: o guardado podia estar desatualizado e mostrar em vez de esconder.
    func toggleDesktopIcons() async {
        guard !demo, !busy else { return }
        await setDesktopIcons(shown: !QuickToggles.desktopIconsShown)
    }

    /// Põe os ícones como pedido (sem nada a fazer se já estiverem assim).
    func setDesktopIcons(shown show: Bool) async {
        guard !demo else { return }
        iconsShown = QuickToggles.desktopIconsShown
        guard show != iconsShown else { return }
        busy = true
        message = nil
        let w = await ToolRunner.run("/usr/bin/defaults", ["write", "com.apple.finder", "CreateDesktop", "-bool", show ? "true" : "false"], timeout: 10)
        if w.ok {
            _ = await ToolRunner.run("/usr/bin/killall", ["Finder"], timeout: 10)
            iconsShown = show
        } else {
            message = "Não consegui mudar os ícones da secretária."
        }
        busy = false
    }

    func loadDemo() {
        demo = true
        dark = false
        iconsShown = true
    }
}

struct QuickTogglesView: View {
    @ObservedObject var store: QuickTogglesStore
    @ObservedObject private var presentation = PresentationMode.shared

    /// Uma linha só: os atalhos não deviam empurrar as ferramentas para baixo.
    var body: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            HStack(spacing: DS.xs) {
                pill(store.dark ? "Claro" : "Escuro", store.dark ? "sun.max" : "moon", on: store.dark,
                     help: store.dark ? "Passar para o modo claro" : "Passar para o modo escuro") {
                    Task { await store.toggleDarkMode() }
                }
                pill("Ícones", store.iconsShown ? "eye" : "eye.slash", on: !store.iconsShown,
                     help: store.iconsShown ? "Esconder os ícones da secretária (o Finder reinicia)" : "Mostrar os ícones da secretária") {
                    Task { await store.toggleDesktopIcons() }
                }
                pill("Apresentar", "play.rectangle", on: presentation.active,
                     help: presentation.active ? "Sair do modo apresentação" : "Esconde os ícones, mantém o ecrã ligado, pausa o Clipboard e cala as notificações") {
                    Task { await presentation.toggle() }
                }
            }
            .disabled(store.busy)
            if let m = store.message { note(m, color: .attentionText) }
        }
        .task { await store.refresh() }
    }

    private func pill(_ title: String, _ symbol: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DS.xs) {
                Image(systemName: symbol).font(DS.meta.weight(.medium))
                Text(L(title)).font(DS.meta).lineLimit(1)
            }
            .foregroundStyle(on ? Color.accentColor : Color.primary)
            .raisedTile(height: 26)
        }
        .buttonStyle(.plain)
        .help(L(help))
        .accessibilityLabel(L(help))
    }
}
