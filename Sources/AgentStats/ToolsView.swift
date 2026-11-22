import SwiftUI
import AppKit

enum ToolSection: String, CaseIterable, Identifiable {
    case ports, brew, apps
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ports: "Portas"
        case .brew: "Homebrew"
        case .apps: "Desinstalar"
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
                            .font(DS.body.weight(.medium)).lineLimit(1)
                            .foregroundStyle(section == item ? Color.primary : Color.secondary)
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
            }
        }
    }
}

// MARK: - Peças comuns

@MainActor private func toolNote(_ text: String, color: Color? = nil) -> some View {
    Text(text).font(DS.meta)
        .foregroundStyle(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.tertiary))
        .fixedSize(horizontal: false, vertical: true)
}

@MainActor private func toolLink(_ title: String, color: Color = .secondary, action: @escaping () -> Void) -> some View {
    Button(title, action: action).buttonStyle(.plain).font(DS.meta).foregroundStyle(color).fixedSize()
}

/// Confirmação dentro do painel (um alerta fechava-o): diz o que vai acontecer e "Cancelar" vem primeiro.
private struct ConfirmBar: View {
    let text: String
    let confirm: String
    let cancel: () -> Void
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            Text(text).font(DS.meta).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.sm) {
                Spacer(minLength: 0)
                Button("Cancelar", action: cancel)
                Button(confirm, role: .destructive, action: action)
            }
            .controlSize(.small)
        }
        .padding(DS.sm)
        .background(RoundedRectangle(cornerRadius: DS.rSmall, style: .continuous).fill(Palette.attention.opacity(0.08)))
    }
}

// MARK: - Portas

private struct PortsView: View {
    @ObservedObject var store: PortsStore

    var body: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            HStack(spacing: DS.sm) {
                Text("À escuta").font(DS.body.weight(.medium))
                Spacer(minLength: DS.sm)
                IconButton(systemName: "arrow.clockwise", help: "Atualizar") { Task { await store.refresh() } }
                    .disabled(store.loading)
            }
            if !store.loaded {
                toolNote("A ler as portas…")
            } else if store.listeners.isEmpty {
                toolNote("Nenhum processo teu está à escuta.")
            }
            ForEach(store.listeners) { listener in row(listener) }
            if let message = store.message { toolNote(message, color: .secondary) }
            toolNote("Só portas TCP dos teus processos. “Rede” quer dizer que outros aparelhos lhe podem chegar.")
        }
        .cardStyle()
        .task { await store.refresh() }
    }

    @ViewBuilder private func row(_ listener: Listener) -> some View {
        VStack(alignment: .leading, spacing: DS.xs) {
            HStack(spacing: DS.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(listener.name).font(DS.body).lineLimit(1).truncationMode(.middle)
                    Text(detail(listener)).font(DS.meta.monospacedDigit()).foregroundStyle(.tertiary).lineLimit(2)
                }
                Spacer(minLength: DS.sm)
                if store.stopping.contains(listener.pid) {
                    Text("A fechar…").font(DS.meta).foregroundStyle(.secondary)
                } else if let identity = listener.identity, PortRules.canTerminate(identity) {
                    let force = store.stubborn.contains(listener.pid)
                    toolLink(force ? "Forçar" : "Terminar", color: force ? Palette.attention : .secondary) {
                        store.confirming = listener.pid
                    }
                } else {
                    Text("macOS").font(DS.meta).foregroundStyle(.tertiary).help("É do sistema: não se termina por aqui")
                }
            }
            if store.confirming == listener.pid {
                let force = store.stubborn.contains(listener.pid)
                ConfirmBar(text: "\(force ? "Forçar o fim de" : "Terminar") \(listener.name) (PID \(String(listener.pid)))? O que não tiver gravado pode perder-se.",
                           confirm: force ? "Forçar" : "Terminar",
                           cancel: { store.confirming = nil },
                           action: { Task { await store.terminate(listener, force: force) } })
            }
        }
        .padding(.vertical, DS.xs)
    }

    private func detail(_ listener: Listener) -> String {
        let shown = listener.ports.prefix(4).map { ":\($0.port)" }.joined(separator: " ")
        let more = listener.ports.count > 4 ? " +\(listener.ports.count - 4)" : ""
        let scope = listener.ports.allSatisfy(\.local) ? "só este Mac" : "rede"
        return "\(shown)\(more) · \(scope)"
    }
}

// MARK: - Homebrew

private struct BrewView: View {
    @ObservedObject var store: BrewStore
    @StateObject private var showDependencies = Box(false)

    var body: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            if store.brew == nil && !store.loaded {
                Text("Homebrew").font(DS.body.weight(.medium))
                toolNote("O Homebrew não está instalado neste Mac.")
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
            toolLink("Procurar atualizações") { Task { await store.perform(.updateIndex) } }
                .disabled(store.busy)
        }
        if let running = store.running {
            HStack(spacing: DS.sm) {
                Image(systemName: "hourglass").font(DS.meta).foregroundStyle(.secondary)
                Text(progress(running)).font(DS.meta).foregroundStyle(.secondary)
            }
        } else if store.outdated.count > 1 {
            if store.confirming == .upgradeAll {
                ConfirmBar(text: "Atualizar \(store.outdated.count) pacotes? (\(store.outdated.map(\.name).joined(separator: ", "))) O brew pode atualizar também as dependências.",
                           confirm: "Atualizar", cancel: { store.confirming = nil },
                           action: { Task { await store.perform(.upgradeAll) } })
            } else {
                toolLink("Atualizar os \(store.outdated.count)…", color: .accentColor) { store.confirming = .upgradeAll }
            }
        }
        if let message = store.message { toolNote(message, color: .secondary) }
        if let output = store.output, !output.isEmpty {
            Text(output)
                .font(.system(size: 10 * TextSize.current.scale, design: .monospaced))
                .foregroundStyle(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.sm)
                .background(RoundedRectangle(cornerRadius: DS.rSmall, style: .continuous).fill(DS.raised))
        }
        if !store.loaded { toolNote("A ler a lista do Homebrew…") }

        let visible = store.packages.filter { showDependencies.value || $0.requested || $0.outdated }
        ForEach(visible) { package in row(package) }

        let hidden = store.packages.count - store.packages.filter { $0.requested || $0.outdated }.count
        if hidden > 0 {
            toolLink(showDependencies.value ? "Esconder dependências" : "Mostrar \(hidden) dependências") { showDependencies.value.toggle() }
        }
        toolNote("Remover não leva dependências nem os dados das apps. O que precisar de password de administrador falha: corre-o no Terminal.")
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
                        .foregroundStyle(package.outdated && !package.pinned ? AnyShapeStyle(Palette.waiting) : AnyShapeStyle(.tertiary))
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

// MARK: - Desinstalar

private struct UninstallView: View {
    @ObservedObject var store: UninstallStore
    @StateObject private var search = Box("")

    var body: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            if let plan = store.plan {
                planView(plan)
            } else {
                list
            }
        }
        .cardStyle()
        .task { await store.refresh() }
    }

    @ViewBuilder private var list: some View {
        HStack(spacing: DS.sm) {
            Text("Apps").font(DS.body.weight(.medium))
            Spacer(minLength: DS.sm)
            if store.loaded { Text("\(store.apps.count)").font(DS.meta.monospacedDigit()).foregroundStyle(.tertiary) }
        }
        if store.apps.count > 5 {
            TextField("Procurar app", text: $search.value).textFieldStyle(.roundedBorder).font(DS.body)
        }
        if let message = store.message { toolNote(message, color: .secondary) }
        if !store.loaded { toolNote("A ler as apps…") }
        let found = store.apps.filter { search.value.isEmpty || $0.name.localizedStandardContains(search.value) }
        LazyVStack(spacing: 0) {
            ForEach(found) { app in
                Button { store.choose(app) } label: {
                    HStack(spacing: DS.sm) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 16, height: 16)
                        Text(app.name).font(DS.body).lineLimit(1)
                        Spacer(minLength: DS.sm)
                        Image(systemName: "chevron.right").font(DS.meta).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        toolNote("Vai tudo para o Lixo. As apps da Apple e o próprio AgentStats não aparecem.")
    }

    @ViewBuilder private func planView(_ plan: UninstallPlan) -> some View {
        HStack(spacing: DS.sm) {
            IconButton(systemName: "chevron.left", help: "Voltar às apps") { store.cancel() }
            VStack(alignment: .leading, spacing: 2) {
                Text(plan.app.name).font(DS.body.weight(.medium)).lineLimit(1)
                Text(plan.app.bundleID).font(DS.meta).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        HStack(spacing: DS.sm) {
            Image(systemName: "checkmark.square.fill").foregroundStyle(.secondary).frame(width: 16)
            Text(store.shortPath(plan.app.path)).lineLimit(1).truncationMode(.middle)
        }
        .font(DS.body)

        if plan.sharedWithCopy {
            toolNote("Há outra cópia desta app no Mac, por isso os dados ficam: também são dela.")
        } else if plan.leftovers.isEmpty {
            toolNote("Não encontrei restos com o identificador desta app.")
        } else {
            HStack(spacing: DS.sm) {
                Text("Restos, escolhe o que vai").font(DS.meta).foregroundStyle(.secondary)
                Spacer(minLength: DS.sm)
                let everything = Set(plan.leftovers.map(\.path))
                toolLink(store.selected == everything ? "Nenhum" : "Todos") {
                    store.selected = store.selected == everything ? [] : everything
                    store.confirming = false
                }
            }
            ForEach(plan.leftovers) { entry in leftover(entry) }
            if plan.leftovers.contains(where: { $0.path.contains("/Library/Containers/") }) {
                toolNote("A pasta em Containers pode ter documentos teus.", color: Palette.waiting)
            }
        }

        if let message = store.message { toolNote(message, color: Palette.waiting) }
        if store.confirming {
            ConfirmBar(text: "Mover \(plan.app.name)\(selectionText) para o Lixo?", confirm: "Mover para o Lixo",
                       cancel: { store.confirming = false }, action: { store.moveToTrash() })
        } else {
            Button("Mover para o Lixo…") { store.confirming = true }.controlSize(.small)
        }
    }

    private var selectionText: String {
        switch store.selected.count {
        case 0: ", sem os restos,"
        case 1: " e 1 resto"
        case let n: " e \(n) restos"
        }
    }

    private func leftover(_ entry: UninstallPlan.Entry) -> some View {
        let on = store.selected.contains(entry.path)
        return Button {
            if on { store.selected.remove(entry.path) } else { store.selected.insert(entry.path) }
            store.confirming = false   // muda o que se ia confirmar
        } label: {
            HStack(spacing: DS.sm) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)).frame(width: 16)
                Text(store.shortPath(entry.path)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .font(DS.meta)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(entry.path)
        .accessibilityValue(on ? "Selecionado" : "Não selecionado")
    }
}
