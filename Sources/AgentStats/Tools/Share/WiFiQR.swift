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
