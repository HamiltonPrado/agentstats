import Foundation

/// Preço de um modelo na API, em dólares por milhão de tokens.
struct ModelPrice: Sendable, Equatable {
    var input: Double
    var output: Double
    var cacheRead: Double
    var cacheWrite: Double

    func cost(_ u: TokenUsage) -> Double {
        (Double(u.input) * input + Double(u.output) * output
         + Double(u.cacheRead) * cacheRead + Double(u.cacheWrite) * cacheWrite) / 1_000_000
    }
}

/// Quanto o mesmo trabalho custaria pago à API (preços públicos, sem descontos nem modo rápido).
/// Com um plano Pro/Max/Plus não é o que pagas: serve para comparar sessões e projetos.
enum Pricing {
    /// Atualizado a 2026-11-22. Ordem irrelevante: ganha o prefixo mais longo.
    static let table: [String: ModelPrice] = [
        // Anthropic
        "claude-fable-5-2": .init(input: 8, output: 40, cacheRead: 0.2, cacheWrite: 10),
        "claude-fable-5-1": .init(input: 10, output: 50, cacheRead: 0.25, cacheWrite: 12.5),
        "claude-fable-5": .init(input: 10, output: 50, cacheRead: 1, cacheWrite: 12.5),
        "claude-opus-5-5": .init(input: 4, output: 20, cacheRead: 0.2, cacheWrite: 5),
        "claude-opus-5": .init(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        "claude-opus-4-8": .init(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        "claude-opus-4-7": .init(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        "claude-opus-4-6": .init(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        "claude-opus-4-5": .init(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        "claude-opus-4": .init(input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75),
        "claude-sonnet-5-5": .init(input: 2, output: 10, cacheRead: 0.1, cacheWrite: 2.5),
        "claude-sonnet-5": .init(input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2.5),
        "claude-sonnet-4": .init(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
        "claude-haiku-5-5": .init(input: 0.1, output: 0.5, cacheRead: 0.01, cacheWrite: 0.125),
        "claude-haiku-4": .init(input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1.25),
        // OpenAI
        "gpt-6.1-sol": .init(input: 2, output: 10, cacheRead: 0.1, cacheWrite: 2.5),
        "gpt-6.1-terra": .init(input: 1, output: 5, cacheRead: 0.05, cacheWrite: 1.25),
        "gpt-6-sol": .init(input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2.5),
        "gpt-6-luna": .init(input: 0.1, output: 0.5, cacheRead: 0.01, cacheWrite: 0.125),
        "gpt-6-astra": .init(input: 10, output: 50, cacheRead: 1, cacheWrite: 12.5),
        "gpt-5.6-sol": .init(input: 4, output: 20, cacheRead: 0.4, cacheWrite: 5),
        "gpt-5.6-terra": .init(input: 2, output: 12, cacheRead: 0.2, cacheWrite: 2.5),
        "gpt-5.6-luna": .init(input: 0.2, output: 1.2, cacheRead: 0.02, cacheWrite: 0.25),
        "gpt-5.6": .init(input: 4, output: 20, cacheRead: 0.4, cacheWrite: 5),
        "gpt-5.5": .init(input: 5, output: 30, cacheRead: 0.5, cacheWrite: 5),
        "gpt-5.4": .init(input: 2.5, output: 15, cacheRead: 0.25, cacheWrite: 2.5),
        "gpt-5.3-codex": .init(input: 1.75, output: 14, cacheRead: 0.175, cacheWrite: 1.75),
        "gpt-5.2": .init(input: 1.75, output: 14, cacheRead: 0.175, cacheWrite: 1.75),
    ]

    /// Família mais recente de cada linha da OpenAI, para versões novas que a tabela ainda não tem
    /// (ex.: "gpt-6.2-sol" usa o preço do "gpt-6.1-sol").
    private static let families = ["sol": "gpt-6.1-sol", "terra": "gpt-6.1-terra", "luna": "gpt-6-luna", "astra": "gpt-6-astra"]

    static func price(for model: String?) -> ModelPrice? {
        guard var m = model?.lowercased(), !m.isEmpty, !m.hasPrefix("<") else { return nil }
        // "us.anthropic.claude-…", "anthropic/claude-…", "claude-…@20251101", "claude-…-20251101"
        if let r = m.range(of: "claude-") { m = String(m[r.lowerBound...]) }
        if let r = m.range(of: "gpt-") { m = String(m[r.lowerBound...]) }
        if let at = m.firstIndex(of: "@") { m = String(m[..<at]) }
        if let r = m.range(of: #"-\d{8}$"#, options: .regularExpression) { m.removeSubrange(r) }   // data da versão
        if let best = table.keys.filter({ m == $0 || m.hasPrefix($0 + "-") || m.hasPrefix($0 + ".") || m.hasPrefix($0 + "@") })
            .max(by: { $0.count < $1.count }) {
            return table[best]
        }
        if m.hasPrefix("gpt-"), let fam = families.first(where: { m.contains("-" + $0.key) }) { return table[fam.value] }
        return nil
    }

    static func cost(_ u: TokenUsage, model: String?) -> Double? { price(for: model).map { $0.cost(u) } }
}
