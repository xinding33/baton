import Foundation

/// Decides what happens when the system shows the anchor's own cursor although Baton just hid it.
///
/// Mission Control does that: it shows the cursor and moves it with the mouse itself. Baton then
/// cannot keep that cursor parked, and moving the mouse moves the cursor on the anchor as well as
/// the one on the other Mac. So, while that lasts, the shared cursor stays on the anchor, or comes
/// back to it. The lock screen shows the cursor too, but nobody is at the anchor then, so the
/// shared cursor stays where it is and Baton stops hiding a cursor the system will show anyway.
public struct CursorShownAnyway: Equatable, Sendable {
    /// After a crossing was refused, further ones are refused without asking again for this long,
    /// so a hand pushing at the border does not hide and show the cursor with every movement.
    public var refuseForMs: UInt64 = 500

    /// A refusal this long after the one before is logged again.
    public var quietMs: UInt64 = 5000

    private var refusedUntil: UInt64 = 0
    private var lastRefusedAt: UInt64?
    /// Whether, on this trip away, the cursor was found shown while the screen was locked.
    public private(set) var shownWhileLocked = false

    public init() {}

    /// Whether the shared cursor belongs on the anchor, the system having been asked whether it
    /// shows the anchor's cursor just after Baton hid it. Nil means the system could not be asked.
    public static func keepsCursorHere(shownAfterHiding: Bool?, screenLocked: Bool) -> Bool {
        shownAfterHiding == true && !screenLocked
    }

    /// Whether a crossing away from the anchor is to be refused without asking the system, as one
    /// was refused a moment ago.
    public func refusesWithoutAsking(now: UInt64) -> Bool {
        now < refusedUntil
    }

    /// A crossing away from the anchor was refused. True for the first in a row, which the log
    /// hears about.
    public mutating func refused(now: UInt64) -> Bool {
        defer {
            refusedUntil = now + refuseForMs
            lastRefusedAt = now
        }
        guard let last = lastRefusedAt else { return true }
        return now >= last + quietMs
    }

    /// The shared cursor left the anchor.
    public mutating func left() {
        lastRefusedAt = nil
        refusedUntil = 0
        shownWhileLocked = false
    }

    /// The cursor here was found shown while the screen was locked: hiding it again is no use for
    /// the rest of this trip.
    public mutating func foundShownWhileLocked() {
        shownWhileLocked = true
    }
}
