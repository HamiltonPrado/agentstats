import AppKit
import Foundation
import UserNotifications

/// Uma versão publicada no GitHub.
struct Release: Equatable, Sendable {
    var version: String   // sem o "v"
    var page: URL
}

enum UpdateCheck {
    static let enabledKey = "updates.check"
    static let lastCheckKey = "updates.lastCheck"
    static let notifiedKey = "updates.notified"
    static let interval: TimeInterval = 24 * 3600
    static let api = URL(string: "https://api.github.com/repos/HamiltonPrado/agentstats/releases/latest")!
    static let brewCommand = "brew upgrade --cask agentstats"

    /// "v1.18.1" → [1, 18, 1]. nil se não for uma versão.
    static func components(_ raw: String) -> [Int]? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.count <= 4, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.map { $0! }
    }

    /// 1.18 == 1.18.0; 1.18.1 > 1.18; 1.10 > 1.9.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let a = components(candidate), let b = components(current) else { return false }
        let n = max(a.count, b.count)
        let pa = a + Array(repeating: 0, count: n - a.count), pb = b + Array(repeating: 0, count: n - b.count)
        return pa.lexicographicallyPrecedes(pb) == false && pa != pb
    }

    /// A resposta de `releases/latest`. Rascunhos e pré-versões não contam.
    static func parse(_ data: Data) -> Release? {
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              j["draft"] as? Bool != true, j["prerelease"] as? Bool != true,
              let tag = j["tag_name"] as? String, components(tag) != nil,
              let html = j["html_url"] as? String, let page = URL(string: html),
              page.scheme == "https", page.host == "github.com" else { return nil }
        var version = tag
        if version.hasPrefix("v") || version.hasPrefix("V") { version.removeFirst() }
        return Release(version: version, page: page)
    }

    static func due(last: Date?, now: Date) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= interval || last > now
    }

    /// Instalada pelo Homebrew: a atualização faz-se por lá.
    static var installedWithHomebrew: Bool {
        ["/opt/homebrew/Caskroom/agentstats", "/usr/local/Caskroom/agentstats"].contains { FileManager.default.fileExists(atPath: $0) }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
}

/// Procura versões novas uma vez por dia, só no GitHub, e avisa uma vez por versão.
@MainActor
final class UpdateStore: ObservableObject {
    static let shared = UpdateStore()

    @Published private(set) var available: Release?
    @Published private(set) var checking = false
    private var timer: Timer?
    private var demo = false

    var enabled: Bool {
        get { Pref.bool(UpdateCheck.enabledKey, true) }
        set {
            Pref.set(newValue, UpdateCheck.enabledKey)
            objectWillChange.send()
            if newValue { check(force: true) } else { available = nil }
        }
    }

    func start() {
        guard !demo, timer == nil else { return }
        // Não à pressa no arranque: o resto da app primeiro.
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in UpdateStore.shared.check() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { self.check() }
    }

    func check(force: Bool = false) {
        guard !demo, enabled, !checking else { return }
        let last = UserDefaults.standard.object(forKey: UpdateCheck.lastCheckKey) as? Date
        guard force || UpdateCheck.due(last: last, now: Date()) else { return }
        checking = true
        Task {
            var request = URLRequest(url: UpdateCheck.api, timeoutInterval: 15)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("AgentStats", forHTTPHeaderField: "User-Agent")
            let release: Release? = await {
                guard let (data, response) = try? await URLSession.shared.data(for: request),
                      (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                return UpdateCheck.parse(data)
            }()
            checking = false
            guard let release else { return }   // sem rede: tenta outra vez na próxima hora
            UserDefaults.standard.set(Date(), forKey: UpdateCheck.lastCheckKey)
            if UpdateCheck.isNewer(release.version, than: UpdateCheck.currentVersion) {
                available = release
                notifyOnce(release)
            } else {
                available = nil
            }
        }
    }

    private func notifyOnce(_ r: Release) {
        guard UserDefaults.standard.string(forKey: UpdateCheck.notifiedKey) != r.version else { return }
        UserDefaults.standard.set(r.version, forKey: UpdateCheck.notifiedKey)
        let content = UNMutableNotificationContent()
        content.title = "AgentStats \(r.version) disponível"
        content.body = UpdateCheck.installedWithHomebrew ? "Atualiza com: \(UpdateCheck.brewCommand)" : "Abre o painel para ver as novidades."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "update-\(r.version)", content: content, trigger: nil))
    }

    func openPage() {
        if let page = available?.page { NSWorkspace.shared.open(page) }
    }

    func copyBrewCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(UpdateCheck.brewCommand, forType: .string)
    }

    func loadDemo(_ release: Release?) {
        demo = true
        available = release
    }
}
