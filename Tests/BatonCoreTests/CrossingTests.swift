import CoreGraphics
import XCTest
@testable import BatonCore

final class CrossingTests: XCTestCase {
    /// The mini on the left and the MacBook on the right of the Studio, tops in line.
    let layout = Layout.resolve(
        root: "studio",
        displays: [
            "studio": [CGRect(x: 0, y: 0, width: 2560, height: 1707)],
            "mini": [CGRect(x: 0, y: 0, width: 2560, height: 1440)],
            "mbp": [CGRect(x: 0, y: 0, width: 1512, height: 982)],
        ],
        placements: [
            Placement(machine: "mini", side: .left, of: "studio", align: .start),
            Placement(machine: "mbp", side: .right, of: "studio", align: .start),
        ]
    )

    // MARK: The step back

    func testStepLeadsBackOverTheBorderJustCrossed() {
        guard case let .cross(machine, entry) = layout.move(on: "mini", from: CGPoint(x: 2550, y: 500), dx: 30, dy: 0) else {
            return XCTFail("expected a crossing")
        }
        XCTAssertEqual(machine, "studio")
        XCTAssertEqual(layout.step(from: entry, on: "studio", toward: "mini"), CGVector(dx: -1, dy: 0))
        XCTAssertNil(layout.step(from: entry, on: "studio", toward: "mbp"))
    }

    func testStepFromEachSide() {
        XCTAssertEqual(layout.step(from: CGPoint(x: 2559, y: 500), on: "mini", toward: "studio"), CGVector(dx: 1, dy: 0))
        XCTAssertEqual(layout.step(from: CGPoint(x: 2559, y: 500), on: "studio", toward: "mbp"), CGVector(dx: 1, dy: 0))
        XCTAssertEqual(layout.step(from: CGPoint(x: 0, y: 500), on: "mbp", toward: "studio"), CGVector(dx: -1, dy: 0))
    }

    func testStepAboveAndBelow() {
        let stacked = Layout.resolve(
            root: "studio",
            displays: ["studio": [CGRect(x: 0, y: 0, width: 2560, height: 1707)], "mbp": [CGRect(x: 0, y: 0, width: 1512, height: 982)]],
            placements: [Placement(machine: "mbp", side: .below, of: "studio")]
        )
        XCTAssertEqual(stacked.step(from: CGPoint(x: 1280, y: 1706), on: "studio", toward: "mbp"), CGVector(dx: 0, dy: 1))
        XCTAssertEqual(stacked.step(from: CGPoint(x: 700, y: 0), on: "mbp", toward: "studio"), CGVector(dx: 0, dy: -1))
    }

    func testNoStepAwayFromTheBorder() {
        XCTAssertNil(layout.step(from: CGPoint(x: 1200, y: 500), on: "studio", toward: "mini"))
        // The Studio is taller than the mini: the bottom of its left edge faces nothing.
        XCTAssertNil(layout.step(from: CGPoint(x: 0, y: 1600), on: "studio", toward: "mini"))
        XCTAssertNil(layout.step(from: CGPoint(x: 0, y: 500), on: "studio", toward: "gone"))
    }

    // MARK: Going straight back

    /// A guard for a cursor that has just come onto the Studio from the mini, at time 1000.
    func arrivedFromMini() -> ReturnGuard {
        var guarded = ReturnGuard()
        guarded.crossed(from: "mini", back: CGVector(dx: -1, dy: 0), now: 1000)
        return guarded
    }

    func testATwitchDoesNotGoBack() {
        var guarded = arrivedFromMini()
        guarded.moved(dx: -1, dy: 0)
        XCTAssertFalse(guarded.allows("mini", now: 1160))
        guarded.moved(dx: -3, dy: 2)
        XCTAssertFalse(guarded.allows("mini", now: 1200))
    }

    func testAPushGoesBack() {
        var guarded = arrivedFromMini()
        for _ in 0..<5 { guarded.moved(dx: -4, dy: 0) }
        XCTAssertFalse(guarded.allows("mini", now: 1200))
        guarded.moved(dx: -4, dy: 0)
        XCTAssertTrue(guarded.allows("mini", now: 1200))
    }

    func testTravelAwayTakesBackThePush() {
        var guarded = arrivedFromMini()
        // A hand shaking on the spot never adds up to a push.
        for _ in 0..<20 {
            guarded.moved(dx: -10, dy: 0)
            guarded.moved(dx: 10, dy: 0)
        }
        XCTAssertFalse(guarded.allows("mini", now: 1400))
        // Nor does movement along the border.
        guarded.moved(dx: 0, dy: 300)
        XCTAssertFalse(guarded.allows("mini", now: 1400))
    }

    func testComingBackFromInsideTheScreenIsAPush() {
        var guarded = arrivedFromMini()
        XCTAssertEqual(guarded.moved(dx: 200, dy: 0), 200)
        XCTAssertEqual(guarded.moved(dx: -200, dy: 0), -200)
        XCTAssertTrue(guarded.allows("mini", now: 1300))
    }

    func testOnlyHoldsForAWhile() {
        let guarded = arrivedFromMini()
        XCTAssertFalse(guarded.allows("mini", now: 1749))
        XCTAssertTrue(guarded.allows("mini", now: 1750))
    }

    func testAnotherMachineIsNotHeld() {
        XCTAssertTrue(arrivedFromMini().allows("mbp", now: 1001))
    }

    func testNothingHeldWithoutABorder() {
        var guarded = arrivedFromMini()
        // Brought home by the menu or the panic key: there is no border behind the cursor.
        guarded.crossed(from: "mini", back: nil, now: 2000)
        XCTAssertEqual(guarded.moved(dx: -5, dy: 0), 0)
        XCTAssertTrue(guarded.allows("mini", now: 2001))
    }

    func testEachCrossingStartsAgain() {
        var guarded = arrivedFromMini()
        for _ in 0..<10 { guarded.moved(dx: -4, dy: 0) }
        guarded.crossed(from: "studio", back: CGVector(dx: 1, dy: 0), now: 1200)
        XCTAssertFalse(guarded.allows("studio", now: 1400))
        XCTAssertTrue(guarded.allows("mini", now: 1400))
    }

    // MARK: A cursor that sticks where it arrived

    func testReportsACursorThatStayedWhileTheMouseMovedOn() {
        var hold = ArrivalHold()
        let spot = CGPoint(x: 0, y: 500)
        hold.arrived(at: spot, now: 1000)
        for step in 1...20 {
            XCTAssertNil(hold.moved(to: spot, inward: 6, now: 1000 + UInt64(step) * 12))
        }
        XCTAssertEqual(hold.moved(to: CGPoint(x: 6, y: 500), inward: 6, now: 1252), ArrivalHold.Report(ms: 252, travel: 120))
        // Said once.
        XCTAssertNil(hold.moved(to: CGPoint(x: 12, y: 500), inward: 6, now: 1264))
    }

    func testReportsACursorThatWentBackWithoutEverMoving() {
        var hold = ArrivalHold()
        let spot = CGPoint(x: 0, y: 500)
        hold.arrived(at: spot, now: 1000)
        for _ in 0..<5 { _ = hold.moved(to: spot, inward: 6, now: 1100) }
        XCTAssertEqual(hold.ended(now: 1180), ArrivalHold.Report(ms: 180, travel: 30))
        XCTAssertNil(hold.ended(now: 1200))
    }

    func testSaysNothingOfACursorThatFollowsTheMouse() {
        var hold = ArrivalHold()
        hold.arrived(at: CGPoint(x: 0, y: 500), now: 1000)
        // The first small movement leaves it within a point of where it arrived.
        XCTAssertNil(hold.moved(to: CGPoint(x: 1, y: 500), inward: 1, now: 1008))
        XCTAssertNil(hold.moved(to: CGPoint(x: 5, y: 500), inward: 4, now: 1016))
        XCTAssertNil(hold.ended(now: 1500))
    }

    func testSaysNothingOfPushingBackAgainstTheBorder() {
        var hold = ArrivalHold()
        let spot = CGPoint(x: 0, y: 500)
        hold.arrived(at: spot, now: 1000)
        for _ in 0..<10 { XCTAssertNil(hold.moved(to: spot, inward: -8, now: 1100)) }
        XCTAssertNil(hold.moved(to: CGPoint(x: 0, y: 520), inward: 0, now: 1200))
        XCTAssertNil(hold.ended(now: 1300))
    }

    func testAMovementFromBeforeTheCursorWasPlacedDoesNotEndTheWatch() {
        var hold = ArrivalHold()
        let spot = CGPoint(x: 0, y: 500)
        hold.arrived(at: spot, now: 1000)
        XCTAssertNil(hold.moved(to: CGPoint(x: 0, y: 900), inward: 5, now: 1002))
        for _ in 0..<4 { _ = hold.moved(to: spot, inward: 5, now: 1100) }
        XCTAssertEqual(hold.moved(to: CGPoint(x: 5, y: 500), inward: 5, now: 1250), ArrivalHold.Report(ms: 250, travel: 20))
    }

    func testStopsWatchingAfterAWhile() {
        var hold = ArrivalHold()
        let spot = CGPoint(x: 0, y: 500)
        hold.arrived(at: spot, now: 1000)
        for _ in 0..<4 { _ = hold.moved(to: spot, inward: 5, now: 1100) }
        XCTAssertNil(hold.moved(to: CGPoint(x: 5, y: 500), inward: 5, now: 2500))
        XCTAssertNil(hold.ended(now: 2600))
    }
}
