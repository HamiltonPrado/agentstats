import SwiftUI

// Os tipos das Definições que não são vista: as métricas, os perfis guardados e as secções.

struct MenuBarMetricSetting: Identifiable {
    let id: String
    let icon: String
    let title: String
    var subtitle: String? = nil
    let isEnabled: Binding<Bool>
}

struct SettingsSnapshot: Codable, Equatable {
    let barOrder: String
    let showAgents: Bool
    let showCPU: Bool
    let showRAM: Bool
    let showTemp: Bool
    let showGPU: Bool
    let showNet: Bool
    let showBattery: Bool
    let showUsage: Bool
    let showActivity: Bool
    let showRecentSection: Bool
    let showHistorySection: Bool
    let density: String
    let theme: String
    let accentHex: String
    /// Opcional: os perfis gravados antes de existir continuam a ler-se (nil = não mexe).
    var showLimits: Bool? = nil

    static let workDefault = SettingsSnapshot(
        barOrder: "agents,cpu,ram,temp,net,gpu,battery",
        showAgents: true, showCPU: true, showRAM: true, showTemp: true,
        showGPU: false, showNet: true, showBattery: false,
        showUsage: true, showActivity: false, showRecentSection: true, showHistorySection: false,
        density: PanelDensity.compact.rawValue, theme: PanelTheme.system.rawValue, accentHex: PrefKey.defaultAccentHex
    )

    static let monitoringDefault = SettingsSnapshot(
        barOrder: MenuBarMetric.defaultOrder,
        showAgents: true, showCPU: true, showRAM: true, showTemp: true,
        showGPU: true, showNet: true, showBattery: true,
        showUsage: true, showActivity: true, showRecentSection: true, showHistorySection: true,
        density: PanelDensity.detailed.rawValue, theme: PanelTheme.dark.rawValue, accentHex: PrefKey.defaultAccentHex
    )
}

/// Secções das Definições.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, menuBar, panel, appearance, alerts, rules
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "Geral"
        case .menuBar: "Barra"
        case .panel: "Painel"
        case .appearance: "Aspeto"
        case .alerts: "Alertas"
        case .rules: "Regras"
        }
    }
}
