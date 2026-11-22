import Testing
@testable import AgentStats

// As contas dos leitores, com contadores inventados: nada lê o Mac.

@Suite struct CPUReaderTests {
    @Test func busyTimeOverTotalPerCoreAndOverall() {
        // user, system, idle, nice
        let before: [[UInt64]] = [[100, 50, 850, 0], [0, 0, 1000, 0]]
        let after: [[UInt64]] = [[160, 70, 910, 10], [10, 10, 1080, 0]]
        let s = CPUReader.sample(current: after, previous: before)
        #expect(s.cores.count == 2)
        #expect(abs(s.cores[0] - 0.6) < 1e-9)   // 90 ocupado em 150
        #expect(abs(s.cores[1] - 0.2) < 1e-9)   // 20 em 100
        #expect(abs(s.user - 80.0 / 250) < 1e-9)   // o nice conta como utilizador
        #expect(abs(s.system - 30.0 / 250) < 1e-9)
        #expect(abs(s.total - 110.0 / 250) < 1e-9)
    }

    @Test func firstReadingOrChangedCoreCountIsZero() {
        let now: [[UInt64]] = [[10, 10, 10, 0], [10, 10, 10, 0]]
        let s = CPUReader.sample(current: now, previous: [])
        #expect(s.cores == [0, 0])
        #expect(s.total == 0)
    }

    @Test func countersThatGoBackwardsNeverGoNegative() {
        let s = CPUReader.sample(current: [[5, 5, 100, 0]], previous: [[50, 50, 50, 0]])
        #expect(s.cores == [0])
        #expect(s.total == 0)
    }
}

@Suite struct MemoryReaderTests {
    @Test func purgeableCountsAsCacheNotApps() {
        var s = MemorySample()
        s.total = 16 * 1024
        let pages = MemoryReader.Pages(anonymous: 500, purgeable: 100, wired: 200, compressor: 50, external: 300, free: 80)
        MemoryReader.apply(pages, pageSize: 16, to: &s)
        #expect(s.app == 400 * 16)
        #expect(s.wired == 200 * 16)
        #expect(s.compressed == 50 * 16)
        #expect(s.cached == 400 * 16)
        #expect(s.free == 80 * 16)
        #expect(s.used == 650 * 16)
    }

    @Test func morePurgeableThanInternalIsZeroApps() {
        var s = MemorySample()
        MemoryReader.apply(MemoryReader.Pages(anonymous: 10, purgeable: 40, wired: 0, compressor: 0, external: 0, free: 0),
                           pageSize: 16, to: &s)
        #expect(s.app == 0)
        #expect(s.cached == 40 * 16)
    }
}

@Suite struct NetworkReaderTests {
    @Test func countsOnlyInterfacesSeenBefore() {
        let d = NetworkReader.delta(current: ["en0": (1500, 700), "en1": (999, 999)], previous: ["en0": (1000, 200)])
        #expect(d.down == 500)
        #expect(d.up == 500)
    }

    @Test func survivesThe32BitWrap() {
        let d = NetworkReader.delta(current: ["en0": (100, 0)], previous: ["en0": (UInt32.max - 99, 0)])
        #expect(d.down == 200)
    }
}

@Suite struct DiskReaderTests {
    @Test func bytesPerSecond() {
        #expect(DiskReader.rate(now: 3_000, before: 1_000, seconds: 2) == 1_000)
    }

    @Test func aCounterThatGoesBackIsZero() {
        #expect(DiskReader.rate(now: 10, before: 1_000, seconds: 2) == 0)
    }
}
