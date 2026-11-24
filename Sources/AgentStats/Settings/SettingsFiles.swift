import AppKit
import UniformTypeIdentifiers

/// Painéis de gravar e abrir para os ficheiros das definições e do CSV.
@MainActor
enum SettingsFiles {
    static func exportSettings() -> String? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = L("AgentStats definições.plist")
        panel.allowedContentTypes = [.propertyList]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try SettingsTransfer.data(UserDefaults.standard.dictionaryRepresentation()).write(to: url, options: .atomic)
            return "Definições guardadas."
        } catch {
            return "Não consegui guardar o ficheiro."
        }
    }

    static func importSettings() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.propertyList]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard let data = try? Data(contentsOf: url), let dict = SettingsTransfer.read(data) else { return "Esse ficheiro não tem definições do AgentStats." }
        let keep = SettingsTransfer.filtered(dict)
        guard !keep.isEmpty else { return "Esse ficheiro não tem definições do AgentStats." }
        for (k, v) in keep { UserDefaults.standard.set(v, forKey: k) }
        return String(localized: "\(keep.count) definições importadas.")
    }

    static func exportCSV(_ usage: UsageSnapshot) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = String(localized: "AgentStats uso \(Budget.day(Date(), .current)).csv")
        panel.allowedContentTypes = [.commaSeparatedText]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Data(UsageCSV.make(usage).utf8).write(to: url, options: .atomic)
    }
}
