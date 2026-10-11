import Foundation

// What Baton adds to the display control carried over from Wink: Settings' view of a Mac's
// displays, which also travels to the anchor's Settings, and the rules for Baton's own restarts.

/// One external display as Settings shows it.
public struct DisplayRow: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case on
        /// Turned off by Baton while its cable stays plugged in.
        case off
        /// Not connected now. It is turned off when it appears.
        case offWhenConnected
    }

    public var uuid: String
    public var name: String
    public var state: State
    /// Why a display that is on has to stay on.
    public var staysOn: String?

    public init(uuid: String, name: String, state: State, staysOn: String? = nil) {
        self.uuid = uuid
        self.name = name
        self.state = state
        self.staysOn = staysOn
    }
}

/// A Mac's external displays, for its own Settings and, sent through the link, for the anchor's.
public struct DisplayPanel: Codable, Equatable, Sendable {
    public var rows: [DisplayRow]
    /// Why nothing can be turned off on this Mac for now, e.g. because Wink is running there.
    public var unavailable: String?
    public var lastError: String?

    public init(rows: [DisplayRow] = [], unavailable: String? = nil, lastError: String? = nil) {
        self.rows = rows
        self.unavailable = unavailable
        self.lastError = lastError
    }
}

/// What Settings or the menu can ask of a Mac's displays. Displays are named by UUID, which stays the same
/// when the display's ID changes.
public enum DisplayAction: Codable, Equatable, Sendable {
    case turnOff(String)
    /// Reconnects the display if it is off, and stops turning it off when it appears.
    case turnOn(String)
    case reconnectAll
}

extension DisplayController {
    /// True when no screen is left to show anything, e.g. because the last one was unplugged.
    /// Screens the Mac put to sleep are not active either, but they come back by themselves, and
    /// the system refuses a display change until they do.
    public var isDark: Bool {
        guard let displays = try? backend.displays() else { return false }
        return !displays.contains { $0.active || $0.asleep }
    }

    public func panel(unavailable: String? = nil, lastError: String? = nil) -> DisplayPanel {
        var panel = DisplayPanel(unavailable: unavailable, lastError: lastError)
        if !backend.available { panel.unavailable = "Display control is unavailable on this macOS." }
        do {
            let live = try backend.displays()
            let off = try store.load().filter { record in !live.contains { $0.uuid == record.uuid } }
            let absent = try (preferences?.load() ?? []).filter { wanted in
                !live.contains { $0.uuid == wanted.uuid } && !off.contains { $0.uuid == wanted.uuid }
            }
            for display in live.filter({ !$0.builtIn }).sorted(by: { $0.id < $1.id }) {
                let reason = DisplayPolicy.reasonToKeepOn(display, among: live)
                panel.rows.append(DisplayRow(uuid: display.uuid, name: display.name, state: .on, staysOn: reason))
            }
            panel.rows += off.map { DisplayRow(uuid: $0.uuid, name: $0.name, state: .off) }
            panel.rows += absent.map { DisplayRow(uuid: $0.uuid, name: $0.name, state: .offWhenConnected) }
        } catch {
            panel.lastError = error.localizedDescription
        }
        return panel
    }

    public func perform(_ action: DisplayAction) throws {
        switch action {
        case let .turnOff(uuid):
            guard let display = try backend.displays().first(where: { $0.uuid == uuid }) else {
                throw DisplayError("That display is no longer connected.")
            }
            try disconnect(display.id)
        case let .turnOn(uuid):
            if let record = try store.load().first(where: { $0.uuid == uuid }) {
                try turnOn(record)
            } else {
                try preferences?.forget(uuid)
            }
        case .reconnectAll:
            var errors: [String] = []
            for record in try store.load() {
                do { try turnOn(record) } catch { errors.append(error.localizedDescription) }
            }
            if !errors.isEmpty { throw DisplayError(errors.joined(separator: "\n")) }
        }
    }

    /// Run when Baton starts. Wink reconnects every display when it quits and turns the remembered
    /// ones off again at launch. Baton restarts on every deploy, where that would rearrange the
    /// windows each time, so a display turned off earlier in this boot stays off as long as it is
    /// still remembered. Records of anything else are reconnected, as Wink does at launch.
    /// Returns the failures.
    public func adopt() -> [String] {
        do {
            let wanted = Set(try preferences?.load().map(\.uuid) ?? [])
            var errors: [String] = []
            for record in try store.load() {
                let isBack = try backend.displays().contains { $0.uuid == record.uuid }
                // A display that is back only needs its record dropped, which `reconnect` does.
                guard isBack || !wanted.contains(record.uuid) else { continue }
                do { try reconnect(record) } catch { errors.append(error.localizedDescription) }
            }
            return errors
        } catch {
            return [error.localizedDescription]
        }
    }
}

/// The standalone Wink keeps the displays it turns off in its own folder. The first time Baton
/// takes charge of a Mac's displays it copies that list, so they stay off without being chosen
/// again. Wink's files are only read.
public enum WinkImport {
    /// Returns the displays copied, or nil if Baton already has a list of its own.
    @discardableResult
    public static func run(from folders: [URL], into preferences: PreferenceStore) throws -> [RememberedDisplay]? {
        guard !FileManager.default.fileExists(atPath: preferences.url.path) else { return nil }
        var found: [RememberedDisplay] = []
        for folder in folders {
            let theirs = (try? PreferenceStore(url: folder.appendingPathComponent("remembered.json")).load()) ?? []
            found += theirs.filter { new in !found.contains { $0.uuid == new.uuid } }
        }
        // Saved even when empty, so that this happens once.
        try preferences.save(found)
        return found
    }
}

/// Names the agent process answerable for the displays that are off. A new agent claims them
/// once its own watchdog is running, which tells the previous agent's watchdog to stand aside.
public struct DisplayOwner {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func claim(_ pid: Int32) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("\(pid)\n".utf8).write(to: url, options: .atomic)
    }

    public func current() -> Int32? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// The decisions of the watchdog process, which reconnects displays when nothing else will.
///
/// Wink's watchdog reconnects as soon as its app is gone. Baton's agent goes away on every
/// deploy and comes straight back, so this one first gives a new agent `grace` seconds to
/// claim the displays, and reconnects them only if none does.
public struct Watchdog {
    public enum Step: Equatable {
        case wait
        /// Reconnect the recorded displays and keep watching.
        case reconnect
        /// Stop, after reconnecting the recorded displays if `reconnect` is set.
        case finish(reconnect: Bool)
    }

    public let agent: Int32
    public let grace: TimeInterval
    private var goneSince: TimeInterval?

    public init(agent: Int32, grace: TimeInterval = 20) {
        self.agent = agent
        self.grace = grace
    }

    /// `owner` is the process that last claimed the displays and `ownerAlive` whether it still runs.
    public mutating func step(now: TimeInterval, agentAlive: Bool, owner: Int32?, ownerAlive: Bool, anyActiveDisplay: Bool) -> Step {
        if agentAlive {
            // With every screen gone there is no way to reach the menu, so bring the others back.
            return anyActiveDisplay ? .wait : .reconnect
        }
        if let owner, owner != agent, ownerAlive { return .finish(reconnect: false) }
        let since = goneSince ?? now
        goneSince = since
        if !anyActiveDisplay || now - since >= grace { return .finish(reconnect: true) }
        return .wait
    }
}
