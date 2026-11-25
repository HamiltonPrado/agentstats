import Foundation
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
}
