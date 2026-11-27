import SwiftUI
import AppKit

struct MenuBarLabel: View {
    @Environment(Monitor.self) private var m
    // Não são lidas no corpo: estão aqui para o ícone se redesenhar quando se muda uma métrica nas Definições.
    @AppStorage(MenuBarMetric.agents.key) var showAgents = MenuBarMetric.agents.defaultOn
    @AppStorage(MenuBarMetric.cpu.key) var showCPU = MenuBarMetric.cpu.defaultOn
    @AppStorage(MenuBarMetric.ram.key) var showRAM = MenuBarMetric.ram.defaultOn
    @AppStorage(MenuBarMetric.gpu.key) var showGPU = MenuBarMetric.gpu.defaultOn
    @AppStorage(MenuBarMetric.net.key) var showNet = MenuBarMetric.net.defaultOn
    @AppStorage(MenuBarMetric.battery.key) var showBattery = MenuBarMetric.battery.defaultOn
    @AppStorage(MenuBarMetric.temp.key) var showTemp = MenuBarMetric.temp.defaultOn

    var body: some View {
        Image(nsImage: render())
    }

    @MainActor
    private func render() -> NSImage { MenuBarDrawer.image(m) }
}
