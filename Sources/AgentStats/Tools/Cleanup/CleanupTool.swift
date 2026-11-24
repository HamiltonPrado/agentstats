import AppKit
import Darwin
import SwiftUI

/// Uma cache conhecida. A lista é fechada: o que não está aqui nunca se limpa.
struct CleanupTarget: Sendable, Equatable, Identifiable {
    enum Tool: String, Sendable {
        case brew, pip, npm

        var name: String {
            switch self {
            case .brew: "O Homebrew"
            case .pip: "O pip"
            case .npm: "O npm"
            }
        }
    }

    var id: String { path }
    /// Relativo à pasta pessoal.
    let path: String
    let name: String
    let detail: String
    /// Já vem marcada: volta a criar-se sozinha e só custa descarregar outra vez.
    let recommended: Bool
    /// Com esta ferramenta a correr não se mexe, mesmo sem ficheiros abertos nesse instante.
    var tool: Tool? = nil
    /// Com esta app aberta não se mexe.
    var bundleID: String? = nil
}

/// Os processos neste instante, para saber o que está em uso.
struct CleanupUsage: Sendable {
    /// Caminhos abertos, mapeados ou como pasta de trabalho.
    let openPaths: [String]
    let commands: [String]
}

enum CleanupBlock: Sendable, Equatable {
    case unknown
    case app(String)
    case tool(CleanupTarget.Tool)
    case inUse

    var text: String {
        switch self {
        case .unknown: "Não consegui confirmar se está em uso, por isso não mexo."
        case .app(let name): String(localized: "Fecha o \(name) primeiro.")
        case .tool(let tool): String(localized: "\(tool.name) está a correr.")
        case .inUse: "Está em uso agora."
        }
    }
}

struct CleanupEntry: Sendable, Equatable, Identifiable {
    var id: String { target.id }
    let target: CleanupTarget
    /// O caminho real, sem ligações.
    let path: String
    let signature: UninstallRules.Signature
    let bytes: UInt64
    let complete: Bool
    var block: CleanupBlock?
}

enum CleanupRules {
    // Fora de propósito: históricos e definições dos agentes, runtimes do Codex, a raiz da Hugging Face
    // (guarda o token de login) e qualquer cache cujo conteúdo não se conheça.
    static let targets: [CleanupTarget] = {
        var out: [CleanupTarget] = []
        out.append(CleanupTarget(path: "Library/Caches/Homebrew", name: "Homebrew",
                                 detail: "Downloads de pacotes. Voltam quando forem precisos.",
                                 recommended: true, tool: .brew))
        out.append(CleanupTarget(path: "Library/Caches/pip", name: "pip",
                                 detail: "Downloads de pacotes Python.",
                                 recommended: true, tool: .pip))
        out.append(CleanupTarget(path: ".npm/_cacache", name: "npm",
                                 detail: "Downloads de pacotes Node.",
                                 recommended: true, tool: .npm))
        out.append(CleanupTarget(path: "Library/Caches/BraveSoftware/Brave-Browser", name: "Brave",
                                 detail: "Os sites abrem mais devagar no início.",
                                 recommended: false, bundleID: "com.brave.Browser"))
        out.append(CleanupTarget(path: "Library/Caches/ms-playwright", name: "Playwright",
                                 detail: "Browsers de testes e MCP. Não voltam sozinhos: npx playwright install.",
                                 recommended: false))
        out.append(CleanupTarget(path: ".cache/huggingface/hub", name: "Hugging Face",
                                 detail: "Modelos. Voltam a descarregar, se ainda estiverem publicados.",
                                 recommended: false))
        out.append(CleanupTarget(path: ".npm/_npx", name: "npx",
                                 detail: "Ferramentas e servidores MCP. Precisam de rede para voltar.",
                                 recommended: false, tool: .npm))
        return out
    }()

    /// O caminho real, só se for uma pasta tua, no disco da pasta pessoal e sem ligações pelo meio.
    static func location(_ target: CleanupTarget, home: String) -> (path: String, signature: UninstallRules.Signature)? {
        let wanted = home + "/" + target.path
        var homeInfo = stat(), info = stat()
        guard stat(home, &homeInfo) == 0, lstat(wanted, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_dev == homeInfo.st_dev,
              let realHome = canonical(home), let real = canonical(wanted),
              real.lowercased() == (realHome + "/" + target.path).lowercased() else { return nil }
        return (real, UninstallRules.Signature(device: info.st_dev, inode: info.st_ino))
    }

    private static func canonical(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// nil: pode mexer. Na dúvida não mexe.
    static func block(_ target: CleanupTarget, path: String, usage: CleanupUsage?, appRunning: Bool) -> CleanupBlock? {
        if appRunning { return .app(target.name) }
        guard let usage else { return .unknown }
        if let tool = target.tool, usage.commands.contains(where: { runs(tool, command: $0) }) { return .tool(tool) }
        let folder = path.lowercased()
        let inside = folder + "/"
        if usage.openPaths.contains(where: { open in
            let p = open.lowercased()
            return p == folder || p.hasPrefix(inside)
        }) { return .inUse }
        // O node fecha os ficheiros depois de os ler: um servidor do npx só se vê pelos argumentos.
        if usage.commands.contains(where: { mentions($0, folder: folder) }) { return .inUse }
        return nil
    }

    private static func mentions(_ command: String, folder: String) -> Bool {
        // Medir (du) e ver quem tem ficheiros abertos (lsof) não é usar.
        if command.hasPrefix("/usr/bin/du ") || command.hasPrefix("/usr/sbin/lsof ") { return false }
        let c = command.lowercased()
        return c.hasSuffix(folder) || c.contains(folder + "/") || c.contains(folder + " ")
    }

    static func runs(_ tool: CleanupTarget.Tool, command: String) -> Bool {
        let words: [String] = command.split(separator: " ").map(String.init)
        let names: [String] = words.map { String($0.split(separator: "/").last ?? "") }
        // O programa, ou o script depois do interpretador e das opções dele ("bash -p …/brew", "node --x npm-cli.js").
        let head = zip(words, names).filter { !$0.0.hasPrefix("-") && $0.1 != "env" }.map(\.1).prefix(2)
        switch tool {
        case .brew:
            return head.contains("brew") || head.contains("brew.rb")   // só como programa, não como texto nos argumentos
        case .pip:
            if head.contains(where: { $0.range(of: #"\Apip[0-9.]*\z"#, options: .regularExpression) != nil }) { return true }
            return zip(words, words.dropFirst()).contains { $0 == "-m" && $1 == "pip" }
        case .npm:
            let known: Set<String> = ["npm", "npx", "npm-cli.js", "npx-cli.js"]
            return head.contains { known.contains($0) }
        }
    }

    static func openPaths(lsofOutput: String) -> (paths: [String], pids: Set<Int32>) {
        var paths: [String] = []
        var pids = Set<Int32>()
        for line in lsofOutput.split(separator: "\n") {
            if line.hasPrefix("n/") {
                paths.append(String(line.dropFirst()))
            } else if line.hasPrefix("p"), let pid = Int32(line.dropFirst()) {
                pids.insert(pid)
            }
        }
        return (paths, pids)
    }

    static func commands(psOutput: String) -> (commands: [String], pids: Set<Int32>) {
        var commands: [String] = []
        var pids = Set<Int32>()
        for raw in psOutput.split(separator: "\n") {
            let line = raw.drop(while: { $0 == " " })
            guard let space = line.firstIndex(of: " "), let pid = Int32(line[..<space]) else { continue }
            pids.insert(pid)
            commands.append(line[line.index(after: space)...].trimmingCharacters(in: .whitespaces))
        }
        return (commands, pids)
    }

    /// nil se alguma das leituras não for de confiança: cada uma tem de ver, pelo menos, este processo.
    static func readUsage() async -> CleanupUsage? {
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "en_US.UTF-8"   // sem isto os acentos vêm em \x e os caminhos não batem certo
        // -b e -w: não ficar preso num volume de rede. Com avisos o lsof sai com 1 e a lista é boa.
        let lsof = await ToolRunner.run("/usr/sbin/lsof", ["-n", "-P", "-b", "-w", "-u", String(getuid()), "-Fpn"],
                                        environment: environment, timeout: 20)
        guard !lsof.timedOut, lsof.status == 0 || lsof.status == 1 else { return nil }
        let files = openPaths(lsofOutput: lsof.out)

        let ps = await ToolRunner.run("/bin/ps", ["-axww", "-o", "pid=,args="], environment: environment, timeout: 10)
        guard ps.ok else { return nil }
        let processes = commands(psOutput: ps.out)

        let me = getpid()
        guard files.pids.contains(me), processes.pids.contains(me) else { return nil }
        return CleanupUsage(openPaths: files.paths, commands: processes.commands)
    }
}

/// Procura quando a secção aparece, move só o que se confirmou e só para o Lixo. Nunca corre sozinha.
@MainActor
final class CleanupStore: ObservableObject {
    struct Environment: Sendable {
        var home = FileManager.default.homeDirectoryForCurrentUser.path
        var targets = CleanupRules.targets
        var usage: @Sendable () async -> CleanupUsage? = { await CleanupRules.readUsage() }
        var isRunning: @Sendable (String) -> Bool = { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
        var measure: @Sendable (String) async -> (bytes: UInt64, complete: Bool) = { path in
            let result = await ToolRunner.run("/usr/bin/du", ["-skxP", path], timeout: 120)
            let bytes: UInt64? = DiskStorage.bytes(duOutput: result.out)
            return (bytes ?? 0, result.ok && bytes != nil)
        }
        /// A única forma de remover: nada aqui apaga de vez nem esvazia o Lixo.
        var trash: @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    }

    static let shared = CleanupStore(environment: Environment())

    /// Abaixo disto não vale a pena mostrar (o que sobra de uma cache acabada de limpar).
    static let minimumBytes: UInt64 = 1_000_000

    @Published private(set) var entries: [CleanupEntry] = []
    @Published private(set) var loaded = false
    @Published private(set) var scanning = false
    @Published private(set) var moving = false
    /// Exatamente o que se mostrou para confirmar: é só isto que se move.
    @Published private(set) var pending: [CleanupEntry]?
    @Published private(set) var message: String?
    @Published private(set) var problems: [String] = []
    /// O que foi mudado em relação ao que vem marcado.
    @Published private var toggled = Set<String>()

    private let environment: Environment
    private var demo = false

    init(environment: Environment) {
        self.environment = environment
    }

    var busy: Bool { scanning || moving }

    func isSelected(_ entry: CleanupEntry) -> Bool {
        entry.block == nil && entry.target.recommended != toggled.contains(entry.id)
    }

    var selected: [CleanupEntry] { entries.filter(isSelected) }

    func toggle(_ entry: CleanupEntry) {
        guard !busy, entry.block == nil else { return }
        toggled.formSymmetricDifference([entry.id])
        pending = nil   // muda o que se ia confirmar
    }

    func refresh() async {
        guard !demo, !busy else { return }
        scanning = true
        pending = nil
        defer { scanning = false }

        let usage = await environment.usage()
        var found: [CleanupEntry] = []
        for target in environment.targets {
            guard let place = CleanupRules.location(target, home: environment.home) else { continue }
            let size = await environment.measure(place.path)
            guard size.bytes >= Self.minimumBytes else { continue }
            let running: Bool = target.bundleID.map(environment.isRunning) ?? false
            let block = CleanupRules.block(target, path: place.path, usage: usage, appRunning: running)
            found.append(CleanupEntry(target: target, path: place.path, signature: place.signature,
                                      bytes: size.bytes, complete: size.complete, block: block))
        }
        entries = found
        loaded = true
    }

    func askToConfirm() {
        guard !busy else { return }
        let chosen = selected
        pending = chosen.isEmpty ? nil : chosen
        message = nil
        problems = []
    }

    func cancel() {
        pending = nil
    }

    /// Confirma tudo outra vez, uma pasta de cada vez: caminho, identidade e se está em uso.
    func moveToTrash() async {
        guard !demo, !busy, let chosen = pending else { return }
        pending = nil
        moving = true
        var moved: [CleanupEntry] = []
        var failed: [String] = []
        for entry in chosen {
            let usage = await environment.usage()
            let running: Bool = entry.target.bundleID.map(environment.isRunning) ?? false
            if let block = CleanupRules.block(entry.target, path: entry.path, usage: usage, appRunning: running) {
                failed.append("\(entry.target.name): \(block.text)")
                continue
            }
            let home = environment.home, trash = environment.trash
            let problem: String? = await Task.detached(priority: .userInitiated) {
                guard let place = CleanupRules.location(entry.target, home: home),
                      place.path == entry.path, place.signature == entry.signature else {
                    return "mudou entretanto, não mexi."
                }
                do { try trash(URL(fileURLWithPath: place.path)) } catch { return "o macOS não deixou mover." }
                return nil
            }.value
            if let problem {
                failed.append("\(entry.target.name): \(problem)")
            } else {
                moved.append(entry)
            }
        }

        let gone = Set(moved.map(\.id))
        entries.removeAll { gone.contains($0.id) }
        toggled.subtract(gone)   // uma opcional que volte a aparecer volta por marcar
        if moved.isEmpty {
            message = "Não movi nada."
        } else {
            let total: UInt64 = moved.reduce(UInt64(0)) { $0 + $1.bytes }
            let names: String = moved.map(\.target.name).joined(separator: ", ")
            message = String(localized: "\(Fmt.disk(total)) no Lixo (\(names)). O espaço só fica livre quando o esvaziares.")
        }
        problems = failed
        moving = false
    }

    func shortPath(_ entry: CleanupEntry) -> String {
        "~/" + entry.target.path
    }

    /// Para as capturas: nunca as pastas reais.
    func loadDemo() {
        demo = true
        loaded = true
        let sizes: [UInt64] = [1_240, 380, 210, 940, 620, 480, 160]
        var found: [CleanupEntry] = []
        for (index, (target, size)) in zip(CleanupRules.targets, sizes).enumerated() {
            found.append(CleanupEntry(target: target, path: "/Users/demo/" + target.path,
                                      signature: UninstallRules.Signature(device: 1, inode: UInt64(index + 1)),
                                      bytes: size * 1_000_000, complete: true,
                                      block: target.bundleID == nil ? nil : .app(target.name)))
        }
        entries = found
    }
}
