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
    private var arrangementWindow: ArrangementWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config: Config
        let secret: Data
        do {
            try FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
            config = try loadConfig()
            secret = try loadSecret()
        } catch {
            log("cannot start: \(error)")
            exit(78)
        }
        log("Baton starting as \(config.role.rawValue) \"\(config.name)\"")
        // Input has to flow without timer coalescing or App Nap.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Sharing input")

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
            arrangementWindow = ArrangementWindowController(anchor: anchor)
        case .client:
            let client = ClientAgent(config: config, secret: secret)
            client.onStateChanged = { [weak self] in self?.refreshMenu() }
            client.start()
            self.client = client
        }

        // Hand the mouse back before being stopped, e.g. by a redeploy.
        signal(SIGTERM, SIG_IGN)
        terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminationSource?.setEventHandler { [weak self] in
            self?.anchor?.goLocal(at: nil)
            exit(0)
        }
        terminationSource?.resume()

        control = ControlServer { [weak self] words in self?.command(words) ?? "" }
        control?.start()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        refreshMenu()
    }

    private func command(_ words: [String]) -> String {
        switch words.first {
        case "status", nil:
            return anchor?.status() ?? client?.status() ?? ""
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
            return anchor?.simulate(Array(words.dropFirst())) ?? "only the anchor simulates input"
        case "arrange":
            return arrange(Array(words.dropFirst()))
        case "bt":
            let steps = Array(words.dropFirst())
            return anchor?.bluetoothSteps(steps) ?? client?.bluetoothSteps(steps) ?? ""
        case "keyboard":
            return anchor?.keyboardCommand(Array(words.dropFirst())) ?? "only the anchor moves the keyboard"
        default:
            return "commands: status, home, pause, resume, sim, arrange, keyboard"
        }
    }

    /// `arrange show` opens the editor; `snapshot` and `drop` exercise it without the mouse.
    private func arrange(_ words: [String]) -> String {
        guard let anchor, let arrangementWindow else { return "only the anchor arranges machines" }
        switch words.first {
        case "show":
            arrangementWindow.show()
        case "snapshot":
            guard words.count == 2 else { return "usage: arrange snapshot <png path>" }
            let view = arrangementWindow.makeView(frame: NSRect(x: 0, y: 0, width: 720, height: 408))
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

    private func refreshMenu() {
        arrangementWindow?.refresh()
        guard let statusItem else { return }
        let menu = NSMenu()
        var title = "⇄"
        if let anchor {
            if case let .remote(name) = anchor.focus { title = "⇄ \(name)" }
            if anchor.paused { title = "⇄ paused" }
            let peers = anchor.peerNames
            menu.addItem(withTitle: peers.isEmpty ? "No other Macs connected" : "Connected: \(peers.joined(separator: ", "))", action: nil, keyEquivalent: "")
            menu.addItem(withTitle: "Bring cursor home (⌃⌥⌘⎋)", action: #selector(home), keyEquivalent: "").target = self
            menu.addItem(withTitle: anchor.paused ? "Resume sharing" : "Pause sharing", action: #selector(togglePause), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Arrange Macs…", action: #selector(showArrangement), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Keyboard is on: \(anchor.keyboardOwner ?? "no Mac")", action: nil, keyEquivalent: "")
            let move = NSMenuItem(title: "Move keyboard to", action: nil, keyEquivalent: "")
            let destinations = NSMenu()
            for name in anchor.onlineMachines.sorted() where name != anchor.keyboardOwner {
                let item = destinations.addItem(withTitle: name, action: #selector(moveKeyboard(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = name
            }
            move.submenu = destinations
            menu.addItem(move)
            let follow = menu.addItem(withTitle: "Keyboard follows the cursor", action: #selector(toggleKeyboardFollows), keyEquivalent: "")
            follow.target = self
            follow.state = anchor.keyboardFollows ? .on : .off
        } else if let client {
            title = client.isConnected ? (client.active ? "⇄ ●" : "⇄") : "⇄ ?"
            menu.addItem(withTitle: client.isConnected ? "Connected to the anchor" : "Looking for the anchor…", action: nil, keyEquivalent: "")
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Baton", action: #selector(quit), keyEquivalent: "").target = self
        statusItem.button?.title = title
        statusItem.menu = menu
    }

    @objc private func home() { anchor?.goLocal(at: nil) }
    @objc private func showArrangement() { arrangementWindow?.show() }
    @objc private func moveKeyboard(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        anchor?.moveKeyboard(to: name)
    }

    @objc private func toggleKeyboardFollows() { anchor.map { $0.setKeyboardFollows(!$0.keyboardFollows) } }
    @objc private func togglePause() { anchor.map { $0.setPaused(!$0.paused) } }
    @objc private func quit() {
        anchor?.goLocal(at: nil)
        // Exit cleanly so launchd leaves the agent stopped.
        exit(0)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "ctl" {
    exit(controlClient(Array(arguments.dropFirst())))
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
