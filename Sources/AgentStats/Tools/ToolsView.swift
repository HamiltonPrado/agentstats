import SwiftUI
import AppKit

enum ToolSection: String, CaseIterable, Identifiable {
    case ports, brew, apps, cleanup
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ports: "Portas"
        case .brew: "Homebrew"
        case .apps: "Desinstalar"
        case .cleanup: "Limpeza"
        }
    }
}

struct ToolsView: View {
    @Environment(\.colorScheme) private var scheme
    @AppStorage("tools.section") private var section: ToolSection = .ports

    var body: some View {
        VStack(alignment: .leading, spacing: DS.md) {
            HStack(spacing: 0) {
                ForEach(ToolSection.allCases) { item in
                    Button { section = item } label: {
                        Text(item.title)
                            .font(DS.body.weight(.medium)).lineLimit(1).minimumScaleFactor(0.75)
                            .padding(.horizontal, DS.xs)
                            .foregroundStyle(section == item ? Color.primary : Color.text2)
                            .frame(maxWidth: .infinity).frame(height: 24)
                            .background(RoundedRectangle(cornerRadius: DS.rSmall, style: .continuous)
                                .fill(section == item ? (scheme == .dark ? Color.white.opacity(0.12) : Color.white) : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(section == item ? .isSelected : [])
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: DS.rControl, style: .continuous).fill(DS.raised))

            switch section {
            case .ports: PortsView(store: .shared)
            case .brew: BrewView(store: .shared)
            case .apps: UninstallView(store: .shared)
            case .cleanup:
                CleaningModeCard(store: .shared)
                CleanupView(store: .shared)
            }
        }
    }
}
