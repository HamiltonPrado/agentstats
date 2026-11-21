import Foundation

struct SpeedTestResult: Sendable {
    let downloadMbps: Double
    let uploadMbps: Double
    let latencyMs: Double
    let measuredAt: Date
}

/// Small, on-demand test against Cloudflare's published speed-test endpoints.
enum SpeedTest {
    private static let base = URL(string: "https://speed.cloudflare.com")!
    private static let warmupBytes = 1_000_000
    private static let downloadSampleBytes = 10_000_000
    private static let uploadSampleBytes = 5_000_000

    static func run() async throws -> SpeedTestResult {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 45
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var latencies: [Double] = []
        for _ in 0..<3 {
            var request = URLRequest(url: endpoint("__down", bytes: 0))
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let start = ContinuousClock.now
            let (_, response) = try await session.data(for: request)
            try check(response)
            latencies.append(seconds(start.duration(to: ContinuousClock.now)) * 1_000)
        }

        // One small warm-up request lets the following parallel samples reuse a live connection.
        _ = try await transfer(session, path: "__down", bytes: warmupBytes, upload: false)
        _ = try await transfer(session, path: "__up", bytes: warmupBytes, upload: true)

        let downStart = ContinuousClock.now
        let downloaded = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<2 {
                group.addTask { try await transfer(session, path: "__down", bytes: downloadSampleBytes, upload: false) }
            }
            var total = 0
            for try await count in group { total += count }
            return total
        }
        let downSeconds = max(seconds(downStart.duration(to: ContinuousClock.now)), 0.001)
        let downloadMbps = Double(downloaded) * 8 / downSeconds / 1_000_000

        let upStart = ContinuousClock.now
        let uploaded = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<2 {
                group.addTask { try await transfer(session, path: "__up", bytes: uploadSampleBytes, upload: true) }
            }
            var total = 0
            for try await count in group { total += count }
            return total
        }
        let upSeconds = max(seconds(upStart.duration(to: ContinuousClock.now)), 0.001)
        let uploadMbps = Double(uploaded) * 8 / upSeconds / 1_000_000

        return SpeedTestResult(downloadMbps: downloadMbps, uploadMbps: uploadMbps,
                               latencyMs: median(latencies), measuredAt: Date())
    }

    private static func transfer(_ session: URLSession, path: String, bytes: Int, upload: Bool) async throws -> Int {
        var request = URLRequest(url: endpoint(path, bytes: bytes))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if upload {
            request.httpMethod = "POST"
            request.httpBody = Data(repeating: 0, count: bytes)
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        try check(response)
        return upload ? bytes : data.count
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[sorted.count / 2]
    }

    private static func endpoint(_ path: String, bytes: Int) -> URL {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "bytes", value: String(bytes))]
        return components.url!
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
