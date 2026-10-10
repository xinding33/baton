import AppKit
import BatonCore
import Network

/// The shared clipboard as the app sees it: `ClipboardService` on the real pasteboard and the
/// real network, with its pane of Settings and its `ctl clipboard` command.
final class SharedClipboard: NSObject {
    private let config: Config
    private let secret: Data
    private let service: ClipboardService

    /// What the menu and Settings show has changed.
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

    /// Anchor only: Pause Sharing was switched, and the clipboard pauses with it on every Mac.
    func setPaused(_ value: Bool) {
        service.setPaused(value)
    }

    /// Copies made here do not reach the other Macs because macOS has not been told to let
    /// Baton read them.
    private func pasteBlocked(_ status: ClipboardService.Status) -> Bool {
        status.enabled && (status.access == .asks || status.access == .denied)
    }

    /// The Macs to turn Handoff off on. The anchor lists every one; a client speaks for itself.
    private func handoffMachines(_ status: ClipboardService.Status) -> [String] {
        status.enabled ? status.turnOffHandoffOn.filter { config.role == .anchor || $0 == config.name } : []
    }

    /// What the menu points out while copies are not getting through as they should.
    var attention: StatusMenu.Attention? {
        let status = service.status
        if pasteBlocked(status) {
            return .init(summary: "Copies made here are not shared", detail: "Copies made on this Mac are not shared: see Clipboard.", pane: StatusMenu.Pane.clipboard)
        }
        guard !handoffMachines(status).isEmpty else { return nil }
        return .init(summary: "Universal Clipboard gets in the way", detail: "Universal Clipboard is also on and gets in the way of the shared clipboard: see Clipboard.", pane: StatusMenu.Pane.clipboard)
    }

    /// The Clipboard pane of Settings.
    private(set) lazy var settingsPane = FormPane(id: StatusMenu.Pane.clipboard, title: "Clipboard", symbol: "doc.on.clipboard") { [unowned self] in self.settingsRows() }

    private func settingsRows() -> [SettingsRow] {
        let status = service.status
        let reachable = config.role == .anchor || status.connected
        var rows: [SettingsRow] = [
            .header("Shared clipboard"),
            .toggle("Share the clipboard between your Macs", on: status.enabled, enabled: reachable,
                    detail: "What is copied on one Mac can be pasted on the others. A copy larger than \(ClipboardContent.format(bytes: status.maxBytes)) is not shared.") { [unowned self] on in
                self.service.setEnabled(on)
            },
        ]
        if status.enabled, status.paused {
            rows.append(.note("Sharing is paused, in \(config.role == .anchor ? "Baton’s menu" : "the menu of the anchor’s Baton"). Until it is resumed, a copy stays on the Mac it was made on.", warning: false))
        }
        if pasteBlocked(status) {
            rows.append(.note("Copies made on this Mac are not shared. In System Settings › Privacy & Security › Paste from Other Apps, set Baton to always allow."))
        }
        let machines = handoffMachines(status)
        if !machines.isEmpty {
            rows.append(.note("Universal Clipboard is also on and gets in the way: macOS sends every copy as well, more slowly, and can replace the one Baton delivered. "
                + "Switch off “Allow Handoff between this Mac and your iCloud devices” in System Settings › General › \(UniversalClipboard.settingsPaneName)."))
        }
        for machine in machines {
            rows.append(.button("Turn Off Handoff on \(machine == config.name ? "This Mac" : machine)…", detail: machine == config.name ? nil : "Opens the setting on \(machine).") { [unowned self] in
                self.service.showHandoffSetting(on: machine)
            })
        }
        rows.append(.text(reachable ? "For all your Macs: switching it on one switches it on every one." : "For all your Macs. It can be switched once this Mac has reached the anchor."))
        return rows
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
                "paused": status.paused,
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
