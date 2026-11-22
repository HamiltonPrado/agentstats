import SwiftUI

struct BrewPackage: Identifiable, Sendable, Equatable {
    enum Kind: String, Sendable { case formula, cask }

    var id: String { "\(kind.rawValue):\(token)" }
    let kind: Kind
    /// O nome completo, que é o que se passa ao brew (ex.: "user/tap/nome").
    let token: String
    let name: String
    let installed: String
    let latest: String
    let outdated: Bool
    let pinned: Bool
    /// Falso: veio como dependência de outro.
    let requested: Bool
}

enum BrewAction: Equatable, Sendable {
    case updateIndex
    case upgrade(BrewPackage)
    case upgradeAll
    case uninstall(BrewPackage)
}

enum BrewRules {
    static let candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    static func packages(json: Data) -> [BrewPackage]? {
        guard let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let formulae = root["formulae"] as? [[String: Any]], let casks = root["casks"] as? [[String: Any]] else { return nil }
        var out: [BrewPackage] = []
        for f in formulae {
            let installs = f["installed"] as? [[String: Any]] ?? []
            guard let name = f["name"] as? String, let token = (f["full_name"] as? String) ?? f["name"] as? String,
                  validToken(token), !installs.isEmpty else { continue }
            out.append(BrewPackage(
                kind: .formula, token: token, name: name,
                installed: installs.last?["version"] as? String ?? "",
                latest: (f["versions"] as? [String: Any])?["stable"] as? String ?? "",
                outdated: f["outdated"] as? Bool ?? false,
                pinned: f["pinned"] as? Bool ?? false,
                requested: installs.contains { $0["installed_on_request"] as? Bool ?? false }))
        }
        for c in casks {
            guard let short = c["token"] as? String, let token = (c["full_token"] as? String) ?? c["token"] as? String,
                  validToken(token), let installed = c["installed"] as? String else { continue }
            out.append(BrewPackage(
                kind: .cask, token: token, name: (c["name"] as? [String])?.first ?? short,
                installed: installed, latest: c["version"] as? String ?? "",
                outdated: c["outdated"] as? Bool ?? false,
                pinned: c["pinned"] as? Bool ?? false,
                requested: true))
        }
        return out.sorted { a, b in
            a.outdated != b.outdated ? a.outdated : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Um nome nunca pode ser lido como opção ("--force") nem como caminho.
    static func validToken(_ token: String) -> Bool {
        token.range(of: #"\A[A-Za-z0-9][A-Za-z0-9@+._/-]*\z"#, options: .regularExpression) != nil && !token.contains("..")
    }

    static func arguments(_ action: BrewAction) -> [String] {
        switch action {
        case .updateIndex: ["update"]
        case .upgrade(let p): ["upgrade", "--\(p.kind.rawValue)", p.token]
        case .upgradeAll: ["upgrade"]
        // Sem --zap, --force nem --ignore-dependencies: se outro pacote precisar dele, o brew recusa.
        case .uninstall(let p): ["uninstall", "--\(p.kind.rawValue)", p.token]
        }
    }

    static func environment(base: [String: String], brew: String) -> [String: String] {
        var env = base
        env["PATH"] = (brew as NSString).deletingLastPathComponent + ":/usr/bin:/bin:/usr/sbin:/sbin"
        // Nada acontece além do que se confirmou:
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_AUTOREMOVE"] = "1"        // sem isto, remover um pacote apaga também "órfãos"
        env["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"   // sem isto, atualizar apaga versões antigas de tudo
        env["HOMEBREW_NO_ANALYTICS"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["HOMEBREW_NO_COLOR"] = "1"
        env["HOMEBREW_NO_EMOJI"] = "1"
        env["HOMEBREW_NO_ASK"] = "1"               // a confirmação já foi feita no painel
        // Se algum passo precisar de administrador falha logo, em vez de pedir a password.
        env["SUDO_ASKPASS"] = "/usr/bin/false"
        return env
    }
}

@MainActor
final class BrewStore: ObservableObject {
    static let shared = BrewStore()

    @Published private(set) var packages: [BrewPackage] = []
    @Published private(set) var loaded = false
    @Published private(set) var loading = false
    @Published private(set) var running: BrewAction?
    @Published private(set) var message: String?
    @Published private(set) var output: String?
    @Published var confirming: BrewAction?

    let brew: String?
    private var demo = false

    init(brew: String? = BrewRules.candidates.first { FileManager.default.isExecutableFile(atPath: $0) }) {
        self.brew = brew
    }

    var outdated: [BrewPackage] { packages.filter { $0.outdated && !$0.pinned } }
    var busy: Bool { loading || running != nil }

    private func run(_ arguments: [String], timeout: TimeInterval) async -> ToolOutput? {
        guard let brew else { return nil }
        return await ToolRunner.run(brew, arguments,
                                    environment: BrewRules.environment(base: ProcessInfo.processInfo.environment, brew: brew),
                                    timeout: timeout)
    }

    func refresh() async {
        guard !demo, !loading else { return }
        loading = true
        defer { loading = false }
        guard let result = await run(["info", "--json=v2", "--installed"], timeout: 90) else { return }
        loaded = true
        guard result.ok, let found = BrewRules.packages(json: Data(result.out.utf8)) else {
            message = "O Homebrew não devolveu a lista."
            output = result.summary
            return
        }
        packages = found
    }

    func perform(_ action: BrewAction) async {
        guard !demo, !busy else { return }
        confirming = nil
        running = action
        message = nil
        output = nil
        if let result = await run(BrewRules.arguments(action), timeout: 30 * 60) {
            output = result.summary
            message = result.ok ? "Feito."
                : result.timedOut ? "Demorou mais de 30 minutos e foi interrompido."
                : "O Homebrew recusou ou falhou. Se precisar de administrador, corre-o no Terminal."
        }
        running = nil
        await refresh()
    }

    func loadDemo() {
        demo = true
        loaded = true
        packages = [
            BrewPackage(kind: .formula, token: "node", name: "node", installed: "24.1.0", latest: "24.2.0", outdated: true, pinned: false, requested: true),
            BrewPackage(kind: .cask, token: "utm", name: "UTM", installed: "4.6.4", latest: "4.6.5", outdated: true, pinned: false, requested: true),
            BrewPackage(kind: .formula, token: "gh", name: "gh", installed: "2.80.0", latest: "2.80.0", outdated: false, pinned: false, requested: true),
            BrewPackage(kind: .formula, token: "ripgrep", name: "ripgrep", installed: "14.1.1", latest: "14.1.1", outdated: false, pinned: false, requested: true),
        ]
    }
}
