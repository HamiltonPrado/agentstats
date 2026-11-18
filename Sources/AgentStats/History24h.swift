import Foundation

/// Um minuto do histórico: médias e máximos das amostras desse minuto.
struct MinuteSample: Codable, Sendable, Equatable {
    var t: TimeInterval        // início do minuto (segundos desde 1970)
    var cpu: Double            // média, 0…1
    var mem: Double            // média, 0…1
    var temp: Double?          // máximo da CPU, °C
    var working: Int           // máximo de agentes a trabalhar ao mesmo tempo
    var attention: Bool        // algum agente precisou de ti neste minuto
}

/// Junta as amostras (a cada 2 s) em minutos. Quando o minuto muda, devolve o minuto completo.
struct MinuteAccumulator: Sendable {
    private var minute: TimeInterval?
    private var cpuSum = 0.0, memSum = 0.0, count = 0
    private var tempMax: Double?
    private var workingMax = 0
    private var attention = false

    mutating func add(cpu: Double, mem: Double, temp: Double?, working: Int, attention needs: Bool, at date: Date) -> MinuteSample? {
        let m = (date.timeIntervalSince1970 / 60).rounded(.down) * 60
        var finished: MinuteSample?
        if let current = minute, current != m, count > 0 {
            finished = MinuteSample(t: current, cpu: cpuSum / Double(count), mem: memSum / Double(count),
                                    temp: tempMax, working: workingMax, attention: attention)
            self = MinuteAccumulator()
        }
        minute = m
        cpuSum += cpu; memSum += mem; count += 1
        if let temp { tempMax = max(tempMax ?? temp, temp) }
        workingMax = max(workingMax, working)
        attention = attention || needs
        return finished
    }
}

/// Histórico das últimas 24 horas, guardado em disco para sobreviver a reinícios.
enum History24h {
    static let window: TimeInterval = 24 * 3600

    static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentStats/history.json")
    }

    /// Remove o que tem mais de 24 h.
    static func pruned(_ samples: [MinuteSample], now: Date = Date()) -> [MinuteSample] {
        let cutoff = now.timeIntervalSince1970 - window
        return samples.filter { $0.t >= cutoff }
    }

    static func load(from url: URL = file, now: Date = Date()) -> [MinuteSample] {
        guard let data = try? Data(contentsOf: url),
              let samples = try? JSONDecoder().decode([MinuteSample].self, from: data) else { return [] }
        return pruned(samples, now: now)
    }

    static func save(_ samples: [MinuteSample], to url: URL = file) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(samples).write(to: url, options: .atomic)
        } catch {
            Log.readers.error("Não foi possível gravar o histórico: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Agrupa em blocos (por omissão de 10 min) para desenhar: 144 barras para 24 h.
    static func buckets(_ samples: [MinuteSample], minutes: Int = 10, now: Date = Date()) -> [(start: TimeInterval, working: Double, attention: Bool)] {
        let size = TimeInterval(minutes * 60)
        let end = (now.timeIntervalSince1970 / size).rounded(.down) * size
        let start = end - window + size
        var out: [(TimeInterval, Double, Bool)] = []
        var i = samples.startIndex
        let sorted = samples.sorted { $0.t < $1.t }
        var t = start
        while t <= end {
            var active = 0, total = 0, att = false
            while i < sorted.endIndex, sorted[i].t < t + size {
                if sorted[i].t >= t {
                    total += 1
                    if sorted[i].working > 0 { active += 1 }
                    att = att || sorted[i].attention
                }
                i += 1
            }
            out.append((t, total > 0 ? Double(active) / Double(minutes) : 0, att))
            t += size
        }
        return out
    }

    /// Minutos com pelo menos um agente a trabalhar.
    static func activeMinutes(_ samples: [MinuteSample]) -> Int { samples.filter { $0.working > 0 }.count }
}
