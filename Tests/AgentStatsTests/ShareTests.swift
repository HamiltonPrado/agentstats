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

    @Test func requestRules() {
        let t = "abc"
        #expect(FileDrop.decide(requestLine: "GET /abc/f.pdf HTTP/1.1", token: t, served: false, expired: false) == .serve)
        #expect(FileDrop.decide(requestLine: "GET /abc/f.pdf HTTP/1.1", token: t, served: true, expired: false) == .gone)
        #expect(FileDrop.decide(requestLine: "GET /abc/f.pdf HTTP/1.1", token: t, served: false, expired: true) == .gone)
        #expect(FileDrop.decide(requestLine: "GET /abd/f.pdf HTTP/1.1", token: t, served: false, expired: false) == .notFound)
        #expect(FileDrop.decide(requestLine: "POST /abc/f.pdf HTTP/1.1", token: t, served: false, expired: false) == .notFound)
        #expect(FileDrop.decide(requestLine: "GET / HTTP/1.1", token: t, served: false, expired: false) == .notFound)
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

        // Depois de entregue, o servidor fecha: uma segunda tentativa não chega a nada.
        let again = try? await session.data(from: URL(string: "\(base)/\(server.token)/nota.txt")!)
        #expect(again == nil || (again?.1 as? HTTPURLResponse)?.statusCode == 410)
    }
}
