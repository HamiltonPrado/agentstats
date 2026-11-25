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

    /// Depois de entregue, o mesmo aparelho ainda pode pedir outra vez durante este tempo: o Chrome para Android
    /// descarrega com um segundo pedido, e o Safari repete quando se cancela e volta a tocar.
    static let regrace: TimeInterval = 60

    enum Decision: Equatable { case serve, notFound, gone }

    /// Só um GET com o código certo, dentro do prazo, e só para o primeiro aparelho que o pediu.
    static func decide(requestLine: String, token: String, client: String, firstClient: String?,
                       deliveredAt: Date?, closed: Bool, now: Date, started: Date) -> Decision {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return .notFound }
        let path = parts[1].split(separator: "/", omittingEmptySubsequences: true)
        guard let first = path.first, first == token else { return .notFound }
        if closed || now.timeIntervalSince(started) > lifetime { return .gone }
        if let firstClient, firstClient != client { return .gone }
        if let deliveredAt, now.timeIntervalSince(deliveredAt) > regrace { return .gone }
        return .serve
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
    /// O primeiro aparelho que pediu o ficheiro: os outros ficam de fora.
    private var firstClient: String?
    private var deliveredAt: Date?
    private var notified = false
    private var closed = false
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

    /// Avisa uma só vez e fecha.
    private func finish(_ end: End) {
        notify(end)
        close()
    }

    private func notify(_ end: End) {
        guard !notified else { return }
        notified = true
        onEnd(end)
    }

    private func close() {
        guard !closed else { return }
        closed = true
        listener?.cancel()
        listener = nil
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        let client: String = {
            if case .hostPort(let host, _) = conn.endpoint { return "\(host)" }
            return "?"
        }()
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
            let line = data.flatMap { String(data: $0, encoding: .utf8) }?.components(separatedBy: "\r\n").first ?? ""
            switch FileDrop.decide(requestLine: line, token: self.token, client: client, firstClient: self.firstClient,
                                   deliveredAt: self.deliveredAt, closed: self.closed, now: Date(), started: self.started) {
            case .notFound: self.reply(conn, FileDrop.status(404, "Not Found"))
            case .gone: self.reply(conn, FileDrop.status(410, "Gone"))
            case .serve:
                if self.firstClient == nil { self.firstClient = client }
                self.send(conn)
            }
        }
    }

    private func reply(_ conn: NWConnection, _ data: Data) {
        conn.send(content: data, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func send(_ conn: NWConnection) {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            reply(conn, FileDrop.status(404, "Not Found"))
            finish(.failed("unreadable"))
            return
        }
        let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        conn.send(content: FileDrop.header(fileName: file.lastPathComponent, size: size), completion: .contentProcessed { _ in })
        Transfer(conn: conn, handle: handle) { [self] complete in
            // Uma transferência cancelada a meio não mata o link: pode tentar-se outra vez.
            guard complete, deliveredAt == nil else { return }
            deliveredAt = Date()
            notify(.delivered)
            queue.asyncAfter(deadline: .now() + FileDrop.regrace) { self.close() }
        }.next()
    }

    /// Envia o ficheiro aos bocados, um a seguir ao outro, na fila do servidor.
    private final class Transfer: @unchecked Sendable {
        let conn: NWConnection
        let handle: FileHandle
        let done: (Bool) -> Void

        init(conn: NWConnection, handle: FileHandle, done: @escaping (Bool) -> Void) {
            self.conn = conn
            self.handle = handle
            self.done = done
        }

        func next() {
            let data = (try? handle.read(upToCount: FileDrop.chunk)) ?? Data()
            if data.isEmpty {
                try? handle.close()
                conn.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { error in
                    self.conn.cancel()
                    self.done(error == nil)
                })
                return
            }
            conn.send(content: data, completion: .contentProcessed { error in
                if error != nil {
                    try? self.handle.close()
                    self.conn.cancel()
                    self.done(false)
                } else {
                    self.next()
                }
            })
        }
    }
}
