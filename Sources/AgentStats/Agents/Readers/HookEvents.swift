import Foundation

/// Eventos enviados pelo Claude Code através de um hook de `Notification`
/// (`AgentStats --hook`, configurado em ~/.claude/settings.json).
///
/// O Claude Code avisa quando mostra um pedido de autorização ou quando fica à espera de resposta.
/// Isto é a fonte fiável para "precisa de aprovação"; a heurística dos processos fica como plano B.
struct HookEvent: Sendable, Equatable {
    enum Kind: String, Sendable { case permission, idle, other }
    let kind: Kind
    let message: String
    let date: Date
}

enum HookEvents {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/agentstats/events")
    }

    /// O hook está instalado se a pasta de eventos existe (é criada no primeiro evento).
    static var isActive: Bool { FileManager.default.fileExists(atPath: directory.path) }

    /// Classifica uma notificação pelo tipo e, como recurso, pelo texto da mensagem.
    static func kind(type: String?, message: String) -> HookEvent.Kind {
        let t = (type ?? "").lowercased(), msg = message.lowercased()
        if t.contains("permission") || msg.contains("permission") || msg.contains("approval") { return .permission }
        if t.contains("idle") || msg.contains("waiting for your input") { return .idle }
        return .other
    }

    /// Modo `--hook`: lê o JSON do stdin e grava o evento da sessão. Nunca escreve no stdout
    /// (a saída de um hook pode ser interpretada pelo Claude Code) e falha em silêncio.
    static func record(stdin: Data, now: Date = Date(), in dir: URL = directory) {
        guard let j = try? JSONSerialization.jsonObject(with: stdin) as? [String: Any],
              let session = j["session_id"] as? String,
              !session.isEmpty, !session.contains("/") else { return }
        let message = (j["message"] as? String) ?? ""
        let event: [String: Any] = [
            "kind": kind(type: j["notification_type"] as? String, message: message).rawValue,
            "message": message,
            "time": now.timeIntervalSince1970,
        ]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: event) else { return }
        try? data.write(to: dir.appendingPathComponent(session + ".json"), options: .atomic)
    }

    /// Último evento de uma sessão (o nome do transcript é o id da sessão).
    static func latest(session: String, in dir: URL = directory) -> HookEvent? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent(session + ".json")),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let time = j["time"] as? Double else { return nil }
        return HookEvent(kind: HookEvent.Kind(rawValue: j["kind"] as? String ?? "") ?? .other,
                         message: j["message"] as? String ?? "",
                         date: Date(timeIntervalSince1970: time))
    }

    /// Remove eventos com mais de um dia (sessões antigas).
    static func prune(in dir: URL = directory, olderThan age: TimeInterval = 86_400) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for f in files where ((try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < cutoff {
            try? FileManager.default.removeItem(at: f)
        }
    }
}
