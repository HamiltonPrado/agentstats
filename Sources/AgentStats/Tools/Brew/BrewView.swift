import SwiftUI
import AppKit

struct BrewView: View {
    @ObservedObject var store: BrewStore
    @StateObject private var showDependencies = Box(false)

    var body: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            if store.brew == nil && !store.loaded {
                Text("Homebrew").font(DS.body.weight(.medium))
                note("O Homebrew não está instalado neste Mac.")
            } else {
                content
            }
        }
        .cardStyle()
        .task { if !store.busy { await store.refresh() } }
    }

    @ViewBuilder private var content: some View {
        HStack(spacing: DS.sm) {
            Text(title).font(DS.body.weight(.medium)).lineLimit(1)
            Spacer(minLength: DS.sm)
            textLink("Procurar atualizações") { Task { await store.perform(.updateIndex) } }
                .disabled(store.busy)
        }
        if let running = store.running {
            HStack(spacing: DS.sm) {
                Image(systemName: "hourglass").font(DS.meta).foregroundStyle(Color.text2)
                Text(progress(running)).font(DS.meta).foregroundStyle(Color.text2)
            }
        } else if store.outdated.count > 1 {
            if store.confirming == .upgradeAll {
                ConfirmBar(text: "Atualizar \(store.outdated.count) pacotes? (\(store.outdated.map(\.name).joined(separator: ", "))) O brew pode atualizar também as dependências.",
                           confirm: "Atualizar", cancel: { store.confirming = nil },
                           action: { Task { await store.perform(.upgradeAll) } })
            } else {
                Button("Atualizar os \(store.outdated.count)…") { store.confirming = .upgradeAll }
                    .buttonStyle(.plain).font(DS.meta).modifier(AccentText()).fixedSize()
            }
        }
        if let message = store.message { note(message, color: .text2) }
        if let output = store.output, !output.isEmpty {
            Text(output)
                .font(.system(size: 10 * TextSize.current.scale, design: .monospaced))
                .foregroundStyle(Color.text2).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.sm)
                .background(RoundedRectangle(cornerRadius: DS.rSmall, style: .continuous).fill(DS.raised))
        }
        if !store.loaded { note("A ler a lista do Homebrew…") }

        let visible = store.packages.filter { showDependencies.value || $0.requested || $0.outdated }
        ForEach(visible) { package in row(package) }

        let hidden = store.packages.count - store.packages.filter { $0.requested || $0.outdated }.count
        if hidden > 0 {
            textLink(showDependencies.value ? "Esconder dependências" : "Mostrar \(hidden) dependências") { showDependencies.value.toggle() }
        }
        note("Remover não leva dependências nem os dados das apps. O que precisar de password de administrador falha: corre-o no Terminal.")
    }

    private var title: String {
        guard store.loaded else { return "Homebrew" }
        let count = store.outdated.count
        return count == 0 ? "Tudo atualizado" : "\(count) por atualizar"
    }

    private func progress(_ action: BrewAction) -> String {
        switch action {
        case .updateIndex: "A procurar atualizações…"
        case .upgrade(let p): "A atualizar \(p.name)…"
        case .upgradeAll: "A atualizar tudo…"
        case .uninstall(let p): "A remover \(p.name)…"
        }
    }

    @ViewBuilder private func row(_ package: BrewPackage) -> some View {
        VStack(alignment: .leading, spacing: DS.xs) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(package.name).font(DS.body).lineLimit(1)
                    Text(detail(package)).font(DS.meta.monospacedDigit()).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(package.outdated && !package.pinned ? AnyShapeStyle(Color.waitingText) : AnyShapeStyle(Color.text3))
                }
                Spacer(minLength: DS.sm)
                if package.outdated && !package.pinned {
                    IconButton(systemName: "arrow.up.circle", help: "Atualizar \(package.name)…") { store.confirming = .upgrade(package) }
                }
                IconButton(systemName: "trash", help: "Remover \(package.name)…") { store.confirming = .uninstall(package) }
            }
            .disabled(store.busy)
            if store.confirming == .upgrade(package) {
                ConfirmBar(text: "Atualizar \(package.name) para \(package.latest)? O brew pode atualizar também as dependências.",
                           confirm: "Atualizar", cancel: { store.confirming = nil },
                           action: { Task { await store.perform(.upgrade(package)) } })
            } else if store.confirming == .uninstall(package) {
                ConfirmBar(text: "Remover \(package.name) com o Homebrew? Não vai para o Lixo.",
                           confirm: "Remover", cancel: { store.confirming = nil },
                           action: { Task { await store.perform(.uninstall(package)) } })
            }
        }
        .padding(.vertical, DS.xs)
    }

    private func detail(_ package: BrewPackage) -> String {
        var parts = [package.outdated ? "\(package.installed) → \(package.latest)" : package.installed]
        if package.kind == .cask { parts.append("app") }
        if package.pinned { parts.append("fixado") }
        return parts.joined(separator: " · ")
    }
}
