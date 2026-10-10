import AppKit
import BatonCore

/// The Displays pane of Settings: this Mac's external displays, and on the anchor the other
/// Macs' too, which are switched over the link.
final class DisplayMenu: NSObject {
    private let toggle = DisplayToggle()
    private let anchor: Anchor?

    init(anchor: Anchor?, client: ClientAgent?, onChange: @escaping () -> Void) {
        self.anchor = anchor
        super.init()
        toggle.onChange = { [unowned toggle] in
            client?.displayPanel = toggle.panel
            onChange()
        }
        client?.onDisplayAction = { [toggle] action in
            log("displays: the anchor asked for \(action)")
            toggle.perform(action)
        }
        toggle.start()
    }

    func quit() {
        toggle.reconnectAllAndExit()
    }

    // MARK: Settings

    private var remotePanels: [(String, DisplayPanel)] {
        (anchor?.displayPanels ?? [:]).sorted { $0.key < $1.key }
    }

    private(set) lazy var settingsPane = FormPane(id: StatusMenu.Pane.displays, title: "Displays", symbol: "display") { [unowned self] in self.settingsRows() }

    private func settingsRows() -> [SettingsRow] {
        let others = remotePanels.filter { !$0.1.rows.isEmpty }
        // On a client, and on an anchor that is alone, there is only this Mac to speak of.
        var rows: [SettingsRow] = [.header(others.isEmpty ? "External displays" : "This Mac")]
        rows += DisplayMenu.rows(for: toggle.panel) { [unowned self] in self.send($0, to: nil) }
        for (machine, panel) in others {
            rows.append(.header(machine))
            rows += DisplayMenu.rows(for: panel) { [unowned self] in self.send($0, to: machine) }
        }
        rows.append(.text("A display that is unticked is off while its cable stays plugged in, and Baton turns it off again whenever it connects. Quit Baton reconnects them all."))
        return rows
    }

    /// One Mac's displays as rows: ticked while on, and `send` is handed what a click asks for.
    static func rows(for panel: DisplayPanel, send: @escaping (DisplayAction) -> Void) -> [SettingsRow] {
        var rows: [SettingsRow] = panel.rows.map { row in
            switch row.state {
            case .on:
                // Greyed out where it has to stay on, or where nothing can be turned off for now.
                return .toggle(row.name, on: true, enabled: row.staysOn == nil && panel.unavailable == nil, detail: row.staysOn) { _ in send(.turnOff(row.uuid)) }
            case .off:
                return .toggle(row.name, on: false, detail: "Off. Tick it to reconnect it.") { _ in send(.turnOn(row.uuid)) }
            case .offWhenConnected:
                return .toggle(row.name, on: false, detail: "Not connected. Baton turns it off when it connects; tick it to stop that.") { _ in send(.turnOn(row.uuid)) }
            }
        }
        if panel.rows.isEmpty { rows.append(.text("No external displays.")) }
        if panel.rows.contains(where: { $0.state == .off }) { rows.append(.button("Reconnect All") { send(.reconnectAll) }) }
        if let unavailable = panel.unavailable { rows.append(.note(unavailable.replacingOccurrences(of: "\n", with: " "), warning: false)) }
        if let error = panel.lastError { rows.append(.note(error)) }
        return rows
    }

    private func send(_ action: DisplayAction, to machine: String?) {
        if let machine {
            log("displays: asking \(machine) for \(action)")
            anchor?.send(action, to: machine)
        } else {
            toggle.perform(action)
        }
    }

    // MARK: Control commands

    /// `displays` prints every panel; `displays [machine] off|on <display>` and
    /// `displays [machine] on all` do what the pane does. Displays go by name or UUID.
    func command(_ words: [String]) -> String {
        var words = words
        var machine: String?
        if let first = words.first, remotePanels.contains(where: { $0.0 == first }) {
            machine = first
            words.removeFirst()
        }
        guard let verb = words.first else {
            var panels = ["this Mac": toggle.panel]
            for (name, panel) in remotePanels { panels[name] = panel }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return String(decoding: (try? encoder.encode(panels)) ?? Data(), as: UTF8.self)
        }
        let panel = machine.flatMap { name in remotePanels.first { $0.0 == name }?.1 } ?? toggle.panel
        let wanted = words.dropFirst().joined(separator: " ")
        let action: DisplayAction
        switch (verb, wanted) {
        case ("on", "all"):
            action = .reconnectAll
        case ("on", _), ("off", _):
            let state: (DisplayRow.State) -> Bool = verb == "off" ? { $0 == .on } : { $0 != .on }
            guard let row = panel.rows.first(where: { state($0.state) && ($0.uuid == wanted || $0.name.caseInsensitiveCompare(wanted) == .orderedSame) }) else {
                return "no display \"\(wanted)\" to turn \(verb); see `displays`"
            }
            action = verb == "off" ? .turnOff(row.uuid) : .turnOn(row.uuid)
        default:
            return "usage: displays | displays [machine] off <display> | displays [machine] on <display>|all"
        }
        send(action, to: machine)
        return "asked \(machine ?? "this Mac") for \(action); `displays` shows the outcome"
    }
}
