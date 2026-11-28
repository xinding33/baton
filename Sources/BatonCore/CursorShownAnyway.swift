import Foundation

/// Decides what happens when the system shows the anchor's own cursor although Baton hid it.
///
/// Mission Control does that: it shows the cursor and moves it with the mouse itself. Baton then
/// cannot keep that cursor parked, and moving the mouse moves the cursor on the anchor as well as
/// the one on the other Mac. So the shared cursor comes back to the anchor, and for a while does
/// not leave it while the system still shows the cursor there. The lock screen shows the cursor
/// too, but nobody is at the anchor then, so the shared cursor stays where it is.
///
/// Whether the cursor shows is believed only once a hide has had time to take effect, so a
/// reading taken too early can neither bring the cursor home nor, on its own, keep it there.
public struct CursorShownAnyway: Equatable, Sendable {
    /// How long a hide is given to take effect before the cursor showing counts.
    public var settleMs: UInt64 = 100
    /// For this long after the cursor was found shown, a crossing away from the anchor is refused
    /// while the system still shows the cursor once it is hidden. Refusals do not extend it.
    public var holdMs: UInt64 = 2000
    /// After a refusal, further crossings are refused without asking again for this long, so a
    /// hand pushing at the border does not hide and show the cursor with every movement.
    public var refuseForMs: UInt64 = 500
    /// A refusal this long after the one before is logged again.
    public var quietMs: UInt64 = 5000

    private var hiddenAt: UInt64 = 0
    private var foundShownAt: UInt64?
    private var refusedUntil: UInt64 = 0
    private var lastRefusedAt: UInt64?

    public init() {}

    /// Whether the shared cursor belongs on the anchor: the system shows the anchor's cursor
    /// although it is hidden, and the screen is known not to be locked. Nil means unknown.
    public static func keepsCursorHere(shown: Bool?, screenLocked: Bool?) -> Bool {
        shown == true && screenLocked == false
    }

    /// The cursor here was just hidden.
    public mutating func hid(now: UInt64) {
        hiddenAt = now
    }

    /// Whether the last hide has had time to take effect.
    public func settled(now: UInt64) -> Bool {
        now >= hiddenAt + settleMs
    }

    /// The cursor here was found shown, long enough after it was hidden, and the shared cursor is
    /// coming home because of it.
    public mutating func foundShown(now: UInt64) {
        foundShownAt = now
    }

    /// Whether a crossing away from the anchor may be refused, the system showing the cursor once
    /// it is hidden: only shortly after the cursor was found shown.
    public func mayRefuse(now: UInt64) -> Bool {
        guard let found = foundShownAt else { return false }
        return now < found + holdMs
    }

    /// Whether a crossing is to be refused without asking the system, as one was a moment ago.
    public func refusesWithoutAsking(now: UInt64) -> Bool {
        mayRefuse(now: now) && now < refusedUntil
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
    }
}
