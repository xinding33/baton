import CoreGraphics
import XCTest
@testable import BatonCore

final class ScrollReversalTests: XCTestCase {
    let both = ScrollAxes(vertical: true, horizontal: true)

    func scroll(lines: (Int64, Int64), points: (Int64, Int64), fixed: (Double, Double), continuous: Bool = false, phase: Int64 = 0, momentumPhase: Int64 = 0) -> Scroll {
        Scroll(at: Motion(x: 300, y: 200, seq: 1), lines1: lines.0, lines2: lines.1, points1: points.0, points2: points.1,
               fixed1: fixed.0, fixed2: fixed.1, continuous: continuous, phase: phase, momentumPhase: momentumPhase)
    }

    // What a wheel and a trackpad send, as the anchor's tap reads them.
    var slowNotch: Scroll { scroll(lines: (1, 0), points: (1, 0), fixed: (0.1, 0)) }
    var fastNotch: Scroll { scroll(lines: (-3, 0), points: (-34, 0), fixed: (-3.4, 0)) }
    /// A high-resolution wheel moving less than a line.
    var partialNotch: Scroll { scroll(lines: (0, 0), points: (2, 0), fixed: (0.2, 0)) }
    var tilt: Scroll { scroll(lines: (0, -2), points: (0, -20), fixed: (0, -2)) }
    var swipe: Scroll { scroll(lines: (-3, 1), points: (-37, 12), fixed: (-3.7, 1.2), continuous: true, phase: 2) }
    var glide: Scroll { scroll(lines: (0, 0), points: (-4, 0), fixed: (-0.4, 0), continuous: true, momentumPhase: 2) }
    var liftOff: Scroll { scroll(lines: (0, 0), points: (0, 0), fixed: (0, 0), continuous: true, phase: 4) }
    var samples: [Scroll] { [slowNotch, fastNotch, partialNotch, tilt, swipe, glide, liftOff] }

    /// Reads an event the way the anchor does before forwarding it.
    func read(_ event: CGEvent) -> Scroll {
        Scroll(
            at: Motion(x: event.location.x, y: event.location.y, seq: 1),
            lines1: event.getIntegerValueField(.scrollWheelEventDeltaAxis1),
            lines2: event.getIntegerValueField(.scrollWheelEventDeltaAxis2),
            points1: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),
            points2: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2),
            fixed1: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
            fixed2: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2),
            continuous: event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
            phase: event.getIntegerValueField(.scrollWheelEventScrollPhase),
            momentumPhase: event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        )
    }

    func assertSame(_ a: Scroll, _ b: Scroll, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual([a.lines1, a.lines2, a.points1, a.points2, a.phase, a.momentumPhase], [b.lines1, b.lines2, b.points1, b.points2, b.phase, b.momentumPhase], message, file: file, line: line)
        XCTAssertEqual(a.continuous, b.continuous, message, file: file, line: line)
        // Events hold these as 16.16 fixed point.
        XCTAssertEqual(a.fixed1, b.fixed1, accuracy: 1.0 / 65536, message, file: file, line: line)
        XCTAssertEqual(a.fixed2, b.fixed2, accuracy: 1.0 / 65536, message, file: file, line: line)
        XCTAssertEqual(a.at.x, b.at.x, message, file: file, line: line)
        XCTAssertEqual(a.at.y, b.at.y, message, file: file, line: line)
    }

    // MARK: Which events to reverse

    func testReversesWheelsAndLeavesTrackpadsAlone() {
        let settings = ScrollSettings()
        XCTAssertEqual(settings.axes(continuous: false), both)
        XCTAssertNil(settings.axes(continuous: true))
    }

    func testReversesOnlyTheChosenAxes() {
        XCTAssertEqual(ScrollSettings(horizontal: false).axes(continuous: false), ScrollAxes(vertical: true, horizontal: false))
        XCTAssertEqual(ScrollSettings(vertical: false).axes(continuous: false), ScrollAxes(vertical: false, horizontal: true))
        XCTAssertNil(ScrollSettings(vertical: false, horizontal: false).axes(continuous: false))
    }

    func testReversesNothingWhenSwitchedOff() {
        XCTAssertNil(ScrollSettings(enabled: false).axes(continuous: false))
    }

    func testMenuSaysWhenTheTapIsMissing() {
        XCTAssertNil(ScrollSettings().note(tapActive: true))
        XCTAssertEqual(ScrollSettings().note(tapActive: false), "Needs Accessibility to reverse a mouse plugged into this Mac")
        XCTAssertNil(ScrollSettings(enabled: false).note(tapActive: false))
    }

    func testSettingsDefaultToReversingBothAxes() throws {
        XCTAssertEqual(try JSONDecoder().decode(ScrollSettings.self, from: Data("{}".utf8)), ScrollSettings())
        XCTAssertEqual(ScrollSettings(), ScrollSettings(enabled: true, vertical: true, horizontal: true))
        let partial = try JSONDecoder().decode(ScrollSettings.self, from: Data(#"{"horizontal": false}"#.utf8))
        XCTAssertEqual(partial, ScrollSettings(horizontal: false))
        let saved = ScrollSettings(enabled: false, vertical: false, horizontal: true)
        XCTAssertEqual(try JSONDecoder().decode(ScrollSettings.self, from: JSONEncoder().encode(saved)), saved)
    }

    // MARK: Reversing an event that passes through

    func testReversesOnlyTheChosenAxesOfAnEvent() {
        for sample in [slowNotch, fastNotch, partialNotch, tilt, scroll(lines: (3, -2), points: (30, -20), fixed: (3, -2))] {
            for (vertical, horizontal) in [(true, true), (true, false), (false, true), (false, false)] {
                let event = sample.makeEvent(source: nil)!
                ScrollAxes(vertical: vertical, horizontal: horizontal).reverse(event)
                var expected = sample
                if vertical { (expected.lines1, expected.points1, expected.fixed1) = (-sample.lines1, -sample.points1, -sample.fixed1) }
                if horizontal { (expected.lines2, expected.points2, expected.fixed2) = (-sample.lines2, -sample.points2, -sample.fixed2) }
                assertSame(read(event), expected, "vertical: \(vertical), horizontal: \(horizontal)")
            }
        }
    }

    func testReversingTwiceRestoresTheEvent() {
        let event = fastNotch.makeEvent(source: nil)!
        both.reverse(event)
        both.reverse(event)
        assertSame(read(event), fastNotch)
    }

    // MARK: Forwarded scrolls

    func testAReplayedScrollKeepsItsNatureAndDeltas() throws {
        for sample in samples {
            let event = try XCTUnwrap(sample.makeEvent(source: nil))
            assertSame(read(event), sample)
            // And still does once it has been serialised, as it is on its way to the window server.
            let posted = try XCTUnwrap(CGEvent(withDataAllocator: nil, data: event.data))
            assertSame(read(posted), sample)
        }
    }

    func testAScrollSurvivesTheWire() throws {
        for sample in samples {
            guard case let .scroll(received) = try Wire.decode(Wire.encode(.scroll(sample)).dropFirst(4)) else { return XCTFail("not a scroll") }
            assertSame(received, sample)
            XCTAssertEqual(received.fixed1, sample.fixed1)
        }
    }

    func testReversingAForwardedScrollMatchesReversingItsEvent() {
        for sample in samples {
            for axes in [both, ScrollAxes(vertical: true, horizontal: false), ScrollAxes(vertical: false, horizontal: true)] {
                let replayed = axes.reverse(sample).makeEvent(source: nil)!
                let passed = sample.makeEvent(source: nil)!
                axes.reverse(passed)
                assertSame(read(replayed), read(passed))
            }
        }
        XCTAssertEqual(both.reverse(fastNotch).lines1, 3)
        XCTAssertEqual(both.reverse(fastNotch).points1, 34)
        XCTAssertEqual(both.reverse(fastNotch).fixed1, 3.4)
        XCTAssertEqual(both.reverse(tilt).lines2, 2)
    }

    func testAnOutOfRangeDeltaDoesNotTrap() {
        let wild = scroll(lines: (.min, .max), points: (.min, .min), fixed: (0, 0))
        XCTAssertEqual(both.reverse(wild).lines2, -.max)
        XCTAssertNotNil(both.reverse(wild).makeEvent(source: nil))
    }
}
