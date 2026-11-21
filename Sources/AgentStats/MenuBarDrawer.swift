import AppKit

/// Desenha o conteúdo da barra de menus diretamente com AppKit/CoreText.
/// (Muito mais barato do que renderizar uma vista SwiftUI a cada atualização.)
@MainActor
enum MenuBarDrawer {
    private static let height: CGFloat = 18
    private static let spacing: CGFloat = 7
    private static let defaultMetricOrder = ["agents", "cpu", "ram", "gpu", "temp", "net", "battery"]

    static var metricOrderKey: String { "bar.order" }

    private enum Segment {
        case symbol(String, CGFloat)
        case text(String, NSFont)
        case cell(title: String, value: String)
        case twoLines(String, String, minWidth: CGFloat)
    }

    private static let titleFont = NSFont.systemFont(ofSize: 7, weight: .semibold)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
    private static let agentFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    private static let netFont = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .medium)

    private static func flag(_ key: String, _ def: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? def : UserDefaults.standard.bool(forKey: key)
    }

    private static func segments(_ m: Monitor) -> [Segment] {
        var s: [Segment] = []
        let agents = flag("bar.agents", true), cpu = flag("bar.cpu", true), ram = flag("bar.ram", true)
        let gpu = flag("bar.gpu", false), temp = flag("bar.temp", true), net = flag("bar.net", true)
        let bat = flag("bar.battery", false)

        if !m.activeAlerts.isEmpty { s.append(.symbol("exclamationmark.triangle.fill", 11)) }
        if m.needsAttentionCount > 0 { s.append(.symbol("hand.raised.fill", 11)) }
        let storedOrder = UserDefaults.standard.string(forKey: metricOrderKey)?
            .split(separator: ",").map(String.init) ?? []
        var seen = Set<String>()
        let order = storedOrder.filter { defaultMetricOrder.contains($0) && seen.insert($0).inserted }
            + defaultMetricOrder.filter { seen.insert($0).inserted }

        for metric in order {
            switch metric {
            case "agents" where agents:
                s.append(.symbol(m.workingCount > 0 ? "circle.fill" : "circle", 7))
                s.append(.text("\(m.workingCount)/\(m.liveAgentCount)", agentFont))
            case "cpu" where cpu:
                s.append(.cell(title: "CPU", value: Fmt.pct(m.cpu.total)))
            case "ram" where ram:
                s.append(.cell(title: "RAM", value: Fmt.pct(m.memory.usage)))
            case "gpu" where gpu:
                if let g = m.gpu { s.append(.cell(title: "GPU", value: Fmt.pct(g))) }
            case "temp" where temp:
                if let t = m.temps?.cpuMax { s.append(.cell(title: "TEMP", value: String(format: "%.0f°", t))) }
            case "net" where net:
                s.append(.twoLines("↑ " + Fmt.rate(m.network.upPerSec, short: true),
                                   "↓ " + Fmt.rate(m.network.downPerSec, short: true), minWidth: 40))
            case "battery" where bat:
                if let b = m.battery { s.append(.cell(title: b.isCharging ? "CARGA" : "BAT", value: Fmt.pct(b.percent))) }
            default:
                break
            }
        }
        if s.isEmpty { s.append(.symbol("gauge.with.dots.needle.33percent", 12)) }
        return s
    }

    private static func attr(_ str: String, _ font: NSFont) -> NSAttributedString {
        NSAttributedString(string: str, attributes: [.font: font, .foregroundColor: NSColor.black])
    }

    private static func symbolImage(_ name: String, _ size: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .semibold))
    }

    private static func width(_ seg: Segment) -> CGFloat {
        switch seg {
        case .symbol(let n, let size): return ceil(symbolImage(n, size)?.size.width ?? size)
        case .text(let t, let f): return ceil(attr(t, f).size().width)
        case .cell(let t, let v): return max(24, ceil(max(attr(t, titleFont).size().width, attr(v, valueFont).size().width)))
        case .twoLines(let a, let b, let mw): return max(mw, ceil(max(attr(a, netFont).size().width, attr(b, netFont).size().width)))
        }
    }

    /// Imagem-modelo (o macOS pinta-a com a cor da barra, em claro e escuro).
    static func image(_ m: Monitor) -> NSImage {
        let segs = segments(m)
        // símbolo + texto dos agentes ficam colados (2 pt); o resto separado por `spacing`
        var widths = segs.map(width)
        var gaps: [CGFloat] = []
        for i in segs.indices.dropLast() {
            if case .symbol(let n, _) = segs[i], n.hasPrefix("circle"), case .text = segs[i + 1] { gaps.append(2) }
            else { gaps.append(spacing) }
        }
        let total = widths.reduce(0, +) + gaps.reduce(0, +) + 2
        widths = widths.map { $0 }

        // Rasteriza uma única vez para um bitmap (um NSImage com drawingHandler seria redesenhado
        // pela barra de menus a cada atualização visual).
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(total * scale)), pixelsHigh: Int(height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let bctx = NSGraphicsContext(bitmapImageRep: rep) else { return NSImage() }
        rep.size = NSSize(width: total, height: height)
        NSGraphicsContext.saveGraphicsState()
        let cg = bctx.cgContext
        cg.scaleBy(x: scale, y: scale)
        cg.translateBy(x: 0, y: height)
        cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        do {
            var x: CGFloat = 1
            for (i, seg) in segs.enumerated() {
                let w = widths[i]
                switch seg {
                case .symbol(let n, let size):
                    if let sym = symbolImage(n, size) {
                        let sz = sym.size
                        sym.draw(in: NSRect(x: x, y: (height - sz.height) / 2, width: sz.width, height: sz.height))
                    }
                case .text(let t, let f):
                    let a = attr(t, f)
                    a.draw(at: NSPoint(x: x, y: (height - a.size().height) / 2))
                case .cell(let t, let v):
                    attr(t, titleFont).draw(at: NSPoint(x: x, y: -0.5))
                    attr(v, valueFont).draw(at: NSPoint(x: x, y: 6))
                case .twoLines(let a, let b, _):
                    let aa = attr(a, netFont), bb = attr(b, netFont)
                    aa.draw(at: NSPoint(x: x + w - aa.size().width, y: -0.5))
                    bb.draw(at: NSPoint(x: x + w - bb.size().width, y: 8.5))
                }
                x += w + (i < gaps.count ? gaps[i] : 0)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        img.isTemplate = true
        return img
    }
}
