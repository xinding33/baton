import CoreGraphics
import XCTest
@testable import BatonCore

final class DisplayPanelTests: XCTestCase {
    var folder: URL!
    var backend: FakeBackend!
    var store: RecoveryStore!
    var preferences: PreferenceStore!
    var controller: DisplayController!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        backend = FakeBackend()
        store = RecoveryStore(url: folder.appendingPathComponent("recovery.json"), boot: "test-boot")
        preferences = PreferenceStore(url: folder.appendingPathComponent("remembered.json"))
        controller = DisplayController(backend: backend, store: store, preferences: preferences, wait: { _ in })
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A controller as a restarted Baton would make it: same files, same boot, same screens.
    func restarted() -> DisplayController {
        DisplayController(backend: backend, store: store, preferences: preferences, wait: { _ in })
    }

    // MARK: The panel

    func testPanelListsEveryStateOfAnExternalDisplay() throws {
        backend.screens.append(Display(id: 3, uuid: "laptop", name: "Built-in", builtIn: true))
        try preferences.save([RememberedDisplay(uuid: "absent", name: "Absent")])
        try controller.disconnect(2)
        XCTAssertEqual(controller.panel().rows, [
            DisplayRow(uuid: "one", name: "First", state: .on),
            DisplayRow(uuid: "two", name: "Second", state: .off),
            DisplayRow(uuid: "absent", name: "Absent", state: .offWhenConnected),
        ])
    }

    func testPanelSaysWhyADisplayStaysOn() throws {
        try controller.disconnect(2)
        XCTAssertEqual(controller.panel().rows.first?.staysOn, "Keep at least one active screen on.")
    }

    func testPanelCarriesTheReasonNothingCanBeTurnedOff() {
        XCTAssertEqual(controller.panel(unavailable: "Wink is running").unavailable, "Wink is running")
        backend.available = false
        XCTAssertNotNil(controller.panel().unavailable)
    }

    func testPanelSurvivesTheLink() throws {
        try controller.disconnect(2)
        let panel = controller.panel(lastError: "oops")
        guard case let .displayPanel(received) = try Wire.decode(Wire.encode(.displayPanel(panel)).dropFirst(4)) else { return XCTFail() }
        XCTAssertEqual(received, panel)
        guard case let .displayAction(action) = try Wire.decode(Wire.encode(.displayAction(.turnOff("two"))).dropFirst(4)) else { return XCTFail() }
        XCTAssertEqual(action, .turnOff("two"))
    }

    // MARK: Menu actions

    func testTurnOffGoesByUUIDAndKeepsTheSafetyRules() throws {
        backend.screens[1].id = 7
        try controller.perform(.turnOff("two"))
        XCTAssertEqual(backend.changes.map(\.0), [7])
        XCTAssertThrowsError(try controller.perform(.turnOff("one")))
        XCTAssertThrowsError(try controller.perform(.turnOff("gone")))
        XCTAssertEqual(backend.changes.count, 1)
    }

    func testTurnOnReconnectsAndForgets() throws {
        try controller.perform(.turnOff("two"))
        try controller.perform(.turnOn("two"))
        XCTAssertEqual(backend.screens.count, 2)
        XCTAssertTrue(try preferences.load().isEmpty)
    }

    func testTurnOnForgetsADisplayThatIsNotConnected() throws {
        try preferences.save([RememberedDisplay(uuid: "absent", name: "Absent")])
        try controller.perform(.turnOn("absent"))
        XCTAssertTrue(try preferences.load().isEmpty)
        XCTAssertTrue(backend.changes.isEmpty)
    }

    func testReconnectAllForgetsEveryDisplay() throws {
        backend.screens.append(Display(id: 3, uuid: "three", name: "Third"))
        try controller.perform(.turnOff("two"))
        try controller.perform(.turnOff("three"))
        try controller.perform(.reconnectAll)
        XCTAssertEqual(backend.screens.count, 3)
        XCTAssertTrue(try preferences.load().isEmpty)
        XCTAssertTrue(try store.load().isEmpty)
    }

    // MARK: Across Baton's own restart

    func testRestartLeavesRememberedDisplaysOff() throws {
        try controller.disconnect(2)
        let next = restarted()
        XCTAssertTrue(next.adopt().isEmpty)
        XCTAssertTrue(next.applyPreferences().isEmpty)
        // Nothing was switched: the display stayed off through the restart.
        XCTAssertEqual(backend.changes.count, 1)
        XCTAssertEqual(backend.screens.map(\.uuid), ["one"])
        XCTAssertEqual(next.panel().rows.map(\.state), [.on, .off])
        try next.perform(.turnOn("two"))
        XCTAssertEqual(backend.screens.count, 2)
    }

    func testRestartReconnectsADisplayNobodyRemembers() throws {
        try controller.disconnect(2)
        try preferences.forget("two")
        XCTAssertTrue(restarted().adopt().isEmpty)
        XCTAssertEqual(backend.screens.count, 2)
        XCTAssertTrue(try store.load().isEmpty)
    }

    func testRestartDropsTheRecordOfADisplayThatCameBack() throws {
        try controller.disconnect(2)
        // E.g. after logging out and in again, which resets the session's displays.
        backend.screens.append(Display(id: 5, uuid: "two", name: "Second"))
        let next = restarted()
        XCTAssertTrue(next.adopt().isEmpty)
        XCTAssertTrue(try store.load().isEmpty)
        XCTAssertEqual(backend.changes.count, 1)
        // It is still remembered, so it is turned off again like any display that reappears.
        XCTAssertTrue(next.applyPreferences().isEmpty)
        XCTAssertEqual(backend.screens.map(\.uuid), ["one"])
    }

    func testRestartKeepsARecordItCouldNotReconnect() throws {
        try controller.disconnect(2)
        try preferences.forget("two")
        backend.rejectEnable = true
        XCTAssertFalse(restarted().adopt().isEmpty)
        XCTAssertEqual(try store.load().map(\.uuid), ["two"])
    }

    func testDarkMeansNoActiveScreen() {
        XCTAssertFalse(controller.isDark)
        backend.screens = backend.screens.map { var screen = $0; screen.active = false; return screen }
        XCTAssertTrue(controller.isDark)
        backend.screens = []
        XCTAssertTrue(controller.isDark)
    }

    func testSleepingScreensAreNotDark() throws {
        try controller.disconnect(2)
        // What a Mac reports once its screens have gone to sleep.
        backend.screens[0].active = false
        backend.screens[0].asleep = true
        XCTAssertFalse(controller.isDark)
        // Unplugged in its sleep, the last screen is gone like any other.
        backend.screens = []
        XCTAssertTrue(controller.isDark)
    }

    func testRecordsFromBeforeSleepWasToldApartStillLoad() throws {
        let record = #"{"boot":"test-boot","displays":[{"id":2,"uuid":"two","name":"Second","builtIn":false,"active":true,"online":true,"mirrors":0}]}"#
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(record.utf8).write(to: store.url)
        XCTAssertEqual(try store.load(), [Display(id: 2, uuid: "two", name: "Second")])
    }

    // MARK: Taking over from Wink

    func testFirstRunCopiesWhatWinkRemembered() throws {
        let wink = folder.appendingPathComponent("Wink"), old = folder.appendingPathComponent("Display Switch")
        let theirs = PreferenceStore(url: wink.appendingPathComponent("remembered.json"))
        try theirs.save([RememberedDisplay(uuid: "two", name: "Second")])
        try PreferenceStore(url: old.appendingPathComponent("remembered.json"))
            .save([RememberedDisplay(uuid: "two", name: "Second"), RememberedDisplay(uuid: "three", name: "Third")])
        XCTAssertEqual(try WinkImport.run(from: [wink, old], into: preferences)?.map(\.uuid), ["two", "three"])
        XCTAssertEqual(try preferences.load().map(\.uuid), ["two", "three"])
        // Wink's own list is left as it was.
        XCTAssertEqual(try theirs.load().map(\.uuid), ["two"])
        XCTAssertTrue(controller.applyPreferences().isEmpty)
        XCTAssertEqual(backend.screens.map(\.uuid), ["one"])
    }

    func testWinkIsOnlyCopiedOnce() throws {
        let wink = folder.appendingPathComponent("Wink")
        XCTAssertEqual(try WinkImport.run(from: [wink], into: preferences), [])
        try PreferenceStore(url: wink.appendingPathComponent("remembered.json")).save([RememberedDisplay(uuid: "two", name: "Second")])
        XCTAssertNil(try WinkImport.run(from: [wink], into: preferences))
        XCTAssertTrue(try preferences.load().isEmpty)
    }

    func testUnreadableWinkFileCopiesNothing() throws {
        let wink = folder.appendingPathComponent("Wink")
        try FileManager.default.createDirectory(at: wink, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: wink.appendingPathComponent("remembered.json"))
        XCTAssertEqual(try WinkImport.run(from: [wink], into: preferences), [])
    }

    // MARK: The watchdog

    func testWatchdogOnlyActsForALivingAgentWhenEveryScreenIsGone() {
        var watchdog = Watchdog(agent: 10, grace: 20)
        XCTAssertEqual(watchdog.step(now: 0, agentAlive: true, owner: 10, ownerAlive: true, anyActiveDisplay: true), .wait)
        XCTAssertEqual(watchdog.step(now: 1, agentAlive: true, owner: 10, ownerAlive: true, anyActiveDisplay: false), .reconnect)
    }

    func testWatchdogStandsAsideForTheNextAgent() {
        // A deploy: the agent stops, and a moment later a new one claims the displays.
        var watchdog = Watchdog(agent: 10, grace: 20)
        XCTAssertEqual(watchdog.step(now: 0, agentAlive: false, owner: 10, ownerAlive: false, anyActiveDisplay: true), .wait)
        XCTAssertEqual(watchdog.step(now: 3, agentAlive: false, owner: 11, ownerAlive: true, anyActiveDisplay: true), .finish(reconnect: false))
    }

    func testWatchdogReconnectsWhenNoAgentComesBack() {
        var watchdog = Watchdog(agent: 10, grace: 20)
        XCTAssertEqual(watchdog.step(now: 100, agentAlive: false, owner: 10, ownerAlive: false, anyActiveDisplay: true), .wait)
        XCTAssertEqual(watchdog.step(now: 119, agentAlive: false, owner: 10, ownerAlive: false, anyActiveDisplay: true), .wait)
        XCTAssertEqual(watchdog.step(now: 120, agentAlive: false, owner: 10, ownerAlive: false, anyActiveDisplay: true), .finish(reconnect: true))
    }

    func testWatchdogIgnoresAClaimLeftByAnEarlierAgent() {
        // The agent died before claiming; the file still names the one before it, long gone.
        var watchdog = Watchdog(agent: 10, grace: 20)
        XCTAssertEqual(watchdog.step(now: 0, agentAlive: false, owner: 9, ownerAlive: false, anyActiveDisplay: true), .wait)
        XCTAssertEqual(watchdog.step(now: 20, agentAlive: false, owner: 9, ownerAlive: false, anyActiveDisplay: true), .finish(reconnect: true))
    }

    func testWatchdogDoesNotWaitInTheDark() {
        var watchdog = Watchdog(agent: 10, grace: 20)
        XCTAssertEqual(watchdog.step(now: 0, agentAlive: false, owner: nil, ownerAlive: false, anyActiveDisplay: false), .finish(reconnect: true))
    }

    // MARK: The cursor layout when a display is turned off

    private func layout(mini: [CGRect]) -> Layout {
        Layout.resolve(
            root: "studio",
            displays: ["studio": [CGRect(x: 0, y: 0, width: 2560, height: 1707)], "mini": mini],
            placements: [Placement(machine: "mini", side: .left, of: "studio", align: .end)]
        )
    }

    func testCursorOnADisplayThatIsTurnedOffMovesToOneThatIsLeft() {
        let main = CGRect(x: 0, y: 0, width: 2560, height: 1440), second = CGRect(x: 2560, y: 0, width: 1920, height: 1080)
        let before = layout(mini: [main, second]), after = layout(mini: [main])
        let cursor = CGPoint(x: 3000, y: 800)
        XCTAssertEqual(before.machines["mini"]!.clamp(cursor), cursor)
        XCTAssertEqual(after.machines["mini"]!.clamp(cursor), CGPoint(x: 2559, y: 800))
        // The mini now ends at its remaining display, and that is what faces the studio.
        XCTAssertEqual(after.machines["mini"]!.virtualBounds, CGRect(x: -2560, y: 267, width: 2560, height: 1440))
        XCTAssertEqual(after.move(on: "studio", from: CGPoint(x: 3, y: 1000), dx: -40, dy: 0), .cross(machine: "mini", point: CGPoint(x: 2559, y: 733)))
    }

    func testTurningOffTheMainDisplayShiftsTheOthersToTheOrigin() {
        // With the main display gone, the second one becomes main and its frame starts at zero.
        let after = layout(mini: [CGRect(x: 0, y: 0, width: 1920, height: 1080)])
        XCTAssertEqual(after.machines["mini"]!.clamp(CGPoint(x: 1000, y: 1300)), CGPoint(x: 1000, y: 1079))
        XCTAssertEqual(after.machines["mini"]!.clamp(CGPoint(x: 3000, y: 800)), CGPoint(x: 1919, y: 800))
        XCTAssertEqual(after.machines["mini"]!.virtualBounds, CGRect(x: -1920, y: 627, width: 1920, height: 1080))
    }

    func testOwnerClaim() throws {
        let owner = DisplayOwner(url: folder.appendingPathComponent("owner.pid"))
        XCTAssertNil(owner.current())
        try owner.claim(4242)
        XCTAssertEqual(owner.current(), 4242)
    }
}
