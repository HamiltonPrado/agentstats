import Darwin
import Foundation

/// IP público (só a pedido) e VPN ativa.
enum NetworkExtras {
    static let traceURL = URL(string: "https://cloudflare.com/cdn-cgi/trace")!

    /// Resposta do `cdn-cgi/trace` do Cloudflare: linhas `chave=valor`.
    static func parseTrace(_ text: String) -> (ip: String, country: String?)? {
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
        }
        guard let ip = fields["ip"], !ip.isEmpty, ip.allSatisfy({ $0.isHexDigit || $0 == "." || $0 == ":" }) else { return nil }
        let loc = fields["loc"].flatMap { $0.count == 2 && $0 != "XX" ? $0 : nil }
        return (ip, loc)
    }

    /// "PT" → "Portugal", no idioma do sistema.
    static func countryName(_ code: String) -> String {
        Locale.current.localizedString(forRegionCode: code) ?? code
    }

    /// `scutil --nc list`: as VPN registadas no macOS que estão ligadas.
    static func connectedVPNs(_ output: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            guard line.contains("(Connected)") else { return nil }
            let quoted = line.split(separator: "\"", omittingEmptySubsequences: false)
            return quoted.count >= 3 ? String(quoted[1]) : nil
        }
    }

    /// Túneis com um endereço IPv4 a sério: as VPN que não se registam no macOS (WireGuard, OpenVPN…).
    /// Os utun do sistema (iCloud, Continuidade) só têm IPv6 de ligação local.
    static func tunnels(_ list: [(name: String, ipv4: String)]) -> [String] {
        var out: [String] = []
        for t in list where (t.name.hasPrefix("utun") || t.name.hasPrefix("ipsec") || t.name.hasPrefix("ppp"))
            && !t.ipv4.hasPrefix("169.254.") && !t.ipv4.isEmpty && !out.contains(t.name) {
            out.append(t.name)
        }
        return out
    }

    static func tunnelAddresses() -> [(name: String, ipv4: String)] {
        Interfaces.ipv4().map { ($0.name, $0.ip) }
    }
}

@MainActor
final class NetworkExtrasStore: ObservableObject {
    static let shared = NetworkExtrasStore()

    @Published private(set) var publicIP: String?
    @Published private(set) var country: String?
    @Published private(set) var fetchingIP = false
    @Published private(set) var ipError: String?
    /// Nomes das VPN ligadas (ou das interfaces de túnel, se não estiverem registadas).
    @Published private(set) var vpns: [String] = []
    @Published private(set) var checkedVPN = false
    private var demo = false

    func refreshVPN() async {
        guard !demo else { return }
        let registered = NetworkExtras.connectedVPNs(await ToolRunner.run("/usr/sbin/scutil", ["--nc", "list"], timeout: 10).out)
        let tunnels = NetworkExtras.tunnels(NetworkExtras.tunnelAddresses())
        // Uma VPN registada também tem túnel: só se mostra o túnel quando não há nenhuma registada.
        vpns = registered.isEmpty ? tunnels : registered
        checkedVPN = true
    }

    /// Só a pedido: o Cloudflare vê o IP, como em qualquer ligação.
    func fetchPublicIP() async {
        guard !demo, !fetchingIP else { return }
        fetchingIP = true
        ipError = nil
        var request = URLRequest(url: NetworkExtras.traceURL, timeoutInterval: 10)
        request.setValue("AgentStats", forHTTPHeaderField: "User-Agent")
        if let (data, response) = try? await URLSession.shared.data(for: request),
           (response as? HTTPURLResponse)?.statusCode == 200,
           let r = NetworkExtras.parseTrace(String(decoding: data, as: UTF8.self)) {
            publicIP = r.ip
            country = r.country.map(NetworkExtras.countryName)
        } else {
            ipError = "Não consegui saber o IP público."
        }
        fetchingIP = false
    }

    func loadDemo() {
        demo = true
        publicIP = "203.0.113.42"
        country = "Portugal"
        vpns = []
        checkedVPN = true
    }
}
