import AppKit

/// Estilo do texto na barra de menus (Definições → Barra de menus).
enum MenuBarStyle: String, CaseIterable, Identifiable {
    case labeled, compact, graphs
    static let defaultsKey = "bar.style"
    var id: String { rawValue }
    var title: String {
        switch self { case .labeled: "Com rótulos"; case .compact: "Compacto"; case .graphs: "Mini-gráficos" }
    }
    static var current: MenuBarStyle {
        MenuBarStyle(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .labeled
    }
}

/// Desenha o conteúdo da barra de menus diretamente com AppKit/CoreText.
/// (Muito mais barato do que renderizar uma vista SwiftUI a cada atualização.)
@MainActor
enum MenuBarDrawer {
    private static let height: CGFloat = 18
    private static let spacing: CGFloat = 7
    private static let graphWidth: CGFloat = 22
    private static let defaultMetricOrder = ["agents", "cpu", "ram", "gpu", "temp", "net", "battery"]

    static var metricOrderKey: String { "bar.order" }
    static let colorDotKey = "bar.colorDot"

    /// Cor de um elemento: `nil` = cor do texto da barra (modelo); senão, uma cor de estado.
    private typealias Tint = NSColor?

    private enum Segment {
        case symbol(String, CGFloat, Tint)
        case text(String, NSFont)
        case cell(title: String, value: String)
        case value(String)                                   // estilo compacto: só o número
        case graph(title: String, value: String, values: [Double], max: Double)
        case twoLines(String, String, minWidth: CGFloat)
    }

    private static let titleFont = NSFont.systemFont(ofSize: 7, weight: .semibold)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
    private static let compactFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    private static let agentFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    private static let netFont = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .medium)

    private static func flag(_ key: String, _ def: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? def : UserDefaults.standard.bool(forKey: key)
    }

    private static func segments(_ m: Monitor, style: MenuBarStyle, colored: Bool) -> [Segment] {
        var s: [Segment] = []
        let agents = flag("bar.agents", true), cpu = flag("bar.cpu", true), ram = flag("bar.ram", true)
        let gpu = flag("bar.gpu", false), temp = flag("bar.temp", true), net = flag("bar.net", true)
        let bat = flag("bar.battery", false)

        if !m.activeAlerts.isEmpty { s.append(.symbol("exclamationmark.triangle.fill", 11, colored ? .systemOrange : nil)) }
        if m.needsAttentionCount > 0 { s.append(.symbol("hand.raised.fill", 11, colored ? .systemRed : nil)) }
        let storedOrder = UserDefaults.standard.string(forKey: metricOrderKey)?
            .split(separator: ",").map(String.init) ?? []
        var seen = Set<String>()
        let order = storedOrder.filter { defaultMetricOrder.contains($0) && seen.insert($0).inserted }
            + defaultMetricOrder.filter { seen.insert($0).inserted }

        /// Uma métrica no estilo escolhido.
        func metric(_ title: String, _ value: String, history: [Double]? = nil, max: Double = 1) -> Segment {
            switch style {
            case .labeled: return .cell(title: title, value: value)
            case .compact: return .value(value)
            case .graphs:
                if let history, history.count > 1 { return .graph(title: title, value: value, values: history, max: max) }
                return .cell(title: title, value: value)
            }
        }

        for item in order {
            switch item {
            case "agents" where agents:
                // O ponto de estado: cheio a trabalhar, vazio sem nada. A cores: verde a trabalhar, vermelho precisa de ti.
                let dotColor: Tint = !colored ? nil
                    : m.needsAttentionCount > 0 ? .systemRed
                    : m.workingCount > 0 ? .systemGreen
                    : nil
                s.append(.symbol(m.workingCount > 0 || m.needsAttentionCount > 0 ? "circle.fill" : "circle", 7, dotColor))
                s.append(.text("\(m.workingCount)/\(m.liveAgentCount)", agentFont))
            case "cpu" where cpu:
                s.append(metric("CPU", Fmt.pct(m.cpu.total), history: m.cpuHistory.values))
            case "ram" where ram:
                s.append(metric("RAM", Fmt.pct(m.memory.usage), history: m.memHistory.values))
            case "gpu" where gpu:
                if let g = m.gpu { s.append(metric("GPU", Fmt.pct(g), history: m.gpuHistory.values)) }
            case "temp" where temp:
                if let t = m.temps?.cpuMax { s.append(metric("TEMP", String(format: "%.0f°", t), history: m.tempHistory.values, max: 110)) }
            case "net" where net:
                let up = Fmt.rate(m.network.upPerSec, short: true), down = Fmt.rate(m.network.downPerSec, short: true)
                switch style {
                case .compact: s.append(.value("↓" + down))
                case .graphs:
                    let mx = Swift.max((m.downHistory.values + m.upHistory.values).max() ?? 1, 10_000)
                    s.append(.graph(title: "REDE", value: "↓" + down, values: m.downHistory.values, max: mx))
                case .labeled: s.append(.twoLines("↑ " + up, "↓ " + down, minWidth: 40))
                }
            case "battery" where bat:
                if let b = m.battery { s.append(metric(b.isCharging ? "CARGA" : "BAT", Fmt.pct(b.percent))) }
            default:
                break
            }
        }
        if s.isEmpty { s.append(.symbol("gauge.with.dots.needle.33percent", 12, nil)) }
        return s
    }

    private static func attr(_ str: String, _ font: NSFont, _ color: NSColor) -> NSAttributedString {
        NSAttributedString(string: str, attributes: [.font: font, .foregroundColor: color])
    }

    private static func symbolImage(_ name: String, _ size: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .semibold))
    }

    private static func width(_ seg: Segment) -> CGFloat {
        let c = NSColor.black
        switch seg {
        case .symbol(let n, let size, _): return ceil(symbolImage(n, size)?.size.width ?? size)
        case .text(let t, let f): return ceil(attr(t, f, c).size().width)
        case .cell(let t, let v): return max(24, ceil(max(attr(t, titleFont, c).size().width, attr(v, valueFont, c).size().width)))
        case .value(let v): return ceil(attr(v, compactFont, c).size().width)
        case .graph(let t, let v, _, _):
            return max(24, ceil(max(attr(t, titleFont, c).size().width, attr(v, valueFont, c).size().width))) + 3 + graphWidth
        case .twoLines(let a, let b, let mw): return max(mw, ceil(max(attr(a, netFont, c).size().width, attr(b, netFont, c).size().width)))
        }
    }

    /// Desenha o ícone da barra de menus.
    /// - Sem cores: imagem-modelo (o macOS pinta-a com a cor da barra, em claro e escuro).
    /// - Com o ponto a cores: imagem normal, com o texto na cor da barra (`appearance`) e o ponto colorido.
    static func image(_ m: Monitor, appearance: NSAppearance? = nil, recording: String? = nil) -> NSImage {
        let colored = flag(colorDotKey, false) || recording != nil
        let style = MenuBarStyle.current
        // A gravar, a barra mostra só isso (sempre a vermelho): não pode passar despercebido.
        let segs: [Segment] = recording.map { [.symbol("stop.circle.fill", 13, .systemRed), .text($0, agentFont)] }
            ?? segments(m, style: style, colored: colored)
        // símbolo + texto dos agentes ficam colados (2 pt); o resto separado por `spacing`
        let widths = segs.map(width)
        var gaps: [CGFloat] = []
        for i in segs.indices.dropLast() {
            if case .symbol(let n, _, _) = segs[i], n.hasPrefix("circle"), case .text = segs[i + 1] { gaps.append(2) }
            else { gaps.append(spacing) }
        }
        let total = widths.reduce(0, +) + gaps.reduce(0, +) + 2

        // Rasteriza uma única vez para um bitmap (um NSImage com drawingHandler seria redesenhado
        // pela barra de menus a cada atualização visual).
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(total * scale)), pixelsHigh: Int(height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let bctx = NSGraphicsContext(bitmapImageRep: rep) else { return NSImage() }
        rep.size = NSSize(width: total, height: height)

        let draw = {
            // Cor do texto: preto na imagem-modelo; a cor do texto da barra na imagem a cores.
            let ink: NSColor = colored ? NSColor.labelColor.usingColorSpace(.deviceRGB) ?? .labelColor : .black
            NSGraphicsContext.saveGraphicsState()
            let cg = bctx.cgContext
            cg.scaleBy(x: scale, y: scale)
            cg.translateBy(x: 0, y: height)
            cg.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
            var x: CGFloat = 1
            for (i, seg) in segs.enumerated() {
                let w = widths[i]
                switch seg {
                case .symbol(let n, let size, let tint):
                    if let sym = symbolImage(n, size) {
                        let sz = sym.size
                        let rect = NSRect(x: x, y: (height - sz.height) / 2, width: sz.width, height: sz.height)
                        let color = tint ?? ink
                        // pinta o símbolo com a cor pedida (o símbolo é uma máscara)
                        let tinted = NSImage(size: sz, flipped: false) { r in
                            sym.draw(in: r)
                            color.set()
                            r.fill(using: .sourceAtop)
                            return true
                        }
                        tinted.draw(in: rect)
                    }
                case .text(let t, let f):
                    let a = attr(t, f, ink)
                    a.draw(at: NSPoint(x: x, y: (height - a.size().height) / 2))
                case .cell(let t, let v):
                    attr(t, titleFont, ink).draw(at: NSPoint(x: x, y: -0.5))
                    attr(v, valueFont, ink).draw(at: NSPoint(x: x, y: 6))
                case .value(let v):
                    let a = attr(v, compactFont, ink)
                    a.draw(at: NSPoint(x: x, y: (height - a.size().height) / 2))
                case .graph(let t, let v, let values, let mx):
                    attr(t, titleFont, ink).draw(at: NSPoint(x: x, y: -0.5))
                    attr(v, valueFont, ink).draw(at: NSPoint(x: x, y: 6))
                    let gx = x + w - graphWidth
                    drawSparkline(values.suffix(30), in: NSRect(x: gx, y: 3, width: graphWidth, height: 12), max: mx, color: ink)
                case .twoLines(let a, let b, _):
                    let aa = attr(a, netFont, ink), bb = attr(b, netFont, ink)
                    aa.draw(at: NSPoint(x: x + w - aa.size().width, y: -0.5))
                    bb.draw(at: NSPoint(x: x + w - bb.size().width, y: 8.5))
                }
                x += w + (i < gaps.count ? gaps[i] : 0)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        // As cores do sistema (labelColor) resolvem-se com a aparência da barra de menus
        if colored, let appearance { appearance.performAsCurrentDrawingAppearance(draw) } else { draw() }

        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        img.isTemplate = !colored
        return img
    }

    /// Mini-gráfico: área suave com a linha por cima (coordenadas viradas: y cresce para baixo).
    private static func drawSparkline(_ values: ArraySlice<Double>, in r: NSRect, max mx: Double, color: NSColor) {
        let vals = Array(values)
        guard vals.count > 1 else { return }
        let top = Swift.max(mx, 0.0001)
        let pts = vals.enumerated().map { i, v in
            NSPoint(x: r.minX + r.width * CGFloat(i) / CGFloat(vals.count - 1),
                    y: r.maxY - r.height * CGFloat(Swift.min(v / top, 1)))
        }
        let area = NSBezierPath()
        area.move(to: NSPoint(x: pts[0].x, y: r.maxY))
        pts.forEach { area.line(to: $0) }
        area.line(to: NSPoint(x: pts[pts.count - 1].x, y: r.maxY))
        area.close()
        color.withAlphaComponent(0.25).setFill()
        area.fill()
        let line = NSBezierPath()
        line.move(to: pts[0])
        pts.dropFirst().forEach { line.line(to: $0) }
        line.lineWidth = 1
        line.lineJoinStyle = .round
        color.setStroke()
        line.stroke()
    }
}
