import AppKit
import BatonCore
import IOKit.ps
import IOKit.pwr_mgt

/// The links a wake can travel over: the anchor's clients, or a client's link to the anchor.
protocol WakeLinks: AnyObject {
    var wakeLinks: [WakeLink] { get }
    func sendWake(_ request: WakeRequest, to link: WakeLink)
    func sendInUse(to link: WakeLink)
}

extension AnchorServer: WakeLinks {
    var wakeLinks: [WakeLink] {
        peers.values.map { WakeLink(name: $0.name, session: UInt64($0.codec.sessionId)) }
    }

    func sendWake(_ request: WakeRequest, to link: WakeLink) {
        send(link.name, .wake(request))
    }

    func sendInUse(to link: WakeLink) {
        send(link.name, .inUse)
    }
}

/// Wakes the Macs' displays together, keeps this Mac reachable, and offers Wake All Macs: the
/// Ripple app's job, done over Baton's own link. It also keeps the Macs awake together while one
/// of them is in use. What to do when is decided by `WakeCoordinator` and `StayAwakeCoordinator`
/// in BatonCore; this is the part that touches the Mac.
final class WakeTogether: NSObject {
    static let shared = WakeTogether()

    private static var settingsFile: URL { Paths.support.appendingPathComponent("wake.json") }
    /// Where Ripple keeps its settings: under its current bundle identifier, and the one it had
    /// before version 1.1.
    private static let rippleDomains = ["io.github.xinding33.ripple", "com.xinding.Ripple"]

    /// A setting or something Settings shows has changed.
    var onStateChanged: (() -> Void)?
    private var coordinator: WakeCoordinator?
    private var settings = WakeSettings()
    private weak var links: WakeLinks?
    private lazy var injector = Injector()
    private let keepAwake = KeepAwake()
    private var recognizer = HotKeyRecognizer()
    private var pendingWatch: DispatchSourceTimer?
    private var inUse: StayAwakeCoordinator?
    private let stayAwake = StayAwake()
    private var toldOthersAt: Date?
    private var heard: (at: Date, outcome: String)?
    private var recent: [String] = []

    func start(as config: Config, links: WakeLinks) {
        self.links = links
        coordinator = WakeCoordinator(name: config.name, role: config.role)
        inUse = StayAwakeCoordinator(role: config.role)
        settings = loadSettings()
        keepAwake.onChange = { [weak self] in self?.onStateChanged?() }
        apply()
        note("ready")
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(screensDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
    }

    // MARK: Settings

    private func loadSettings() -> WakeSettings {
        if let data = try? Data(contentsOf: Self.settingsFile) {
            do {
                return try JSONDecoder().decode(WakeSettings.self, from: data)
            } catch {
                note("cannot read \(Self.settingsFile.lastPathComponent) (\(error)); using the defaults")
                return WakeSettings()
            }
        }
        // Baton takes over from Ripple, so a Mac starts out with what was chosen in Ripple there.
        var settings = WakeSettings()
        let domains = Self.rippleDomains.compactMap { UserDefaults.standard.persistentDomain(forName: $0) }
        if let ripple = domains.first(where: { $0["installID"] != nil }) {
            settings.wakeOthers = ripple["autoWake"] as? Bool ?? settings.wakeOthers
            settings.keepAwake = ripple["keepAwake"] as? Bool ?? settings.keepAwake
            settings.keepAwakeOnlyOnPower = ripple["keepAwakeOnlyOnAC"] as? Bool ?? settings.keepAwakeOnlyOnPower
            note("first run: settings taken from Ripple (wake the others \(settings.wakeOthers), keep awake \(settings.keepAwake), only on power adapter \(settings.keepAwakeOnlyOnPower))")
        }
        save(settings)
        return settings
    }

    private func save(_ settings: WakeSettings) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(settings).write(to: Self.settingsFile, options: .atomic)
        } catch {
            note("could not save the wake settings: \(error)")
        }
    }

    private func change(_ what: String, _ edit: (inout WakeSettings) -> Void) {
        edit(&settings)
        save(settings)
        apply()
        note(what)
        onStateChanged?()
    }

    private func apply() {
        coordinator?.wakeOthers = settings.wakeOthers
        keepAwake.configure(wanted: settings.keepAwake, onlyOnPower: settings.keepAwakeOnlyOnPower)
        if !settings.stayAwakeWithOthers { stayAwake.standDown("switched off") }
    }

    // MARK: Waking

    /// The coordinator's clock has to keep counting through sleep, which `Net.monotonicMillis` does not.
    private static func now() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1_000_000
    }

    private func run(_ decide: (inout WakeCoordinator, UInt64, [WakeLink]) -> [WakeCoordinator.Action]) {
        guard var coordinator else { return }
        let actions = decide(&coordinator, Self.now(), links?.wakeLinks ?? [])
        self.coordinator = coordinator
        for action in actions {
            switch action {
            case .wakeDisplay: injector.wake("Baton wake together")
            case let .send(request, link): links?.sendWake(request, to: link)
            case let .log(text): note(text)
            }
        }
        watchPending()
    }

    /// While a wake is fresh, offers it to machines as they connect.
    private func watchPending() {
        guard pendingWatch == nil, coordinator?.hasPending(now: Self.now()) == true else { return }
        pendingWatch = repeatingTimer(every: 0.5) { [weak self] in
            guard let self else { return }
            self.run { $0.linksChanged(now: $1, links: $2) }
            if self.coordinator?.hasPending(now: Self.now()) != true {
                self.pendingWatch?.cancel()
                self.pendingWatch = nil
            }
        }
    }

    @objc private func screensDidWake() {
        run { $0.displayWoke(now: $1, links: $2) }
    }

    /// Wake All Macs, from the menu or the hotkey.
    func wakeAll() {
        run { $0.wakeAll(now: $1, links: $2) }
    }

    /// A wake request arrived over the link from `sender`.
    func received(_ request: WakeRequest, from sender: String) {
        run { $0.received(request, from: sender, now: $1, links: $2) }
    }

    /// Called by every event tap for each event. Returns true for the Wake All Macs hotkey, which
    /// then goes no further.
    func consumes(_ type: CGEventType, _ event: CGEvent) -> Bool {
        guard type == .keyDown || type == .keyUp, coordinator != nil else { return false }
        let outcome = recognizer.process(
            settings.hotKey,
            code: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
            down: type == .keyDown,
            autorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            flags: event.flags.rawValue
        )
        // The tap's callback has to return at once, so the work happens after it.
        if outcome == .fire { DispatchQueue.main.async { self.wakeAll() } }
        return outcome != .pass
    }

    /// Anchor only: Pause Sharing was switched. While it is on, a display that wakes wakes no
    /// other Mac and the Macs do not keep each other awake. Wake All Macs still works.
    func setPaused(_ value: Bool) {
        guard let coordinator, value != coordinator.paused else { return }
        self.coordinator?.paused = value
        inUse?.paused = value
        if value { stayAwake.standDown("sharing is paused") }
        note(value ? "sharing is paused: only Wake All Macs reaches the other Macs" : "sharing is resumed")
        onStateChanged?()
    }

    // MARK: Staying awake together

    /// Called by every event tap for each event from this Mac's own devices. While they are in
    /// use the other Macs are told, once per `StayAwakeCoordinator.reportEveryMs`.
    func sawInput() {
        guard inUse?.reportIsDue(now: Self.now()) == true else { return }
        // The tap's callback has to return at once, so the work happens after it.
        DispatchQueue.main.async {
            guard let links = self.links else { return }
            let others = links.wakeLinks
            others.forEach(links.sendInUse)
            if !others.isEmpty { self.toldOthersAt = Date() }
        }
    }

    /// The machine called `sender` says it is in use, or passes on that another is.
    func heardInUse(from sender: String) {
        guard let inUse else { return }
        for action in inUse.received(from: sender, links: links?.wakeLinks ?? []) {
            switch action {
            case let .send(link):
                links?.sendInUse(to: link)
            case .stayAwake:
                stayAwake.heard(enabled: settings.stayAwakeWithOthers, onlyOnPower: settings.keepAwakeOnlyOnPower) { [weak self] heldBackBy in
                    guard let self else { return }
                    let outcome = heldBackBy.map { "left to its own timers: \($0)" } ?? "staying awake with it"
                    // A report comes every few seconds; the log gets only what changed.
                    if outcome != self.heard?.outcome { self.note("another Mac is in use; \(outcome)") }
                    self.heard = (Date(), outcome)
                }
            }
        }
    }

    private static func ago(_ date: Date?) -> String {
        date.map { "\(Int(-$0.timeIntervalSinceNow)) s ago" } ?? "never"
    }

    // MARK: Settings, menu and control

    /// Whether the menu can offer Wake All Macs, and the hotkey that does the same.
    var canWakeAll: Bool { coordinator != nil }
    var hotKeyDisplay: String? { settings.hotKey?.display }
    var hotKey: HotKey? { settings.hotKey }

    /// The Sleep & Wake pane of Settings.
    private(set) lazy var settingsPane = FormPane(id: StatusMenu.Pane.wake, title: "Sleep & Wake", symbol: "moon") { [unowned self] in
        guard self.coordinator != nil else { return [.text("Waking together has not started on this Mac.")] }
        return WakeTogether.rows(for: self.settings, holdingAwake: self.keepAwake.isHolding, onPowerAdapter: KeepAwake.onPowerAdapter, sharingPaused: self.coordinator?.paused == true) { [unowned self] in self.change($0, $1) }
    }

    /// The pane's rows for `settings`. `change` is handed a line for the log and what a click alters.
    static func rows(for settings: WakeSettings, holdingAwake: Bool, onPowerAdapter: Bool, sharingPaused: Bool = false, change: @escaping (String, (inout WakeSettings) -> Void) -> Void) -> [SettingsRow] {
        let paused = settings.keepAwake && !holdingAwake
        let waiting = settings.stayAwakeWithOthers && settings.keepAwakeOnlyOnPower && !onPowerAdapter
        let pause: [SettingsRow] = sharingPaused ? [.note("Sharing is paused, in Baton’s menu. Until it is resumed, a display that wakes does not wake the other Macs, and a Mac in use does not keep the others awake. Wake All Macs still works.", warning: false)] : []
        return pause + [
            .header("Waking"),
            .toggle("Wake the other Macs when this Mac wakes", on: settings.wakeOthers,
                    detail: "Wake All Macs, in Baton’s menu\(settings.hotKey.map { " or with \($0.display)" } ?? ""), wakes them whenever you ask.") { on in
                change("wake the others when this Mac wakes: \(on)") { $0.wakeOthers = on }
            },
            .header("Staying awake"),
            .toggle("Keep this Mac awake" + (paused ? " (paused on battery)" : ""), on: settings.keepAwake,
                    detail: "Holds off idle sleep, so that this Mac stays in reach and can be woken. Its display still sleeps on schedule.") { on in
                change("keep this Mac awake: \(on)") { $0.keepAwake = on }
            },
            .toggle("Stay awake while another Mac is in use" + (waiting ? " (paused on battery)" : ""), on: settings.stayAwakeWithOthers,
                    detail: "Keeps this Mac’s display on while you are working at one of the others.") { on in
                change("stay awake while another Mac is in use: \(on)") { $0.stayAwakeWithOthers = on }
            },
            // Greyed out but still showing its setting while neither of the two above is on.
            .toggle("Only on power adapter", on: settings.keepAwakeOnlyOnPower, enabled: settings.keepAwake || settings.stayAwakeWithOthers, indent: 1) { on in
                change("keep awake only on power adapter: \(on)") { $0.keepAwakeOnlyOnPower = on }
            },
            .text("For this Mac only. Each Mac has its own switches."),
        ]
    }

    /// `ctl wake`: shows the state. `all` wakes every Mac; the rest change this Mac's settings.
    func command(_ words: [String]) -> String {
        let usage = "usage: wake [all | others on|off | keep on|off | in-use on|off | adapter-only on|off]"
        guard let coordinator else { return "wake-together has not started" }
        switch (words.first, words.count) {
        case (nil, _):
            break
        case ("all", 1):
            wakeAll()
        case ("others", 2) where ["on", "off"].contains(words[1]):
            change("wake the others when this Mac wakes: \(words[1])") { $0.wakeOthers = words[1] == "on" }
        case ("keep", 2) where ["on", "off"].contains(words[1]):
            change("keep this Mac awake: \(words[1])") { $0.keepAwake = words[1] == "on" }
        case ("in-use", 2) where ["on", "off"].contains(words[1]):
            change("stay awake while another Mac is in use: \(words[1])") { $0.stayAwakeWithOthers = words[1] == "on" }
        case ("adapter-only", 2) where ["on", "off"].contains(words[1]):
            change("keep awake only on power adapter: \(words[1])") { $0.keepAwakeOnlyOnPower = words[1] == "on" }
        default:
            return usage
        }
        var report: [String: Any] = [
            "name": coordinator.name,
            "role": coordinator.role.rawValue,
            "wakeOthers": settings.wakeOthers,
            "keepAwake": settings.keepAwake,
            "keepAwakeOnlyOnPower": settings.keepAwakeOnlyOnPower,
            "keepingAwake": keepAwake.isHolding,
            "stayAwakeWithOthers": settings.stayAwakeWithOthers,
            "toldOthersInUse": Self.ago(toldOthersAt),
            "heardInUse": heard.map { "\(Self.ago($0.at)); \($0.outcome)" } ?? "never",
            "onPowerAdapter": KeepAwake.onPowerAdapter,
            "hotKey": settings.hotKey?.display ?? "none",
            "links": (links?.wakeLinks ?? []).map(\.name).sorted(),
            "recent": recent,
        ]
        if coordinator.role == .anchor { report["sharingPaused"] = coordinator.paused }
        return jsonString(report)
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// Logs `text` and keeps it for `ctl wake`.
    private func note(_ text: String) {
        log("wake: \(text)")
        recent = Array((recent + ["\(Self.clock.string(from: Date())) \(text)"]).suffix(8))
    }
}

/// Holds off idle system sleep, so this Mac keeps its link and can be woken. The display still
/// sleeps on schedule.
final class KeepAwake {
    private var wanted = false
    private var onlyOnPower = true
    private var assertion: IOPMAssertionID = 0
    private(set) var isHolding = false
    private var powerSource: CFRunLoopSource?
    var onChange: (() -> Void)?

    init() {
        // Plugging in or unplugging decides whether the Mac is held awake.
        let context = Unmanaged.passUnretained(self).toOpaque()
        let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<KeepAwake>.fromOpaque(context).takeUnretainedValue().update()
        }, context)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        powerSource = source
    }

    static var onPowerAdapter: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return true }
        return (type as String) == kIOPMACPowerKey
    }

    func configure(wanted: Bool, onlyOnPower: Bool) {
        self.wanted = wanted
        self.onlyOnPower = onlyOnPower
        update()
    }

    private func update() {
        let hold = wanted && (!onlyOnPower || Self.onPowerAdapter)
        guard hold != isHolding else { return }
        if hold {
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Baton keeps this Mac reachable so it can wake with your other Macs" as CFString,
                &assertion
            )
            guard result == kIOReturnSuccess else { return log("wake: cannot hold this Mac awake (\(result))") }
            isHolding = true
        } else {
            IOPMAssertionRelease(assertion)
            isHolding = false
        }
        log("wake: \(isHolding ? "holding this Mac awake" : "no longer holding this Mac awake")")
        onChange?()
    }
}
