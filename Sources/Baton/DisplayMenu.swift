import AppKit
import BatonCore

/// The Displays part of the menu: this Mac's external displays, and in the anchor's menu the
/// other Macs' too, which are switched over the link.
final class DisplayMenu: NSObject {
    private let toggle = DisplayToggle()
    private let anchor: Anchor?

    /// A menu item's request: `action` for the displays of `machine`, or of this Mac if nil.
    private final class Request: NSObject {
        let machine: String?
        let action: DisplayAction

        init(machine: String?, action: DisplayAction) {
            self.machine = machine
            self.action = action
        }
    }

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

    // MARK: The menu

    func addItems(to menu: NSMenu) {
        menu.addItem(.separator())
        menu.addItem(withTitle: "Displays", action: nil, keyEquivalent: "")
        DisplayMenu.add(toggle.panel, on: nil, to: menu, target: self)
        for (machine, panel) in remotePanels where !panel.rows.isEmpty {
            let item = menu.addItem(withTitle: "Displays on \(machine)", action: nil, keyEquivalent: "")
            item.submenu = NSMenu()
            DisplayMenu.add(panel, on: machine, to: item.submenu!, target: self)
        }
    }

    private var remotePanels: [(String, DisplayPanel)] {
        (anchor?.displayPanels ?? [:]).sorted { $0.key < $1.key }
    }

    static func add(_ panel: DisplayPanel, on machine: String?, to menu: NSMenu, target: DisplayMenu?) {
        @discardableResult
        func add(_ title: String, _ action: DisplayAction? = nil, tip: String? = nil) -> NSMenuItem {
            // Without an action the item is shown disabled.
            let item = menu.addItem(withTitle: title, action: action == nil ? nil : #selector(clicked(_:)), keyEquivalent: "")
            item.target = target
            item.representedObject = action.map { Request(machine: machine, action: $0) }
            item.toolTip = tip
            return item
        }
        for row in panel.rows {
            switch row.state {
            case .on:
                if let reason = row.staysOn {
                    add("\(row.name) — stays on", tip: reason).state = .on
                } else if panel.unavailable != nil {
                    add(row.name).state = .on
                } else {
                    add(row.name, .turnOff(row.uuid), tip: "Turn off \(row.name)").state = .on
                }
            case .off:
                add("\(row.name) — off", .turnOn(row.uuid), tip: "Reconnect \(row.name). Until you do, Baton turns it off whenever it connects.")
            case .offWhenConnected:
                add("\(row.name) — off when connected", .turnOn(row.uuid), tip: "Stop turning off \(row.name) when it connects")
            }
        }
        if panel.rows.isEmpty { add("No external displays") }
        if panel.rows.contains(where: { $0.state == .off }) { add("Reconnect All", .reconnectAll) }
        for line in (panel.unavailable ?? "").split(separator: "\n") { add(String(line)) }
        if let error = panel.lastError {
            let firstLine = error.split(separator: "\n").first.map(String.init) ?? error
            add("⚠ \(firstLine.count > 90 ? firstLine.prefix(90) + "…" : firstLine)", tip: error)
        }
    }

    @objc private func clicked(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? Request else { return }
        send(request.action, to: request.machine)
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
    /// `displays [machine] on all` do what the menu does. Displays go by name or UUID.
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
