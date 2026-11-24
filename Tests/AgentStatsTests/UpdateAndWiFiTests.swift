import Foundation
import Testing
@testable import AgentStats

@Suite("Versões novas")
struct UpdateCheckTests {
    @Test(arguments: [("1.19", "1.18.1", true), ("1.18.1", "1.18.1", false), ("1.18", "1.18.0", false),
                      ("1.10", "1.9", true), ("v2.0", "1.99.9", true), ("1.18.0", "1.18.1", false),
                      ("banana", "1.0", false), ("1.2.x", "1.0", false)])
    func compares(_ candidate: String, _ current: String, _ newer: Bool) {
        #expect(UpdateCheck.isNewer(candidate, than: current) == newer)
    }

    private func json(_ fields: String) -> Data { Data("{\(fields)}".utf8) }

    @Test func readsTheLatestRelease() {
        let r = UpdateCheck.parse(json(#""tag_name":"v1.19","html_url":"https://github.com/HamiltonPrado/agentstats/releases/tag/v1.19","draft":false,"prerelease":false"#))
        #expect(r?.version == "1.19")
        #expect(r?.page.host == "github.com")
    }

    @Test func ignoresDraftsPrereleasesAndOtherHosts() {
        #expect(UpdateCheck.parse(json(#""tag_name":"v2","html_url":"https://github.com/x","prerelease":true"#)) == nil)
        #expect(UpdateCheck.parse(json(#""tag_name":"v2","html_url":"https://github.com/x","draft":true"#)) == nil)
        #expect(UpdateCheck.parse(json(#""tag_name":"v2","html_url":"https://example.com/x""#)) == nil)
        #expect(UpdateCheck.parse(json(#""tag_name":"nightly","html_url":"https://github.com/x""#)) == nil)
        #expect(UpdateCheck.parse(Data("not json".utf8)) == nil)
    }

    @Test func checksOncePerDay() {
        let now = Date()
        #expect(UpdateCheck.due(last: nil, now: now))
        #expect(!UpdateCheck.due(last: now.addingTimeInterval(-3600), now: now))
        #expect(UpdateCheck.due(last: now.addingTimeInterval(-25 * 3600), now: now))
        #expect(UpdateCheck.due(last: now.addingTimeInterval(3600), now: now))   // relógio andou para trás
    }
}

@Suite("Wi-Fi")
struct WiFiTests {
    private func info(_ rssi: Int) -> WiFiInfo {
        WiFiInfo(interface: "en0", ssid: nil, rssi: rssi, noise: -92, txRate: 866, channel: 36, band: "5 GHz")
    }

    @Test(arguments: [(-40, WiFiInfo.Quality.excellent), (-55, .excellent), (-60, .good), (-67, .good),
                      (-70, .fair), (-75, .fair), (-80, .weak)])
    func qualityFromSignal(_ rssi: Int, _ q: WiFiInfo.Quality) {
        #expect(info(rssi).quality == q)
    }

    @Test func signalToNoise() {
        #expect(info(-60).snr == 32)
    }
}
