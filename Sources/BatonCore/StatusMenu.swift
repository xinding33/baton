import Foundation

/// What the menu bar item's menu holds: what is done in a hurry, and what needs somebody's
/// attention now. Everything that is set once and left alone is in the Settings window.
public enum StatusMenu {
    /// Something that is wrong on this Mac, and the Settings pane that puts it right.
    public struct Attention: Equatable, Sendable {
        /// One line, for the menu.
        public var summary: String
        /// In full, for the window.
        public var detail: String
        public var pane: String

        public init(summary: String, detail: String, pane: String) {
            self.summary = summary
            self.detail = detail
            self.pane = pane
        }
    }

    public struct Facts: Equatable, Sendable {
        public var role: Role

        // On the anchor.
        /// The connected clients.
        public var peers: [String] = []
        /// The other Mac the cursor is on, if it is on one.
        public var focus: String?
        public var paused = false
        /// Whether a keyboard is shared at all.
        public var sharesKeyboard = false
        public var keyboardOwner: String?
        /// Every Mac the keyboard could be on, this one included.
        public var online: [String] = []

        // On a client.
        public var connected = false
        /// The cursor is on this Mac.
        public var active = false

        public var attention: [Attention] = []
        /// Whether Wake All Macs can be offered, and its hotkey.
        public var canWakeAll = false
        public var wakeHotKey: String?
        /// What the updater is doing, or which Mac is on another version.
        public var update: String?

        public init(role: Role) {
            self.role = role
        }
    }

    public enum Item: Equatable, Sendable {
        case attention(Attention)
        case status(String)
        case home
        case pause(resume: Bool)
        /// Where the shared keyboard is, and the Macs it can be moved to.
        case keyboard(owner: String?, destinations: [String])
        case wakeAll(hotKey: String?)
        /// A line that opens a pane of Settings, e.g. while an update installs.
        case notice(String, pane: String)
        case settings
        case quit
        case separator

        public var isSeparator: Bool { self == .separator }
    }

    /// The names of the Settings panes the menu opens.
    public enum Pane {
        public static let general = "general"
        public static let arrange = "arrange"
        public static let keyboard = "keyboard"
        public static let mouse = "mouse"
        public static let displays = "displays"
        public static let wake = "wake"
        public static let clipboard = "clipboard"
        public static let updates = "updates"
    }

    /// What the menu bar item itself says: where the cursor is.
    public static func title(_ facts: Facts) -> String {
        switch facts.role {
        case .anchor:
            if facts.paused { return "⇄ paused" }
            return facts.focus.map { "⇄ \($0)" } ?? "⇄"
        case .client:
            guard facts.connected else { return "⇄ ?" }
            return facts.active ? "⇄ ●" : "⇄"
        }
    }

    public static func items(_ facts: Facts) -> [Item] {
        var sections: [[Item]] = [facts.attention.map(Item.attention)]

        var main: [Item] = []
        switch facts.role {
        case .anchor:
            main.append(.status(facts.peers.isEmpty ? "No other Macs connected" : "Connected: \(facts.peers.sorted().joined(separator: ", "))"))
            main.append(.pause(resume: facts.paused))
            main.append(.home)
            if facts.sharesKeyboard {
                main.append(.keyboard(owner: facts.keyboardOwner, destinations: facts.online.filter { $0 != facts.keyboardOwner }.sorted()))
            }
        case .client:
            main.append(.status(facts.connected ? "Connected to the anchor" : "Looking for the anchor…"))
        }
        if facts.canWakeAll { main.append(.wakeAll(hotKey: facts.wakeHotKey)) }
        sections.append(main)

        sections.append(facts.update.map { [.notice($0, pane: Pane.updates)] } ?? [])

        sections.append([.settings, .quit])
        return Array(sections.filter { !$0.isEmpty }.joined(separator: [.separator]))
    }
}

extension AnchorAttention {
    /// One line for all the Macs that have no place yet, however many there are.
    public static func unplacedSummary(_ names: [String]) -> String? {
        guard let first = names.first else { return nil }
        return names.count == 1 ? "\(first) has no place yet" : "\(names.joined(separator: ", ")) have no place yet"
    }
}
