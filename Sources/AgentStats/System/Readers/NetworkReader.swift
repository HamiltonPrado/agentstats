import Foundation
import Darwin
import IOKit

final class NetworkReader {
    private var prev: [String: (UInt32, UInt32)] = [:]
    private var lastTime = Date()
    private var accDown: UInt64 = 0
    private var accUp: UInt64 = 0
    private var wifi: WiFiInfo?
    private var wifiReads = 0

    private func isPhysical(_ name: String) -> Bool {
        name.hasPrefix("en") || name.hasPrefix("pdp_ip")
    }

    func read() -> NetworkSample {
        var s = NetworkSample()
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return s }
        defer { freeifaddrs(ifaddr) }

        var cur: [String: (UInt32, UInt32)] = [:]
        var p = ifaddr
        while let a = p {
            let ifa = a.pointee
            let name = String(cString: ifa.ifa_name)
            if let addr = ifa.ifa_addr, isPhysical(name) {
                let family = Int32(addr.pointee.sa_family)
                if family == AF_LINK, let data = ifa.ifa_data {
                    let d = data.assumingMemoryBound(to: if_data.self).pointee
                    cur[name] = (d.ifi_ibytes, d.ifi_obytes)
                }
            }
            p = ifa.ifa_next
        }

        if let a = Interfaces.ipv4().first(where: { isPhysical($0.name) }) {
            s.localIP = a.ip
            s.interface = a.name
        }

        let now = Date()
        let dt = max(now.timeIntervalSince(lastTime), 0.001)
        let (down, up) = Self.delta(current: cur, previous: prev)
        if !prev.isEmpty {
            s.downPerSec = Double(down) / dt
            s.upPerSec = Double(up) / dt
            accDown += down; accUp += up
        }
        s.totalDown = accDown
        s.totalUp = accUp
        prev = cur
        lastTime = now
        // O Wi-Fi muda devagar: de 5 em 5 leituras chega.
        if wifiReads % 5 == 0 { wifi = WiFiReader.read() }
        wifiReads += 1
        s.wifi = wifi
        return s
    }

    /// Bytes recebidos e enviados entre duas leituras, só nas interfaces que já existiam na anterior.
    /// Os contadores são de 32 bits e dão a volta.
    static func delta(current: [String: (UInt32, UInt32)], previous: [String: (UInt32, UInt32)]) -> (down: UInt64, up: UInt64) {
        var down: UInt64 = 0, up: UInt64 = 0
        for (name, c) in current {
            guard let pv = previous[name] else { continue }
            down += UInt64(c.0 &- pv.0)
            up += UInt64(c.1 &- pv.1)
        }
        return (down, up)
    }
}
