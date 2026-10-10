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
        default:
            return "commands: status, home, pause, resume, sim"
        }
    }

    private func refreshMenu() {
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
