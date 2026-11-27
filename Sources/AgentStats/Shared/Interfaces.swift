import Darwin
import Foundation

/// Os endereços IPv4 das interfaces ligadas, pela ordem do sistema. Um só sítio com o `getifaddrs`
/// (código com ponteiros: três cópias já começavam a divergir).
enum Interfaces {
    struct Address: Equatable, Sendable {
        let name: String
        let ip: String
        let loopback: Bool
    }

    static func ipv4() -> [Address] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return [] }
        defer { freeifaddrs(ifaddr) }
        var out: [Address] = []
        var p = ifaddr
        while let a = p {
            let i = a.pointee
            if let addr = i.ifa_addr, Int32(addr.pointee.sa_family) == AF_INET, (i.ifa_flags & UInt32(IFF_UP)) != 0 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    out.append(Address(name: String(cString: i.ifa_name), ip: Sys.string(host),
                                       loopback: (i.ifa_flags & UInt32(IFF_LOOPBACK)) != 0))
                }
            }
            p = i.ifa_next
        }
        return out
    }
}
