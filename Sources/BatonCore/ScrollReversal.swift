import CoreGraphics
import Foundation

/// Whether a Mac reverses mouse-wheel scrolling. With macOS "Natural scrolling" on, this leaves
/// trackpads natural and makes notched wheels scroll the traditional way.
public struct ScrollSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var vertical: Bool
    public var horizontal: Bool

    public init(enabled: Bool = true, vertical: Bool = true, horizontal: Bool = true) {
        self.enabled = enabled
        self.vertical = vertical
        self.horizontal = horizontal
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        vertical = try c.decodeIfPresent(Bool.self, forKey: .vertical) ?? true
        horizontal = try c.decodeIfPresent(Bool.self, forKey: .horizontal) ?? true
    }

    /// The axes to reverse on one scroll event, or nil to leave it as it is. Trackpads and the
    /// Magic Mouse send continuous events and notched wheels discrete ones, which is how the two
    /// are told apart. `rival` is another app reversing the wheel on this Mac: reversing as well
    /// would undo its work.
    public func axes(continuous: Bool, rival: ScrollRival?) -> ScrollAxes? {
        guard enabled, !continuous, rival == nil, vertical || horizontal else { return nil }
        return ScrollAxes(vertical: vertical, horizontal: horizontal)
    }

    /// What the menu says when the wheel is not being reversed the way the checkmarks suggest.
    public func note(rival: ScrollRival?, tapActive: Bool) -> String? {
        if let rival { return "\(rival.rawValue) is running, so Baton leaves the wheel to it" }
        if enabled, !tapActive { return "Needs Accessibility to reverse a mouse plugged into this Mac" }
        return nil
    }
}

/// Another app that reverses the wheel. While one runs on a Mac, Baton does not reverse there.
public enum ScrollRival: String, CaseIterable, Sendable {
    case backspin = "Backspin"
    /// What Backspin was called before version 1.3.0.
    case scrollFlip = "ScrollFlip"

    public var bundleID: String {
        switch self {
        case .backspin: return "io.github.xinding33.backspin"
        case .scrollFlip: return "io.github.xinding33.scrollflip"
        }
    }

    public static func running(among bundleIDs: some Sequence<String>) -> ScrollRival? {
        let running = Set(bundleIDs.map { $0.lowercased() })
        return allCases.first { running.contains($0.bundleID) }
    }
}

/// The scroll axes to negate: vertical is axis 1, horizontal is axis 2.
public struct ScrollAxes: Equatable, Sendable {
    public var vertical: Bool
    public var horizontal: Bool

    public init(vertical: Bool, horizontal: Bool) {
        self.vertical = vertical
        self.horizontal = horizontal
    }

    private var signs: (Int64, Int64) { (vertical ? -1 : 1, horizontal ? -1 : 1) }

    /// Negates these axes of a scroll event in place.
    public func reverse(_ event: CGEvent) {
        // Read everything first: setting the line delta makes the system recompute the others.
        let line1 = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let line2 = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        let fixed1 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let fixed2 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        let point1 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let point2 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
        let (sign1, sign2) = signs

        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: sign1 &* line1)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: sign2 &* line2)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(sign1) * fixed1)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(sign2) * fixed2)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: sign1 &* point1)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: sign2 &* point2)
    }

    /// The same scroll with these axes negated.
    public func reverse(_ scroll: Scroll) -> Scroll {
        let (sign1, sign2) = signs
        var s = scroll
        s.lines1 = sign1 &* s.lines1
        s.lines2 = sign2 &* s.lines2
        s.fixed1 = Double(sign1) * s.fixed1
        s.fixed2 = Double(sign2) * s.fixed2
        s.points1 = sign1 &* s.points1
        s.points2 = sign2 &* s.points2
        return s
    }
}

extension Scroll {
    /// The event that replays this scroll. It keeps what tells a wheel from a trackpad (discrete
    /// or continuous, and the gesture phases) and all three forms of each delta.
    public func makeEvent(source: CGEventSource?) -> CGEvent? {
        let units: CGScrollEventUnit = continuous ? .pixel : .line
        let wheel1 = Int32(clamping: continuous ? points1 : lines1)
        let wheel2 = Int32(clamping: continuous ? points2 : lines2)
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: units, wheelCount: 2, wheel1: wheel1, wheel2: wheel2, wheel3: 0) else { return nil }
        // The line deltas go first: setting them makes the system recompute the others.
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: lines1)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: lines2)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: fixed1)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: fixed2)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: points1)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: points2)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: continuous ? 1 : 0)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumPhase)
        event.location = CGPoint(x: at.x, y: at.y)
        return event
    }
}
