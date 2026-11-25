import AppKit
import CoreImage
import Foundation
import Testing
@testable import AgentStats

@MainActor @Suite("Ler o ecrã", .serialized)
struct ScreenReadingTests {
    private func image(text: String) -> CGImage {
        let size = NSSize(width: 900, height: 220)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        (text as NSString).draw(at: NSPoint(x: 20, y: 120), withAttributes: [.font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.black])
        ("Segunda linha" as NSString).draw(at: NSPoint(x: 20, y: 40), withAttributes: [.font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage!
    }

    @Test func readsTextTopToBottom() {
        let text = ScreenReading.text(in: image(text: "Olá AgentStats 2026"))
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines.first?.contains("AgentStats") == true)
        #expect(lines.last?.contains("Segunda") == true)
    }

    @Test func readsAQRCode() throws {
        let filter = CIFilter(name: "CIQRCodeGenerator")!
        filter.setValue(Data("https://github.com/HamiltonPrado/agentstats".utf8), forKey: "inputMessage")
        let output = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let cg = try #require(CIContext().createCGImage(output, from: output.extent))
        #expect(ScreenReading.codes(in: cg) == ["https://github.com/HamiltonPrado/agentstats"])
    }

    @Test func orderIsByLineThenColumn() {
        let lines: [(CGRect, String)] = [(CGRect(x: 0.5, y: 0.8, width: 0.2, height: 0.05), "b"),
                                         (CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.05), "c"),
                                         (CGRect(x: 0.1, y: 0.81, width: 0.2, height: 0.05), "a")]
        #expect(ScreenReading.ordered(lines) == ["a", "b", "c"])
    }

    @Test func onlyWebLinksOpen() {
        #expect(ScreenReading.webLink("https://example.com/x") != nil)
        #expect(ScreenReading.webLink("WIFI:S:Casa;T:WPA;P:segredo;;") == nil)
        #expect(ScreenReading.webLink("file:///etc/passwd") == nil)
        #expect(ScreenReading.webLink("javascript:alert(1)") == nil)
    }

    @Test func colorFormats() {
        let c = NSColor(srgbRed: 52 / 255, green: 120 / 255, blue: 246 / 255, alpha: 1)
        #expect(ScreenReading.hex(c) == "#3478F6")
        #expect(ScreenReading.rgbText(c) == "rgb(52, 120, 246)")
    }
}

@Suite("Atalhos rápidos")
struct QuickTogglesTests {
    @Test func desktopIconsDefaultToShown() {
        #expect(QuickToggles.desktopIconsShown(nil as Any?))
        #expect(!QuickToggles.desktopIconsShown(false as Any?))
        #expect(!QuickToggles.desktopIconsShown(NSNumber(value: false) as Any?))
    }
}

@Suite("IP público e VPN")
struct NetworkExtrasTests {
    @Test func readsCloudflareTrace() {
        let r = NetworkExtras.parseTrace("fl=1\nh=cloudflare.com\nip=203.0.113.42\nts=1\nloc=PT\nwarp=off\n")
        #expect(r?.ip == "203.0.113.42" && r?.country == "PT")
        #expect(NetworkExtras.parseTrace("ip=2001:db8::1\nloc=XX\n")?.country == nil)
        #expect(NetworkExtras.parseTrace("ip=<script>\n") == nil)
        #expect(NetworkExtras.parseTrace("nada") == nil)
        #expect(SystemView.ipText("1.2.3.4", "Portugal") == "1.2.3.4 · Portugal")
    }

    @Test func connectedVPNsOnly() {
        let out = """
            Available network connection services in the current set (*=enabled):
            * (Disconnected)   81E6 VPN (com.nordvpn.NordVPN) "NordVPN - NordLynx"             [VPN:com.nordvpn.NordVPN]
            * (Connected)      3775 VPN (io.tailscale.ipn.macsys) "Tailscale"                      [VPN:io.tailscale.ipn.macsys]
            """
        #expect(NetworkExtras.connectedVPNs(out) == ["Tailscale"])
    }

    @Test func tunnelsNeedARealAddress() {
        let list = [(name: "utun0", ipv4: "169.254.1.1"), (name: "en0", ipv4: "192.168.1.5"), (name: "utun3", ipv4: "10.8.0.2")]
        #expect(NetworkExtras.tunnels(list) == ["utun3"])
    }
}

@Suite("Acessórios Bluetooth")
struct AccessoryBatteryTests {
    @Test func readsProfilerOutput() {
        let json = """
            {"SPBluetoothDataType":[{"device_connected":[
              {"AirPods Pro":{"device_minorType":"Headphones","device_batteryLevelLeft":"82%","device_batteryLevelRight":"79%","device_batteryLevelCase":"45%"}},
              {"Magic Keyboard":{"device_minorType":"Keyboard","device_batteryLevelMain":"100%"}},
              {"Coisa":{"device_minorType":"Speaker"}}
            ],"device_not_connected":[{"Velho":{"device_batteryLevelMain":"50%"}}]}]}
            """
        let a = AccessoryBatteryReader.parse(profiler: Data(json.utf8))
        #expect(a.map(\.name) == ["AirPods Pro", "Magic Keyboard"])
        #expect(a[0].parts.map(\.percent) == [82, 79, 45])
        #expect(a[0].lowest == 45 && a[0].symbol == "airpods")
        #expect(a[1].parts == [.init(label: "", percent: 100)])
    }

    @Test func percentages() {
        #expect(AccessoryBatteryReader.percent("80%") == 80)
        #expect(AccessoryBatteryReader.percent(NSNumber(value: 7)) == 7)
        #expect(AccessoryBatteryReader.percent("120%") == nil)
        #expect(AccessoryBatteryReader.percent(nil) == nil)
    }

    @Test func sameDeviceOnce() {
        let x = AccessoryBattery(name: "Magic Mouse", kind: "Mouse", parts: [.init(label: "", percent: 50)])
        let y = AccessoryBattery(name: "magic mouse", kind: nil, parts: [.init(label: "", percent: 51)])
        #expect(AccessoryBatteryReader.merged([x], [y]).count == 1)
    }
}
