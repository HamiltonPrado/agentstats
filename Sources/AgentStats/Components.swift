import SwiftUI
import AppKit

/// Substituto de @State (as Command Line Tools não incluem o plugin de macros do SwiftUI).
final class Box<T>: ObservableObject {
    @Published var value: T
    init(_ v: T) { value = v }
}

enum Palette {
    static func usage(_ v: Double) -> Color { v > 0.85 ? .red : v > 0.6 ? .orange : .green }
    static func temp(_ c: Double) -> Color { c >= 90 ? .red : c >= 75 ? .orange : c >= 60 ? .yellow : .green }
    static let brand = LinearGradient(colors: [Color(red: 0.55, green: 0.36, blue: 0.96), Color(red: 0.23, green: 0.51, blue: 0.96)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing)
}

extension View {
    /// Estilo base de cartão: fundo subtil, borda fina, cantos contínuos.
    func cardStyle(padding: CGFloat = 10, highlight: Color? = nil) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(highlight ?? Color.primary.opacity(0.07), lineWidth: highlight == nil ? 0.5 : 1.2)
            )
    }
}

struct Card<Content: View>: View {
    let title: String
    let icon: String
    var trailing: String? = nil
    var tint: Color = .secondary
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
                if let trailing {
                    Text(trailing).font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            content
        }
        .cardStyle()
    }
}

struct SectionHeader: View {
    let title: String
    var count: Int? = nil
    var color: Color = .secondary
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title.uppercased()).font(.system(size: 10, weight: .bold)).tracking(0.6).foregroundStyle(.secondary)
            if let count { Text("\(count)").font(.system(size: 10, weight: .bold).monospacedDigit()).foregroundStyle(.tertiary) }
            Spacer()
        }
    }
}

struct Sparkline: View {
    let values: [Double]
    var maxValue: Double? = nil
    var color: Color = .accentColor

    var body: some View {
        GeometryReader { g in
            let mx = max(maxValue ?? (values.max() ?? 1), 0.0001)
            let pts = values.enumerated().map { i, v in
                CGPoint(x: g.size.width * CGFloat(i) / CGFloat(max(values.count - 1, 1)),
                        y: g.size.height * (1 - CGFloat(min(v / mx, 1))))
            }
            ZStack {
                Path { p in
                    guard let f = pts.first, let l = pts.last else { return }
                    p.move(to: CGPoint(x: f.x, y: g.size.height))
                    pts.forEach { p.addLine(to: $0) }
                    p.addLine(to: CGPoint(x: l.x, y: g.size.height))
                }
                .fill(LinearGradient(colors: [color.opacity(0.28), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                Path { p in
                    guard let f = pts.first else { return }
                    p.move(to: f)
                    pts.dropFirst().forEach { p.addLine(to: $0) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

struct Bar: View {
    let value: Double
    var color: Color = .accentColor
    var height: CGFloat = 6
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color).frame(width: max(height, g.size.width * CGFloat(min(max(value, 0), 1))))
            }
        }
        .frame(height: height)
    }
}

struct RingGauge<Center: View>: View {
    let value: Double?
    let color: Color
    var lineWidth: CGFloat = 4.5
    @ViewBuilder var center: Center

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.15), lineWidth: lineWidth)
            if let value {
                Circle()
                    .trim(from: 0, to: CGFloat(min(max(value, 0.005), 1)))
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.5), value: value)
            }
            center
        }
    }
}

struct StatRow: View {
    let label: String
    let value: String
    var color: Color? = nil
    var body: some View {
        HStack(spacing: 6) {
            if let color { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8) }
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).monospacedDigit().foregroundStyle(.primary)
        }
        .font(.system(size: 11))
    }
}

struct Pill: View {
    let text: String
    var icon: String? = nil
    var color: Color = .secondary
    var body: some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon).font(.system(size: 8.5, weight: .semibold)) }
            Text(text).lineLimit(1)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(color)
        .padding(.horizontal, 6).padding(.vertical, 2.5)
        .background(Capsule().fill(color.opacity(0.12)))
    }
}

struct IconButton: View {
    let systemName: String
    var help: String = ""
    var active = false
    var tint: Color = .secondary
    let action: () -> Void
    @StateObject private var hover = Box(false)

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(active ? Color.accentColor : tint)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(active ? Color.accentColor.opacity(0.15) : Color.primary.opacity(hover.value ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hover.value = $0 }
    }
}
