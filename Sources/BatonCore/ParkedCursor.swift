import CoreGraphics
import Foundation

/// Watches the anchor's own cursor while the shared cursor is on another machine.
///
/// That cursor is parked out of sight and the mouse is disconnected from it, so the mouse moves
/// only the shared cursor. Something else can undo either, and nothing says so when it does: then
/// the mouse moves the cursor here as well as the one on the other Mac. This says when to take it
/// back, and what the log should hear about it.
public struct ParkedCursor: Equatable, Sendable {
    public struct Loose: Equatable, Sendable {
        /// How far from where it was parked the cursor was found, in points.
        public let distance: Double
        /// Whether the cursor had been captured, the mouse disconnected from it and it hidden.
        /// It is not when the event tap was down as the shared cursor left.
        public let captured: Bool
        /// The first time on this trip away. The log hears about that one.
        public let first: Bool
    }

    /// How far the cursor may stray from where it was parked, in points on either axis.
    public var slack: Double = 2

    private var taken = 0

    public init() {}

    /// The shared cursor left this machine.
    public mutating func left() {
        taken = 0
    }

    /// Whether a cursor seen at `location`, that should be at `park`, is to be taken back. Asks
    /// nothing of the system, so it can come before anything that does.
    public func isLoose(location: CGPoint, park: CGPoint, captured: Bool) -> Bool {
        !captured || abs(Double(location.x - park.x)) > slack || abs(Double(location.y - park.y)) > slack
    }

    /// The cursor here was seen at `location`, while it should be at `park`. Nil while it is there
    /// and captured; otherwise it is to be taken back.
    public mutating func check(location: CGPoint, park: CGPoint, captured: Bool) -> Loose? {
        guard isLoose(location: location, park: park, captured: captured) else { return nil }
        let dx = Double(location.x - park.x)
        let dy = Double(location.y - park.y)
        taken += 1
        return Loose(distance: (dx * dx + dy * dy).squareRoot(), captured: captured, first: taken == 1)
    }

    /// The shared cursor came back. Says how many times the cursor here was taken back while it was
    /// away, if it was.
    public mutating func returned() -> Int? {
        defer { taken = 0 }
        return taken > 0 ? taken : nil
    }
}
