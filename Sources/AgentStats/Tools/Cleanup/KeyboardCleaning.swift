import AppKit
import ApplicationServices
import Carbon.HIToolbox

// Modo de limpeza: teclado bloqueado e ecrã preto. O que importa é nunca deixar ninguém preso:
// - sem filtro a funcionar não há ecrã preto;
// - sai por três caminhos independentes: botão, as duas teclas ⌘ e tempo;
// - o tempo, as ⌘ e a permissão vigiam-se na thread do filtro, por isso soltam mesmo com a app pendurada;
// - se a app morrer, o macOS retira o filtro com ela.

enum CleaningEnd: Sendable, Equatable {
    case button, keys, timeUp, permission, secureInput, system, tapFailed

    var message: String? {
        switch self {
        case .button, .keys, .timeUp: nil
        case .permission: "Parei porque o AgentStats perdeu a Acessibilidade. O teclado está livre."
        case .secureInput: "Parei porque uma app ligou a entrada segura, que passa por cima do bloqueio."
        case .system: "Parei porque o Mac bloqueou, adormeceu ou mudou de utilizador."
        case .tapFailed: "Parei porque o macOS desligou o bloqueio. O teclado está livre."
        }
    }
}

enum CleaningRules {
    static let durations: [Int] = [1, 2, 5]   // minutos
    static let holdButton: TimeInterval = 2
    static let holdKeys: TimeInterval = 3

    // O CGEventType não tem nome para as teclas de brilho e som (14) nem para os gestos (29 a 32).
    private static let systemDefined: UInt32 = 14
    private static let gestures: ClosedRange<UInt32> = 29...32

    /// Tudo o que se engole. O ponteiro e o clique esquerdo passam sempre: são o caminho do botão de sair.
    static let blocked: Set<UInt32> = {
        var types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .scrollWheel]
        types += [.rightMouseDown, .rightMouseUp, .rightMouseDragged]
        types += [.otherMouseDown, .otherMouseUp, .otherMouseDragged]
        var out = Set(types.map(\.rawValue))
        out.insert(systemDefined)
        for gesture in gestures { out.insert(gesture) }
        return out
    }()

    static var mask: CGEventMask {
        var mask: CGEventMask = 0
        for type in blocked { mask |= CGEventMask(1) << CGEventMask(type) }
        return mask
    }

    /// As duas ⌘ ao mesmo tempo, pelos bits de cada lado (NX_DEVICELCMDKEYMASK e NX_DEVICERCMDKEYMASK).
    static func bothCommands(_ flags: CGEventFlags) -> Bool {
        let left: UInt64 = 0x08, right: UInt64 = 0x10
        return flags.rawValue & left != 0 && flags.rawValue & right != 0
    }
}

/// O que o filtro decide, sem tocar no sistema.
struct CleaningWatch: Sendable {
    let deadline: TimeInterval
    private var keysSince: TimeInterval?

    init(deadline: TimeInterval) {
        self.deadline = deadline
    }

    /// true: engolir o evento.
    mutating func handle(type: UInt32, flags: CGEventFlags, at now: TimeInterval) -> Bool {
        if type == CGEventType.flagsChanged.rawValue {
            if CleaningRules.bothCommands(flags) {
                keysSince = keysSince ?? now
            } else {
                keysSince = nil
            }
        }
        return CleaningRules.blocked.contains(type)
    }

    /// Porque deve acabar agora, se deve.
    func end(at now: TimeInterval, trusted: Bool) -> CleaningEnd? {
        if !trusted { return .permission }
        if now >= deadline { return .timeUp }
        if let keysSince, now - keysSince >= CleaningRules.holdKeys { return .keys }
        return nil
    }
}

protocol KeyboardLocking: AnyObject {
    /// false: não bloqueou nada.
    func start(seconds: TimeInterval, onEnd: @escaping @Sendable (CleaningEnd) -> Void) -> Bool
    func stop()
}

/// O filtro de eventos, numa thread só dele: a main thread ocupada não atrasa as teclas nem as saídas.
final class KeyboardLock: KeyboardLocking, @unchecked Sendable {
    private let lock = NSLock()
    private var stopRequested = false
    private var cancelled = false
    // Só na thread do filtro:
    private var watch = CleaningWatch(deadline: 0)
    private var port: CFMachPort?

    /// O relógio de arranque: acertar a hora não mexe no prazo.
    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Espera de propósito (no máximo 2 s) até o bloqueio estar mesmo instalado: o ecrã de limpeza só aparece
    /// quando as teclas já não chegam às apps, e se não der, nada fica a meio.
    func start(seconds: TimeInterval, onEnd: @escaping @Sendable (CleaningEnd) -> Void) -> Bool {
        let ready = DispatchSemaphore(value: 0)
        let installed = Flag()
        let thread = Thread { @Sendable [self] in
            run(seconds: seconds, installed: installed, ready: ready, onEnd: onEnd)
        }
        thread.name = "local.agentstats.cleaning"
        thread.qualityOfService = .userInteractive
        thread.start()
        guard ready.wait(timeout: .now() + 2) == .success, installed.value else {
            lock.withLock { cancelled = true }
            return false
        }
        return true
    }

    func stop() {
        lock.withLock { stopRequested = true }
    }

    private var shouldStop: Bool {
        lock.withLock { stopRequested || cancelled }
    }

    private func run(seconds: TimeInterval, installed: Flag, ready: DispatchSemaphore,
                     onEnd: @Sendable (CleaningEnd) -> Void) {
        // self fica vivo até esta função sair, por isso o ponteiro sem retain é válido enquanto houver filtro.
        let info = Unmanaged.passUnretained(self).toOpaque()
        guard !shouldStop,
              let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CleaningRules.mask, callback: keyboardLockCallback, userInfo: info),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            ready.signal()
            return
        }
        watch = CleaningWatch(deadline: Self.now + seconds)
        port = tap
        let loop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(loop, source, .defaultMode)
        CGEvent.tapEnable(tap: tap, enable: true)
        installed.set()
        ready.signal()

        var reason = CleaningEnd.button
        var trusted = true
        var checked = Self.now
        while !shouldStop {
            let result = CFRunLoopRunInMode(.defaultMode, 0.1, false)
            if result == .finished || !CFMachPortIsValid(tap) {
                reason = .tapFailed
                break
            }
            if !CGEvent.tapIsEnabled(tap: tap) {
                // Religa uma vez; se o macOS não deixar (permissão tirada), solta tudo.
                CGEvent.tapEnable(tap: tap, enable: true)
                guard CGEvent.tapIsEnabled(tap: tap) else {
                    reason = .tapFailed
                    break
                }
            }
            let now = Self.now
            // Um filtro ativo sem permissão pode prender o rato e o teclado do sistema: vê-se sempre.
            if now - checked >= 0.5 {
                checked = now
                trusted = AXIsProcessTrusted()
            }
            if let end = watch.end(at: now, trusted: trusted) {
                reason = end
                break
            }
        }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(loop, source, .defaultMode)
        CFMachPortInvalidate(tap)
        port = nil
        onEnd(reason)
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        return watch.handle(type: type.rawValue, flags: event.flags, at: Self.now) ? nil : Unmanaged.passUnretained(event)
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var on = false
        var value: Bool { lock.withLock { on } }
        func set() { lock.withLock { on = true } }
    }
}

private func keyboardLockCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                  info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let info else { return Unmanaged.passUnretained(event) }
    return Unmanaged<KeyboardLock>.fromOpaque(info).takeUnretainedValue().handle(type: type, event: event)
}

/// Liga o bloqueio ao ecrã preto. Só começa quando se carrega no botão.
@MainActor
final class CleaningModeStore: ObservableObject {
    struct Environment {
        var trusted: @MainActor () -> Bool = { AXIsProcessTrusted() }
        var requestAccess: @MainActor () -> Void = { AX.ensureTrusted() }
        var secureInput: @MainActor () -> Bool = { IsSecureEventInputEnabled() }
        var recording: @MainActor () -> Bool = { CaptureStore.shared.isRecording }
        var makeLock: @MainActor () -> any KeyboardLocking = { KeyboardLock() }
        var showOverlay: @MainActor (CleaningModeStore) -> Void = { CleaningOverlay.shared.show($0) }
        var hideOverlay: @MainActor () -> Void = { CleaningOverlay.shared.hide() }
        /// As teclas engolidas não contam como atividade: sem isto o ecrã podia adormecer a meio.
        var keepDisplayAwake: @MainActor () -> NSObjectProtocol? = {
            ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated],
                                                  reason: "AgentStats: limpeza do teclado e do ecrã")
        }
        var observesSystem = true
    }

    static let shared = CleaningModeStore(environment: Environment())

    @Published private(set) var trusted = false
    @Published private(set) var active = false
    /// Para a contagem no ecrã preto. O prazo a sério é o do filtro.
    @Published private(set) var endsAt: Date?
    @Published private(set) var message: String?
    @Published private(set) var asked = false

    private let environment: Environment
    private var keyboard: (any KeyboardLocking)?
    private var session = 0
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var demo = false

    init(environment: Environment) {
        self.environment = environment
    }

    func refresh() {
        guard !demo else { return }
        let now = environment.trusted()
        if now != trusted { trusted = now }
        if now { asked = false }
    }

    func requestAccess() {
        guard !demo else { return }
        asked = true
        environment.requestAccess()
    }

    func start(minutes: Int) {
        guard !demo, !active else { return }
        message = nil
        refresh()
        guard trusted else {
            message = "Falta a Acessibilidade. Não bloqueei nada."
            return
        }
        guard !environment.recording() else {
            message = "Para a gravação de ecrã primeiro."
            return
        }
        // Com entrada segura as teclas passam ao lado de qualquer filtro: seria um bloqueio a fingir.
        guard !environment.secureInput() else {
            message = "Uma app tem a entrada segura ligada (um campo de password ou o Terminal), por isso as teclas passavam. Fecha-a e tenta de novo."
            return
        }

        let safeMinutes: Int = CleaningRules.durations.contains(minutes) ? minutes : 2
        let seconds = TimeInterval(safeMinutes * 60)
        session += 1
        let current = session
        let keyboard = environment.makeLock()
        let started = keyboard.start(seconds: seconds) { [weak self] reason in
            Task { @MainActor [weak self] in self?.ended(reason, session: current) }
        }
        guard started else {
            message = "O macOS não deixou bloquear o teclado. Tira o AgentStats da lista de Acessibilidade e volta a juntá-lo."
            return
        }
        self.keyboard = keyboard
        active = true
        endsAt = Date().addingTimeInterval(seconds)
        activity = environment.keepDisplayAwake()
        environment.showOverlay(self)
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        if environment.observesSystem { observe() }
    }

    func stop(_ reason: CleaningEnd = .button) {
        guard active else { return }
        keyboard?.stop()
        finish(reason)
    }

    func check() {
        guard active else { return }
        if environment.secureInput() {
            stop(.secureInput)
        } else if !environment.trusted() {
            stop(.permission)
        } else if let endsAt, Date() > endsAt.addingTimeInterval(1) {
            stop(.timeUp)   // rede de segurança do ecrã preto, se o aviso do filtro não chegar
        }
    }

    private func ended(_ reason: CleaningEnd, session ended: Int) {
        guard active, ended == session else { return }
        finish(reason)
    }

    private func finish(_ reason: CleaningEnd) {
        active = false
        keyboard = nil
        endsAt = nil
        timer?.invalidate()
        timer = nil
        for observer in observers { observer.center.removeObserver(observer.token) }
        observers = []
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        environment.hideOverlay()
        message = reason.message
        refresh()
    }

    /// O bloqueio nunca chega ao ecrã de login nem a outro utilizador.
    private func observe() {
        let workspace = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                                          NSWorkspace.sessionDidResignActiveNotification]
        for name in names {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop(.system) }
            }
            observers.append((workspace, token))
        }
        let distributed = DistributedNotificationCenter.default()
        let token = distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop(.system) }
        }
        observers.append((distributed, token))
    }

    /// Para as capturas: não lê permissões nem bloqueia nada.
    func loadDemo(trusted: Bool = true) {
        demo = true
        self.trusted = trusted
    }
}
