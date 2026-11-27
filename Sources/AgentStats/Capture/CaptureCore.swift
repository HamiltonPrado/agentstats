import Foundation

enum ShotKind: CaseIterable, Sendable {
    case area, window, screen

    var title: String {
        switch self {
        case .area: "Área"
        case .window: "Janela"
        case .screen: "Ecrã"
        }
    }

    var symbol: String {
        switch self {
        case .area: "rectangle.dashed"
        case .window: "macwindow"
        case .screen: "display"
        }
    }
}

/// Argumentos do `screencapture` e nomes dos ficheiros. Sem AppKit, para se testar sem captar nada.
enum CaptureCommand {
    static let tool = URL(fileURLWithPath: "/usr/sbin/screencapture")

    /// `display` começa em 1, o ecrã principal.
    static func screenshot(_ kind: ShotKind, display: Int, file: URL) -> [String] {
        switch kind {
        case .area: ["-i", "-s", file.path]
        case .window: ["-i", "-w", file.path]
        case .screen: ["-D\(display)", file.path]
        }
    }

    static func recording(display: Int, microphone: Bool, clicks: Bool, file: URL) -> [String] {
        var args = ["-v", "-D\(display)"]
        if microphone { args.append("-g") }
        if clicks { args.append("-k") }
        args.append(file.path)
        return args
    }

    /// "Captura 2026-11-22 às 14.03.22.png". Nunca reutiliza um nome: o `screencapture` escreve por cima.
    static func file(prefix: String, ext: String, in directory: URL, date: Date,
                     exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.dateFormat = "HH.mm.ss"
        let base = String(localized: "\(prefix) \(day.string(from: date)) às \(time.string(from: date))")
        var url = directory.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while exists(url) {
            url = directory.appendingPathComponent("\(base) (\(n)).\(ext)")
            n += 1
        }
        return url
    }

    /// Uma gravação deixada por uma AgentStats que morreu. O pid pode ter sido reutilizado por outro
    /// `screencapture` do utilizador, por isso também tem de estar órfã e a gravar para o nosso ficheiro.
    static func isOrphan(executable: String, parent: Int32, arguments: String?, file: String) -> Bool {
        guard executable == tool.path, parent == 1, !file.isEmpty, let arguments else { return false }
        return arguments.contains(file)
    }
}
