import Foundation
import IOKit.pwr_mgt
import XCTest
@testable import Baton

final class StayAwakeHoldTests: XCTestCase {
    /// Whether this process holds the display on, as `pmset -g assertions` would list it.
    private func holdsTheDisplayOn() -> Bool {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
              let all = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return false }
        let mine = all[NSNumber(value: getpid())] ?? []
        return mine.contains { $0[kIOPMAssertionNameKey] as? String == StayAwake.screenSaverHoldName }
    }

    func testLockingTheScreenEndsTheHold() {
        let center = NotificationCenter()
        let awake = StayAwake(center: center)
        awake.queue.sync { awake.holdScreenSaverOff(for: 30) }
        XCTAssertTrue(holdsTheDisplayOn())

        // The lock screen would otherwise keep the display lit until the hold ran out.
        center.post(name: StayAwake.screenLocked, object: nil)
        awake.queue.sync {}
        XCTAssertFalse(holdsTheDisplayOn())
    }

    func testStandingDownEndsTheHoldAndALaterReportStartsItAgain() {
        let awake = StayAwake(center: NotificationCenter())
        awake.queue.sync { awake.holdScreenSaverOff(for: 30) }
        awake.standDown("sharing is paused")
        awake.queue.sync {}
        XCTAssertFalse(holdsTheDisplayOn())

        awake.queue.sync { awake.holdScreenSaverOff(for: 30) }
        XCTAssertTrue(holdsTheDisplayOn())
        awake.queue.sync { awake.holdScreenSaverOff(for: nil) }
        XCTAssertFalse(holdsTheDisplayOn())
    }
}
