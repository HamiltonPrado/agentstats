import AppKit
import CoreAudio

/// O `--snapshot` vai para o README e para o site, por isso nada aqui vem do Mac onde corre.
/// Cada loja fica em modo demonstração e deixa de ler.
@MainActor
enum DemoData {
    private struct DemoProcess {
        let pid: Int
        let name: String
        let cpu: Double
        let megabytes: UInt64
        let elapsed: String
        var app: String? = nil
    }

    private static let safari = "/Applications/Safari.app"
    private static let music = "/System/Applications/Music.app"
    private static let terminal = "/System/Applications/Utilities/Terminal.app"

    static func load(now: Date = Date()) -> Monitor {
        CaptureStore.shared.loadDemo()
        PortsStore.shared.loadDemo()
        BrewStore.shared.loadDemo()
        UninstallStore.shared.loadDemo()
        CleanupStore.shared.loadDemo()
        CleaningModeStore.shared.loadDemo()
        ClaudeHookStore.shared.loadDemo()
        ClipboardStore.shared.loadDemo(now: now)
        SpeedTestStore.shared.loadDemo(now: now)
        DiskScanStore.shared.loadDemo()
        AppMixer.shared.loadDemo(safari: safari, music: music)
        AudioControlStore.demo = true

        let m = Monitor(demo: true)
        system(m, now: now)
        processes(m)
        agents(m, now: now)
        return m
    }

    private static func wave(_ base: Double, _ amplitude: Double, _ speed: Double) -> History {
        var h = History()
        for i in 0..<60 {
            let x = Double(i) * speed
            let shape: Double = sin(x) + 0.4 * sin(x * 2.7)
            h.push(base + amplitude * shape)
        }
        return h
    }

    private static func system(_ m: Monitor, now: Date) {
        let gb: UInt64 = 1 << 30
        let mb: UInt64 = 1 << 20

        m.machine = "Apple M4"
        m.model = "Mac16,1"
        m.pCores = 4
        m.eCores = 6
        m.uptime = 3 * 3600 + 25 * 60
        m.thermal = .nominal

        m.cpu.total = 0.23
        m.cpu.user = 0.16
        m.cpu.system = 0.07
        m.cpu.cores = [0.46, 0.38, 0.31, 0.22, 0.24, 0.19, 0.16, 0.13, 0.11, 0.10]
        m.cpu.load = (2.1, 1.85, 1.6)

        m.memory.total = 24 * gb
        m.memory.app = 9 * gb
        m.memory.wired = 2 * gb + 512 * mb
        m.memory.compressed = gb + 512 * mb
        m.memory.cached = 6 * gb
        m.memory.free = 5 * gb
        m.memory.swapTotal = 2 * gb
        m.memory.swapUsed = 256 * mb

        m.network.downPerSec = 2_400_000
        m.network.upPerSec = 320_000
        m.network.wifi = WiFiInfo(interface: "en0", ssid: "Casa", rssi: -52, noise: -94, txRate: 1200, channel: 149, band: "5 GHz")
        m.network.totalDown = 3 * gb
        m.network.totalUp = 420 * mb
        m.network.localIP = "192.0.2.24"   // reservado para documentação (RFC 5737)
        m.network.interface = "en0"

        m.disk.total = 494_380_000_000   // o disco conta em múltiplos de 1000
        m.disk.free = 218_270_000_000
        m.disk.readPerSec = 4_100_000
        m.disk.writePerSec = 1_300_000
        m.gpu = 0.18

        var temps = TemperatureSample()
        temps.cpuAvg = 47.5
        temps.cpuMax = 54.2
        temps.chipAvg = 45.1
        temps.ssd = 36.4
        temps.battery = 30.2
        for i in 1...24 { temps.sensors.append((name: "Sensor \(i)", value: 40 + Double(i) / 2)) }
        m.temps = temps

        var battery = BatterySample()
        battery.percent = 0.78
        battery.minutesRemaining = 400
        battery.cycles = 120
        battery.health = 0.96
        battery.temperature = 30.2
        battery.systemWatts = 9.4
        m.battery = battery
        m.energyApps = [
            AppEnergy(id: "safari", name: "Safari", watts: 1.42),
            AppEnergy(id: "node", name: "node", watts: 0.86),
            AppEnergy(id: "music", name: "Music", watts: 0.21),
        ]
        m.energySinceUnplug = .demo(since: now.addingTimeInterval(-2.5 * 3600), apps: [
            AppEnergy(id: "safari", name: "Safari", watts: 0, joules: 14_400),
            AppEnergy(id: "node", name: "node", watts: 0, joules: 8_300),
            AppEnergy(id: "music", name: "Music", watts: 0, joules: 1_900),
        ])
        m.batteryDays = [BatteryDay(day: BatteryHistory.dayString(now.addingTimeInterval(-90 * 86_400)), health: 0.98, cycles: 96),
                         BatteryDay(day: BatteryHistory.dayString(now), health: 0.96, cycles: 120)]

        m.cpuHistory = wave(0.23, 0.07, 0.31)
        m.memHistory = wave(0.54, 0.02, 0.12)
        m.gpuHistory = wave(0.18, 0.05, 0.4)
        m.downHistory = wave(1_800_000, 700_000, 0.35)
        m.upHistory = wave(400_000, 120_000, 0.25)
        m.tempHistory = wave(52, 3, 0.2)

        let end: Double = (now.timeIntervalSince1970 / 60).rounded(.down) * 60
        var day: [MinuteSample] = []
        for i in 0..<1440 {
            let x = Double(i)
            let busy: Bool = (300..<420).contains(i) || (700..<790).contains(i) || (1300..<1440).contains(i)
            var cpu: Double = 0.14 + 0.06 * sin(x / 40)
            var temp: Double = 42 + 3 * sin(x / 30)
            if busy {
                cpu += 0.22
                temp += 12
            }
            let charge: Double = i < 900 ? 0.45 + x / 1800 : 0.95 - (x - 900) / 3200
            let mem: Double = 0.52 + 0.04 * sin(x / 90)
            day.append(MinuteSample(t: end - Double(1440 - i) * 60, cpu: cpu, mem: mem, temp: temp,
                                    working: busy ? 1 : 0, attention: (750..<760).contains(i), battery: charge))
        }
        m.day = day
    }

    private static func processes(_ m: Monitor) {
        let list: [DemoProcess] = [
            DemoProcess(pid: 4301, name: "claude", cpu: 34.2, megabytes: 420, elapsed: "48:12"),
            DemoProcess(pid: 4100, name: "node", cpu: 18.6, megabytes: 610, elapsed: "01:12:40"),
            DemoProcess(pid: 2210, name: "Safari", cpu: 11.4, megabytes: 880, elapsed: "03:10:00", app: safari),
            DemoProcess(pid: 4420, name: "codex", cpu: 8.9, megabytes: 260, elapsed: "22:05"),
            DemoProcess(pid: 410, name: "WindowServer", cpu: 7.3, megabytes: 190, elapsed: "03:25:00"),
            DemoProcess(pid: 4200, name: "python3", cpu: 4.1, megabytes: 150, elapsed: "40:18"),
            DemoProcess(pid: 2305, name: "Terminal", cpu: 2.2, megabytes: 130, elapsed: "02:45:00", app: terminal),
            DemoProcess(pid: 2400, name: "Music", cpu: 1.6, megabytes: 210, elapsed: "01:30:00", app: music),
        ]
        var samples: [ProcSample] = []
        var apps: [Int: AppInfo.Entry] = [:]
        for p in list {
            samples.append(ProcSample(pid: p.pid, ppid: 1, cpu: p.cpu, rssKB: p.megabytes * 1024,
                                      elapsed: p.elapsed, name: p.name, args: p.name))
            if let path = p.app {
                apps[p.pid] = AppInfo.Entry(name: p.name, icon: NSWorkspace.shared.icon(forFile: path))
            }
        }
        AppInfo.loadDemo(apps)
        m.topProcesses = samples
        m.topMemory = samples.sorted { $0.rssKB > $1.rssKB }
    }

    private static func agents(_ m: Monitor, now: Date) {
        let shop = "/Users/demo/loja"
        let api = "/Users/demo/api"
        let docs = "/Users/demo/guia"

        let claude = AgentProcess(pid: 4301, kind: "Claude Code", cpu: 34, memKB: 430_080, elapsed: "48:12",
                                  cwd: shop, children: ["npm"], isSubagent: false)
        let codex = AgentProcess(pid: 4420, kind: "Codex", cpu: 9, memKB: 266_240, elapsed: "22:05",
                                 cwd: api, children: [], isSubagent: false)
        let copilot = AgentProcess(pid: 4510, kind: "Copilot", cpu: 1, memKB: 153_600, elapsed: "15:40",
                                   cwd: docs, children: [], isSubagent: false)

        let approval = AgentSession(id: "demo-api", kind: "Codex", title: "Migrar a base de dados", cwd: api,
                                    model: "gpt-5.2-codex", state: .needsApproval("Bash"), detail: "npm run migrate",
                                    lastActivity: now.addingTimeInterval(-40), subagents: 0, process: codex)
        let working = AgentSession(id: "demo-shop", kind: "Claude Code", title: "Corrigir o checkout", cwd: shop,
                                   model: "claude-opus-5-5", state: .runningTool("Bash"), detail: "npm test -- checkout",
                                   lastActivity: now.addingTimeInterval(-8), subagents: 1, process: claude)
        let waiting = AgentSession(id: "demo-docs", kind: "Copilot", title: "Rever o guia de instalação", cwd: docs,
                                   model: nil, state: .waitingUser, detail: "Guia revisto. Queres que faça o resumo?",
                                   lastActivity: now.addingTimeInterval(-300), subagents: 0, process: copilot)
        m.sessions = [approval, working, waiting]
        m.agents = [claude, codex, copilot]

        let shopTokens = TokenUsage(input: 82_000, output: 36_000, cacheRead: 1_540_000, cacheWrite: 92_000)
        let apiTokens = TokenUsage(input: 120_000, output: 21_000, cacheRead: 680_000, cacheWrite: 0)
        let docsTokens = TokenUsage(input: 40_000, output: 9_000, cacheRead: 210_000, cacheWrite: 0)

        var usage = UsageSnapshot()
        usage.perSession = [working.id: shopTokens, approval.id: apiTokens, waiting.id: docsTokens]
        usage.perSessionCost = [working.id: 2.65, approval.id: 0.74]
        usage.todayClaude = shopTokens
        usage.todayCodex = apiTokens
        usage.todayOther = docsTokens

        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd"
        let totals: [Int] = [1_200_000, 2_900_000, 2_100_000, 3_600_000, 800_000, 1_700_000]
        for (i, total) in totals.enumerated() {
            let date = now.addingTimeInterval(Double(i - totals.count) * 86_400)
            var d = DayUsage(day: format.string(from: date))
            d.claude.cacheRead = total
            d.cost = Double(total) / 800_000
            usage.week.append(d)
        }
        var today = DayUsage(day: format.string(from: now), claude: shopTokens, codex: apiTokens, other: docsTokens)
        today.cost = 3.39
        usage.week.append(today)
        usage.projects = [
            ProjectUsage(name: "loja", usage: TokenUsage(cacheRead: 9_600_000), cost: 12.40),
            ProjectUsage(name: "api", usage: TokenUsage(cacheRead: 4_100_000), cost: 4.85),
            ProjectUsage(name: "guia", usage: TokenUsage(cacheRead: 1_430_000), cost: 1.50),
        ]

        let codexWindows: [LimitWindow] = [
            LimitWindow(id: "codex.primary", label: "5 horas", usedPercent: 18, resetsAt: now.addingTimeInterval(3 * 3600), duration: 5 * 3600),
            LimitWindow(id: "codex.secondary", label: "Semana", usedPercent: 33, resetsAt: now.addingTimeInterval(4 * 86_400), duration: 7 * 86_400),
        ]
        usage.codexLimits = PlanLimits(provider: .codex, plan: "Plus", windows: codexWindows,
                                       observedAt: now.addingTimeInterval(-90))
        m.usage = usage

        let claudeWindows: [LimitWindow] = [
            LimitWindow(id: "claude.five", label: "5 horas", usedPercent: 42, resetsAt: now.addingTimeInterval(2 * 3600), duration: 5 * 3600),
            LimitWindow(id: "claude.week", label: "Semana", usedPercent: 78, resetsAt: now.addingTimeInterval(2 * 86_400), duration: 7 * 86_400),
        ]
        m.claudeLimits = PlanLimits(provider: .claude, plan: "Max", windows: claudeWindows,
                                    observedAt: now.addingTimeInterval(-30))

        var history: [AgentActivityRecord] = []
        history.append(AgentActivityRecord(session: working, tokens: shopTokens.total, now: now.addingTimeInterval(-2880)))
        history.append(AgentActivityRecord(session: approval, tokens: apiTokens.total, now: now.addingTimeInterval(-1320)))
        history.append(AgentActivityRecord(session: waiting, tokens: docsTokens.total, now: now.addingTimeInterval(-940)))
        m.activityHistory = history
    }
}
