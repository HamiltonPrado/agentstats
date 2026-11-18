import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var m: Monitor
    @AppStorage("bar.agents") var showAgents = true
    @AppStorage("bar.cpu") var showCPU = true
    @AppStorage("bar.ram") var showRAM = true
    @AppStorage("bar.temp") var showTemp = true
    @AppStorage("bar.gpu") var showGPU = false
    @AppStorage("bar.net") var showNet = true
    @AppStorage("bar.battery") var showBattery = false
    @StateObject private var login = Box(SMAppService.mainApp.status == .enabled)
    @StateObject private var loginErr = Box<String?>(nil)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            group("Barra de menus") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pré-visualização").font(.system(size: 10)).foregroundStyle(.tertiary)
                    MenuBarLabel()
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                    Divider().opacity(0.5)
                    row("sparkles", .purple, "Agentes", "A trabalhar / total", $showAgents)
                    row("cpu", .blue, "CPU", nil, $showCPU)
                    row("memorychip", .purple, "Memória", nil, $showRAM)
                    row("thermometer.medium", .orange, "Temperatura", "Máximo da CPU", $showTemp)
                    row("cube.transparent", .teal, "GPU", nil, $showGPU)
                    row("network", .blue, "Rede", "Upload e download", $showNet)
                    row("battery.75percent", .green, "Bateria", nil, $showBattery)
                }
            }

            group("Geral") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        icon("arrow.clockwise", .gray)
                        Text("Atualizar a cada").font(.system(size: 12))
                        Spacer()
                        Picker("", selection: Binding(
                            get: { m.refreshInterval },
                            set: { m.refreshInterval = $0; m.restart() })) {
                            Text("1 s").tag(1.0); Text("2 s").tag(2.0); Text("5 s").tag(5.0)
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 130)
                    }
                    row("bell.badge", .red, "Notificações", "Quando um agente termina", $m.notifyOnFinish)
                    row("power", .green, "Abrir ao iniciar sessão", nil, Binding(
                        get: { login.value },
                        set: { on in
                            do {
                                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                                login.value = on; loginErr.value = nil
                            } catch { loginErr.value = error.localizedDescription }
                        }))
                    if let e = loginErr.value { Text(e).font(.caption).foregroundStyle(.red) }
                }
            }

            HStack {
                Text("AgentStats 1.1").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Link("Código no GitHub", destination: URL(string: "https://github.com/HamiltonPrado/agentstats")!)
                    .font(.system(size: 10.5))
            }
            .padding(.horizontal, 4)
        }
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.system(size: 10, weight: .bold)).tracking(0.6).foregroundStyle(.secondary)
                .padding(.leading, 4)
            content().cardStyle()
        }
    }

    private func icon(_ name: String, _ color: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.gradient)
            Image(systemName: name).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white)
        }
        .frame(width: 22, height: 22)
    }

    private func row(_ iconName: String, _ color: Color, _ title: String, _ sub: String?, _ binding: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            icon(iconName, color)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 12))
                if let sub { Text(sub).font(.system(size: 10)).foregroundStyle(.tertiary) }
            }
            Spacer()
            Toggle("", isOn: binding).toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
    }
}
