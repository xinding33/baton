import XCTest
@testable import BatonCore

final class CursorShownAnywayTests: XCTestCase {
    func testTheCursorStaysOnlyWhenShownAndTheScreenIsKnownUnlocked() {
        XCTAssertTrue(CursorShownAnyway.keepsCursorHere(shown: true, screenLocked: false))
        XCTAssertFalse(CursorShownAnyway.keepsCursorHere(shown: true, screenLocked: true))
        XCTAssertFalse(CursorShownAnyway.keepsCursorHere(shown: true, screenLocked: nil))
        XCTAssertFalse(CursorShownAnyway.keepsCursorHere(shown: false, screenLocked: false))
        // When the system cannot be asked, the cursor goes as it always did.
        XCTAssertFalse(CursorShownAnyway.keepsCursorHere(shown: nil, screenLocked: false))
    }

    func testAHideIsGivenTimeToTakeEffect() {
        var shown = CursorShownAnyway()
        shown.hid(now: 1000)
        XCTAssertFalse(shown.settled(now: 1001))
        XCTAssertFalse(shown.settled(now: 1099))
        XCTAssertTrue(shown.settled(now: 1100))
    }

    func testCrossingsAreRefusableOnlyShortlyAfterTheCursorWasFoundShown() {
        var shown = CursorShownAnyway()
        // A reading right after a hide never refuses on its own.
        XCTAssertFalse(shown.mayRefuse(now: 1000))
        shown.foundShown(now: 1000)
        XCTAssertTrue(shown.mayRefuse(now: 2999))
        // Refusals do not extend the hold, so a wrong reading cannot keep the cursor here.
        _ = shown.refused(now: 2900)
        XCTAssertFalse(shown.mayRefuse(now: 3000))
        XCTAssertFalse(shown.refusesWithoutAsking(now: 3001))
    }

    func testARefusalHoldsOffAskingAgainForAMoment() {
        var shown = CursorShownAnyway()
        shown.foundShown(now: 1000)
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

    func testLeavingStartsTheRefusalsAfresh() {
        var shown = CursorShownAnyway()
        shown.foundShown(now: 1000)
        _ = shown.refused(now: 1000)
        shown.left()
        XCTAssertFalse(shown.refusesWithoutAsking(now: 1001))
        XCTAssertTrue(shown.refused(now: 1002))
    }
}
