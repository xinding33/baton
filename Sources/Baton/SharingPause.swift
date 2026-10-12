import AppKit
import BatonCore

/// Pause Sharing's hotkey, and whether sharing is paused when Baton starts: the Sharing pane of
/// the anchor's Settings, `ctl sharing`, and what every Mac's event tap asks about each key.
/// The pause itself is the anchor's (`Anchor.setPaused`). A client listens for the hotkey the
/// anchor names and asks the anchor to switch.
final class SharingPause {
    static let shared = SharingPause()

    private static var settingsFile: URL { Paths.support.appendingPathComponent("sharing.json") }
    /// Where a Baton that restarts itself leaves word of whether sharing was paused.
    private static var restartFile: URL { Paths.support.appendingPathComponent("sharing-restart.json") }
    /// A restart that takes longer than this is a new start, and goes by the setting.
    static let restartWindow: TimeInterval = 60

    /// A setting or something Settings shows has changed.
    var onStateChanged: (() -> Void)?
    /// The hotkey for Wake All Macs on this Mac, which cannot be this one too. A test replaces it.
    var wakeAllHotKey: () -> HotKey? = { WakeTogether.shared.hotKey }

    private(set) var settings = SharingSettings()
    private weak var anchor: Anchor?
    /// The hotkey this Mac listens for: the anchor's setting, which a client is told.
    private(set) var hotKey: HotKey?
    /// What the hotkey does here: the anchor switches, and a client asks the anchor to.
    private var toggle: (() -> Void)?
    private var recognizer = HotKeyRecognizer()

    /// Settings is waiting for the keys of a new hotkey. No Mac acts on the old one meanwhile.
    private(set) var recording = false
    private var failure: String?
    private var keyMonitor: Any?
    private var windowObserver: NSObjectProtocol?

    // MARK: Starting

    /// Anchor only, once everything that pauses with sharing has started.
    func start(anchor: Anchor) {
        self.anchor = anchor
        settings = loadSettings()
        hotKey = settings.hotKey
        toggle = { [weak anchor] in
            guard let anchor else { return }
            anchor.setPaused(!anchor.paused)
        }
        let carried = takeRestartState()
        log("sharing: the hotkey is \(hotKey?.display ?? "off"); Baton starts \(settings.startPaused ? "paused" : "sharing")")
        guard settings.startsPaused(carried: carried) else { return }
        log(carried == nil ? "sharing: starting paused, as it is set to" : "sharing: staying paused, as it was before the restart")
        anchor.setPaused(true)
    }

    /// Client only: the anchor said which hotkey pauses sharing, or the link to it is gone.
    /// `ask` tells the anchor that it was pressed.
    func follow(_ hotKey: HotKey?, ask: (() -> Void)? = nil) {
        guard anchor == nil else { return }
        self.hotKey = hotKey
        toggle = ask
    }

    /// The hotkey a client is to listen for.
    var offered: HotKey? { recording ? nil : hotKey }

    private func tellClients() {
        guard let server = anchor?.server else { return }
        for name in server.peers.keys { server.send(name, .sharingHotKey(offered)) }
    }

    // MARK: Restarting

    /// Baton is about to restart itself, for an update or to apply a setting. Sharing comes
    /// back as it is now, whatever it is set to start as.
    func willRestart() {
        guard let anchor else { return }
        try? JSONEncoder().encode(["paused": anchor.paused]).write(to: Self.restartFile, options: .atomic)
    }

    /// Whether sharing was paused when Baton restarted itself a moment ago; nil if it did not.
    private func takeRestartState() -> Bool? {
        let file = Self.restartFile
        defer { try? FileManager.default.removeItem(at: file) }
        guard let written = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date,
              abs(written.timeIntervalSinceNow) < Self.restartWindow,
              let data = try? Data(contentsOf: file) else { return nil }
        return (try? JSONDecoder().decode([String: Bool].self, from: data))?["paused"]
    }

    // MARK: The hotkey

    /// Called by every event tap for each event. Returns true for the hotkey, which then goes
    /// no further.
    func consumes(_ type: CGEventType, _ event: CGEvent) -> Bool {
        guard type == .keyDown || type == .keyUp else { return false }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.rawValue
        if recording {
            // The window is handed the keys of the new hotkey. What Baton already acts on would
            // never get there, so it is turned away here.
            let pressed = HotKey(keyCode: code, key: HotKey.name(forKeyCode: code), modifiers: HotKey.modifiers(in: flags))
            guard type == .keyDown, pressed.taken(wakeAll: wakeAllHotKey()) != nil else { return false }
            DispatchQueue.main.async { _ = self.typed(code: code, flags: flags, types: nil) }
            return true
        }
        let outcome = recognizer.process(
            hotKey,
            code: code,
            down: type == .keyDown,
            autorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            flags: flags
        )
        // The tap's callback has to return at once, so the work happens after it.
        if outcome == .fire {
            DispatchQueue.main.async {
                if self.anchor != nil { log("sharing: the hotkey was pressed") }
                self.toggle?()
            }
        }
        return outcome != .pass
    }

    /// Anchor only: the hotkey was pressed on the client called `name`.
    func pressed(on name: String) {
        guard anchor != nil, !recording else { return }
        log("sharing: the hotkey was pressed on \(name)")
        toggle?()
    }

    // MARK: Recording a new hotkey

    private func beginRecording() {
        guard !recording else { return }
        recording = true
        failure = nil
        tellClients()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.recording else { return event }
            // A key typed anywhere but in the pane was not meant for it.
            guard event.window != nil, event.window?.contentView === self.settingsPane.view else {
                self.endRecording()
                return event
            }
            let taken = self.typed(code: event.keyCode, flags: UInt64(event.modifierFlags.rawValue), types: event.characters(byApplyingModifiers: []))
            return taken ? nil : event
        }
        if let window = settingsPane.view.window {
            windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                self?.endRecording()
            }
        }
        onStateChanged?()
    }

    private func endRecording() {
        guard recording else { return }
        recording = false
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        windowObserver = nil
        tellClients()
        onStateChanged?()
    }

    /// A key went down while a hotkey is being recorded: `code` with the modifiers in `flags`,
    /// which `types` that character on the keyboard in use. Returns whether it was meant for
    /// the recording, as every key is.
    @discardableResult
    func typed(code: UInt16, flags: UInt64, types: String?) -> Bool {
        guard recording else { return false }
        let modifiers = HotKey.modifiers(in: flags)
        if code == 53, modifiers.isEmpty {
            endRecording()
            return true
        }
        let pressed = HotKey(keyCode: code, key: HotKey.name(forKeyCode: code, types: types), modifiers: modifiers)
        if let problem = SharingSettings.problem(with: pressed, wakeAll: wakeAllHotKey()) {
            failure = problem
            onStateChanged?()
            return true
        }
        endRecording()
        change("the hotkey is \(pressed.display)") { $0.hotKey = pressed }
        return true
    }

    // MARK: Settings

    private func loadSettings() -> SharingSettings {
        guard let data = try? Data(contentsOf: Self.settingsFile) else { return SharingSettings() }
        do {
            return try JSONDecoder().decode(SharingSettings.self, from: data)
        } catch {
            log("sharing: cannot read \(Self.settingsFile.lastPathComponent) (\(error)); using the defaults")
            return SharingSettings()
        }
    }

    private func change(_ what: String, _ edit: (inout SharingSettings) -> Void) {
        edit(&settings)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(settings).write(to: Self.settingsFile, options: .atomic)
        } catch {
            log("sharing: could not save the settings: \(error)")
        }
        hotKey = settings.hotKey
        failure = nil
        tellClients()
        log("sharing: \(what)")
        onStateChanged?()
    }

    /// The Sharing pane of the anchor's Settings.
    private(set) lazy var settingsPane: FormPane = {
        let pane = FormPane(id: StatusMenu.Pane.sharing, title: "Sharing", symbol: "playpause") { [unowned self] in self.rows() }
        pane.onOpen = { [unowned self] in self.failure = nil }
        // A recording that nobody finished must not leave the hotkey switched off.
        pane.onClose = { [unowned self] in self.endRecording() }
        return pane
    }()

    private static let starts: [(paused: Bool, title: String, detail: String)] = [
        (false, "Start sharing", "Sharing begins as soon as Baton has started."),
        (true, "Stay paused", "Each Mac is left to itself until you resume sharing, from Baton’s menu or with the shortcut."),
    ]

    func rows() -> [SettingsRow] {
        let options: [String], detail: String
        if recording {
            options = ["Press the new shortcut…", "Cancel"]
            detail = "Hold at least one of ⌃, ⌥ and ⌘ and press a key. Esc cancels."
        } else {
            options = (settings.hotKey.map { [$0.display] } ?? []) + ["None", "Record a New Shortcut…"]
            detail = settings.hotKey == nil
                ? "Without a shortcut, sharing is paused and resumed from Baton’s menu."
                : "Does what Pause Sharing and Resume Sharing in Baton’s menu do, from the keyboard of whichever Mac you are at."
        }
        var rows: [SettingsRow] = [
            .header("Shortcut"),
            .choice("Pause or resume sharing", options: options, selected: 0, detail: detail) { [unowned self] index in
                if self.recording {
                    if index == 1 { self.endRecording() }
                    return
                }
                switch index - (self.settings.hotKey == nil ? 0 : 1) {
                case 0 where self.settings.hotKey != nil: self.change("the hotkey is off") { $0.hotKey = nil }
                case 1: self.beginRecording()
                default: break
                }
            },
        ]
        if let failure { rows.append(.note(failure)) }
        let start = SharingPause.starts.firstIndex { $0.paused == settings.startPaused } ?? 0
        rows += [
            .header("Starting"),
            .choice("When Baton starts", options: SharingPause.starts.map(\.title), selected: start, detail: SharingPause.starts[start].detail) { [unowned self] index in
                guard SharingPause.starts.indices.contains(index) else { return }
                let paused = SharingPause.starts[index].paused
                self.change("Baton starts \(paused ? "paused" : "sharing")") { $0.startPaused = paused }
            },
            .text("When Baton restarts by itself, for an update or to apply a setting, sharing is left as it was."),
            .text("For all your Macs, and kept on this one."),
        ]
        return rows
    }

    // MARK: Control commands

    /// `ctl sharing`: shows the state. The rest change the anchor's settings.
    func command(_ words: [String]) -> String {
        guard let anchor else {
            return words.isEmpty ? jsonString(["hotKey": hotKey?.display ?? "none", "settings": "on the anchor"]) : "only the anchor has these settings"
        }
        switch (words.first, words.count) {
        case (nil, _):
            break
        case ("hotkey", 2) where words[1] == "none":
            endRecording()
            change("the hotkey is off") { $0.hotKey = nil }
        case ("hotkey", 2...):
            let text = words.dropFirst().joined(separator: "+")
            guard let parsed = HotKey.parse(text) else { return "cannot read “\(text)”: write it like control+option+command+p" }
            if let problem = SharingSettings.problem(with: parsed, wakeAll: wakeAllHotKey()) { return problem }
            endRecording()
            change("the hotkey is \(parsed.display)") { $0.hotKey = parsed }
        case ("start", 2) where ["paused", "sharing"].contains(words[1]):
            change("Baton starts \(words[1])") { $0.startPaused = words[1] == "paused" }
        default:
            return "usage: sharing [hotkey <keys>|none | start paused|sharing]"
        }
        return jsonString([
            "paused": anchor.paused,
            "hotKey": settings.hotKey?.display ?? "none",
            "startPaused": settings.startPaused,
            "recording": recording,
        ] as [String: Any])
    }
}
