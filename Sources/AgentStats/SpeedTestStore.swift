import SwiftUI

/// O teste de velocidade vive fora da vista: mudar de separador ou fechar o painel não perde o
/// resultado nem deixa arrancar um segundo teste por cima do que está a correr.
@MainActor
final class SpeedTestStore: ObservableObject {
    static let shared = SpeedTestStore()

    @Published private(set) var running = false
    @Published private(set) var result: SpeedTestResult?
    @Published private(set) var error: String?

    private var demo = false
    private let test: @Sendable () async throws -> SpeedTestResult

    init(test: @escaping @Sendable () async throws -> SpeedTestResult = { try await SpeedTest.run() }) {
        self.test = test
    }

    @discardableResult
    func start() -> Task<Void, Never>? {
        guard !running, !demo else { return nil }
        running = true
        error = nil
        return Task {
            do {
                result = try await test()
            } catch {
                self.error = "Não foi possível concluir o teste. Verifica a ligação e tenta novamente."
            }
            running = false
        }
    }

    func loadDemo(now: Date) {
        demo = true
        result = SpeedTestResult(downloadMbps: 284.6, uploadMbps: 92.3, latencyMs: 14, measuredAt: now)
    }
}
