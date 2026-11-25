import AppKit

/// Tradução de um texto em tempo de execução, pela tabela `Localizable.strings` do idioma do sistema.
/// O português é a língua de origem: sem tradução, fica o texto tal como está. Não interpreta `%`.
func L(_ s: String) -> String {
    s.isEmpty ? s : Bundle.main.localizedString(forKey: s, value: s, table: nil)
}

/// A app está em inglês nesta execução? (O idioma só muda ao reabrir.) Sem a tabela carregada,
/// como nos testes, é português.
let appIsEnglish: Bool = L("Hoje") == "Today"


/// O idioma da app, à parte do sistema. Fica em `AppleLanguages` do próprio AgentStats e vale a partir da reabertura.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, pt, en
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: L("Igual ao sistema")
        case .pt: "Português"
        case .en: "English"
        }
    }

    static var current: AppLanguage {
        guard let list = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "local.agentstats")?["AppleLanguages"] as? [String],
              let first = list.first else { return .system }
        return first.hasPrefix("pt") ? .pt : first.hasPrefix("en") ? .en : .system
    }

    func apply() {
        switch self {
        case .system: UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        case .pt: UserDefaults.standard.set(["pt-PT"], forKey: "AppleLanguages")
        case .en: UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
        }
    }

    /// Abre outra instância e sai desta, para o idioma novo entrar.
    @MainActor static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
