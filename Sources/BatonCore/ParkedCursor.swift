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

    /// The cursor here was seen at `location`, while it should be at `park`. Nil while it is there
    /// and captured; otherwise it is to be taken back.
    public mutating func check(location: CGPoint, park: CGPoint, captured: Bool) -> Loose? {
        let dx = Double(location.x - park.x)
        let dy = Double(location.y - park.y)
        guard !captured || abs(dx) > slack || abs(dy) > slack else { return nil }
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
