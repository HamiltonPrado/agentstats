import Darwin
import Foundation
import Network
import UniformTypeIdentifiers

/// As regras do envio de um ficheiro para o telemóvel, sem rede, para se testarem.
enum FileDrop {
    static let lifetime: TimeInterval = 10 * 60
    static let chunk = 1 << 20

    /// 128 bits aleatórios, em hexadecimal: impossível de adivinhar na rede local.
    static func token() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func url(host: String, port: UInt16, token: String, fileName: String) -> URL? {
        let name = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? "ficheiro"
        return URL(string: "http://\(host):\(port)/\(token)/\(name)")
    }

    enum Decision: Equatable { case serve, notFound, gone }

    /// Só um GET para o caminho com o código certo, uma vez e dentro do prazo.
    static func decide(requestLine: String, token: String, served: Bool, expired: Bool) -> Decision {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return .notFound }
        let path = parts[1].split(separator: "/", omittingEmptySubsequences: true)
        guard let first = path.first, first == token else { return .notFound }
        return served || expired ? .gone : .serve
    }

    static func header(fileName: String, size: Int64) -> Data {
        let type = UTType(filenameExtension: (fileName as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let ascii = fileName.unicodeScalars.map { $0.isASCII && $0 != "\"" && $0.value >= 32 ? String($0) : "_" }.joined()
        let encoded = fileName.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ascii
        let lines = ["HTTP/1.1 200 OK", "Content-Type: \(type)", "Content-Length: \(size)",
                     "Content-Disposition: attachment; filename=\"\(ascii)\"; filename*=UTF-8''\(encoded)",
                     "Cache-Control: no-store", "Connection: close", "", ""]
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    static func status(_ code: Int, _ text: String) -> Data {
        Data("HTTP/1.1 \(code) \(text)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
    }

    /// O IPv4 da rede local (Wi-Fi ou cabo), onde o telemóvel chega.
    static func localAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        var found: [(String, String)] = []
        var p = ifaddr
        while let a = p {
            let i = a.pointee
            if let addr = i.ifa_addr, Int32(addr.pointee.sa_family) == AF_INET, (i.ifa_flags & UInt32(IFF_UP)) != 0,
               (i.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    found.append((String(cString: i.ifa_name), Sys.string(host)))
                }
            }
            p = i.ifa_next
        }
        return preferred(found)
    }

    /// en0, en1… antes de túneis (VPN) e endereços de ligação local.
    static func preferred(_ list: [(name: String, ip: String)]) -> String? {
        let usable = list.filter { !$0.ip.hasPrefix("169.254.") }
        return (usable.first { $0.name.hasPrefix("en") } ?? usable.first { !$0.name.hasPrefix("utun") })?.ip
    }
}

/// O servidor de uma só entrega. Corre numa fila própria; avisa o fim pelo `onEnd`.
final class FileDropServer: @unchecked Sendable {
    enum End: Equatable { case delivered, expired, stopped, failed(String) }

    let file: URL
    let token = FileDrop.token()
    private let queue = DispatchQueue(label: "agentstats.filedrop")
    private var listener: NWListener?
    private var served = false
    private var ended = false
    /// Só usado na fila do servidor: espera pela porta.
    private var ready: CheckedContinuation<UInt16?, Never>?
    private let started = Date()
    private let onEnd: @Sendable (End) -> Void

    init(file: URL, onEnd: @escaping @Sendable (End) -> Void) {
        self.file = file
        self.onEnd = onEnd
    }

    /// Devolve a porta, ou nil se não conseguir abrir.
    func start() async -> UInt16? {
        await withCheckedContinuation { (cont: CheckedContinuation<UInt16?, Never>) in
            queue.async {
                guard let l = try? NWListener(using: .tcp, on: .any) else { cont.resume(returning: nil); return }
                self.listener = l
                self.ready = cont
                l.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        self.ready?.resume(returning: l.port?.rawValue)
                        self.ready = nil
                    case .failed(let e):
                        if let ready = self.ready {
                            ready.resume(returning: nil)
                            self.ready = nil
                        } else {
                            self.finish(.failed(e.localizedDescription))
                        }
                    default: break
                    }
                }
                l.newConnectionHandler = { conn in self.handle(conn) }
                l.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + FileDrop.lifetime) { self.finish(.expired) }
            }
        }
    }

    func stop() { queue.async { self.finish(.stopped) } }

    private func finish(_ end: End) {
        guard !ended else { return }
        ended = true
        listener?.cancel()
        listener = nil
        onEnd(end)
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
            let line = data.flatMap { String(data: $0, encoding: .utf8) }?.components(separatedBy: "\r\n").first ?? ""
            let expired = Date().timeIntervalSince(self.started) > FileDrop.lifetime
            switch FileDrop.decide(requestLine: line, token: self.token, served: self.served || self.ended, expired: expired) {
            case .notFound: self.reply(conn, FileDrop.status(404, "Not Found"))
            case .gone: self.reply(conn, FileDrop.status(410, "Gone"))
            case .serve:
                self.served = true
                self.send(conn)
            }
        }
    }

    private func reply(_ conn: NWConnection, _ data: Data) {
        conn.send(content: data, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func send(_ conn: NWConnection) {
        guard let h = try? FileHandle(forReadingFrom: file) else {
            reply(conn, FileDrop.status(404, "Not Found"))
            finish(.failed("unreadable"))
            return
        }
        let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        conn.send(content: FileDrop.header(fileName: file.lastPathComponent, size: size), completion: .contentProcessed { _ in })
        func next() {
            let data = (try? h.read(upToCount: FileDrop.chunk)) ?? Data()
            if data.isEmpty {
                try? h.close()
                conn.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { error in
                    conn.cancel()
                    self.finish(error == nil ? .delivered : .failed(error!.localizedDescription))
                })
                return
            }
            conn.send(content: data, completion: .contentProcessed { error in
                if let error {
                    try? h.close()
                    conn.cancel()
                    self.finish(.failed(error.localizedDescription))
                } else {
                    next()
                }
            })
        }
        next()
    }
}
