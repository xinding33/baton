import AppKit
import BatonCore
import CoreBluetooth
import Network
import SystemConfiguration

/// Sets Baton up on a Mac that has no `config.json`, and is its Settings window afterwards.
///
/// The first run comes before anything else starts: no event tap, no listener, no connection.
/// Only when the window's Start button has written `config.json` and `secret.key` does the app
/// go on to share input, and the same window then stays as Settings.
final class SetupWindowController: NSObject, NSWindowDelegate {
    /// The parts of the Mac the window reads and changes. A test replaces them, so that it never
    /// touches the real files, launch agent, permissions or network.
    struct Environment {
        var installation = Installation()
        var login = LoginItem()
        var computerName: () -> String? = { SCDynamicStoreCopyComputerName(nil, nil) as String? }
        var accessibility: () -> Bool = { AXIsProcessTrusted() }
        var bluetooth: () -> BluetoothAccess = {
            switch CBManager.authorization {
            case .allowedAlways: return .allowed
            case .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined: return .notAsked
            @unknown default: return .notAsked
            }
        }
        /// Makes macOS list Baton under Accessibility, which it only does once Baton has asked.
        var askForAccessibility: () -> Void = {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
        var askForBluetooth: () -> Void = {
            let mover = KeyboardMover()
            return { mover.requestPermission() }
        }()
        var open: (URL) -> Void = { NSWorkspace.shared.open($0) }
        /// Puts the window in front of its user.
        var present: (NSWindow) -> Void = { window in
            // Baton has no menu bar of its own, and without an Edit menu ⌘V does nothing in a
            // text field, which is how most pairing codes arrive.
            if NSApp.mainMenu == nil { NSApp.mainMenu = SetupWindowController.makeMainMenu() }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
        /// The pasteboard can make its caller wait, so it is not written on the main thread.
        var copy: (String) -> Void = { text in
            DispatchQueue.global(qos: .userInitiated).async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
        /// Whether a client being set up may look for the anchor, which is what makes macOS ask
        /// about the local network.
        var searchesNetwork = true
        var relaunch: () -> Void = { Relaunch.now() }
        var quit: () -> Void = { exit(0) }
    }

    private struct Draft: Equatable {
        var name = ""
        var role = Role.anchor
        var code = ""
        var keyboardAddress: String?
        var openAtLogin = true
    }

    static func makeMainMenu() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let main = NSMenu()
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit
        return main
    }

    private var environment: Environment
    private var mode = SetupState.Mode.settings
    private var need: SetupNeed?
    private var draft = Draft()
    /// What the draft started from: the settings on disk.
    private var saved = Draft()
    private var hasSecret = false
    private var configProblems: [String] = []
    /// Set once Start or Apply has been tried, after which an empty field is called a mistake.
    private var insists = false
    private var failure: String?
    private var start: ((Config, Data) -> Void)?

    private weak var anchor: Anchor?
    private weak var client: ClientAgent?
    /// Opens the arrangement window, for a Mac that has no place yet.
    var onShowArrangement: (() -> Void)?

    private var window: NSWindow?
    private var view: SetupView?
    private var timer: DispatchSourceTimer?
    private var browser: NWBrowser?
    private var searched = LocalNetworkAccess.unknown
    /// The Bluetooth keyboards paired with this Mac, once they have been read.
    var keyboards: [BluetoothKeyboard]?
    private var readingKeyboards = false
    /// A client alternates between two addresses while it cannot connect, each with its own
    /// failure. Both are kept for a while so that the diagnosis does not flicker between them.
    private var recentFailures: [(at: UInt64, reason: String)] = []
    /// Tells a Mac that is on no network from one that is not allowed onto it.
    private var pathMonitor: NWPathMonitor?
    private var online = true

    init(environment: Environment = Environment()) {
        self.environment = environment
    }

    // MARK: Starting

    /// Calls `start` with this Mac's settings: at once if it is set up, otherwise when the setup
    /// window has been completed.
    func whenSetUp(_ start: @escaping (Config, Data) -> Void) {
        environment.login.adopt()
        let contents = environment.installation.load()
        if let config = contents.config, let secret = contents.secret {
            loadDraft(from: contents)
            for problem in configProblems { log("config: \(problem)") }
            return start(config, secret)
        }
        mode = .firstRun
        need = contents.need
        self.start = start
        loadDraft(from: contents)
        log("not set up yet (\(need.map { "\($0)" } ?? "")); showing the setup window")
        show()
    }

    /// The running agent, once there is one.
    func attach(anchor: Anchor?, client: ClientAgent?) {
        self.anchor = anchor
        self.client = client
        guard client != nil, pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in self?.online = path.status == .satisfied }
        monitor.start(queue: .main)
        pathMonitor = monitor
    }

    private func loadDraft(from contents: Installation.Contents) {
        var draft = Draft()
        draft.name = contents.config?.name ?? MachineName.suggestion(fromComputerName: environment.computerName())
        draft.role = contents.config?.role ?? .anchor
        draft.code = environment.installation.pairingCode ?? ""
        draft.keyboardAddress = contents.config?.keyboardAddress.map { BluetoothAddress.normalize($0) ?? $0 }
        draft.openAtLogin = environment.login.isOn || (mode == .firstRun && environment.login.problem == nil)
        self.draft = draft
        saved = draft
        hasSecret = contents.secret != nil
        configProblems = contents.config?.problems ?? []
        insists = false
        failure = nil
    }

    // MARK: The window

    func show() {
        if window == nil {
            let view = SetupView()
            view.onEdit = { [weak self] in self?.edit($0) }
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: view.fittingSize), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = view
            self.window = window
            self.view = view
            refresh()
            window.center()
        }
        if window?.isVisible == false, mode == .settings {
            // Changes that were not applied do not survive closing the window.
            loadDraft(from: environment.installation.load())
            keyboards = nil
        }
        window.map(environment.present)
        if timer == nil { timer = repeatingTimer(every: 1) { [weak self] in self?.refresh() } }
        refresh()
    }

    func windowWillClose(_ notification: Notification) {
        timer?.cancel()
        timer = nil
        stopSearching()
        guard mode == .firstRun else { return }
        // Without settings there is nothing to run, and no menu bar item to come back through.
        log("the setup window was closed before Baton was set up; quitting")
        environment.quit()
    }

    /// Brings the window up to date with this Mac. Called every second while it is open.
    func refresh() {
        search()
        readKeyboards()
        noteFailures()
        guard let window, let view else { return }
        view.apply(makeState())
        window.title = mode == .firstRun ? "Set Up Baton" : "Baton Settings"
        // The window grows and shrinks downwards as notes come and go.
        let size = view.fittingSize
        if abs(size.height - window.contentLayoutRect.height) > 0.5 {
            var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
            frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
            window.setFrame(frame, display: true)
        }
    }

    // MARK: Looking for the anchor during the first run

    /// A client being set up looks for the anchor, which tells its user three things before they
    /// press Start: that Local Network access is on, that the anchor is up, and what it is called.
    private func search() {
        guard mode == .firstRun, draft.role == .client else { return stopSearching() }
        guard environment.searchesNetwork, window?.isVisible == true, browser == nil else { return }
        searched = .searching
        let browser = NWBrowser(for: .bonjour(type: batonServiceType, domain: nil), using: NWParameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let names = results.compactMap { result -> String? in
                if case let .service(name, _, _, _) = result.endpoint { return name }
                return nil
            }
            self?.found(names.sorted().first)
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case let .waiting(error) = state { self?.searchFailed("\(error)") }
            if case let .failed(error) = state { self?.searchFailed("\(error)") }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func stopSearching() {
        browser?.cancel()
        browser = nil
        searched = .unknown
    }

    func found(_ anchorName: String?) {
        searched = anchorName.map { .working($0) } ?? .searching
        refresh()
    }

    func searchFailed(_ reason: String) {
        log("setup: looking for the anchor: \(reason)")
        if LinkFacts(name: "", connected: false, discovery: reason).diagnosis == .localNetworkBlocked { searched = .blocked }
        refresh()
    }

    // MARK: The shared keyboard

    private var choosesKeyboard: Bool { mode == .settings && anchor != nil && draft.role == .anchor }

    private func readKeyboards() {
        guard choosesKeyboard, keyboards == nil, !readingKeyboards, window?.isVisible == true, environment.bluetooth() == .allowed, let anchor else { return }
        readingKeyboards = true
        anchor.pairedKeyboards { [weak self] keyboards in
            guard let self else { return }
            self.readingKeyboards = false
            self.keyboards = keyboards
            if keyboards != nil { self.refresh() }
        }
    }

    // MARK: What the window shows

    private func noteFailures() {
        let now = Net.monotonicMillis()
        if let reason = client?.linkFacts.failures.last {
            recentFailures.removeAll { $0.reason == reason }
            recentFailures.append((now, reason))
        }
        recentFailures.removeAll { now - $0.at > 12000 }
    }

    private var linkFacts: LinkFacts? {
        guard var facts = client?.linkFacts else { return nil }
        noteFailures()
        facts.failures = recentFailures.map(\.reason)
        facts.online = online
        return facts
    }

    private var nameProblem: String? {
        if draft.name.isEmpty, !insists { return nil }
        if let problem = MachineName.problem(with: draft.name) { return problem }
        if draft.role == .client, mode == .firstRun, case let .working(anchorName?) = searched, anchorName == draft.name {
            return "The Mac with the mouse is already called “\(anchorName)”. Give this Mac a name of its own."
        }
        return nil
    }

    /// Whether the code field holds a code to pair with, as opposed to being left alone.
    private var entersCode: Bool {
        let typed = PairingCode.normalize(draft.code)
        return typed != PairingCode.normalize(saved.code) && !(typed.isEmpty && hasSecret)
    }

    private var codeProblem: String? {
        guard entersCode || !hasSecret else { return nil }
        guard let problem = PairingCode.problem(with: draft.code) else { return nil }
        switch problem {
        case .empty:
            return insists ? problem.description : nil
        case let .wrongLength(count):
            // Not while the code is still being typed.
            return insists || count > PairingCode.length ? problem.description : nil
        case .foreignCharacter, .mistyped:
            return problem.description
        }
    }

    private var codeNote: String? {
        if hasSecret, saved.code.isEmpty, PairingCode.normalize(draft.code).isEmpty {
            return "This Mac is paired by a key file that was copied to it, which has no code. Leave this empty to keep it. To pair another Mac by code, generate one here and enter it on every Mac."
        }
        if mode == .settings, entersCode, codeProblem == nil, PairingCode.problem(with: draft.code) == nil {
            return "With a new code this Mac only reaches Macs that have been given the same one."
        }
        return nil
    }

    private var changed: Bool {
        draft.name != saved.name || draft.role != saved.role || draft.keyboardAddress != saved.keyboardAddress || entersCode
    }

    /// What needs somebody's attention while Baton runs, most pressing first: in full for the
    /// window, and in a line for the menu.
    private func attention(accessibility: Bool) -> [(text: String, summary: String, arrange: Bool)] {
        var items: [(String, String, Bool)] = []
        if let anchor {
            if !accessibility {
                items.append(("Accessibility is not allowed yet, so the mouse cannot leave this Mac.", "Accessibility is not allowed yet", false))
            }
            let config = anchor.currentConfig
            for name in AnchorAttention.unplaced(online: anchor.onlineMachines, placed: Set(anchor.layout.machines.keys), anchor: config.name) {
                items.append(("“\(name)” is connected but has no place next to the other Macs yet, so the cursor cannot reach it. Choose Arrange Macs… in Baton’s menu and drag it to where it sits.",
                              "\(name) has no place yet: Arrange Macs…", true))
            }
        } else if client != nil {
            if !accessibility {
                items.append(("Accessibility is not allowed yet, so this Mac cannot be controlled.", "Accessibility is not allowed yet", false))
            }
            if let diagnosis = linkFacts?.diagnosis, diagnosis.needsAttention {
                items.append((diagnosis.advice, diagnosis.summary, false))
            }
        }
        return items
    }

    func makeState() -> SetupState {
        var state = SetupState()
        state.mode = mode
        state.name = draft.name
        state.nameProblem = nameProblem
        state.role = draft.role
        state.code = draft.code
        state.codeProblem = codeProblem
        state.codeNote = codeNote
        state.openAtLogin = draft.openAtLogin
        state.loginNote = environment.login.problem

        let accessibility = environment.accessibility()
        let bluetooth = environment.bluetooth()
        var localNetwork = searched
        if mode == .settings, let diagnosis = linkFacts?.diagnosis { localNetwork = LocalNetworkAccess(diagnosis) }
        state.permissions = PermissionRow.rows(role: draft.role, accessibility: accessibility, bluetooth: bluetooth, localNetwork: localNetwork)

        switch mode {
        case .firstRun:
            // A copy that macOS runs from a random place can be set up, but not opened at login.
            let misplaced = LaunchAgent.isTranslocated(environment.login.executable) ? environment.login.problem : nil
            state.banner = [need?.explanation, misplaced].compactMap { $0 }.joined(separator: "\n\n")
            if state.banner?.isEmpty == true { state.banner = nil }
            state.actionTitle = "Start Baton"
            state.cancelTitle = "Quit"
            state.actionNote = failure
        case .settings:
            let attention = attention(accessibility: accessibility)
            var lines = attention.map(\.text)
            if lines.isEmpty {
                if let anchor {
                    let peers = anchor.peerNames
                    let pairing = saved.code.isEmpty ? "give it the same pairing code as this Mac" : "enter the code below"
                    lines.append(peers.isEmpty
                        ? "No other Macs are connected yet. On each of them, open Baton, choose “controlled from another Mac” and \(pairing)."
                        : "Sharing the mouse and keyboard with \(peers.joined(separator: ", ")).")
                } else if let diagnosis = linkFacts?.diagnosis {
                    lines.append(diagnosis.advice)
                }
            }
            lines += configProblems.map { "In config.json, \($0)." }
            state.status = lines.isEmpty ? nil : lines.joined(separator: "\n")
            state.statusNeedsAttention = !attention.isEmpty || !configProblems.isEmpty
            if draft.name != saved.name, client != nil {
                state.nameNote = "The Mac with the mouse knows this one by its name. After the change, give it its place again there, with Arrange Macs…"
            }
            if choosesKeyboard {
                state.keyboards = KeyboardChoices.entries(paired: keyboards ?? [], configured: draft.keyboardAddress ?? saved.keyboardAddress)
                state.keyboardAddress = draft.keyboardAddress
                if bluetooth != .allowed {
                    state.keyboardNote = "Allow Bluetooth below to see the keyboards paired with this Mac."
                } else if keyboards == nil {
                    state.keyboardNote = "Reading the keyboards paired with this Mac…"
                } else if keyboards?.isEmpty == true {
                    state.keyboardNote = "No Bluetooth keyboard is paired with this Mac. Pair it in System Settings › Bluetooth, then open this window again."
                } else {
                    state.keyboardNote = "Baton follows this keyboard from Mac to Mac, so that its keys reach the Mac the cursor is on. With Keyboard follows the cursor, in the menu, it also moves the keyboard’s own connection there."
                }
            }
            state.actionTitle = "Apply and Restart"
            state.actionEnabled = changed
            state.cancelTitle = "Close"
            let pause = anchor != nil ? "The cursor comes back to this Mac while it does." : "This Mac is out of reach while it does."
            state.actionNote = failure ?? (changed ? "Baton restarts on this Mac to apply this. \(pause)" : nil)
        }
        state.actionFailed = failure != nil
        return state
    }

    // MARK: Edits

    private func edit(_ edit: SetupView.Edit) {
        failure = nil
        switch edit {
        case let .name(name): draft.name = name
        case let .role(role): draft.role = role
        case let .code(code): draft.code = code
        case .generateCode: draft.code = PairingCode.generate()
        case .copyCode: environment.copy(PairingCode.format(draft.code))
        case let .keyboard(address): draft.keyboardAddress = address
        case let .openAtLogin(on): draft.openAtLogin = on
        case let .permission(kind): fix(kind)
        case .apply: return apply()
        case .cancel: window?.close()
        }
        refresh()
    }

    private func fix(_ kind: PermissionKind) {
        switch kind {
        case .accessibility:
            environment.askForAccessibility()
        case .bluetooth where environment.bluetooth() == .notAsked:
            return environment.askForBluetooth()
        case .bluetooth, .localNetwork:
            break
        }
        environment.open(kind.settingsURL)
    }

    private func apply() {
        insists = true
        failure = nil
        guard nameProblem == nil, codeProblem == nil else { return refresh() }
        do {
            switch mode {
            case .firstRun: try finishFirstRun()
            case .settings: try applySettings()
            }
        } catch {
            failure = "That could not be saved: \(error.localizedDescription)"
            log("setup: \(error)")
        }
        refresh()
    }

    private func finishFirstRun() throws {
        let installation = environment.installation
        try installation.prepare()
        if case .unreadableConfig = need { try installation.setAsideUnreadableConfig() }
        var config = installation.load().config ?? Config(name: draft.name, role: draft.role)
        config.rename(to: draft.name)
        config.role = draft.role
        try installation.save(config)
        if entersCode || !hasSecret { try installation.pair(with: draft.code) }
        let login = environment.login
        if draft.openAtLogin != login.isOn, !draft.openAtLogin || login.problem == nil {
            try login.set(draft.openAtLogin)
        }

        let contents = installation.load()
        guard let config = contents.config, let secret = contents.secret else {
            throw LoginItemError(reason: "the settings were written but cannot be read back")
        }
        log("set up as \(config.role.rawValue) \"\(config.name)\"")
        // From here on the window is Settings: its permissions and status follow the running agent.
        mode = .settings
        need = nil
        loadDraft(from: contents)
        let start = self.start
        self.start = nil
        start?(config, secret)
    }

    private func applySettings() throws {
        if anchor?.handoffRunning == true {
            throw LoginItemError(reason: "the keyboard is moving between Macs just now. Try again in a moment.")
        }
        let draft = self.draft, saved = self.saved
        let keepsKeyboard = choosesKeyboard
        if draft.name != saved.name || draft.role != saved.role || draft.keyboardAddress != saved.keyboardAddress {
            let edit: (inout Config) -> Void = { config in
                config.rename(to: draft.name)
                config.role = draft.role
                if keepsKeyboard { config.keyboardAddress = draft.keyboardAddress }
            }
            // The anchor rewrites the whole file from its own copy, so its copy is what changes.
            if let anchor {
                anchor.updateConfig(edit)
                // It only logs a failure to write, and a restart would then bring the old settings back.
                let written = environment.installation.load().config
                guard written?.name == draft.name, written?.role == draft.role, !keepsKeyboard || written?.keyboardAddress == draft.keyboardAddress else {
                    throw LoginItemError(reason: "config.json could not be written. The log says why.")
                }
                environment.installation.renameKnownDisplays(from: saved.name, to: draft.name)
            } else {
                try environment.installation.updateConfig(edit)
            }
        }
        if entersCode { try environment.installation.pair(with: draft.code) }
        log("settings changed; restarting to apply them")
        anchor?.goLocal(at: nil)
        self.saved = draft
        environment.relaunch()
    }

    // MARK: The menu

    /// What needs attention goes to the top of the menu, where it is seen. Settings and Open at
    /// Login go where this is called from.
    func addItems(to menu: NSMenu) {
        let attention = attention(accessibility: environment.accessibility())
        for (index, item) in attention.enumerated() {
            let entry = NSMenuItem(title: "⚠︎ \(item.summary)", action: item.arrange ? #selector(showArrangement) : #selector(showFromMenu), keyEquivalent: "")
            entry.target = self
            entry.toolTip = item.text
            menu.insertItem(entry, at: index)
        }
        if !attention.isEmpty { menu.insertItem(.separator(), at: attention.count) }

        menu.addItem(withTitle: "Settings…", action: #selector(showFromMenu), keyEquivalent: "").target = self
        let login = environment.login
        // Turning it on takes a copy that will still be there at login.
        let item = menu.addItem(withTitle: "Open at Login", action: login.canToggle ? #selector(toggleLogin) : nil, keyEquivalent: "")
        item.target = self
        item.state = login.isOn ? .on : .off
        item.toolTip = login.problem
    }

    @objc private func showFromMenu() { show() }
    @objc private func showArrangement() { onShowArrangement?() }
    @objc private func toggleLogin() { _ = setLogin(!environment.login.isOn) }

    private func setLogin(_ on: Bool) -> String? {
        do {
            try environment.login.set(on)
            return nil
        } catch {
            log("open at login: \(error)")
            return "\(error)"
        }
    }

    // MARK: Control commands

    /// `ctl settings ...` drives the window without the mouse, as `ctl arrange` does its own.
    func command(_ words: [String]) -> String {
        let usage = "usage: settings [show | snapshot <png path> | name <name> | role anchor|client | code <code> | generate | keyboard <address>|none | login on|off | apply]"
        switch (words.first, words.count) {
        case (nil, _):
            break
        case ("show", 1):
            show()
        case ("snapshot", 2):
            return SetupView.writeSnapshot(of: makeState(), to: URL(fileURLWithPath: words[1])) ? "wrote \(words[1])" : "could not write \(words[1])"
        case ("name", 2):
            edit(.name(words[1]))
        case ("role", 2):
            guard let role = Role(rawValue: words[1]) else { return usage }
            edit(.role(role))
        case ("code", 2...):
            edit(.code(words.dropFirst().joined(separator: "-")))
        case ("generate", 1):
            edit(.generateCode)
        case ("keyboard", 2):
            guard choosesKeyboard else { return "the shared keyboard is chosen on the anchor, once Baton is running" }
            guard words[1] == "none" || BluetoothAddress.normalize(words[1]) != nil else { return usage }
            edit(.keyboard(BluetoothAddress.normalize(words[1])))
        case ("login", 2):
            guard ["on", "off"].contains(words[1]) else { return usage }
            if mode == .firstRun {
                edit(.openAtLogin(words[1] == "on"))
            } else if let problem = setLogin(words[1] == "on") {
                return problem
            }
        case ("apply", 1):
            apply()
        default:
            return usage
        }
        return report()
    }

    private func report() -> String {
        let state = makeState()
        let login = environment.login
        var report: [String: Any] = [
            "mode": mode == .firstRun ? "first run" : "settings",
            "window": window?.isVisible == true ? "open" : "closed",
            "name": state.name,
            "role": state.role.rawValue,
            "paired": hasSecret,
            // The code itself stays out of a report that ends up in terminals and logs.
            "code": PairingCode.normalize(draft.code).isEmpty ? "none" : (PairingCode.problem(with: draft.code) == nil ? "entered" : "incomplete"),
            "unappliedChanges": mode == .settings && changed,
            "openAtLogin": mode == .firstRun ? draft.openAtLogin : login.isOn,
            "launchAgent": ["file": login.agent.url.path, "installed": login.isOn, "starts": login.agent.executable ?? ""] as [String: Any],
            "permissions": Dictionary(uniqueKeysWithValues: state.permissions.map { ($0.kind.rawValue, $0.state) }),
        ]
        if let need { report["needs"] = "\(need)" }
        if let problem = state.nameProblem { report["nameProblem"] = problem }
        if let problem = state.codeProblem { report["codeProblem"] = problem }
        if let problem = login.problem { report["openAtLoginProblem"] = problem }
        if let status = state.status { report["status"] = status }
        if let note = state.actionNote { report["note"] = note }
        if let keyboards = state.keyboards { report["keyboards"] = keyboards.map { $0.address ?? "none" } }
        if let facts = linkFacts { report["link"] = facts.diagnosis.summary }
        return jsonString(report)
    }
}
