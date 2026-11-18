import SwiftUI

enum Metric: String {
    case cpu, memory, temp, gpu, disk, battery, network
}

private struct TileData {
    let title: String
    let icon: String
    let value: String
    let sub: String
    let fraction: Double?
    let color: Color
}

struct SystemView: View {
    @EnvironmentObject var m: Monitor
    @AppStorage("system.detail") private var selected: Metric = .cpu

    var body: some View {
        VStack(spacing: 10) {
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow { tile(.cpu); tile(.memory) }
                GridRow { tile(.temp); tile(.gpu) }
                GridRow { tile(.disk); tile(.battery) }
            }
            networkStrip
            detail
        }
    }

    // MARK: Mosaicos

    private func data(_ metric: Metric) -> TileData {
        switch metric {
        case .cpu:
            return TileData(title: "CPU", icon: "cpu", value: Fmt.pct(m.cpu.total),
                            sub: "Carga \(String(format: "%.1f", m.cpu.load.0)) · \(m.cpu.cores.count) núcleos",
                            fraction: m.cpu.total, color: .blue)
        case .memory:
            return TileData(title: "Memória", icon: "memorychip", value: Fmt.pct(m.memory.usage),
                            sub: "\(Fmt.bytes(m.memory.used)) de \(Fmt.bytes(m.memory.total))",
                            fraction: m.memory.usage, color: m.memory.pressure >= 2 ? .orange : .purple)
        case .temp:
            let t = m.temps?.cpuMax
            return TileData(title: "Temperatura", icon: "thermometer.medium",
                            value: t.map { String(format: "%.0f°", $0) } ?? "—",
                            sub: thermalLabel, fraction: t.map { $0 / 110 }, color: Palette.temp(t ?? 0))
        case .gpu:
            return TileData(title: "GPU", icon: "cube.transparent", value: m.gpu.map(Fmt.pct) ?? "—",
                            sub: "Utilização", fraction: m.gpu, color: .teal)
        case .disk:
            return TileData(title: "Disco", icon: "internaldrive", value: Fmt.pct(m.disk.usage),
                            sub: "\(Fmt.bytes(m.disk.free)) livres", fraction: m.disk.usage, color: Palette.usage(m.disk.usage))
        case .battery:
            guard let b = m.battery else {
                return TileData(title: "Energia", icon: "powerplug", value: "AC", sub: "Sem bateria", fraction: nil, color: .green)
            }
            let sub = b.isCharging ? "A carregar" : b.externalPower ? "Na corrente"
                : b.minutesRemaining.map { "\(Fmt.minutes($0)) restantes" } ?? "Na bateria"
            return TileData(title: "Bateria", icon: batteryIcon(b), value: Fmt.pct(b.percent), sub: sub,
                            fraction: b.percent, color: b.percent < 0.15 && !b.isCharging ? .red : b.percent < 0.3 ? .orange : .green)
        case .network:
            return TileData(title: "Rede", icon: "network", value: "", sub: "", fraction: nil, color: .blue)
        }
    }

    private func tile(_ metric: Metric) -> some View {
        let d = data(metric)
        let isSel = selected == metric
        return Button { withAnimation(.easeInOut(duration: 0.18)) { selected = metric } } label: {
            HStack(spacing: 10) {
                RingGauge(value: d.fraction, color: d.color) {
                    Image(systemName: d.icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(d.color)
                }
                .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text(d.title).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                    Text(d.value).font(.system(size: 17, weight: .bold, design: .rounded).monospacedDigit())
                    Text(d.sub).font(.system(size: 9.5)).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .cardStyle(padding: 10, highlight: isSel ? Color.accentColor.opacity(0.7) : nil)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var networkStrip: some View {
        let isSel = selected == .network
        let mx = max((m.downHistory.values + m.upHistory.values).max() ?? 1, 10_000)
        return Button { withAnimation(.easeInOut(duration: 0.18)) { selected = .network } } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Label { Text(Fmt.rate(m.network.downPerSec)).monospacedDigit() } icon: {
                        Image(systemName: "arrow.down").foregroundStyle(.blue)
                    }
                    Label { Text(Fmt.rate(m.network.upPerSec)).monospacedDigit() } icon: {
                        Image(systemName: "arrow.up").foregroundStyle(.pink)
                    }
                }
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 100, alignment: .leading)
                ZStack {
                    Sparkline(values: m.downHistory.values, maxValue: mx, color: .blue)
                    Sparkline(values: m.upHistory.values, maxValue: mx, color: .pink)
                }
                .frame(height: 34)
            }
            .cardStyle(padding: 10, highlight: isSel ? Color.accentColor.opacity(0.7) : nil)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Detalhe

    @ViewBuilder private var detail: some View {
        switch selected {
        case .cpu: cpuDetail
        case .memory: memoryDetail
        case .temp: tempDetail
        case .gpu: gpuDetail
        case .disk: diskDetail
        case .battery: batteryDetail
        case .network: networkDetail
        }
    }

    private var cpuDetail: some View {
        Card(title: "CPU", icon: "cpu", trailing: Fmt.pct(m.cpu.total), tint: .blue) {
            Sparkline(values: m.cpuHistory.values, maxValue: 1, color: .blue).frame(height: 44)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(m.cpu.cores.enumerated()), id: \.offset) { _, v in
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 2).fill(Palette.usage(v)).frame(height: max(3, 26 * v))
                    }
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.06)))
                }
            }
            .frame(height: 26)
            Divider().opacity(0.5)
            StatRow(label: "Utilizador", value: Fmt.pct(m.cpu.user), color: .blue)
            StatRow(label: "Sistema", value: Fmt.pct(m.cpu.system), color: .red)
            StatRow(label: "Carga média (1 · 5 · 15 min)",
                    value: String(format: "%.2f · %.2f · %.2f", m.cpu.load.0, m.cpu.load.1, m.cpu.load.2))
            if let p = m.pCores, let e = m.eCores { StatRow(label: "Núcleos", value: "\(p) performance + \(e) eficiência") }
            StatRow(label: "Chip", value: m.machine.replacingOccurrences(of: "Apple ", with: ""))
        }
    }

    private var memoryDetail: some View {
        Card(title: "Memória", icon: "memorychip", trailing: "\(Fmt.bytes(m.memory.used)) / \(Fmt.bytes(m.memory.total))", tint: .purple) {
            Sparkline(values: m.memHistory.values, maxValue: 1, color: .purple).frame(height: 40)
            GeometryReader { g in
                let t = Double(max(m.memory.total, 1))
                HStack(spacing: 1.5) {
                    seg(.purple, Double(m.memory.app) / t, g.size.width)
                    seg(.orange, Double(m.memory.wired) / t, g.size.width)
                    seg(.pink, Double(m.memory.compressed) / t, g.size.width)
                    seg(.gray.opacity(0.5), Double(m.memory.cached) / t, g.size.width)
                    Spacer(minLength: 0)
                }
                .background(Color.primary.opacity(0.07))
                .clipShape(Capsule())
            }
            .frame(height: 10)
            StatRow(label: "Apps", value: Fmt.bytes(m.memory.app), color: .purple)
            StatRow(label: "Wired", value: Fmt.bytes(m.memory.wired), color: .orange)
            StatRow(label: "Comprimida", value: Fmt.bytes(m.memory.compressed), color: .pink)
            StatRow(label: "Em cache", value: Fmt.bytes(m.memory.cached), color: .gray)
            Divider().opacity(0.5)
            StatRow(label: "Swap", value: "\(Fmt.bytes(m.memory.swapUsed)) / \(Fmt.bytes(m.memory.swapTotal))")
            StatRow(label: "Pressão", value: m.memory.pressure >= 4 ? "Crítica" : m.memory.pressure >= 2 ? "Elevada" : "Normal")
        }
    }

    private func seg(_ c: Color, _ f: Double, _ w: CGFloat) -> some View {
        Rectangle().fill(c).frame(width: max(0, w * f))
    }

    @ViewBuilder private var tempDetail: some View {
        if let t = m.temps { TemperatureCard(t: t, history: m.tempHistory.values, thermal: thermalLabel) }
        else { unavailable("Temperaturas", "thermometer.medium", "Os sensores de temperatura não estão disponíveis neste Mac.") }
    }

    @ViewBuilder private var gpuDetail: some View {
        if let g = m.gpu {
            Card(title: "GPU", icon: "cube.transparent", trailing: Fmt.pct(g), tint: .teal) {
                Sparkline(values: m.gpuHistory.values, maxValue: 1, color: .teal).frame(height: 50)
                StatRow(label: "Utilização atual", value: Fmt.pct(g))
                StatRow(label: "Máximo (último minuto)", value: Fmt.pct(m.gpuHistory.values.max() ?? 0))
            }
        } else { unavailable("GPU", "cube.transparent", "Não foi possível ler a utilização da GPU.") }
    }

    private var diskDetail: some View {
        Card(title: "Disco", icon: "internaldrive", trailing: "\(Fmt.bytes(m.disk.used)) / \(Fmt.bytes(m.disk.total))", tint: .green) {
            Bar(value: m.disk.usage, color: Palette.usage(m.disk.usage), height: 8)
            StatRow(label: "Usado", value: Fmt.bytes(m.disk.used))
            StatRow(label: "Livre", value: Fmt.bytes(m.disk.free))
            Divider().opacity(0.5)
            StatRow(label: "Leitura", value: Fmt.rate(m.disk.readPerSec), color: .green)
            StatRow(label: "Escrita", value: Fmt.rate(m.disk.writePerSec), color: .orange)
        }
    }

    @ViewBuilder private var batteryDetail: some View {
        if let b = m.battery {
            Card(title: "Bateria", icon: batteryIcon(b), trailing: Fmt.pct(b.percent), tint: .green) {
                Bar(value: b.percent, color: b.percent < 0.15 ? .red : .green, height: 8)
                StatRow(label: "Estado", value: b.isCharging ? "A carregar" : b.externalPower ? "Ligada à corrente" : "Na bateria")
                if let mins = b.minutesRemaining {
                    StatRow(label: b.isCharging ? "Até carga completa" : "Tempo restante", value: Fmt.minutes(mins))
                }
                if let w = b.watts, w > 0.1 { StatRow(label: "Potência", value: String(format: "%.1f W", w)) }
                if let h = b.health { StatRow(label: "Saúde", value: Fmt.pct(h)) }
                StatRow(label: "Ciclos", value: "\(b.cycles)")
                if let t = m.temps?.battery ?? b.temperature { StatRow(label: "Temperatura", value: String(format: "%.1f ºC", t)) }
            }
        } else { unavailable("Energia", "powerplug", "Este Mac não tem bateria.") }
    }

    private var networkDetail: some View {
        Card(title: "Rede", icon: "network", trailing: m.network.interface, tint: .blue) {
            StatRow(label: "Download", value: Fmt.rate(m.network.downPerSec), color: .blue)
            StatRow(label: "Upload", value: Fmt.rate(m.network.upPerSec), color: .pink)
            Divider().opacity(0.5)
            StatRow(label: "Recebido (sessão)", value: Fmt.bytes(m.network.totalDown))
            StatRow(label: "Enviado (sessão)", value: Fmt.bytes(m.network.totalUp))
            StatRow(label: "IP local", value: m.network.localIP)
        }
    }

    private func unavailable(_ title: String, _ icon: String, _ text: String) -> some View {
        Card(title: title, icon: icon) {
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    // MARK: Auxiliares

    private var thermalLabel: String {
        switch m.thermal {
        case .nominal: return "Térmico normal"
        case .fair: return "Morno"
        case .serious: return "Quente"
        case .critical: return "Crítico"
        @unknown default: return "—"
        }
    }

    private func batteryIcon(_ b: BatterySample) -> String {
        if b.isCharging { return "battery.100percent.bolt" }
        switch b.percent {
        case ..<0.15: return "battery.0percent"
        case ..<0.4: return "battery.25percent"
        case ..<0.65: return "battery.50percent"
        case ..<0.9: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

struct TemperatureCard: View {
    let t: TemperatureSample
    let history: [Double]
    let thermal: String
    @StateObject private var expanded = Box(false)

    var body: some View {
        Card(title: "Temperaturas", icon: "thermometer.medium",
             trailing: t.cpuMax.map { String(format: "%.0f ºC", $0) }, tint: Palette.temp(t.cpuMax ?? 0)) {
            if history.count > 1 {
                Sparkline(values: history, maxValue: 110, color: Palette.temp(t.cpuMax ?? 0)).frame(height: 40)
            }
            if let a = t.cpuAvg, let mx = t.cpuMax {
                StatRow(label: "CPU (média · máx.)", value: String(format: "%.1f · %.1f ºC", a, mx), color: Palette.temp(mx))
            }
            if let c = t.chipAvg { StatRow(label: "Chip (SoC)", value: String(format: "%.1f ºC", c), color: Palette.temp(c)) }
            if let s = t.ssd { StatRow(label: "SSD", value: String(format: "%.1f ºC", s), color: Palette.temp(s)) }
            if let b = t.battery { StatRow(label: "Bateria", value: String(format: "%.1f ºC", b), color: Palette.temp(b)) }
            StatRow(label: "Estado térmico", value: thermal)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.value.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text(expanded.value ? "Esconder sensores" : "Ver os \(t.sensors.count) sensores")
                    Image(systemName: "chevron.down").rotationEffect(.degrees(expanded.value ? 180 : 0))
                }
                .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            if expanded.value {
                ForEach(Array(t.sensors.enumerated()), id: \.offset) { _, s in
                    StatRow(label: s.name, value: String(format: "%.1f ºC", s.value))
                }
            }
        }
    }
}
