import AppKit
import CoreLocation
import CoreWLAN
import Foundation

struct WiFiInfo: Equatable, Sendable {
    var interface: String
    /// nil sem autorização da Localização: o macOS esconde o nome da rede.
    var ssid: String?
    var rssi: Int          // dBm
    var noise: Int         // dBm
    var txRate: Double     // Mbps
    var channel: Int?
    var band: String?      // "2,4 GHz", "5 GHz", "6 GHz"

    var snr: Int { rssi - noise }

    enum Quality: String { case excellent = "Excelente", good = "Boa", fair = "Razoável", weak = "Fraca" }

    /// Pelo sinal, com os limites habituais (−55, −67 e −75 dBm).
    var quality: Quality {
        switch rssi {
        case (-55)...: .excellent
        case (-67)...: .good
        case (-75)...: .fair
        default: .weak
        }
    }
}

enum WiFiReader {
    static func read() -> WiFiInfo? {
        guard let i = CWWiFiClient.shared().interface(), i.powerOn() else { return nil }
        let rssi = i.rssiValue()
        guard rssi != 0 else { return nil }   // ligado, mas sem rede
        return WiFiInfo(interface: i.interfaceName ?? "Wi-Fi", ssid: i.ssid(), rssi: rssi, noise: i.noiseMeasurement(),
                        txRate: i.transmitRate(), channel: i.wlanChannel()?.channelNumber,
                        band: i.wlanChannel().map { band($0.channelBand) } ?? nil)
    }

    static func band(_ b: CWChannelBand) -> String? {
        switch b {
        case .band2GHz: "2,4 GHz"
        case .band5GHz: "5 GHz"
        case .band6GHz: "6 GHz"
        default: nil
        }
    }
}

/// O macOS só dá o nome da rede Wi-Fi a apps com acesso à Localização. A app nunca pede a posição.
@MainActor
final class LocationAccess: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationAccess()
    private let manager = CLLocationManager()
    @Published private(set) var status: CLAuthorizationStatus

    override init() {
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    var allowed: Bool { status == .authorizedAlways || status == .authorized }
    var undecided: Bool { status == .notDetermined }

    func request() {
        manager.requestWhenInUseAuthorization()
    }

    func openSettings() {
        SystemSettings.open(.location)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        Task { @MainActor in self.status = s }
    }
}
