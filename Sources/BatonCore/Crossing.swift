import CoreGraphics
import Foundation

extension Layout {
    /// The step off `name` at `point` that leads straight onto `other`: one point left, right, up
    /// or down. Nil unless `point` is on an edge facing `other`.
    public func step(from point: CGPoint, on name: String, toward other: String) -> CGVector? {
        let steps = [CGVector(dx: -1, dy: 0), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: -1), CGVector(dx: 0, dy: 1)]
        return steps.first { step in
            if case let .cross(machine, _) = move(on: name, from: point, dx: step.dx * 2, dy: step.dy * 2) {
                return machine == other
            }
            return false
        }
    }
}

/// Stops the cursor slipping straight back over a border it has just crossed.
///
/// The cursor lands on the very edge of the machine it enters, so the smallest movement the
/// other way would take it back: a twitch of the hand, or the mouse settling. For a short while
/// after a crossing, going back takes a real push against the border instead.
public struct ReturnGuard: Equatable, Sendable {
    /// How far the mouse must travel back, in points, to return to the machine it came from.
    public var push: Double = 24
    /// How long after a crossing that is asked for, in milliseconds.
    public var window: UInt64 = 750

    private var origin: String?
    private var backX = 0.0
    private var backY = 0.0
    private var since: UInt64 = 0
    private var pushed = 0.0

    public init() {}

    /// The cursor crossed from `origin`, which now lies one `back` step away. Without a step the
    /// cursor did not come over a border, and nothing holds it.
    public mutating func crossed(from origin: String, back: CGVector?, now: UInt64) {
        self.origin = back == nil ? nil : origin
        backX = Double(back?.dx ?? 0)
        backY = Double(back?.dy ?? 0)
        since = now
        pushed = 0
    }

    /// The mouse moved. Returns how far that was away from the border, in points: less than
    /// nothing when it was towards it. Travel away takes back what was pushed against the border.
    @discardableResult
    public mutating func moved(dx: Double, dy: Double) -> Double {
        guard origin != nil else { return 0 }
        let back = dx * backX + dy * backY
        pushed = max(0, pushed + back)
        return -back
    }

    /// Whether the cursor may cross to `machine` now.
    public func allows(_ machine: String, now: UInt64) -> Bool {
        machine != origin || now - since >= window || pushed >= push
    }
}

/// Notices the cursor staying where a crossing put it while the mouse moves on into the screen.
/// The system ignores the mouse for a moment after the cursor is placed, unless that is
/// switched off, and this is how the log tells whether it was.
public struct ArrivalHold: Equatable, Sendable {
    public struct Report: Equatable, Sendable {
        public let ms: UInt64
        /// How far the mouse travelled into the screen meanwhile, in points.
        public let travel: Double
    }

    /// How long after arriving the cursor is watched, in milliseconds.
    public var window: UInt64 = 1000
    /// Travel that a cursor crawling off the border could account for, in points.
    public var slack: Double = 8

    private var x = 0.0
    private var y = 0.0
    private var since: UInt64?
    private var ignored = 0.0

    public init() {}

    public mutating func arrived(at point: CGPoint, now: UInt64) {
        x = Double(point.x)
        y = Double(point.y)
        since = now
        ignored = 0
    }

    /// A mouse movement came in, `inward` points away from the border, with the cursor at
    /// `location`. Says once how long the cursor was held, when it gets away.
    public mutating func moved(to location: CGPoint, inward: Double, now: UInt64) -> Report? {
        guard let since else { return nil }
        guard now - since <= window else {
            self.since = nil
            return nil
        }
        if abs(Double(location.x) - x) <= 1, abs(Double(location.y) - y) <= 1 {
            if inward > 0 { ignored += inward }
            return nil
        }
        // A movement from before the cursor was placed can still be on its way, and says nothing.
        return ignored == 0 ? nil : ended(now: now)
    }

    /// The cursor left for another machine, or the watch is over. Says how long it was held, if
    /// it was.
    public mutating func ended(now: UInt64) -> Report? {
        guard let since else { return nil }
        self.since = nil
        return ignored > slack ? Report(ms: now - since, travel: ignored) : nil
    }
}
