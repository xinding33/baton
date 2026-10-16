import CoreGraphics
import XCTest
@testable import BatonCore

final class ParkedCursorTests: XCTestCase {
    let park = CGPoint(x: 0, y: 724)

    func testACursorWhereItWasParkedIsLeftAlone() {
        var parked = ParkedCursor()
        XCTAssertNil(parked.check(location: park, park: park, captured: true))
        XCTAssertNil(parked.check(location: CGPoint(x: 2, y: 722), park: park, captured: true))
        XCTAssertNil(parked.returned())
    }

    func testACursorThatMovedIsTakenBackAndReportedOnce() {
        var parked = ParkedCursor()
        let loose = parked.check(location: CGPoint(x: 300, y: 324), park: park, captured: true)
        XCTAssertEqual(loose, ParkedCursor.Loose(distance: 500, captured: true, first: true))
        XCTAssertEqual(parked.check(location: CGPoint(x: 3, y: 724), park: park, captured: true)?.first, false)
        XCTAssertEqual(parked.returned(), 2)
        XCTAssertNil(parked.returned())
    }

    func testACursorThatWasNeverCapturedIsTakenEvenWhereItWasParked() {
        var parked = ParkedCursor()
        XCTAssertEqual(parked.check(location: park, park: park, captured: false), ParkedCursor.Loose(distance: 0, captured: false, first: true))
    }

    func testAskingWhetherItIsLooseCountsNothing() {
        var parked = ParkedCursor()
        XCTAssertTrue(parked.isLoose(location: CGPoint(x: 40, y: 724), park: park, captured: true))
        XCTAssertTrue(parked.isLoose(location: park, park: park, captured: false))
        XCTAssertFalse(parked.isLoose(location: park, park: park, captured: true))
        XCTAssertEqual(parked.check(location: CGPoint(x: 40, y: 724), park: park, captured: true)?.first, true)
    }

    func testEachTripAwayIsReportedAfresh() {
        var parked = ParkedCursor()
        _ = parked.check(location: CGPoint(x: 40, y: 724), park: park, captured: true)
        parked.left()
        XCTAssertEqual(parked.check(location: CGPoint(x: 40, y: 724), park: park, captured: true)?.first, true)
    }
}
