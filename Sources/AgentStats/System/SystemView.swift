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
    @ObservedObject private var speed = SpeedTestStore.shared
    @ObservedObject private var location = LocationAccess.shared
    @ObservedObject private var extras = NetworkExtrasStore.shared
    @ObservedObject private var accessories = AccessoryBatteryStore.shared

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
                           sub: String(localized: "carga \(Fmt.num(m.cpu.load.0, 1))"), valueColor: heatOrPrimary(m.cpu.total))
        case .memory:
            return Readout(title: "Memória", value: Fmt.pct(m.memory.usage),
                           sub: Fmt.bytesShort(m.memory.used),
                           valueColor: m.memory.pressure >= 4 ? .attentionText : m.memory.pressure >= 2 ? .waitingText : .primary)
        case .temp:
            let t = m.temps?.cpuMax
            return Readout(title: "Temperatura", value: t.map { Fmt.num($0, 0) + "°" } ?? "—",
                           sub: thermalLabel, valueColor: t.map(Palette.tempText) ?? .primary)
        case .gpu:
            return Readout(title: "GPU", value: m.gpu.map(Fmt.pct) ?? "—", sub: "utilização")
        case .disk:
            return Readout(title: "Disco", value: Fmt.pct(m.disk.usage),
                           sub: String(localized: "\(Fmt.diskShort(m.disk.free)) livres"), valueColor: heatOrPrimary(m.disk.usage))
        case .battery:
            guard let b = m.battery else { return Readout(title: "Energia", value: "AC", sub: "sem bateria") }
            let sub = b.isCharging ? "a carregar" : b.externalPower ? "na corrente"
                : b.minutesRemaining.map { Fmt.minutes($0) } ?? "na bateria"
            return Readout(title: "Bateria", value: Fmt.pct(b.percent), sub: sub,
                           valueColor: b.percent < 0.15 && !b.isCharging ? .attentionText : .primary)
        case .network:
            return Readout(title: "Rede", value: "", sub: "")
        }
    }

    private func heatOrPrimary(_ f: Double) -> Color { Palette.heatText(f) }

    private func readout(_ metric: Metric) -> some View {
        let d = data(metric)
        let isSel = selected == metric
        return Button { withAnimation(Motion.ease(0.16)) { selected = metric } } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(L(d.title)).font(DS.meta).foregroundStyle(Color.text2).lineLimit(1).minimumScaleFactor(0.75)
                Text(L(d.value)).font(DS.figure).foregroundStyle(d.valueColor).lineLimit(1).minimumScaleFactor(0.8)
                Text(L(d.sub)).font(DS.meta.monospacedDigit()).foregroundStyle(Color.text3).lineLimit(1).minimumScaleFactor(0.75)
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
                    Text("↑ " + Fmt.rate(m.network.upPerSec)).foregroundStyle(Color.text2)
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
                .accessibilityValue(String(localized: "máximo \(Fmt.pct(m.cpuHistory.values.max() ?? 0))"))
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
            .accessibilityValue(L(m.cpu.cores.map(Fmt.pct).joined(separator: ", ")))
            Divider().opacity(0.5)
            StatRow(label: "Utilizador", value: Fmt.pct(m.cpu.user))
            StatRow(label: "Sistema", value: Fmt.pct(m.cpu.system))
            StatRow(label: "Carga média 1 · 5 · 15 min",
                    value: [m.cpu.load.0, m.cpu.load.1, m.cpu.load.2].map { Fmt.num($0, 2) }.joined(separator: " · "))
            if let p = m.pCores, let e = m.eCores { StatRow(label: "Núcleos", value: String(localized: "\(p) de desempenho, \(e) de eficiência")) }
            Divider().opacity(0.5)
            DayChart(samples: m.day, value: { $0.cpu }, maxValue: 1, title: "CPU", format: Fmt.pct)
            StatRow(label: "Chip", value: m.machine.replacingOccurrences(of: "Apple ", with: ""))
            topProcesses(byMemory: false)
        }
    }

    private var memoryDetail: some View {
        // Passos do mesmo neutro para as partes da memória (não quatro cores)
        let steps: [Color] = [.primary.opacity(0.7), .primary.opacity(0.45), .primary.opacity(0.25), .primary.opacity(0.12)]
        return Card(title: "Memória", icon: "memorychip", trailing: String(localized: "\(Fmt.bytes(m.memory.used)) de \(Fmt.bytes(m.memory.total))")) {
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
            StatRow(label: "Swap", value: String(localized: "\(Fmt.bytes(m.memory.swapUsed)) de \(Fmt.bytes(m.memory.swapTotal))"))
            StatRow(label: "Pressão", value: m.memory.pressure >= 4 ? "Crítica" : m.memory.pressure >= 2 ? "Elevada" : "Normal",
                    valueColor: m.memory.pressure >= 4 ? .attentionText : m.memory.pressure >= 2 ? .waitingText : .primary)
            Divider().opacity(0.5)
            DayChart(samples: m.day, value: { $0.mem }, maxValue: 1, title: "Memória", format: Fmt.pct)
            topProcesses(byMemory: true)
        }
    }

    /// Os 5 que mais gastam, com o mesmo menu do separador Processos (terminar, forçar, copiar PID).
    @ViewBuilder private func topProcesses(byMemory: Bool) -> some View {
        let list = Array((byMemory ? m.topMemory : m.topProcesses).prefix(5))
        if let first = list.first {
            let maxValue = max(byMemory ? Double(first.rssKB) : first.cpu, 1)
            Divider().opacity(0.5)
            Text("Os que mais gastam").font(DS.body.weight(.medium))
            VStack(spacing: 0) {
                ForEach(list) { p in ProcRow(p: p, sortByMem: byMemory, maxValue: maxValue) }
            }
            .padding(.horizontal, -DS.sm)
            Text("Botão direito num processo para o terminar").font(DS.meta).foregroundStyle(Color.text3)
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
        DiskCard(disk: m.disk, store: .shared)
    }

    @ViewBuilder private var batteryDetail: some View {
        if let b = m.battery {
            Card(title: "Bateria", icon: batteryIcon(b), trailing: Fmt.pct(b.percent)) {
                Bar(value: b.percent, color: b.percent < 0.15 && !b.isCharging ? .red : .accentColor, height: 6)
                StatRow(label: "Estado", value: b.isCharging ? "A carregar" : b.externalPower ? "Ligada à corrente" : "Na bateria")
                if let mins = b.minutesRemaining {
                    StatRow(label: b.isCharging ? "Até carga completa" : "Tempo restante", value: Fmt.minutes(mins))
                }
                if let w = b.systemWatts { StatRow(label: "Consumo do Mac", value: Fmt.num(w, 1) + " W") }
                if let w = b.watts, w > 0.1, b.isCharging { StatRow(label: "Potência de carga", value: Fmt.num(w, 1) + " W") }
                if let h = b.health { StatRow(label: "Saúde", value: Fmt.pct(h)) }
                StatRow(label: "Ciclos", value: "\(b.cycles)")
                if let c = BatteryHistory.change(m.batteryDays) {
                    if let h = c.from.health { StatRow(label: String(localized: "Saúde há \(c.days) dias"), value: Fmt.pct(h)) }
                    StatRow(label: String(localized: "Ciclos em \(c.days) dias"), value: "+\(max(0, c.to.cycles - c.from.cycles))")
                }
                if let t = m.temps?.battery ?? b.temperature { StatRow(label: "Temperatura", value: Fmt.temp(t)) }
                Divider().opacity(0.5)
                accessoriesSection
                energySection
                sinceUnplugSection
                Divider().opacity(0.5)
                DayChart(samples: m.day, value: { $0.battery }, maxValue: 1, title: "Bateria", format: Fmt.pct)
            }
        } else {
            Card(title: "Energia", icon: "powerplug") {
                Text("Este Mac não tem bateria").font(DS.body).foregroundStyle(Color.text2)
                Divider().opacity(0.5)
                accessoriesSection
                energySection
            }
        }
    }

    /// Acessórios Bluetooth com bateria. Só aparece quando há algum ligado.
    @ViewBuilder private var accessoriesSection: some View {
        Group {
            if !accessories.accessories.isEmpty {
                Text("Acessórios").font(DS.body.weight(.medium))
                ForEach(accessories.accessories) { a in accessoryRow(a) }
                Divider().opacity(0.5)
            }
        }
        .task {
            while !Task.isCancelled {
                await accessories.refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func accessoryRow(_ a: AccessoryBattery) -> some View {
        let low: Bool = a.lowest <= 20
        let color: Color = low ? Color.attentionText : Color.primary
        let text: String = a.parts.map { p in p.label.isEmpty ? "\(p.percent)%" : "\(L(p.label)) \(p.percent)%" }.joined(separator: " · ")
        return HStack(spacing: DS.sm) {
            Image(systemName: a.symbol).font(DS.body).foregroundStyle(Color.text2).frame(width: 18)
            Text(L(a.name)).font(DS.body).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: DS.sm)
            Text(L(text)).font(DS.body.monospacedDigit()).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var energySection: some View {
        Text("Apps que gastam mais").font(DS.body.weight(.medium))
        if let apps = m.energyApps {
            let most = max(apps.first?.watts ?? 0, 0.01)
            ForEach(apps.prefix(5)) { app in
                VStack(alignment: .leading, spacing: DS.xs) {
                    StatRow(label: app.name, value: Fmt.num(app.watts, 2) + " W")
                    Bar(value: app.watts / most, color: .secondary.opacity(0.5), height: 2)
                }
            }
            if apps.isEmpty { Text("Nada de relevante agora.").font(DS.meta).foregroundStyle(Color.text2) }
            Text("Estimativa dos últimos segundos. Não inclui o ecrã nem processos de root, como o WindowServer.")
                .font(DS.meta).foregroundStyle(Color.text3).fixedSize(horizontal: false, vertical: true)
        } else {
            Text("A medir…").font(DS.meta).foregroundStyle(Color.text3)
        }
    }

    @ViewBuilder private var sinceUnplugSection: some View {
        let e = m.energySinceUnplug
        let apps = e.top()
        if let since = e.since, !apps.isEmpty {
            Divider().opacity(0.5)
            Text(L(e.onBattery ? "Desde que saiu da corrente" : "Na última vez na bateria")).font(DS.body.weight(.medium))
            let most = max(apps[0].joules, 1)
            ForEach(apps) { app in
                VStack(alignment: .leading, spacing: DS.xs) {
                    StatRow(label: app.name, value: Self.wattHours(app.joules))
                    Bar(value: app.joules / most, color: .secondary.opacity(0.5), height: 2)
                }
            }
            Text("Na bateria desde \(Fmt.hm(since)). Só conta com o AgentStats aberto.")
                .font(DS.meta).foregroundStyle(Color.text3).fixedSize(horizontal: false, vertical: true)
        }
    }

    nonisolated static func wattHours(_ joules: Double) -> String {
        let wh = joules / 3600
        return Fmt.num(wh, wh < 1 ? 2 : 1) + " Wh"
    }

    nonisolated static func ipText(_ ip: String, _ country: String?) -> String {
        guard let country else { return ip }
        return ip + " · " + country
    }

    private var vpnRow: some View {
        let on: Bool = !extras.vpns.isEmpty
        let value: String = on ? extras.vpns.joined(separator: ", ") : "Desligada"
        let color: Color = on ? Color.accentColor : Color.primary
        return StatRow(label: "VPN", value: value, valueColor: color)
    }

    @ViewBuilder private var publicIPRow: some View {
        HStack(spacing: DS.sm) {
            Text("IP público").font(DS.body).foregroundStyle(Color.text2)
            Spacer(minLength: DS.sm)
            if extras.fetchingIP {
                ProgressView().controlSize(.small)
            } else if let ip = extras.publicIP {
                Text(L(Self.ipText(ip, extras.country))).font(DS.body.monospacedDigit()).textSelection(.enabled)
                    .lineLimit(1).minimumScaleFactor(0.8)
                IconButton(systemName: "arrow.clockwise", help: "Ver outra vez") { Task { await extras.fetchPublicIP() } }
            } else {
                textLink("Ver", color: .accentColor) { Task { await extras.fetchPublicIP() } }
                    .help("Pergunta ao Cloudflare. Só quando carregas aqui.")
            }
        }
        if let e = extras.ipError { note(e, color: .text2) }
    }

    @ViewBuilder private func wifiSection(_ w: WiFiInfo) -> some View {
        Divider().opacity(0.5)
        HStack(spacing: DS.xs) {
            Image(systemName: Self.wifiSymbol(w.quality)).font(DS.body).foregroundStyle(Color.text2)
            Text(L(w.ssid ?? "Wi-Fi")).font(DS.body.weight(.medium)).lineLimit(1)
            Spacer()
            Text(L(w.quality.rawValue)).font(DS.body)
                .foregroundStyle(w.quality == .weak ? Color.attentionText : w.quality == .fair ? Color.waitingText : Color.primary)
        }
        .accessibilityElement(children: .combine)
        StatRow(label: "Sinal", value: String(localized: "\(w.rssi) dBm · ruído \(w.noise) dBm"))
        StatRow(label: "Velocidade da ligação", value: String(localized: "\(Fmt.num(w.txRate, 0)) Mbps"))
        if let c = w.channel { StatRow(label: "Canal", value: w.band.map { "\(c) · \($0)" } ?? "\(c)") }
        if w.ssid == nil { wifiNameAccess }
    }

    @ViewBuilder private var wifiNameAccess: some View {
        if location.undecided {
            Button("Mostrar o nome da rede…") { location.request() }
                .buttonStyle(.link).font(DS.meta)
                .help("O macOS só dá o nome da rede a apps com acesso à Localização. A app não pede a tua posição.")
        } else if !location.allowed {
            Button("Nome da rede: dá acesso à Localização nas Definições do Sistema") { location.openSettings() }
                .buttonStyle(.link).font(DS.meta).multilineTextAlignment(.leading)
        }
    }

    nonisolated static func wifiSymbol(_ q: WiFiInfo.Quality) -> String {
        switch q {
        case .excellent, .good: "wifi"
        case .fair: "wifi.exclamationmark"
        case .weak: "wifi.exclamationmark"
        }
    }

    private var networkDetail: some View {
        Card(title: "Rede", icon: "network", trailing: m.network.interface) {
            StatRow(label: "Download", value: Fmt.rate(m.network.downPerSec), swatch: .accentColor)
            StatRow(label: "Upload", value: Fmt.rate(m.network.upPerSec), swatch: .secondary)
            Divider().opacity(0.5)
            StatRow(label: "Recebido desde que a app abriu", value: Fmt.bytes(m.network.totalDown))
            StatRow(label: "Enviado desde que a app abriu", value: Fmt.bytes(m.network.totalUp))
            StatRow(label: "IP local", value: m.network.localIP)
            publicIPRow
            if extras.checkedVPN { vpnRow }
            if let w = m.network.wifi { wifiSection(w) }
            Divider().opacity(0.5)
            if let result = speed.result {
                StatRow(label: "Velocidade de download", value: String(localized: "\(Fmt.num(result.downloadMbps, 1)) Mbps"), swatch: .accentColor)
                StatRow(label: "Velocidade de upload", value: String(localized: "\(Fmt.num(result.uploadMbps, 1)) Mbps"), swatch: .secondary)
                StatRow(label: "Latência", value: String(localized: "\(Fmt.num(result.latencyMs, 0)) ms"))
            }
            if let error = speed.error {
                Text(L(error)).font(DS.meta).foregroundStyle(Color.text2)
            }
            // A hora da medição à esquerda e o botão à direita, com cara de botão (antes parecia o nome de uma linha).
            HStack(spacing: DS.xs) {
                if let result = speed.result, !speed.running {
                    Text(String(localized: "Medido às \(Fmt.hm(result.measuredAt))")).font(DS.meta).foregroundStyle(Color.text3)
                }
                Spacer()
                if speed.running { ProgressView().controlSize(.small) }
                Button {
                    speed.start()
                } label: {
                    Label(L(speed.running ? "A testar…" : speed.result == nil ? "Testar velocidade" : "Repetir teste"),
                          systemImage: "arrow.clockwise")
                        .font(DS.meta)
                }
                .controlSize(.small)
                .disabled(speed.running)
                .help("Cloudflare · cerca de 32 MB por teste; medições podem ser recolhidas de forma agregada")
                .accessibilityHint("Envia aproximadamente 32 MB para medir a ligação através do Cloudflare")
            }
        }
        .task {
            while !Task.isCancelled {
                await extras.refreshVPN()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private func unavailable(_ title: String, _ icon: String, _ text: String) -> some View {
        Card(title: title, icon: icon) {
            Text(L(text)).font(DS.body).foregroundStyle(Color.text2)
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

