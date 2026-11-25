import Foundation

/// O texto que os telemóveis leem para entrar numa rede Wi-Fi (o formato `WIFI:` que o iOS e o Android entendem).
enum WiFiQR {
    enum Security: String, CaseIterable, Identifiable, Sendable {
        case wpa = "WPA", wep = "WEP", open = "nopass"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .wpa: "WPA/WPA2/WPA3"
            case .wep: "WEP"
            case .open: "Sem password"
            }
        }
    }

    /// Os caracteres especiais do formato levam uma barra antes.
    static func escaped(_ s: String) -> String {
        var out = ""
        for c in s {
            if [Character("\\"), ";", ",", ":", "\""].contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }

    static func payload(ssid: String, password: String, security: Security, hidden: Bool = false) -> String? {
        let name = ssid.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, security == .open || !password.isEmpty else { return nil }
        var s = "WIFI:T:\(security.rawValue);S:\(escaped(name));"
        if security != .open { s += "P:\(escaped(password));" }
        if hidden { s += "H:true;" }
        return s + ";"
    }
}

/// A password de uma rede Wi-Fi que o Mac já conhece, lida do porta-chaves do sistema com o `security` do macOS.
/// É o macOS que pede a password de administrador (ou o Touch ID) no diálogo dele: a app nunca a vê.
enum WiFiPassword {
    enum Outcome: Equatable {
        case found(String)
        case notSaved
        case cancelled
        case failed
    }

    static func arguments(ssid: String) -> [String] {
        ["find-generic-password", "-D", "AirPort network password", "-a", ssid, "-w"]
    }

    /// 44 é "não existe"; 128 ou "canceled" é o Cancelar do diálogo do macOS.
    static func outcome(status: Int32, out: String, err: String) -> Outcome {
        if status == 0 {
            let password = out.trimmingCharacters(in: .newlines)
            return password.isEmpty ? .notSaved : .found(password)
        }
        if status == 44 || err.contains("could not be found") { return .notSaved }
        if status == 128 || err.lowercased().contains("cancel") { return .cancelled }
        return .failed
    }

    static func fetch(ssid: String) async -> Outcome {
        let name = ssid.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return .failed }
        let r = await ToolRunner.run("/usr/bin/security", arguments(ssid: name), timeout: 120)
        return outcome(status: r.timedOut ? -1 : r.status, out: r.out, err: r.err)
    }
}
