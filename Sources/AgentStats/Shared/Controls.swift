import SwiftUI
import AppKit

struct Card<Content: View>: View {
    let title: String
    let icon: String
    var trailing: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            HStack(spacing: DS.sm) {
                Image(systemName: icon).font(DS.body).foregroundStyle(Color.text2).frame(width: 16)
                Text(title).font(DS.title)
                Spacer()
                if let trailing {
                    Text(trailing).font(DS.body.monospacedDigit()).foregroundStyle(Color.text2)
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
    var kind: StatusKind? = nil
    var body: some View {
        HStack(spacing: DS.sm) {
            if let kind { StatusDot(kind) }
            Text(title).font(DS.meta.weight(.medium)).foregroundStyle(Color.text2)
            if let count { Text("\(count)").font(DS.meta.monospacedDigit()).foregroundStyle(Color.text3) }
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct StatRow: View {
    let label: String
    let value: String
    /// Amostra da legenda, quando a linha corresponde a uma série de um gráfico.
    var swatch: Color? = nil
    var valueColor: Color = .primary
    var body: some View {
        HStack(spacing: DS.sm) {
            if let swatch { RoundedRectangle(cornerRadius: 2).fill(swatch).frame(width: 8, height: 8) }
            Text(label).foregroundStyle(Color.text2)
            Spacer(minLength: DS.sm)
            Text(value).monospacedDigit().foregroundStyle(valueColor)
        }
        .font(DS.body)
        .accessibilityElement(children: .combine)
    }
}

struct IconButton: View {
    let systemName: String
    var help: String = ""
    let action: () -> Void
    @StateObject private var hover = Box(false)

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(DS.body)
                .foregroundStyle(Color.text2)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: DS.rSmall, style: .continuous)
                    .fill(hover.value ? DS.raised : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hover.value = $0 }
    }
}

/// Texto pequeno de explicação ou aviso, que quebra em várias linhas.
@MainActor func note(_ text: String, color: Color = .text3) -> some View {
    Text(text).font(DS.meta).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
}

/// Ação discreta, em texto.
@MainActor func textLink(_ title: String, color: Color = .text2, action: @escaping () -> Void) -> some View {
    Button(title, action: action).buttonStyle(.plain).font(DS.meta).foregroundStyle(color).fixedSize()
}
