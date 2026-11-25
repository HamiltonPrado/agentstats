import AppKit
import SwiftUI
import UserNotifications

/// Regras "quando… então…". Ficam só neste Mac e não entram no exportar/importar das definições:
/// um ficheiro de outra pessoa nunca instala um comando que corra sozinho.
struct Rule: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var enabled = true
    var trigger: Trigger
    var action: Action

    enum Trigger: Codable, Equatable, Sendable {
        case agentFinished
        case agentNeedsYou
        case batteryBelow(Int)
        case powerConnected
        case powerDisconnected
        case displayConnected
        case displayDisconnected

        var title: String {
            switch self {
            case .agentFinished: L("Um agente termina")
            case .agentNeedsYou: L("Um agente precisa de ti")
            case .batteryBelow(let p): String(localized: "A bateria desce dos \(p)%")
            case .powerConnected: L("Ligo à corrente")
            case .powerDisconnected: L("Desligo da corrente")
            case .displayConnected: L("Ligo um monitor")
            case .displayDisconnected: L("Desligo um monitor")
            }
        }
    }

    enum Action: Codable, Equatable, Sendable {
        case sound(String)
        case notify(String)
        case command(String)
        case presentation(Bool)
        case muteMicrophone
        case arrangeWindow(String)   // WindowAction.rawValue

        var title: String {
            switch self {
            case .sound(let s): String(localized: "tocar o som \(s)")
            case .notify(let t): String(localized: "avisar: \(t)")
            case .command(let c): String(localized: "correr: \(c)")
            case .presentation(let on): L(on ? "ligar o modo apresentação" : "desligar o modo apresentação")
            case .muteMicrophone: L("silenciar o microfone")
            case .arrangeWindow(let a): String(localized: "pôr a janela da frente em: \(L(WindowAction(rawValue: a)?.title ?? a))")
            }
        }
    }
}

/// O que aconteceu, para as regras decidirem.
enum RuleEvent: Equatable, Sendable {
    case agentFinished, agentNeedsYou
    case battery(previous: Double?, now: Double)
    case power(connected: Bool)
    case displays(previous: Int, now: Int)
}

enum RuleMatching {
    static let sounds = ["Glass", "Ping", "Hero", "Submarine", "Funk", "Purr", "Sosumi", "Blow", "Pop", "Tink"]

    /// A bateria só conta ao atravessar o limite para baixo (uma vez por descida).
    static func matches(_ trigger: Rule.Trigger, _ event: RuleEvent) -> Bool {
        switch (trigger, event) {
        case (.agentFinished, .agentFinished), (.agentNeedsYou, .agentNeedsYou): return true
        case (.batteryBelow(let p), .battery(let prev, let now)):
            let limit = Double(p) / 100
            return now < limit && (prev.map { $0 >= limit } ?? false)
        case (.powerConnected, .power(let c)): return c
        case (.powerDisconnected, .power(let c)): return !c
        case (.displayConnected, .displays(let a, let b)): return b > a
        case (.displayDisconnected, .displays(let a, let b)): return b < a
        default: return false
        }
    }
}

@MainActor
final class RulesStore: ObservableObject {
    static let shared = RulesStore()
    static let key = "rules.list"

    @Published var rules: [Rule] = [] { didSet { if !demo { save() } } }
    @Published private(set) var lastRun: String?
    private var demo = false
    private var lastBattery: Double?
    private var lastPower: Bool?
    private var lastDisplays = NSScreen.screens.count

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key), let saved = try? JSONDecoder().decode([Rule].self, from: data) { rules = saved }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(rules) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    func start() {
        guard !demo else { return }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let store = RulesStore.shared
                let now = NSScreen.screens.count
                if now != store.lastDisplays { store.fire(.displays(previous: store.lastDisplays, now: now)) }
                store.lastDisplays = now
            }
        }
    }

    /// Chamado pelo Monitor a cada leitura da bateria.
    func battery(percent: Double, externalPower: Bool) {
        fire(.battery(previous: lastBattery, now: percent))
        if let last = lastPower, last != externalPower { fire(.power(connected: externalPower)) }
        lastBattery = percent
        lastPower = externalPower
    }

    func fire(_ event: RuleEvent) {
        guard !demo else { return }
        for rule in rules where rule.enabled && RuleMatching.matches(rule.trigger, event) { run(rule.action) }
    }

    func run(_ action: Rule.Action) {
        switch action {
        case .sound(let name): NSSound(named: name)?.play()
        case .notify(let text):
            let c = UNMutableNotificationContent()
            c.title = "AgentStats"
            c.body = text
            Notify.add(UNNotificationRequest(identifier: "rule-\(UUID().uuidString)", content: c, trigger: nil))
        case .command(let cmd):
            Task {
                let r = await ToolRunner.run("/bin/zsh", ["-lc", cmd], timeout: 120)
                lastRun = r.ok ? String(localized: "Correu: \(cmd)") : String(localized: "Falhou (\(r.status)): \(cmd)")
            }
        case .presentation(let on): Task { await PresentationMode.shared.set(on) }
        case .muteMicrophone: MicMuteStore.shared.set(true)
        case .arrangeWindow(let raw): if let a = WindowAction(rawValue: raw) { WindowMover.apply(a) }
        }
    }

    func loadDemo() {
        demo = true
        rules = [Rule(trigger: .agentFinished, action: .sound("Glass")),
                 Rule(trigger: .batteryBelow(20), action: .presentation(false)),
                 Rule(trigger: .displayConnected, action: .arrangeWindow(WindowAction.maximize.rawValue))]
    }
}

/// Definições → Regras.
struct RulesSettings: View {
    @ObservedObject var store: RulesStore
    @StateObject private var draftTrigger = Box("agentFinished")
    @StateObject private var draftAction = Box("sound")
    @StateObject private var percent = Box<Double>(20)
    @StateObject private var sound = Box("Glass")
    @StateObject private var text = Box("")
    @StateObject private var window = Box(WindowAction.maximize.rawValue)

    private let triggers: [(String, String)] = [("agentFinished", "Um agente termina"), ("agentNeedsYou", "Um agente precisa de ti"),
        ("batteryBelow", "A bateria desce de…"), ("powerConnected", "Ligo à corrente"), ("powerDisconnected", "Desligo da corrente"),
        ("displayConnected", "Ligo um monitor"), ("displayDisconnected", "Desligo um monitor")]
    private let actions: [(String, String)] = [("sound", "Tocar um som"), ("notify", "Mostrar um aviso"), ("command", "Correr um comando"),
        ("presentationOn", "Ligar o modo apresentação"), ("presentationOff", "Desligar o modo apresentação"),
        ("mute", "Silenciar o microfone"), ("window", "Organizar a janela da frente")]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.lg) {
            VStack(alignment: .leading, spacing: DS.sm) {
                Text("Regras").font(DS.body.weight(.medium))
                if store.rules.isEmpty { note("Ainda não há regras. Cria uma em baixo.") }
                ForEach(store.rules) { rule in
                    HStack(alignment: .top, spacing: DS.sm) {
                        Toggle("", isOn: Binding(get: { rule.enabled }, set: { on in
                            if let i = store.rules.firstIndex(where: { $0.id == rule.id }) { store.rules[i].enabled = on }
                        })).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(localized: "Quando: \(rule.trigger.title)")).font(DS.body)
                            Text(String(localized: "Então: \(rule.action.title)")).font(DS.meta).foregroundStyle(Color.text2).lineLimit(2)
                        }
                        Spacer()
                        IconButton(systemName: "trash", help: "Apagar") { store.rules.removeAll { $0.id == rule.id } }
                    }
                }
                if let r = store.lastRun { note(r, color: .text2) }
            }
            .cardStyle()

            VStack(alignment: .leading, spacing: DS.sm) {
                Text("Nova regra").font(DS.body.weight(.medium))
                Picker("Quando", selection: $draftTrigger.value) { ForEach(triggers, id: \.0) { Text(L($0.1)).tag($0.0) } }
                if draftTrigger.value == "batteryBelow" {
                    HStack {
                        Slider(value: $percent.value, in: 5...95).controlSize(.small)
                        Text("\(Int((percent.value / 5).rounded() * 5))%").font(DS.body.monospacedDigit()).frame(width: 40)
                    }
                }
                Picker("Então", selection: $draftAction.value) { ForEach(actions, id: \.0) { Text(L($0.1)).tag($0.0) } }
                switch draftAction.value {
                case "sound":
                    Picker("Som", selection: $sound.value) { ForEach(RuleMatching.sounds, id: \.self) { Text($0).tag($0) } }
                        .onChange(of: sound.value) { _, s in NSSound(named: s)?.play() }
                case "notify":
                    TextField("Texto do aviso", text: $text.value).textFieldStyle(.roundedBorder)
                case "command":
                    TextField("Comando (zsh)", text: $text.value).textFieldStyle(.roundedBorder).font(DS.body.monospaced())
                    note("Corre como tu, no zsh. Só regras criadas aqui: não vêm nas definições importadas.")
                case "window":
                    Picker("Janela", selection: $window.value) {
                        ForEach(WindowAction.allCases.filter { !$0.changesDisplay }) { Text(L($0.title)).tag($0.rawValue) }
                    }
                default: EmptyView()
                }
                HStack {
                    Spacer()
                    Button("Juntar regra") { add() }.disabled(!canAdd).controlSize(.small)
                }
            }
            .cardStyle()
        }
    }

    private var canAdd: Bool {
        !(draftAction.value == "notify" || draftAction.value == "command") || !text.value.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func add() {
        let trigger: Rule.Trigger = switch draftTrigger.value {
        case "agentNeedsYou": .agentNeedsYou
        case "batteryBelow": .batteryBelow(Int((percent.value / 5).rounded() * 5))
        case "powerConnected": .powerConnected
        case "powerDisconnected": .powerDisconnected
        case "displayConnected": .displayConnected
        case "displayDisconnected": .displayDisconnected
        default: .agentFinished
        }
        let t = text.value.trimmingCharacters(in: .whitespaces)
        let action: Rule.Action = switch draftAction.value {
        case "notify": .notify(t)
        case "command": .command(t)
        case "presentationOn": .presentation(true)
        case "presentationOff": .presentation(false)
        case "mute": .muteMicrophone
        case "window": .arrangeWindow(window.value)
        default: .sound(sound.value)
        }
        store.rules.append(Rule(trigger: trigger, action: action))
        text.value = ""
    }
}
