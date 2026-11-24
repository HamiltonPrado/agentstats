import Foundation

/// Que separadores se veem, por que ordem e em qual o painel abre. Tudo em UserDefaults.
enum TabLayout {
    static let orderKey = "panel.tabOrder"
    static let hiddenKey = "panel.hiddenTabs"
    static let startKey = "panel.startTab"
    static let shortcutsKey = "panel.tabShortcuts"
    /// Abrir no último separador usado (o comportamento de sempre).
    static let lastUsed = "last"

    /// Todos os separadores, pela ordem escolhida. Os que não estão guardados (de versões novas) vão para o fim.
    static func order(_ raw: String?) -> [Tab] {
        var seen = Set<Tab>()
        var out: [Tab] = []
        for part in (raw ?? "").split(separator: ",") {
            if let tab = Tab(rawValue: String(part)), Tab.main.contains(tab), seen.insert(tab).inserted { out.append(tab) }
        }
        for tab in Tab.main where seen.insert(tab).inserted { out.append(tab) }
        return out
    }

    static func hidden(_ raw: String?) -> Set<Tab> {
        Set((raw ?? "").split(separator: ",").compactMap { Tab(rawValue: String($0)) })
    }

    /// Os que aparecem na barra. Nunca fica vazia: com tudo escondido, aparece o primeiro.
    static func visible(order rawOrder: String?, hidden rawHidden: String?) -> [Tab] {
        let all = order(rawOrder)
        let shown = all.filter { !hidden(rawHidden).contains($0) }
        return shown.isEmpty ? [all[0]] : shown
    }

    static func encode(_ tabs: [Tab]) -> String { tabs.map(\.rawValue).joined(separator: ",") }

    static func moved(order rawOrder: String?, _ tab: Tab, by offset: Int) -> String {
        var all = order(rawOrder)
        guard let i = all.firstIndex(of: tab), all.indices.contains(i + offset) else { return encode(all) }
        all.swapAt(i, i + offset)
        return encode(all)
    }

    /// Arrastar: põe o separador na posição de outro.
    static func moving(order rawOrder: String?, _ tab: Tab, to target: Tab) -> String {
        var all = order(rawOrder)
        guard tab != target, let from = all.firstIndex(of: tab), let to = all.firstIndex(of: target) else { return encode(all) }
        all.remove(at: from)
        all.insert(tab, at: to)
        return encode(all)
    }

    /// Mostrar ou esconder. Esconder o último que se vê não faz nada.
    static func toggled(hidden rawHidden: String?, _ tab: Tab, order rawOrder: String?) -> String {
        var set = hidden(rawHidden)
        if set.contains(tab) {
            set.remove(tab)
        } else if visible(order: rawOrder, hidden: rawHidden).filter({ $0 != tab }).isEmpty == false {
            set.insert(tab)
        }
        return encode(order(rawOrder).filter { set.contains($0) })
    }

    /// Em que separador abre o painel. As Definições ficam abertas se era onde se estava.
    static func tabOnOpen(stored: Tab, start: String?, visible: [Tab]) -> Tab {
        if let start, start != lastUsed, let tab = Tab(rawValue: start), visible.contains(tab) { return tab }
        if stored == .settings || visible.contains(stored) { return stored }
        return visible[0]
    }

    /// O separador do atalho n (1, 2, 3…), pela ordem da barra.
    static func shortcutTab(_ number: Int, visible: [Tab]) -> Tab? {
        visible.indices.contains(number - 1) ? visible[number - 1] : nil
    }

    /// Lidos agora das preferências.
    static var currentVisible: [Tab] {
        let d = UserDefaults.standard
        return visible(order: d.string(forKey: orderKey), hidden: d.string(forKey: hiddenKey))
    }
}
