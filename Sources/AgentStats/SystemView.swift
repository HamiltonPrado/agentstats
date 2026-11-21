import SwiftUI

enum Metric: String {
    case cpu, memory, temp, gpu, disk, battery, network
}

/// Uma leitura do painel: rótulo, número e contexto. A cor só aparece quando o número pede atenção.
private struct Readout {
    let title: String
    let value: String
    let sub: String
    var valueColor: Color = .primary
}

struct SystemView: View {
    @Environment(Monitor.self) private var m
    @Environment(\.agentAccentColor) private var agentAccentColor
    @AppStorage("system.detail") private var selected: Metric = .cpu
    @StateObject private var speedTestRunning = Box(false)
    @StateObject private var speedTestResult = Box<SpeedTestResult?>(nil)
    @StateObject private var speedTestError = Box<String?>(nil)

    var body: some View {
        VStack(spacing: DS.md) {
            Grid(horizontalSpacing: DS.sm, verticalSpacing: DS.sm) {
                GridRow { readout(.cpu); readout(.memory); readout(.temp) }
                GridRow { readout(.gpu); readout(.disk); readout(.battery) }
            }
            networkStrip
            detail
        }
    }

    // MARK: Leituras

    private func data(_ metric: Metric) -> Readout {
        switch metric {
        case .cpu:
            return Readout(title: "CPU", value: Fmt.pct(m.cpu.total),
                           sub: "carga " + Fmt.num(m.cpu.load.0, 1), valueColor: heatOrPrimary(m.cpu.total))
        case .memory:
            return Readout(title: "Memória", value: Fmt.pct(m.memory.usage),
                           sub: Fmt.bytesShort(m.memory.used),
                           valueColor: m.memory.pressure >= 4 ? .red : m.memory.pressure >= 2 ? .orange : .primary)
        case .temp:
            let t = m.temps?.cpuMax
            return Readout(title: "Temperatura", value: t.map { Fmt.num($0, 0) + "°" } ?? "—",
                           sub: thermalLabel, valueColor: t.map { Palette.temp($0) == .secondary ? .primary : Palette.temp($0) } ?? .primary)
        case .gpu:
            return Readout(title: "GPU", value: m.gpu.map(Fmt.pct) ?? "—", sub: "utilização")
        case .disk:
            return Readout(title: "Disco", value: Fmt.pct(m.disk.usage),
                           sub: Fmt.bytesShort(m.disk.free) + " livres", valueColor: heatOrPrimary(m.disk.usage))
        case .battery:
            guard let b = m.battery else { return Readout(title: "Energia", value: "AC", sub: "sem bateria") }
            let sub = b.isCharging ? "a carregar" : b.externalPower ? "na corrente"
                : b.minutesRemaining.map { Fmt.minutes($0) } ?? "na bateria"
            return Readout(title: "Bateria", value: Fmt.pct(b.percent), sub: sub,
                           valueColor: b.percent < 0.15 && !b.isCharging ? .red : .primary)
        case .network:
            return Readout(title: "Rede", value: "", sub: "")
        }
    }

    private func heatOrPrimary(_ f: Double) -> Color { Palette.heat(f) == .secondary ? .primary : Palette.heat(f) }

    private func readout(_ metric: Metric) -> some View {
        let d = data(metric)
        let isSel = selected == metric
        return Button { withAnimation(Motion.ease(0.16)) { selected = metric } } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(d.title).font(DS.meta).foregroundStyle(.secondary).lineLimit(1)
                Text(d.value).font(DS.figure).foregroundStyle(d.valueColor).lineLimit(1).minimumScaleFactor(0.8)
                Text(d.sub).font(DS.meta.monospacedDigit()).foregroundStyle(.tertiary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.md).padding(.vertical, DS.sm)
            .background(RoundedRectangle(cornerRadius: DS.rControl + 2, style: .continuous).fill(isSel ? DS.raised : DS.surface))
            .overlay(RoundedRectangle(cornerRadius: DS.rControl + 2, style: .continuous)
                .strokeBorder(isSel ? agentAccentColor.opacity(0.6) : DS.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(d.title): \(d.value), \(d.sub)")
        .accessibilityHint("Mostra o detalhe")
        .accessibilityAddTraits(isSel ? .isSelected : [])
    }

    private var networkStrip: some View {
        let isSel = selected == .network
        let mx = max((m.downHistory.values + m.upHistory.values).max() ?? 1, 10_000)
        return Button { withAnimation(Motion.ease(0.16)) { selected = .network } } label: {
            HStack(spacing: DS.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("↓ " + Fmt.rate(m.network.downPerSec))
                    Text("↑ " + Fmt.rate(m.network.upPerSec)).foregroundStyle(.secondary)
                }
                .font(DS.body.monospacedDigit())
                .frame(width: 96, alignment: .leading)
                ZStack {
                    Sparkline(values: m.upHistory.values, maxValue: mx, color: .secondary, fill: false)
                    Sparkline(values: m.downHistory.values, maxValue: mx)
                }
                .frame(height: 28)
            }
            .padding(.horizontal, DS.md).padding(.vertical, DS.sm)
            .background(RoundedRectangle(cornerRadius: DS.rCard, style: .continuous).fill(isSel ? DS.raised : DS.surface))
            .overlay(RoundedRectangle(cornerRadius: DS.rCard, style: .continuous)
                .strokeBorder(isSel ? agentAccentColor.opacity(0.6) : DS.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Rede: download \(Fmt.rate(m.network.downPerSec)), upload \(Fmt.rate(m.network.upPerSec))")
        .accessibilityHint("Mostra o detalhe")
    }

    // MARK: Detalhe (o gráfico principal do separador)

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
        Card(title: "CPU", icon: "cpu", trailing: Fmt.pct(m.cpu.total)) {
            Sparkline(values: m.cpuHistory.values, maxValue: 1).frame(height: 48)
                .accessibilityLabel("Gráfico da CPU no último minuto")
                .accessibilityValue("máximo " + Fmt.pct(m.cpuHistory.values.max() ?? 0))
            HStack(alignment: .bottom, spacing: DS.xs) {
                ForEach(Array(m.cpu.cores.enumerated()), id: \.offset) { _, v in
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Palette.heat(v) == .secondary ? Color.secondary.opacity(0.5) : Palette.heat(v))
                            .frame(height: max(2, 20 * v))
                    }
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 2).fill(DS.surface))
                }
            }
            .frame(height: 20)
            .help("Utilização de cada núcleo")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Utilização por núcleo")
            .accessibilityValue(m.cpu.cores.map(Fmt.pct).joined(separator: ", "))
            Divider().opacity(0.5)
            StatRow(label: "Utilizador", value: Fmt.pct(m.cpu.user))
            StatRow(label: "Sistema", value: Fmt.pct(m.cpu.system))
            StatRow(label: "Carga média 1 · 5 · 15 min",
                    value: [m.cpu.load.0, m.cpu.load.1, m.cpu.load.2].map { Fmt.num($0, 2) }.joined(separator: " · "))
            if let p = m.pCores, let e = m.eCores { StatRow(label: "Núcleos", value: "\(p) de desempenho, \(e) de eficiência") }
            Divider().opacity(0.5)
            DayChart(samples: m.day, value: { $0.cpu }, maxValue: 1, title: "CPU", format: Fmt.pct)
            StatRow(label: "Chip", value: m.machine.replacingOccurrences(of: "Apple ", with: ""))
        }
    }

    private var memoryDetail: some View {
        // Passos do mesmo neutro para as partes da memória (não quatro cores)
        let steps: [Color] = [.primary.opacity(0.7), .primary.opacity(0.45), .primary.opacity(0.25), .primary.opacity(0.12)]
        return Card(title: "Memória", icon: "memorychip", trailing: "\(Fmt.bytes(m.memory.used)) de \(Fmt.bytes(m.memory.total))") {
            Sparkline(values: m.memHistory.values, maxValue: 1).frame(height: 48)
            GeometryReader { g in
                let t = Double(max(m.memory.total, 1))
                HStack(spacing: 1) {
                    seg(steps[0], Double(m.memory.app) / t, g.size.width)
                    seg(steps[1], Double(m.memory.wired) / t, g.size.width)
                    seg(steps[2], Double(m.memory.compressed) / t, g.size.width)
                    seg(steps[3], Double(m.memory.cached) / t, g.size.width)
                    Spacer(minLength: 0)
                }
                .background(DS.surface)
                .clipShape(Capsule())
            }
            .frame(height: 8)
            StatRow(label: "Apps", value: Fmt.bytes(m.memory.app), swatch: steps[0])
            StatRow(label: "Wired", value: Fmt.bytes(m.memory.wired), swatch: steps[1])
            StatRow(label: "Comprimida", value: Fmt.bytes(m.memory.compressed), swatch: steps[2])
            StatRow(label: "Em cache", value: Fmt.bytes(m.memory.cached), swatch: steps[3])
            Divider().opacity(0.5)
            StatRow(label: "Swap", value: "\(Fmt.bytes(m.memory.swapUsed)) de \(Fmt.bytes(m.memory.swapTotal))")
            StatRow(label: "Pressão", value: m.memory.pressure >= 4 ? "Crítica" : m.memory.pressure >= 2 ? "Elevada" : "Normal",
                    valueColor: m.memory.pressure >= 4 ? .red : m.memory.pressure >= 2 ? .orange : .primary)
            Divider().opacity(0.5)
            DayChart(samples: m.day, value: { $0.mem }, maxValue: 1, title: "Memória", format: Fmt.pct)
        }
    }

    private func seg(_ c: Color, _ f: Double, _ w: CGFloat) -> some View {
        Rectangle().fill(c).frame(width: max(0, w * f))
    }

    @ViewBuilder private var tempDetail: some View {
        if let t = m.temps { TemperatureCard(t: t, history: m.tempHistory.values, thermal: thermalLabel, day: m.day) }
        else { unavailable("Temperaturas", "thermometer.medium", "Os sensores de temperatura não estão disponíveis neste Mac") }
    }

    @ViewBuilder private var gpuDetail: some View {
        if let g = m.gpu {
            Card(title: "GPU", icon: "cube", trailing: Fmt.pct(g)) {
                Sparkline(values: m.gpuHistory.values, maxValue: 1).frame(height: 48)
                StatRow(label: "Utilização atual", value: Fmt.pct(g))
                StatRow(label: "Máximo no último minuto", value: Fmt.pct(m.gpuHistory.values.max() ?? 0))
            }
        } else { unavailable("GPU", "cube", "Não foi possível ler a utilização da GPU") }
    }

    private var diskDetail: some View {
        Card(title: "Disco", icon: "internaldrive", trailing: "\(Fmt.bytes(m.disk.used)) de \(Fmt.bytes(m.disk.total))") {
            Bar(value: m.disk.usage, color: Palette.heat(m.disk.usage) == .secondary ? .accentColor : Palette.heat(m.disk.usage), height: 6)
            StatRow(label: "Usado", value: Fmt.bytes(m.disk.used))
            StatRow(label: "Livre", value: Fmt.bytes(m.disk.free))
            Divider().opacity(0.5)
            StatRow(label: "Leitura", value: Fmt.rate(m.disk.readPerSec))
            StatRow(label: "Escrita", value: Fmt.rate(m.disk.writePerSec))
        }
    }

    @ViewBuilder private var batteryDetail: some View {
        if let b = m.battery {
            Card(title: "Bateria", icon: batteryIcon(b), trailing: Fmt.pct(b.percent)) {
                Bar(value: b.percent, color: b.percent < 0.15 && !b.isCharging ? .red : .accentColor, height: 6)
                StatRow(label: "Estado", value: b.isCharging ? "A carregar" : b.externalPower ? "Ligada à corrente" : "Na bateria")
                if let mins = b.minutesRemaining {
                    StatRow(label: b.isCharging ? "Até carga completa" : "Tempo restante", value: Fmt.minutes(mins))
                }
                if let w = b.watts, w > 0.1 { StatRow(label: "Potência", value: Fmt.num(w, 1) + " W") }
                if let h = b.health { StatRow(label: "Saúde", value: Fmt.pct(h)) }
                StatRow(label: "Ciclos", value: "\(b.cycles)")
                if let t = m.temps?.battery ?? b.temperature { StatRow(label: "Temperatura", value: Fmt.temp(t)) }
            }
        } else { unavailable("Energia", "powerplug", "Este Mac não tem bateria") }
    }

    private var networkDetail: some View {
        Card(title: "Rede", icon: "network", trailing: m.network.interface) {
            StatRow(label: "Download", value: Fmt.rate(m.network.downPerSec), swatch: .accentColor)
            StatRow(label: "Upload", value: Fmt.rate(m.network.upPerSec), swatch: .secondary)
            Divider().opacity(0.5)
            StatRow(label: "Recebido desde que a app abriu", value: Fmt.bytes(m.network.totalDown))
            StatRow(label: "Enviado desde que a app abriu", value: Fmt.bytes(m.network.totalUp))
            StatRow(label: "IP local", value: m.network.localIP)
            Divider().opacity(0.5)
            if let result = speedTestResult.value {
                StatRow(label: "Velocidade de download", value: "\(Fmt.num(result.downloadMbps, 1)) Mbps", swatch: .accentColor)
                StatRow(label: "Velocidade de upload", value: "\(Fmt.num(result.uploadMbps, 1)) Mbps", swatch: .secondary)
                StatRow(label: "Latência", value: "\(Fmt.num(result.latencyMs, 0)) ms")
            }
            if let error = speedTestError.value {
                Text(error).font(DS.meta).foregroundStyle(.secondary)
            }
            Button {
                Task { await runSpeedTest() }
            } label: {
                HStack(spacing: DS.xs) {
                    if speedTestRunning.value { ProgressView().controlSize(.small) }
                    Text(speedTestRunning.value ? "A testar…" : speedTestResult.value == nil ? "Testar velocidade" : "Repetir teste")
                    Spacer()
                    if let result = speedTestResult.value, !speedTestRunning.value {
                        Text(result.measuredAt.formatted(date: .omitted, time: .shortened))
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(DS.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(speedTestRunning.value)
            .accessibilityHint("Envia aproximadamente 32 MB para medir a ligação através do Cloudflare")
            Text("Cloudflare · cerca de 32 MB por teste; medições podem ser recolhidas de forma agregada")
                .font(DS.meta).foregroundStyle(.tertiary)
        }
    }

    @MainActor private func runSpeedTest() async {
        speedTestRunning.value = true
        speedTestError.value = nil
        defer { speedTestRunning.value = false }
        do {
            speedTestResult.value = try await SpeedTest.run()
        } catch {
            speedTestError.value = "Não foi possível concluir o teste. Verifica a ligação e tenta novamente."
        }
    }

    private func unavailable(_ title: String, _ icon: String, _ text: String) -> some View {
        Card(title: title, icon: icon) {
            Text(text).font(DS.body).foregroundStyle(.secondary)
        }
    }

    // MARK: Auxiliares

    private var thermalLabel: String {
        switch m.thermal {
        case .nominal: return "normal"
        case .fair: return "morno"
        case .serious: return "quente"
        case .critical: return "crítico"
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
    @Environment(\.agentAccentColor) private var agentAccentColor
    let t: TemperatureSample
    let history: [Double]
    let thermal: String
    var day: [MinuteSample] = []
    @StateObject private var expanded = Box(false)

    private func color(_ c: Double) -> Color { Palette.temp(c) == .secondary ? .primary : Palette.temp(c) }

    var body: some View {
        Card(title: "Temperaturas", icon: "thermometer.medium", trailing: t.cpuMax.map { Fmt.temp($0, 0) }) {
            if history.count > 1 {
                Sparkline(values: history, maxValue: 110).frame(height: 48)
            }
            if let a = t.cpuAvg, let mx = t.cpuMax {
                StatRow(label: "CPU, média e máximo", value: Fmt.num(a, 1) + " · " + Fmt.temp(mx), valueColor: color(mx))
            }
            if let c = t.chipAvg { StatRow(label: "Chip", value: Fmt.temp(c), valueColor: color(c)) }
            if let s = t.ssd { StatRow(label: "SSD", value: Fmt.temp(s), valueColor: color(s)) }
            if let b = t.battery { StatRow(label: "Bateria", value: Fmt.temp(b), valueColor: color(b)) }
            StatRow(label: "Estado térmico", value: thermal.prefix(1).uppercased() + thermal.dropFirst())
            Divider().opacity(0.5)
            DayChart(samples: day, value: { $0.temp }, maxValue: 110, title: "Temperatura da CPU", format: { Fmt.temp($0, 0) })
            Button {
                withAnimation(Motion.ease(0.2)) { expanded.value.toggle() }
            } label: {
                HStack(spacing: DS.xs) {
                    Text(expanded.value ? "Esconder sensores" : "Ver os \(t.sensors.count) sensores")
                    Image(systemName: "chevron.down").rotationEffect(.degrees(expanded.value ? 180 : 0))
                }
                .font(DS.meta).foregroundStyle(agentAccentColor)
            }
            .buttonStyle(.plain)
            if expanded.value {
                ForEach(Array(t.sensors.enumerated()), id: \.offset) { _, s in
                    StatRow(label: s.name, value: Fmt.temp(s.value))
                }
            }
        }
    }
}
