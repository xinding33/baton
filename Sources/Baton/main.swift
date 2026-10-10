import AppKit
import BatonCore
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var anchor: Anchor?
    private var client: ClientAgent?
    private var control: ControlServer?
    private var statusItem: NSStatusItem?
    private var activity: NSObjectProtocol?
    private var terminationSource: DispatchSourceSignal?
    private var arrangement: ArrangementPane?
    private var keyboard: KeyboardSettings?
    private var displayMenu: DisplayMenu?
    private var clipboard: SharedClipboard?
    private let settings = SetupWindowController()
    private let window = SettingsWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        control = ControlServer { [weak self] words in self?.command(words) ?? "" }
        control?.start()
        // A Mac that is not set up yet shows the setup window, and starts once that is done.
        settings.host = window
        window.setPanes([settings])
        settings.whenSetUp { [weak self] config, secret in self?.start(config, secret) }
    }

    private func start(_ config: Config, _ secret: Data) {
        log("Baton starting as \(config.role.rawValue) \"\(config.name)\"")
        // Input has to flow without timer coalescing or App Nap.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Sharing input")

        let clipboard = SharedClipboard(config: config, secret: secret)
        clipboard.onStateChanged = { [weak self] in self?.refreshMenu() }
        self.clipboard = clipboard

        switch config.role {
        case .anchor:
            let anchor = Anchor(config: config, secret: secret)
            anchor.onStateChanged = { [weak self] in self?.refreshMenu() }
            do {
                try anchor.start()
            } catch {
                log("cannot start the anchor: \(error)")
                exit(1)
            }
            self.anchor = anchor
            arrangement = ArrangementPane(anchor: anchor)
            keyboard = KeyboardSettings(anchor: anchor)
            keyboard?.onStateChanged = { [weak self] in self?.refreshMenu() }
            keyboard?.clipboardRows = { [weak clipboard] in clipboard?.settingsRows() ?? [] }
            WakeTogether.shared.start(as: config, links: anchor.server)
            clipboard.onSettingChanged = { [weak anchor] in anchor?.setShareClipboard($0) }
            anchor.onPausedChanged = { [weak clipboard] paused in
                WakeTogether.shared.setPaused(paused)
                clipboard?.setPaused(paused)
            }
        case .client:
            let client = ClientAgent(config: config, secret: secret)
            client.onStateChanged = { [weak self] in self?.refreshMenu() }
            client.onAnchorChanged = { [weak clipboard] in clipboard?.anchorChanged($0) }
            client.start()
            self.client = client
            WakeTogether.shared.start(as: config, links: client)
        }
        displayMenu = DisplayMenu(anchor: anchor, client: client) { [weak self] in self?.refreshMenu() }
        WakeTogether.shared.onStateChanged = { [weak self] in self?.refreshMenu() }
        clipboard.start()
        Updates.shared.onStateChanged = { [weak self] in self?.refreshMenu() }
        Updates.shared.start(as: config, secret: secret, anchor: anchor, client: client)

        // Hand the mouse back before being stopped, e.g. by a redeploy.
        signal(SIGTERM, SIG_IGN)
        terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminationSource?.setEventHandler { [weak self] in
            self?.anchor?.goLocal(at: nil)
            exit(0)
        }
        terminationSource?.resume()

        ScrollReverser.shared.onStateChanged = { [weak self] in self?.refreshMenu() }
        ScrollReverser.shared.start(forwarding: { [anchor] in anchor.map { $0.focus != .local } ?? false })

        settings.attach(anchor: anchor, client: client)
        settings.otherAttention = { [weak clipboard] in [clipboard?.attention].compactMap { $0 } }
        settings.onMenuIconChanged = { [weak self] in self?.refreshMenu() }
        // General first, then each feature's own pane. Where the Macs sit comes after their displays.
        // The clipboard is in the Keyboard pane, and has its own where there is none: on a client.
        var panes: [SettingsPane?] = [settings, ScrollReverser.shared.settingsPane, keyboard?.pane, displayMenu?.settingsPane, arrangement]
        panes += [WakeTogether.shared.settingsPane, keyboard == nil ? clipboard.settingsPane : nil, Updates.shared.settingsPane]
        window.setPanes(panes.compactMap { $0 })
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        refreshMenu()
    }

    /// Opening Baton while it is running shows the icon again, and its settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        MenuIcon.setHidden(false)
        refreshMenu()
        window.show()
        return false
    }

    private func command(_ words: [String]) -> String {
        switch words.first {
        case "status", nil:
            return anchor?.status() ?? client?.status() ?? settings.command([])
        case "settings":
            return window.command(Array(words.dropFirst()), setup: settings.command)
        case "opened":
            _ = applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
            return "shown"
        case "home":
            anchor?.goLocal(at: nil)
            return anchor?.status() ?? "only the anchor moves the cursor"
        case "pause":
            anchor?.setPaused(true)
            return anchor?.status() ?? "only the anchor can pause"
        case "resume":
            anchor?.setPaused(false)
            return anchor?.status() ?? "only the anchor can pause"
        case "sim":
            return anchor?.simulate(Array(words.dropFirst())) ?? client?.simulate(Array(words.dropFirst())) ?? ""
        case "arrange":
            return arrange(Array(words.dropFirst()))
        case "bt":
            let steps = Array(words.dropFirst())
            return anchor?.bluetoothSteps(steps) ?? client?.bluetoothSteps(steps) ?? ""
        case "keyboard":
            return anchor?.keyboardCommand(Array(words.dropFirst())) ?? "only the anchor moves the keyboard"
        case "scroll":
            return ScrollReverser.shared.command(Array(words.dropFirst()))
        case "displays":
            return displayMenu?.command(Array(words.dropFirst())) ?? ""
        case "wake":
            return WakeTogether.shared.command(Array(words.dropFirst()))
        case "clipboard":
            return clipboard?.command(Array(words.dropFirst())) ?? ""
        case "update":
            return Updates.shared.command(Array(words.dropFirst()))
        case "menu":
            return menuReport()
        case "icon":
            guard words.count == 2, ["show", "hide"].contains(words[1]) else { return "usage: icon show|hide" }
            MenuIcon.setHidden(words[1] == "hide")
            refreshMenu()
            return "the menu bar icon is \(MenuIcon.isHidden ? "hidden" : "shown")"
        default:
            return "commands: status, home, pause, resume, sim, arrange, keyboard, scroll, displays, wake, clipboard, update, icon, menu, settings"
        }
    }

    /// `arrange show` opens the editor; `snapshot` and `drop` exercise it without the mouse.
    private func arrange(_ words: [String]) -> String {
        guard let anchor, let arrangement else { return "only the anchor arranges machines" }
        switch words.first {
        case "show":
            window.show(arrangement.id)
        case "snapshot":
            guard words.count == 2 else { return "usage: arrange snapshot <png path>" }
            let view = arrangement.makeView(frame: NSRect(x: 0, y: 0, width: 720, height: 408))
            return view.writeSnapshot(to: URL(fileURLWithPath: words[1])) ? "wrote \(words[1])" : "could not write \(words[1])"
        case "drop":
            guard words.count == 4, let x = Double(words[2]), let y = Double(words[3]) else { return "usage: arrange drop <machine> <x> <y>" }
            var arrangement = anchor.arrangement()
            arrangement.drop(words[1], at: CGPoint(x: x, y: y), snap: 80)
            anchor.apply(arrangement)
        default:
            return "usage: arrange show | snapshot <png path> | drop <machine> <x> <y>"
        }
        return anchor.status()
    }

    /// What the menu is made from: where things stand on this Mac right now.
    private var menuFacts: StatusMenu.Facts {
        var facts = StatusMenu.Facts(role: anchor != nil ? .anchor : .client)
        if let anchor {
            facts.peers = anchor.peerNames
            if case let .remote(name) = anchor.focus { facts.focus = name }
            facts.paused = anchor.paused
            facts.sharesKeyboard = anchor.currentConfig.keyboardAddress != nil
            facts.keyboardOwner = anchor.keyboardOwner
            facts.online = anchor.onlineMachines.sorted()
        } else if let client {
            facts.connected = client.isConnected
            facts.active = client.active
        }
        facts.attention = settings.attention()
        facts.canWakeAll = WakeTogether.shared.canWakeAll
        facts.wakeHotKey = WakeTogether.shared.hotKeyDisplay
        facts.update = Updates.shared.menuLine
        return facts
    }

    /// Redraws the menu, and the Settings pane that is on show: called whenever something
    /// either of them shows has changed.
    private func refreshMenu() {
        window.refresh()
        guard let statusItem else { return }
        let facts = menuFacts
        statusItem.button?.title = StatusMenu.title(facts)
        statusItem.menu = MenuBarMenu.make(StatusMenu.items(facts)) { [weak self] in self?.chose($0) }
        // Never hidden while it is the only sign that a permission is missing.
        statusItem.isVisible = !MenuIcon.isHidden || !AXIsProcessTrusted()
    }

    private func chose(_ choice: MenuBarMenu.Choice) {
        switch choice {
        case .home: anchor?.goLocal(at: nil)
        case let .setPaused(paused): anchor?.setPaused(paused)
        case let .moveKeyboard(name): _ = anchor?.moveKeyboard(to: name)
        case .wakeAll: WakeTogether.shared.wakeAll()
        case let .settings(pane): window.show(pane)
        case .quit: quit()
        }
    }

    /// `ctl menu`: the menu as it stands, a line for each item.
    private func menuReport() -> String {
        guard let menu = statusItem?.menu else { return "no menu yet: Baton is not set up" }
        func lines(_ menu: NSMenu, indent: String) -> [String] {
            menu.items.flatMap { item -> [String] in
                if item.isSeparatorItem { return ["\(indent)---"] }
                return ["\(indent)\(item.title)\(item.action == nil && item.submenu == nil ? "  [greyed out]" : "")"] + (item.submenu.map { lines($0, indent: indent + "    ") } ?? [])
            }
        }
        return lines(menu, indent: "").joined(separator: "\n")
    }

    private func quit() {
        anchor?.goLocal(at: nil)
        // Exit cleanly so launchd leaves the agent stopped. Displays that are off come back first.
        guard let displayMenu else { exit(0) }
        displayMenu.quit()
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "ctl" {
    exit(controlClient(Array(arguments.dropFirst())))
}
if arguments.first == "display-watchdog" {
    exit(runDisplayWatchdog(Array(arguments.dropFirst())))
}
if arguments.first == "display-check" {
    exit(runDisplayCheck(Array(arguments.dropFirst())))
}
if arguments.first == "update-check" {
    exit(runUpdateCheck(Array(arguments.dropFirst())))
}
if arguments.first == "login" {
    exit(LoginItem().run(Array(arguments.dropFirst())))
}

// Opened by hand while the agent is already running: that is how a hidden menu bar icon comes
// back, and how its settings are reached. A second copy must not start, or it would take the
// agent's port and control socket. launchd starting its job is nobody asking for a window.
if arguments.isEmpty, controlClient([Relaunch.isLaunchdJob ? "status" : "opened"], quiet: true) == 0 {
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
