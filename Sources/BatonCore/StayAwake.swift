import Foundation

/// Decides how the Macs stay awake together. A Mac that is in use says so over the link, and a
/// Mac that hears it counts that as activity of its own, so its display does not sleep while
/// someone is working at one of the others. The reports travel as a wake does: a client tells
/// the anchor, which passes it on to the other clients.
public struct StayAwakeCoordinator {
    public enum Action: Equatable {
        /// Count the report as activity on this Mac, if `StayAwakeConditions` allow it.
        case stayAwake
        case send(to: WakeLink)
    }

    /// A Mac in use says so this often. Display sleep is counted in minutes, so this is plenty.
    public static let reportEveryMs: UInt64 = 10000

    public let role: Role
    private var lastReportAt: UInt64?

    public init(role: Role) {
        self.role = role
    }

    /// Whether input seen on this Mac at `now` is to be reported to the others. True once per
    /// `reportEveryMs`, so it can be asked for every event.
    public mutating func reportIsDue(now: UInt64) -> Bool {
        if let last = lastReportAt, now >= last, now - last < Self.reportEveryMs { return false }
        lastReportAt = now
        return true
    }

    /// The machine called `sender` says it is in use.
    public func received(from sender: String, links: [WakeLink]) -> [Action] {
        // To the other clients, and never back to the one it came from.
        let others = role == .anchor ? links.filter { $0.name != sender }.sorted { $0.name < $1.name } : []
        return [.stayAwake] + others.map { .send(to: $0) }
    }
}

/// What a Mac looks at before it counts another Mac's use as activity of its own.
public struct StayAwakeConditions: Equatable, Sendable {
    /// Stay Awake While Another Mac Is in Use.
    public var enabled: Bool
    public var onlyOnPower: Bool
    public var onPowerAdapter: Bool
    public var displayAsleep: Bool
    public var locked: Bool

    public init(enabled: Bool, onlyOnPower: Bool, onPowerAdapter: Bool, displayAsleep: Bool, locked: Bool) {
        self.enabled = enabled
        self.onlyOnPower = onlyOnPower
        self.onPowerAdapter = onPowerAdapter
        self.displayAsleep = displayAsleep
        self.locked = locked
    }

    /// Nil when the report counts as activity; otherwise why this Mac is left to its own timers.
    public var heldBackBy: String? {
        if !enabled { return "switched off" }
        if onlyOnPower, !onPowerAdapter { return "on battery" }
        // Staying awake is not waking. A display that is off stays off: waking is up to Wake
        // Others When This Mac Wakes on the Mac that woke.
        if displayAsleep { return "the display is asleep" }
        // A Mac nobody has unlocked would only show its lock screen all day.
        if locked { return "the screen is locked" }
        return nil
    }
}

/// How long a report from another Mac holds the screen saver off here. Counting the report as
/// activity restarts the display's sleep timer and leaves the screen saver's alone: that one runs
/// from the last input at this Mac, and on a Mac that asks for its password at once the screen
/// saver starting is the lock. So each report also holds the screen saver off for as long as this
/// Mac's own settings would have, and the time runs from the last input at any of the Macs.
public enum ScreenSaverHold {
    /// When a Mac starts its screen saver if that has never been set.
    public static let usualScreenSaverSeconds = 1200

    /// Seconds from a report, or nil when there is nothing to hold off. `screenSaverAfter` is in
    /// seconds, nil when never set and 0 for never; `displaySleepsAfterMinutes` is nil when
    /// unknown and 0 for never.
    public static func seconds(screenSaverAfter: Int?, displaySleepsAfterMinutes: Int?) -> Int? {
        let screenSaver = screenSaverAfter ?? usualScreenSaverSeconds
        guard screenSaver > 0 else { return nil }
        // The hold keeps the display on as well, so it ends no later than the display would have
        // slept. A short pause must not end it either: reports stop while you read.
        guard let minutes = displaySleepsAfterMinutes, minutes > 0 else { return screenSaver }
        return min(screenSaver, minutes * 60)
    }
}
