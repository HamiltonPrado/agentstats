import AppKit
import SwiftUI

/// Boas-vindas na primeira vez: o que é a app, onde está e que permissões pode vir a pedir (só quando usares).
enum Welcome {
    static let shownKey = "welcome.shown"

    /// Só para quem nunca abriu a app: quem atualiza já tem preferências guardadas.
    static func shouldShow(_ d: UserDefaults = .standard) -> Bool {
        guard !d.bool(forKey: shownKey) else { return false }
        return d.object(forKey: "panel.tab2") == nil && d.object(forKey: "settings.section") == nil
    }
}

@MainActor
final class WelcomeWindow {
    static var window: NSWindow?

    static func show() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 560), styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = L("Bem-vindo ao AgentStats")
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: WelcomeView {
            UserDefaults.standard.set(true, forKey: Welcome.shownKey)
            window?.close()
            window = nil
            AppState.controller?.togglePanel()
        })
        w.center()
        window = w
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        UserDefaults.standard.set(true, forKey: Welcome.shownKey)
    }
}

struct WelcomeView: View {
    let start: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.lg) {
            HStack(spacing: DS.md) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("AgentStats").font(.title2.weight(.semibold))
                    Text("Agentes de IA e o teu Mac, na barra de menus").font(DS.body).foregroundStyle(Color.text2)
                }
            }
            VStack(alignment: .leading, spacing: DS.md) {
                tip("cursorarrow.click", "Clica no ícone na barra de menus", "Abre o painel. Clicar fora fecha-o.")
                tip("contextualmenu.and.cursorarrow", "Botão direito no ícone", "Menu rápido: separadores, modo escuro, Definições e Sair.")
                tip("keyboard", "Atalhos", "⌘1–7 mudam de separador dentro do painel; ⌘, abre as Definições.")
                tip("hand.raised", "Permissões só quando precisas", "O macOS pede-as na primeira vez que usares a captura, o mixer ou a limpeza do teclado. Nada é enviado: tudo fica neste Mac.")
            }
            Spacer(minLength: 0)
            HStack {
                Button("Ver as Definições") {
                    UserDefaults.standard.set(true, forKey: Welcome.shownKey)
                    NSApp.keyWindow?.close()
                    AppState.controller?.openSettings()
                }
                Spacer()
                Button("Começar", action: start).keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.lg + DS.sm)
        .frame(width: 460, height: 560, alignment: .topLeading)
    }

    private func tip(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: DS.md) {
            Image(systemName: symbol).font(.title3).foregroundStyle(Color.accentColor).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(L(title)).font(DS.body.weight(.medium))
                Text(L(text)).font(DS.meta).foregroundStyle(Color.text2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
