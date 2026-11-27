import Foundation

/// As métricas que podem aparecer na barra de menus: a chave da preferência e o valor por omissão num só sítio
/// (estavam repetidos nas Definições, no desenho do ícone e no controlador, e podiam discordar).
enum MenuBarMetric: String, CaseIterable {
    case agents, cpu, ram, gpu, temp, net, battery

    var key: String { "bar." + rawValue }

    var defaultOn: Bool {
        switch self {
        case .gpu, .battery: false
        default: true
        }
    }

    var isOn: Bool { Pref.bool(key, defaultOn) }

    /// A ordem por omissão, como fica guardada em `MenuBarDrawer.metricOrderKey`.
    static let defaultOrder = allCases.map(\.rawValue).joined(separator: ",")
}
