import XCTest
@testable import BatonCore

final class CursorShownAnywayTests: XCTestCase {
    func testTheCursorStaysOnlyWhenTheSystemShowsItOutsideTheLockScreen() {
        XCTAssertTrue(CursorShownAnyway.keepsCursorHere(shownAfterHiding: true, screenLocked: false))
        XCTAssertFalse(CursorShownAnyway.keepsCursorHere(shownAfterHiding: true, screenLocked: true))
        XCTAssertFalse(CursorShownAnyway.keepsCursorHere(shownAfterHiding: false, screenLocked: false))
        // When the system cannot be asked, the cursor goes as it always did.
        XCTAssertFalse(CursorShownAnyway.keepsCursorHere(shownAfterHiding: nil, screenLocked: false))
    }

    func testARefusalHoldsOffAskingAgainForAMoment() {
        var shown = CursorShownAnyway()
        XCTAssertFalse(shown.refusesWithoutAsking(now: 1000))
        XCTAssertTrue(shown.refused(now: 1000))
        XCTAssertTrue(shown.refusesWithoutAsking(now: 1499))
        XCTAssertFalse(shown.refusesWithoutAsking(now: 1500))
    }

    func testRefusalsInARowAreLoggedOnce() {
        var shown = CursorShownAnyway()
        XCTAssertTrue(shown.refused(now: 1000))
        XCTAssertFalse(shown.refused(now: 1500))
        XCTAssertFalse(shown.refused(now: 6400))
        // After a quiet spell, the next one is news again.
        XCTAssertTrue(shown.refused(now: 11400))
    }

    func testLeavingStartsAfresh() {
        var shown = CursorShownAnyway()
        _ = shown.refused(now: 1000)
        shown.foundShownWhileLocked()
        XCTAssertTrue(shown.shownWhileLocked)
        shown.left()
        XCTAssertFalse(shown.shownWhileLocked)
        XCTAssertFalse(shown.refusesWithoutAsking(now: 1001))
        XCTAssertTrue(shown.refused(now: 1002))
    }
}
