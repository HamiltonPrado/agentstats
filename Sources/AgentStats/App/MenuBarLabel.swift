import SwiftUI
import AppKit
import ServiceManagement
import Combine
import UserNotifications

struct MenuBarLabel: View {
    @Environment(Monitor.self) private var m
    @AppStorage("bar.agents") var showAgents = true
    @AppStorage("bar.cpu") var showCPU = true
    @AppStorage("bar.ram") var showRAM = true
    @AppStorage("bar.gpu") var showGPU = false
    @AppStorage("bar.net") var showNet = true
    @AppStorage("bar.battery") var showBattery = false
    @AppStorage("bar.temp") var showTemp = true

    var body: some View {
        Image(nsImage: render())
    }

    @MainActor
    private func render() -> NSImage { MenuBarDrawer.image(m) }

    private func cell(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: -2) {
            Text(L(title)).font(.system(size: 7, weight: .semibold))
            Text(L(value)).font(.system(size: 10, weight: .semibold).monospacedDigit())
        }
        .frame(minWidth: 24, alignment: .leading)
    }
}
