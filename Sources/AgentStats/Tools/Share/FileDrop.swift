import Darwin
import Foundation
import Network
import UniformTypeIdentifiers

/// As regras do envio de um ficheiro para o telemóvel, sem rede, para se testarem.
enum FileDrop {
    static let lifetime: TimeInterval = 10 * 60
    static let chunk = 1 << 20
    /// Ligações abertas ao mesmo tempo: um telemóvel usa uma ou duas; o resto é ruído (ou abuso) da rede.
    static let maxConnections = 8
    /// Tempo para chegar a linha do pedido, e tempo máximo sem progresso durante o envio.
    static let requestTimeout: TimeInterval = 10
    static let stallTimeout: TimeInterval = 30
    /// A linha do pedido nunca é maior do que isto (o caminho é o código mais o nome).
    static let maxRequest = 8 * 1024

    /// A primeira linha de um pedido HTTP, quando já chegou inteira.
    static func requestLine(_ buffer: Data) -> String? {
        guard let end = buffer.range(of: Data("\r\n".utf8)) else { return nil }
        return String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
    }

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
        preferred(Interfaces.ipv4().filter { !$0.loopback }.map { ($0.name, $0.ip) })
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
    /// O endereço onde escuta (o da rede local que o URL anuncia); nil = todos.
    private let host: String?
    private let queue = DispatchQueue(label: "agentstats.filedrop")
    private var listener: NWListener?
    /// As ligações abertas, para as fechar todas no fim (e não as deixar a enviar depois do Parar).
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    /// O primeiro aparelho que pediu o ficheiro: os outros ficam de fora.
    private var firstClient: String?
    private var deliveredAt: Date?
    private var notified = false
    private var closed = false
    /// Só usado na fila do servidor: espera pela porta.
    private var ready: CheckedContinuation<UInt16?, Never>?
    private let started = Date()
    private let onEnd: @Sendable (End) -> Void

    init(file: URL, host: String? = nil, onEnd: @escaping @Sendable (End) -> Void) {
        self.file = file
        self.host = host
        self.onEnd = onEnd
    }

    private func parameters() -> NWParameters {
        let p = NWParameters.tcp
        // Só no endereço da rede local: nem na VPN, nem noutras interfaces.
        if let host { p.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: .any) }
        return p
    }

    /// Devolve a porta, ou nil se não conseguir abrir.
    func start() async -> UInt16? {
        await withCheckedContinuation { (cont: CheckedContinuation<UInt16?, Never>) in
            queue.async {
                guard !self.closed, let l = try? NWListener(using: self.parameters()) else { cont.resume(returning: nil); return }
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
                    case .waiting(let e):
                        // Sem rede utilizável: não fica à espera para sempre.
                        guard self.ready != nil else { break }
                        self.finish(.failed(e.localizedDescription))
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
        for conn in connections.values { conn.cancel() }
        connections = [:]
        // Fechado antes de estar pronto: quem espera pela porta recebe nil.
        ready?.resume(returning: nil)
        ready = nil
    }

    private func handle(_ conn: NWConnection) {
        guard !closed, connections.count < FileDrop.maxConnections else { conn.cancel(); return }
        let id = ObjectIdentifier(conn)
        connections[id] = conn
        conn.stateUpdateHandler = { state in
            switch state {
            case .cancelled, .failed: self.connections[id] = nil
            default: break
            }
        }
        conn.start(queue: queue)
        let client: String = {
            if case .hostPort(let host, _) = conn.endpoint { return "\(host)" }
            return "?"
        }()
        // Quem abre e não diz nada é fechado.
        let answered = Flag()
        queue.asyncAfter(deadline: .now() + FileDrop.requestTimeout) { if !answered.value { conn.cancel() } }
        readRequest(conn, Data()) { line in
            answered.value = true
            guard let line else { conn.cancel(); return }
            self.answer(conn, line: line, client: client)
        }
    }

    /// Junta os bocados até chegar a linha do pedido inteira (pode vir em vários pacotes).
    private func readRequest(_ conn: NWConnection, _ buffer: Data, _ done: @escaping @Sendable (String?) -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let line = FileDrop.requestLine(buffer) { return done(line) }
            if error != nil || isComplete || buffer.count > FileDrop.maxRequest { return done(nil) }
            self.readRequest(conn, buffer, done)
        }
    }

    private func answer(_ conn: NWConnection, line: String, client: String) {
        switch FileDrop.decide(requestLine: line, token: token, client: client, firstClient: firstClient,
                               deliveredAt: deliveredAt, closed: closed, now: Date(), started: started) {
        case .notFound: reply(conn, FileDrop.status(404, "Not Found"))
        case .gone: reply(conn, FileDrop.status(410, "Gone"))
        case .serve:
            if firstClient == nil { firstClient = client }
            send(conn)
        }
    }

    private func reply(_ conn: NWConnection, _ data: Data) {
        conn.send(content: data, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func send(_ conn: NWConnection) {
        let regular = (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        guard regular, let handle = try? FileHandle(forReadingFrom: file) else {
            reply(conn, FileDrop.status(404, "Not Found"))
            finish(.failed("unreadable"))
            return
        }
        let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        conn.send(content: FileDrop.header(fileName: file.lastPathComponent, size: size), completion: .contentProcessed { _ in })
        Transfer(conn: conn, handle: handle, queue: queue) { [self] complete in
            // Uma transferência cancelada a meio não mata o link: pode tentar-se outra vez.
            guard complete, deliveredAt == nil else { return }
            deliveredAt = Date()
            notify(.delivered)
            queue.asyncAfter(deadline: .now() + FileDrop.regrace) { self.close() }
        }.next()
    }

    /// Só lido e escrito na fila do servidor.
    private final class Flag: @unchecked Sendable { var value = false }

    /// Envia o ficheiro aos bocados, um a seguir ao outro, na fila do servidor.
    private final class Transfer: @unchecked Sendable {
        let conn: NWConnection
        let handle: FileHandle
        let queue: DispatchQueue
        let done: (Bool) -> Void
        /// Conta os bocados enviados: se não mexer durante `stallTimeout`, o outro lado parou de ler.
        private var progress = 0
        private var finished = false

        init(conn: NWConnection, handle: FileHandle, queue: DispatchQueue, done: @escaping (Bool) -> Void) {
            self.conn = conn
            self.handle = handle
            self.queue = queue
            self.done = done
        }

        private func watch() {
            let seen = progress
            queue.asyncAfter(deadline: .now() + FileDrop.stallTimeout) {
                guard !self.finished, self.progress == seen else { return }
                self.end(false)
            }
        }

        private func end(_ complete: Bool) {
            guard !finished else { return }
            finished = true
            try? handle.close()
            conn.cancel()
            done(complete)
        }

        func next() {
            guard !finished else { return }
            progress += 1
            watch()
            let data = (try? handle.read(upToCount: FileDrop.chunk)) ?? Data()
            if data.isEmpty {
                conn.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { error in
                    self.end(error == nil)
                })
                return
            }
            conn.send(content: data, completion: .contentProcessed { error in
                if error != nil { self.end(false) } else { self.next() }
            })
        }
    }
}
