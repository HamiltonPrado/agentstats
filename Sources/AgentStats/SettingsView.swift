import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @Environment(Monitor.self) private var m
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
        @Bindable var m = m
        VStack(alignment: .leading, spacing: DS.lg) {
            group("Barra de menus") {
                VStack(alignment: .leading, spacing: DS.md) {
                    MenuBarLabel()
                        .padding(.horizontal, DS.sm).padding(.vertical, DS.xs)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .background(RoundedRectangle(cornerRadius: DS.rSmall, style: .continuous).fill(DS.raised))
                        .help("Pré-visualização")
                    row("terminal", "Agentes", "A trabalhar e total", $showAgents)
                    row("cpu", "CPU", nil, $showCPU)
                    row("memorychip", "Memória", nil, $showRAM)
                    row("thermometer.medium", "Temperatura", "Máximo da CPU", $showTemp)
                    row("cube", "GPU", nil, $showGPU)
                    row("network", "Rede", "Upload e download", $showNet)
                    row("battery.75percent", "Bateria", nil, $showBattery)
                }
            }

            group("Alertas") {
                VStack(alignment: .leading, spacing: DS.md) {
                    row("cpu", "CPU alta", "Notifica após 20 s acima do limite", $m.cpuAlertEnabled)
                    if m.cpuAlertEnabled {
                        Picker("", selection: $m.cpuThreshold) {
                            Text("70%").tag(0.7); Text("80%").tag(0.8); Text("85%").tag(0.85); Text("90%").tag(0.9); Text("95%").tag(0.95)
                        }
                        .pickerStyle(.segmented).labelsHidden().padding(.leading, 28)
                    }
                    row("thermometer.high", "Temperatura alta", "Máximo da CPU", $m.tempAlertEnabled)
                    if m.tempAlertEnabled {
                        Picker("", selection: $m.tempThreshold) {
                            Text("75°").tag(75.0); Text("80°").tag(80.0); Text("85°").tag(85.0); Text("90°").tag(90.0); Text("95°").tag(95.0)
                        }
                        .pickerStyle(.segmented).labelsHidden().padding(.leading, 28)
                    }
                }
            }

            group("Geral") {
                VStack(alignment: .leading, spacing: DS.md) {
                    HStack(spacing: DS.md) {
                        icon("arrow.clockwise")
                        Text("Atualizar a cada").font(DS.body)
                        Spacer()
                        Picker("", selection: $m.refreshInterval) {
                            Text("1 s").tag(1.0); Text("2 s").tag(2.0); Text("5 s").tag(5.0)
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 128)
                    }
                    row("bell", "Notificações", "Ao terminar e quando precisa de ti", $m.notifyOnFinish)
                    row("power", "Abrir ao iniciar sessão", nil, Binding(
                        get: { login.value },
                        set: { on in
                            do {
                                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                                login.value = on; loginErr.value = nil
                            } catch { loginErr.value = error.localizedDescription }
                        }))
                    if let e = loginErr.value { Text(e).font(DS.meta).foregroundStyle(.red) }
                }
            }

            HStack {
                Text("AgentStats 1.5").font(DS.meta).foregroundStyle(.tertiary)
                Spacer()
                Link("Código no GitHub", destination: URL(string: "https://github.com/HamiltonPrado/agentstats")!)
                    .font(DS.meta)
            }
            .padding(.horizontal, DS.xs)
        }
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            Text(title).font(DS.meta.weight(.medium)).foregroundStyle(.secondary)
                .padding(.leading, DS.xs)
            content().cardStyle()
        }
    }

    /// Ícones de linha, todos do mesmo tamanho e na cor do texto secundário.
    private func icon(_ name: String) -> some View {
        Image(systemName: name).font(DS.body).foregroundStyle(.secondary).frame(width: 16)
    }

    private func row(_ iconName: String, _ title: String, _ sub: String?, _ binding: Binding<Bool>) -> some View {
        HStack(spacing: DS.md) {
            icon(iconName)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(DS.body)
                if let sub { Text(sub).font(DS.meta).foregroundStyle(.tertiary) }
            }
            Spacer()
            Toggle("", isOn: binding).toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
    }
}
