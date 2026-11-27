import SwiftUI

// As peças comuns das Definições (grupos, linhas, limites) e a lógica dos perfis e da ordem das métricas.
// No ficheiro principal ficam só as secções.
extension SettingsView {
    /// `title` nil: o primeiro grupo de uma secção com o mesmo nome do separador não repete o título.
    func group<C: View>(_ title: String?, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            if let title {
                Text(L(title)).font(DS.meta.weight(.medium)).foregroundStyle(Color.text2)
                    .padding(.leading, DS.xs)
            }
            content().cardStyle()
        }
    }

    var metricSettings: [MenuBarMetricSetting] {
        [
            .init(id: "agents", icon: "terminal", title: "Agentes", subtitle: "A trabalhar e total", isEnabled: $showAgents),
            .init(id: "cpu", icon: "cpu", title: "CPU", isEnabled: $showCPU),
            .init(id: "ram", icon: "memorychip", title: "Memória", isEnabled: $showRAM),
            .init(id: "temp", icon: "thermometer.medium", title: "Temperatura", subtitle: "Máximo da CPU", isEnabled: $showTemp),
            .init(id: "gpu", icon: "cube", title: "GPU", isEnabled: $showGPU),
            .init(id: "net", icon: "network", title: "Rede", subtitle: "Upload e download", isEnabled: $showNet),
            .init(id: "battery", icon: "battery.75percent", title: "Bateria", isEnabled: $showBattery),
        ]
    }

    var orderedMetrics: [MenuBarMetricSetting] {
        let byID = Dictionary(uniqueKeysWithValues: metricSettings.map { ($0.id, $0) })
        let defaults = metricSettings.map(\.id)
        var seen = Set<String>()
        var ids = barOrder.split(separator: ",").map(String.init)
            .filter { byID[$0] != nil && seen.insert($0).inserted }
        ids += defaults.filter { seen.insert($0).inserted }
        return ids.compactMap { byID[$0] }
    }

    var accentColorBinding: Binding<Color> {
        Binding(get: { Color(hexRGB: accentHex) }, set: { accentHex = $0.hexRGB })
    }

    var currentSnapshot: SettingsSnapshot {
        SettingsSnapshot(
            barOrder: barOrder,
            showAgents: showAgents, showCPU: showCPU, showRAM: showRAM, showTemp: showTemp,
            showGPU: showGPU, showNet: showNet, showBattery: showBattery,
            showUsage: showUsage, showActivity: showActivity,
            showRecentSection: showRecentSection, showHistorySection: showHistorySection,
            density: densityRawValue, theme: appearanceThemeRaw, accentHex: accentHex, showLimits: showLimits
        )
    }

    func selectProfile(_ profile: String) {
        savedProfile.value = nil
        activeProfile = profile
        guard profile != "custom" else { return }

        let saved = profile == "work" ? workProfileData : monitoringProfileData
        if let data = saved.data(using: .utf8), let snapshot = try? JSONDecoder().decode(SettingsSnapshot.self, from: data) {
            apply(snapshot)
        } else {
            apply(profile == "work" ? .workDefault : .monitoringDefault)
        }
    }

    func saveActiveProfile() {
        guard activeProfile != "custom",
              let data = try? JSONEncoder().encode(currentSnapshot),
              let json = String(data: data, encoding: .utf8) else { return }
        if activeProfile == "work" { workProfileData = json }
        else { monitoringProfileData = json }
        savedProfile.value = activeProfile
    }

    func apply(_ snapshot: SettingsSnapshot) {
        barOrder = snapshot.barOrder
        showAgents = snapshot.showAgents; showCPU = snapshot.showCPU; showRAM = snapshot.showRAM
        showTemp = snapshot.showTemp; showGPU = snapshot.showGPU; showNet = snapshot.showNet
        showBattery = snapshot.showBattery
        showUsage = snapshot.showUsage; showActivity = snapshot.showActivity
        showRecentSection = snapshot.showRecentSection; showHistorySection = snapshot.showHistorySection
        densityRawValue = snapshot.density
        appearanceThemeRaw = snapshot.theme
        accentHex = snapshot.accentHex
        if let limits = snapshot.showLimits { showLimits = limits }
    }

    func moveMetric(_ dragged: String?, to target: String) -> Bool {
        var ids = orderedMetrics.map(\.id)
        guard let dragged, dragged != target, let from = ids.firstIndex(of: dragged), let to = ids.firstIndex(of: target) else { return false }
        ids.remove(at: from)
        ids.insert(dragged, at: to)
        barOrder = ids.joined(separator: ",")
        return true
    }

    func moveMetric(from index: Int, by offset: Int) {
        var ids = orderedMetrics.map(\.id)
        let destination = index + offset
        guard ids.indices.contains(index), ids.indices.contains(destination) else { return }
        ids.swapAt(index, destination)
        barOrder = ids.joined(separator: ",")
    }

    /// Limite de um alerta: qualquer valor no intervalo, com o valor escrito ao lado.
    func limit(_ title: String, _ value: Binding<Double>, in range: ClosedRange<Double>, step: Double,
                       format: @escaping (Double) -> String) -> some View {
        HStack(spacing: DS.md) {
            // Sem "step" no Slider: o macOS desenhava uma marca por passo. Arredonda-se aqui.
            Slider(value: Binding(get: { value.wrappedValue },
                                  set: { value.wrappedValue = min(max(($0 / step).rounded() * step, range.lowerBound), range.upperBound) }),
                   in: range)
                .controlSize(.small)
                .accessibilityLabel(L(title))
                .accessibilityValue(L(format(value.wrappedValue)))
            Text(L(format(value.wrappedValue)))
                .font(DS.body.monospacedDigit())
                .lineLimit(1).fixedSize()
                .frame(minWidth: 48, alignment: .trailing)
        }
        .padding(.leading, 28)
    }

    /// Ícones de linha, todos do mesmo tamanho e na cor do texto secundário.
    func icon(_ name: String) -> some View {
        Image(systemName: name).font(DS.body).foregroundStyle(Color.text2).frame(width: 16)
    }

    func row(_ iconName: String, _ title: String, _ sub: String?, _ binding: Binding<Bool>) -> some View {
        HStack(spacing: DS.md) {
            icon(iconName)
            VStack(alignment: .leading, spacing: 2) {
                Text(L(title)).font(DS.body).lineLimit(1)
                if let sub { Text(L(sub)).font(DS.meta).foregroundStyle(Color.text3).lineLimit(2) }
            }
            Spacer()
            Toggle("", isOn: binding).toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
    }
}
