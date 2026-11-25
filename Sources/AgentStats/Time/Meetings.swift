import AppKit
@preconcurrency import EventKit
import SwiftUI

/// A próxima reunião do Calendário: quanto falta e o link para entrar (Zoom, Meet, Teams, Webex).
enum Meetings {
    static let enabledKey = "meetings.enabled"
    /// A partir de quando aparece na barra de menus.
    static let soon: TimeInterval = 15 * 60

    private static let hosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com", "whereby.com", "facetime.apple.com"]

    /// O primeiro link de videochamada num texto (URL do evento, local ou notas).
    static func joinLink(in texts: [String?]) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        for text in texts.compactMap({ $0 }) where !text.isEmpty {
            let range = NSRange(text.startIndex..., in: text)
            for match in detector?.matches(in: text, range: range) ?? [] {
                guard let url = match.url, let host = url.host?.lowercased(),
                      hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { continue }
                return url
            }
        }
        return nil
    }

    /// "em 12 min", "agora", "às 15:30".
    static func when(start: Date, end: Date, now: Date) -> String {
        if start <= now && end > now { return L("agora") }
        let mins = Int((start.timeIntervalSince(now) / 60).rounded(.up))
        if mins < 60 { return String(localized: "em \(mins) min") }
        return PlanLimitsCard.resetText(start, now: now)
    }

    /// Texto curto para a barra de menus, só quando está perto ou a decorrer.
    static func menuBarText(start: Date, end: Date, now: Date) -> String? {
        if start <= now && end > now { return L("agora") }
        let left = start.timeIntervalSince(now)
        guard left > 0, left <= soon else { return nil }
        return "\(Int((left / 60).rounded(.up))) min"
    }
}

struct MeetingInfo: Equatable {
    var title: String
    var start: Date
    var end: Date
    var link: URL?
}

@MainActor
final class MeetingsStore: ObservableObject {
    static let shared = MeetingsStore()

    @Published private(set) var next: MeetingInfo?
    @Published private(set) var access: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    @Published var enabled: Bool = Pref.bool(Meetings.enabledKey, false) {
        didSet {
            guard !demo else { return }   // as capturas não mexem nas preferências reais
            Pref.set(enabled, Meetings.enabledKey)
            refresh()
            onChange?()
        }
    }
    var onChange: (() -> Void)?
    private let store = EKEventStore()
    private var timer: Timer?
    private var demo = false

    var allowed: Bool { access == .fullAccess || access == .authorized }

    func start() {
        guard !demo else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in MainActor.assumeIsolated { MeetingsStore.shared.refresh() } }
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MeetingsStore.shared.refresh() }
        }
        refresh()
    }

    func requestAccess() {
        Task {
            _ = try? await store.requestFullAccessToEvents()
            access = EKEventStore.authorizationStatus(for: .event)
            if allowed { enabled = true }
            refresh()
        }
    }

    func refresh() {
        guard !demo else { return }
        access = EKEventStore.authorizationStatus(for: .event)
        guard enabled, allowed else { next = nil; onChange?(); return }
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3 * 3600), end: now.addingTimeInterval(24 * 3600), calendars: nil)
        let event = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now && $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
            .first
        next = event.map { MeetingInfo(title: $0.title ?? L("Reunião"), start: $0.startDate, end: $0.endDate,
                                       link: Meetings.joinLink(in: [$0.url?.absoluteString, $0.location, $0.notes])) }
        onChange?()
    }

    var menuBarText: String? {
        guard enabled, let n = next else { return nil }
        return Meetings.menuBarText(start: n.start, end: n.end, now: Date())
    }

    func loadDemo(now: Date) {
        demo = true
        enabled = true
        access = .fullAccess
        next = MeetingInfo(title: "Revisão do sprint", start: now.addingTimeInterval(12 * 60), end: now.addingTimeInterval(42 * 60),
                           link: URL(string: "https://meet.google.com/abc-defg-hij"))
    }
}

struct MeetingCard: View {
    @ObservedObject var store: MeetingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            Text("Próxima reunião").font(DS.body.weight(.medium))
            if !store.enabled || !store.allowed {
                note(store.access == .denied || store.access == .restricted
                     ? "Sem acesso ao Calendário. Dá-o em Definições do Sistema → Privacidade e Segurança → Calendários."
                     : "Mostra a próxima reunião, com o link para entrar, e a contagem na barra de menus nos últimos 15 minutos.", color: .text2)
                if store.access != .denied && store.access != .restricted {
                    Button("Ligar ao Calendário") { store.allowed ? (store.enabled = true) : store.requestAccess() }.controlSize(.small)
                }
            } else if let n = store.next {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L(n.title)).font(DS.body).lineLimit(2)
                            Text(Meetings.when(start: n.start, end: n.end, now: context.date)).font(DS.meta).foregroundStyle(Color.text2)
                        }
                        Spacer()
                        if let link = n.link { Button("Entrar") { NSWorkspace.shared.open(link) }.controlSize(.small) }
                    }
                }
                HStack { Spacer(); textLink("Desligar") { store.enabled = false } }
            } else {
                note("Nada nas próximas 24 horas.")
                HStack { Spacer(); textLink("Desligar") { store.enabled = false } }
            }
        }
        .cardStyle()
    }
}
