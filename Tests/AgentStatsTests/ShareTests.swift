import Foundation
import Network
import Testing
@testable import AgentStats

@Suite("Partilhar")
struct ShareTests {
    @Test func wifiPayload() {
        #expect(WiFiQR.payload(ssid: "Casa", password: "abc123", security: .wpa) == "WIFI:T:WPA;S:Casa;P:abc123;;")
        #expect(WiFiQR.payload(ssid: "Café; Lda", password: "a:b\\c", security: .wpa) == #"WIFI:T:WPA;S:Café\; Lda;P:a\:b\\c;;"#)
        #expect(WiFiQR.payload(ssid: "Livre", password: "", security: .open) == "WIFI:T:nopass;S:Livre;;")
        #expect(WiFiQR.payload(ssid: "  ", password: "x", security: .wpa) == nil)
        #expect(WiFiQR.payload(ssid: "Casa", password: "", security: .wpa) == nil)
    }

    @Test func savedWiFiPassword() {
        #expect(WiFiPassword.arguments(ssid: "Casa") == ["find-generic-password", "-D", "AirPort network password", "-a", "Casa", "-w"])
        #expect(WiFiPassword.outcome(status: 0, out: "segredo123\n", err: "") == .found("segredo123"))
        #expect(WiFiPassword.outcome(status: 44, out: "", err: "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain.") == .notSaved)
        #expect(WiFiPassword.outcome(status: 128, out: "", err: "User canceled the operation.") == .cancelled)
        #expect(WiFiPassword.outcome(status: 1, out: "", err: "outra coisa") == .failed)
    }

    @Test func requestRules() {
        let t = "abc", t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func d(_ line: String, client: String = "phone", first: String? = nil, delivered: Date? = nil, closed: Bool = false, at: TimeInterval = 10) -> FileDrop.Decision {
            FileDrop.decide(requestLine: line, token: t, client: client, firstClient: first, deliveredAt: delivered, closed: closed, now: t0 + at, started: t0)
        }
        #expect(d("GET /abc/f.pdf HTTP/1.1") == .serve)
        #expect(d("GET /abd/f.pdf HTTP/1.1") == .notFound)
        #expect(d("POST /abc/f.pdf HTTP/1.1") == .notFound)
        #expect(d("GET / HTTP/1.1") == .notFound)
        #expect(d("GET /abc/f.pdf HTTP/1.1", at: FileDrop.lifetime + 1) == .gone)                    // expirou
        #expect(d("GET /abc/f.pdf HTTP/1.1", client: "laptop", first: "phone") == .gone)             // outro aparelho
        #expect(d("GET /abc/f.pdf HTTP/1.1", first: "phone", delivered: t0 + 5, at: 30) == .serve)    // o Android pede outra vez
        #expect(d("GET /abc/f.pdf HTTP/1.1", first: "phone", delivered: t0 + 5, at: 5 + FileDrop.regrace + 1) == .gone)
        #expect(d("GET /abc/f.pdf HTTP/1.1", closed: true) == .gone)
        #expect(FileDrop.token().count == 32 && FileDrop.token() != FileDrop.token())
    }

    @Test func addressesAndHeaders() {
        #expect(FileDrop.preferred([("utun3", "10.8.0.2"), ("en0", "192.168.1.20")]) == "192.168.1.20")
        #expect(FileDrop.preferred([("en1", "169.254.3.3")]) == nil)
        #expect(FileDrop.url(host: "192.168.1.20", port: 8080, token: "t", fileName: "Férias 2024.pdf")?.absoluteString == "http://192.168.1.20:8080/t/F%C3%A9rias%202024.pdf")
        let h = String(decoding: FileDrop.header(fileName: "Férias.pdf", size: 10), as: UTF8.self)
        #expect(h.contains("Content-Type: application/pdf") && h.contains("Content-Length: 10") && h.contains("filename*=UTF-8''F%C3%A9rias%2Epdf"))
    }

    @Test func servesOnceThenRefuses() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("drop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("nota.txt")
        let body = Data(String(repeating: "AgentStats ", count: 200_000).utf8)   // ~2 MB: mais de um bloco
        try body.write(to: file)

        let ended = AsyncStream<FileDropServer.End>.makeStream()
        let server = FileDropServer(file: file) { ended.continuation.yield($0) }
        let port = try #require(await server.start())
        let base = "http://127.0.0.1:\(port)"
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)

        let (wrong, r0) = try await session.data(from: URL(string: "\(base)/errado/nota.txt")!)
        #expect((r0 as? HTTPURLResponse)?.statusCode == 404 && wrong.isEmpty)

        let (data, r1) = try await session.data(from: URL(string: "\(base)/\(server.token)/nota.txt")!)
        #expect((r1 as? HTTPURLResponse)?.statusCode == 200)
        #expect(data == body)
        var it = ended.stream.makeAsyncIterator()
        #expect(await it.next() == .delivered)

        // O mesmo aparelho pode pedir outra vez logo a seguir (o Chrome para Android faz isto).
        let (again, r2) = try await session.data(from: URL(string: "\(base)/\(server.token)/nota.txt")!)
        #expect((r2 as? HTTPURLResponse)?.statusCode == 200 && again == body)
        server.stop()
    }
    @Test func requestLineNeedsTheWholeLine() {
        #expect(FileDrop.requestLine(Data("GET /abc/x HTT".utf8)) == nil)
        #expect(FileDrop.requestLine(Data("GET /abc/x HTTP/1.1\r\nHost: y\r\n".utf8)) == "GET /abc/x HTTP/1.1")
    }

    /// O Parar fecha também as ligações abertas, e um pedido partido em dois pacotes ainda é servido.
    @Test func stopClosesOpenConnectionsAndSplitRequestsWork() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("drop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        try Data("ola".utf8).write(to: file)
        let server = FileDropServer(file: file, host: "127.0.0.1") { _ in }
        let port = try #require(await server.start())

        // Um pedido em dois bocados
        let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let q = DispatchQueue(label: "test")
        conn.start(queue: q)
        conn.send(content: Data("GET /\(server.token)/a.txt".utf8), completion: .contentProcessed { _ in })
        try await Task.sleep(for: .milliseconds(100))
        conn.send(content: Data(" HTTP/1.1\r\n\r\n".utf8), completion: .contentProcessed { _ in })
        let reply: Data = await withCheckedContinuation { c in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in c.resume(returning: data ?? Data()) }
        }
        #expect(String(decoding: reply, as: UTF8.self).hasPrefix("HTTP/1.1 200"))
        conn.cancel()

        // Uma ligação que não diz nada é fechada pelo Parar
        let idle = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let closed = AsyncStream<Void>.makeStream()
        idle.stateUpdateHandler = { if case .ready = $0 { idle.receive(minimumIncompleteLength: 1, maximumLength: 10) { _, _, done, err in if done || err != nil { closed.continuation.yield() } } } }
        idle.start(queue: q)
        try await Task.sleep(for: .milliseconds(200))
        server.stop()
        var it = closed.stream.makeAsyncIterator()
        _ = await it.next()
        idle.cancel()
    }

    /// Parado antes de abrir: quem espera pela porta recebe nil, em vez de ficar à espera para sempre.
    @Test func stoppedBeforeStartReturnsNil() async {
        let server = FileDropServer(file: URL(fileURLWithPath: "/dev/null")) { _ in }
        server.stop()
        #expect(await server.start() == nil)
    }
}
