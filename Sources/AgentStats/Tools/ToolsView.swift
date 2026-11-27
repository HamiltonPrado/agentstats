import SwiftUI
import AppKit

enum ToolSection: String, CaseIterable, Identifiable {
    // A ordem é a da grelha: em cima o dia a dia, em baixo a manutenção do Mac.
    case windows, share, images, files, disks
    case cleanup, apps, startup, brew, ports
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
        case .share: "Partilhar"
        }
    }

    var symbol: String {
        switch self {
        case .windows: "macwindow.on.rectangle"
        case .share: "qrcode"
        case .images: "photo.on.rectangle"
        case .files: "doc.text.magnifyingglass"
        case .disks: "externaldrive"
        case .cleanup: "sparkles"
        case .apps: "xmark.app"
        case .startup: "power"
        case .brew: "mug"
        case .ports: "network"
        }
    }
}

struct ToolsView: View {
    /// Duas linhas de cinco ícones, todos do mesmo tamanho: em texto, os nomes compridos encolhiam.
    static let rows: [[ToolSection]] = stride(from: 0, to: ToolSection.allCases.count, by: 5).map {
        Array(ToolSection.allCases[$0..<min($0 + 5, ToolSection.allCases.count)])
    }

    @Environment(\.colorScheme) private var scheme
    @AppStorage(PrefKey.toolsSection) private var section: ToolSection = .ports

    var body: some View {
        VStack(alignment: .leading, spacing: DS.md) {
            QuickTogglesView(store: .shared)
            VStack(spacing: 2) {
                ForEach(Self.rows, id: \.self) { line in
                    HStack(spacing: 2) {
                        ForEach(line) { item in sectionButton(item) }
                    }
                }
            }
            .segmentTrack()

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
            case .share: ShareView(store: .shared)
            }
        }
    }

    private func sectionButton(_ item: ToolSection) -> some View {
        Button { section = item } label: {
            VStack(spacing: 3) {
                Image(systemName: item.symbol)
                    .font(.system(size: 15 * TextSize.current.scale, weight: .medium))
                    .frame(height: 18)
                Text(L(item.title))
                    .font(DS.meta.weight(.medium)).lineLimit(1).minimumScaleFactor(0.9)
            }
            .foregroundStyle(section == item ? Color.accentColor : Color.text2)
            .frame(maxWidth: .infinity).frame(height: 46)
            .segmentFill(section == item, scheme: scheme)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(section == item ? .isSelected : [])
    }
}
