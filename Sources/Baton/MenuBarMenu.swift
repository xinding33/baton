import AppKit
import BatonCore

/// Draws `StatusMenu`'s items as the menu bar item's menu.
enum MenuBarMenu {
    /// What a click in the menu asks for.
    enum Choice {
        case home
        case setPaused(Bool)
        case moveKeyboard(to: String)
        case wakeAll
        /// Opens Settings, on a pane or on the one it showed last.
        case settings(pane: String?)
        case quit
    }

    /// An item's target, which the item itself keeps alive.
    private final class Action: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func fire() { run() }
    }

    static func make(_ items: [StatusMenu.Item], perform: @escaping (Choice) -> Void) -> NSMenu {
        let menu = NSMenu()
        items.forEach { add($0, to: menu, perform: perform) }
        return menu
    }

    /// Without a choice the item is greyed out: a line to read.
    @discardableResult
    private static func add(_ title: String, _ choice: Choice? = nil, to menu: NSMenu, perform: @escaping (Choice) -> Void) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        if let choice {
            let action = Action { perform(choice) }
            item.representedObject = action
            item.target = action
            item.action = #selector(Action.fire)
        }
        return item
    }

    private static func add(_ item: StatusMenu.Item, to menu: NSMenu, perform: @escaping (Choice) -> Void) {
        switch item {
        case let .attention(attention):
            add("⚠︎ \(attention.summary)", .settings(pane: attention.pane), to: menu, perform: perform).toolTip = attention.detail
        case let .status(text):
            add(text, to: menu, perform: perform)
        case .home:
            add("Bring Cursor Home (⌃⌥⌘⎋)", .home, to: menu, perform: perform)
        case let .pause(resume):
            add(resume ? "Resume Sharing" : "Pause Sharing", .setPaused(!resume), to: menu, perform: perform)
        case let .keyboard(owner, destinations):
            let entry = add("Keyboard: \(owner ?? "on no Mac")", to: menu, perform: perform)
            guard !destinations.isEmpty else { return }
            let submenu = NSMenu()
            add("Move to", to: submenu, perform: perform)
            for name in destinations { add(name, .moveKeyboard(to: name), to: submenu, perform: perform) }
            entry.submenu = submenu
        case let .wakeAll(hotKey):
            add("Wake All Macs" + (hotKey.map { " (\($0))" } ?? ""), .wakeAll, to: menu, perform: perform)
        case let .notice(text, pane):
            add(text, .settings(pane: pane), to: menu, perform: perform)
        case .settings:
            add("Settings…", .settings(pane: nil), to: menu, perform: perform)
        case .quit:
            add("Quit Baton", .quit, to: menu, perform: perform)
        case .separator:
            menu.addItem(.separator())
        }
    }
}
