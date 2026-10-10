import XCTest
@testable import BatonCore

final class StayAwakeTests: XCTestCase {
    typealias Action = StayAwakeCoordinator.Action

    let mini = WakeLink(name: "mini", session: 1)
    let mbp = WakeLink(name: "mbp", session: 2)
    let studio = WakeLink(name: "studio", session: 7)
    let every = StayAwakeCoordinator.reportEveryMs

    // MARK: Saying this Mac is in use

    func testFirstInputIsReportedAtOnce() {
        var mac = StayAwakeCoordinator(role: .anchor)
        XCTAssertTrue(mac.reportIsDue(now: 0))
    }

    func testSteadyInputIsReportedOncePerInterval() {
        var mac = StayAwakeCoordinator(role: .anchor)
        let reports = stride(from: UInt64(5000), to: 5000 + 3 * every, by: 8).filter { mac.reportIsDue(now: $0) }
        XCTAssertEqual(reports, [5000, 5000 + every, 5000 + 2 * every])
    }

    func testInputAfterAQuietSpellIsReportedAtOnce() {
        var mac = StayAwakeCoordinator(role: .client)
        XCTAssertTrue(mac.reportIsDue(now: 1000))
        XCTAssertFalse(mac.reportIsDue(now: 1000 + every - 1))
        XCTAssertTrue(mac.reportIsDue(now: 1000 + 60 * every))
    }

    func testClockThatStartedOverDoesNotSilenceTheReports() {
        var mac = StayAwakeCoordinator(role: .client)
        XCTAssertTrue(mac.reportIsDue(now: 500_000))
        XCTAssertTrue(mac.reportIsDue(now: 20))
    }

    // MARK: Hearing that another Mac is in use

    func testClientStaysAwakeAndSendsNothing() {
        let mini = StayAwakeCoordinator(role: .client)
        XCTAssertEqual(mini.received(from: "studio", links: [studio]), [.stayAwake])
    }

    func testAnchorStaysAwakeAndPassesItOnToTheOtherClients() {
        let studio = StayAwakeCoordinator(role: .anchor)
        XCTAssertEqual(studio.received(from: "mini", links: [mini, mbp]), [.stayAwake, .send(to: mbp)])
        XCTAssertEqual(studio.received(from: "mbp", links: [mini, mbp]), [.stayAwake, .send(to: mini)])
    }

    func testAnchorWithOneClientPassesNothingBack() {
        let studio = StayAwakeCoordinator(role: .anchor)
        XCTAssertEqual(studio.received(from: "mini", links: [mini]), [.stayAwake])
    }

    // MARK: Whether to count it

    func conditions(enabled: Bool = true, onlyOnPower: Bool = true, onPowerAdapter: Bool = true, displayAsleep: Bool = false, locked: Bool = false) -> StayAwakeConditions {
        StayAwakeConditions(enabled: enabled, onlyOnPower: onlyOnPower, onPowerAdapter: onPowerAdapter, displayAsleep: displayAsleep, locked: locked)
    }

    func testAwakeUnlockedMacOnPowerStaysAwake() {
        XCTAssertNil(conditions().heldBackBy)
    }

    func testSwitchedOffMacIsLeftAlone() {
        XCTAssertEqual(conditions(enabled: false).heldBackBy, "switched off")
    }

    func testMacOnBatteryFollowsOnlyOnPowerAdapter() {
        XCTAssertEqual(conditions(onPowerAdapter: false).heldBackBy, "on battery")
        XCTAssertNil(conditions(onlyOnPower: false, onPowerAdapter: false).heldBackBy)
    }

    func testSleepingDisplayIsNotWoken() {
        XCTAssertEqual(conditions(displayAsleep: true).heldBackBy, "the display is asleep")
    }

    func testLockedMacIsLeftToSleep() {
        XCTAssertEqual(conditions(locked: true).heldBackBy, "the screen is locked")
    }

    // MARK: Settings and the wire

    func testSettingDefaultsToOnInAnOlderFile() throws {
        let settings = try JSONDecoder().decode(WakeSettings.self, from: Data(#"{"keepAwake": false}"#.utf8))
        XCTAssertTrue(settings.stayAwakeWithOthers)
    }

    func testSettingRoundTrips() throws {
        var settings = WakeSettings()
        settings.stayAwakeWithOthers = false
        let decoded = try JSONDecoder().decode(WakeSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertFalse(decoded.stayAwakeWithOthers)
    }

    func testInUseMessageRoundTripsOverTheWire() throws {
        let frame = try Wire.encode(.inUse)
        guard case .inUse = try Wire.decode(frame.dropFirst(4)) else { return XCTFail("not an in-use report") }
    }
}
