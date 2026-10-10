import AppKit
import BatonCore
import Network

/// The shared clipboard as the app sees it: `ClipboardService` on the real pasteboard and the
/// real network, with its menu items and its `ctl clipboard` command.
final class SharedClipboard: NSObject {
    private let config: Config
    private let secret: Data
    private let service: ClipboardService

    /// The menu needs redrawing.
    var onStateChanged: (() -> Void)?
    /// Anchor only: sharing was switched on or off and the setting should be saved.
    var onSettingChanged: ((Bool) -> Void)?
    /// Opens a pane of System Settings.
    var openSettings: (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// - Parameters:
    ///   - pasteboard: the general pasteboard unless a test hands in its own.
    ///   - universalClipboard: whether this Mac's settings leave Universal Clipboard on.
    init(config: Config, secret: Data, pasteboard: NSPasteboard = .general, universalClipboard: @escaping () -> Bool = { UniversalClipboard.isOn() }) {
        self.config = config
        self.secret = secret
        service = ClipboardService(
            name: config.name,
            hub: config.role == .anchor,
            board: SystemClipboard(pasteboard),
            enabled: config.shareClipboard,
            maxBytes: config.clipboardMaxMB * 1024 * 1024,
            universalClipboard: universalClipboard,
            log: { log("clipboard: \($0)") }
        )
    }

    /// The clipboard has its own listener, one port above the input link's.
    private var port: NWEndpoint.Port { NWEndpoint.Port(rawValue: config.port &+ 1)! }

    /// The same TLS as the input link, but as ordinary traffic: the heartbeat and the cursor
    /// travel as interactive video and go ahead of it on Wi-Fi.
    private var parameters: NWParameters {
        let parameters = Net.tlsParameters(secret: secret)
        parameters.serviceClass = .bestEffort
        return parameters
    }

    func start() {
        service.onStatusChanged = { [weak self] in DispatchQueue.main.async { self?.onStateChanged?() } }
        service.onEnabledChanged = { [weak self] value in DispatchQueue.main.async { self?.onSettingChanged?(value) } }
        service.onShowHandoffSetting = { [weak self] in
            DispatchQueue.main.async {
                log("clipboard: showing the Handoff setting")
                self?.openSettings(UniversalClipboard.settingsURL)
            }
        }
        if config.role == .anchor { service.listen(on: port, using: parameters) }
    }

    /// Client only: follows the input link to the anchor and drops with it.
    func anchorChanged(_ host: NWEndpoint.Host?) {
        if let host {
            service.connect(to: host, port: port, using: parameters)
        } else {
            service.disconnect()
        }
    }

    func menuItems() -> [NSMenuItem] {
        let status = service.status
        let reachable = config.role == .anchor || status.connected
        let share = NSMenuItem(title: "Share clipboard", action: reachable ? #selector(toggle) : nil, keyEquivalent: "")
        share.target = self
        share.state = status.enabled ? .on : .off
        var items = [share]
        if status.enabled, status.access == .asks || status.access == .denied {
            items.append(NSMenuItem(title: "Copies made here are not shared: allow Baton in Privacy & Security › Paste from Other Apps", action: nil, keyEquivalent: ""))
        }
        // The anchor lists every Mac that should turn Handoff off; a client speaks for itself.
        let machines = status.enabled ? status.turnOffHandoffOn.filter { config.role == .anchor || $0 == config.name } : []
        if !machines.isEmpty {
            items.append(NSMenuItem(title: "Universal Clipboard is also on and gets in the way:", action: nil, keyEquivalent: ""))
        }
        for machine in machines {
            let item = NSMenuItem(title: "Turn off Handoff on \(machine == config.name ? "this Mac" : machine)…", action: #selector(showHandoffSetting(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = machine
            item.toolTip = "macOS also sends every copy to \(machine == config.name ? "this Mac" : machine), more slowly, and can replace the one Baton delivered. "
                + "This opens System Settings › General › \(UniversalClipboard.settingsPaneName) there: switch off “Allow Handoff between this Mac and your iCloud devices”."
            items.append(item)
        }
        return items
    }

    @objc private func toggle() {
        service.setEnabled(!service.status.enabled)
    }

    @objc private func showHandoffSetting(_ sender: NSMenuItem) {
        guard let machine = sender.representedObject as? String else { return }
        service.showHandoffSetting(on: machine)
    }

    func command(_ words: [String]) -> String {
        switch words.first {
        case "on", "off":
            service.setEnabled(words[0] == "on")
            return "sharing the clipboard: \(words[0])"
        case nil:
            let status = service.status
            var report: [String: Any] = [
                "enabled": status.enabled,
                "pasteAccess": status.access.rawValue,
                "maxBytes": status.maxBytes,
                "shared": status.shared,
                "lastEvent": status.lastEvent,
                "universalClipboardHere": status.universalClipboard,
                "turnOffHandoffOn": status.turnOffHandoffOn,
                "handoffClipboardSeen": status.handoffClipboardSeen.map { "\(Int(-$0.timeIntervalSinceNow)) s ago" } ?? "never",
            ]
            if config.role == .anchor {
                report["port"] = status.port.map { Int($0) } ?? 0
                report["peers"] = status.peers
            } else {
                report["connected"] = status.connected
            }
            return jsonString(report)
        default:
            return "usage: clipboard [on|off]"
        }
    }
}
