import AppKit
import UniformTypeIdentifiers

/// Painéis de gravar e abrir para os ficheiros das definições e do CSV.
@MainActor
enum SettingsFiles {
    static func exportSettings() async -> String? {
        guard let url = await FilePanels.save(name: L("AgentStats definições.plist"), types: [.propertyList]) else { return nil }
        do {
            try SettingsTransfer.data(UserDefaults.standard.dictionaryRepresentation()).write(to: url, options: .atomic)
            return "Definições guardadas."
        } catch {
            return "Não consegui guardar o ficheiro."
        }
    }

    static func importSettings(into monitor: Monitor) async -> String? {
        guard let url = await FilePanels.open(types: [.propertyList]).first else { return nil }
        guard let data = try? Data(contentsOf: url), let dict = SettingsTransfer.read(data) else { return "Esse ficheiro não tem definições do AgentStats." }
        let keep = SettingsTransfer.filtered(dict)
        guard !keep.isEmpty else { return "Esse ficheiro não tem definições do AgentStats." }
        for (k, v) in keep { UserDefaults.standard.set(v, forKey: k) }
        monitor.reloadFromDefaults()
        return String(localized: "\(keep.count) definições importadas.")
    }

    static func exportCSV(_ usage: UsageSnapshot) async {
        guard let url = await FilePanels.save(name: String(localized: "AgentStats uso \(Budget.day(Date(), .current)).csv"),
                                              types: [.commaSeparatedText]) else { return }
        do { try Data(UsageCSV.make(usage).utf8).write(to: url, options: .atomic) } catch { FilePanels.reportSaveFailure() }
    }
}
