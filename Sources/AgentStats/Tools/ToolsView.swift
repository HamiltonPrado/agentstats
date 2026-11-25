import SwiftUI
import AppKit

enum ToolSection: String, CaseIterable, Identifiable {
    case ports, brew, apps, cleanup, disks, startup, files, images, windows
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ports: "Rede"
        case .brew: "Homebrew"
        case .apps: "Desinstalar"
        case .cleanup: "Limpeza"
        case .disks: "Discos"
        case .startup: "Arranque"
        case .files: "Ficheiros"
        case .images: "Imagens"
        case .windows: "Janelas"
        }
    }
}

struct ToolsView: View {
    static let rows: [[ToolSection]] = stride(from: 0, to: ToolSection.allCases.count, by: 3).map {
        Array(ToolSection.allCases[$0..<min($0 + 3, ToolSection.allCases.count)])
    }

    @Environment(\.colorScheme) private var scheme
    @AppStorage("tools.section") private var section: ToolSection = .ports

    var body: some View {
        VStack(alignment: .leading, spacing: DS.md) {
            QuickTogglesView(store: .shared)
            // Três linhas de três: nove secções numa só ficavam ilegíveis na largura do painel.
            VStack(spacing: 2) {
                ForEach(Self.rows, id: \.self) { line in
                    HStack(spacing: 0) {
                        ForEach(line) { item in sectionButton(item) }
                    }
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: DS.rControl, style: .continuous).fill(DS.raised))

            switch section {
            case .ports:
                PortsView(store: .shared)
                DNSFlushView(store: .shared)
            case .brew: BrewView(store: .shared)
            case .apps: UninstallView(store: .shared)
            case .cleanup:
                CleaningModeCard(store: .shared)
                CleanupView(store: .shared)
            case .disks: DisksView(store: .shared)
            case .startup: StartupView(store: .shared)
            case .files: LargeFilesView(store: .shared)
            case .images: ImagesView(store: .shared)
            case .windows: WindowsView()
            }
        }
    }

    private func sectionButton(_ item: ToolSection) -> some View {
        Button { section = item } label: {
            Text(L(item.title))
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
