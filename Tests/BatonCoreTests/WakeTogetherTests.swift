import CoreGraphics
import XCTest
@testable import BatonCore

final class WakeTogetherTests: XCTestCase {
    typealias Action = WakeCoordinator.Action

    let mini = WakeLink(name: "mini", session: 1)
    let mbp = WakeLink(name: "mbp", session: 2)
    let studio = WakeLink(name: "studio", session: 7)

    func anchor() -> WakeCoordinator { WakeCoordinator(name: "studio", role: .anchor) }
    func client(_ name: String = "mini") -> WakeCoordinator { WakeCoordinator(name: name, role: .client) }

    /// What a decision does, without the lines it writes to the log.
    func effects(_ actions: [Action]) -> [Action] {
        actions.filter { if case .log = $0 { return false } else { return true } }
    }

    // MARK: A display wakes

    func testAnchorDisplayWakeGoesToEveryClient() {
        var studio = anchor()
        let wake = WakeRequest(origin: "studio")
        XCTAssertEqual(effects(studio.displayWoke(now: 1000, links: [mini, mbp])), [.send(wake, to: mbp), .send(wake, to: mini)])
    }

    func testClientDisplayWakeGoesToTheAnchor() {
        var mini = client()
        XCTAssertEqual(effects(mini.displayWoke(now: 1000, links: [studio])), [.send(WakeRequest(origin: "mini"), to: studio)])
    }

    func testDisplayWakeIsNotSentWhenSwitchedOff() {
        var mini = client()
        mini.wakeOthers = false
        XCTAssertEqual(effects(mini.displayWoke(now: 1000, links: [studio])), [])
        // Wake All Macs is asked for, so the setting does not apply to it.
        XCTAssertEqual(effects(mini.wakeAll(now: 2000, links: [studio])), [.send(WakeRequest(origin: "mini"), to: studio)])
    }

    func testDisplayFlickeringOnTwiceWakesTheOthersOnce() {
        var mini = client()
        XCTAssertEqual(effects(mini.displayWoke(now: 1000, links: [studio])).count, 1)
        XCTAssertEqual(effects(mini.displayWoke(now: 1000 + WakeCoordinator.minIntervalMs - 1, links: [studio])), [])
        XCTAssertEqual(effects(mini.displayWoke(now: 1000 + WakeCoordinator.minIntervalMs, links: [studio])).count, 1)
    }

    // MARK: A wake arrives

    func testClientWakesItsDisplayAndSendsNothing() {
        var mini = client()
        XCTAssertEqual(effects(mini.received(WakeRequest(origin: "mbp"), from: "studio", now: 1000, links: [studio])), [.wakeDisplay])
        XCTAssertFalse(mini.hasPending(now: 1000))
    }

    func testAnchorWakesItsDisplayAndPassesItOnToTheOtherClients() {
        var studio = anchor()
        let actions = effects(studio.received(WakeRequest(origin: "mini"), from: "mini", now: 1000, links: [mini, mbp]))
        XCTAssertEqual(actions, [.wakeDisplay, .send(WakeRequest(origin: "mini"), to: mbp)])
    }

    func testAnchorPassesAClientsWakeOnWhateverItsOwnSetting() {
        var studio = anchor()
        studio.wakeOthers = false
        XCTAssertEqual(effects(studio.displayWoke(now: 500, links: [mini, mbp])), [])
        let actions = effects(studio.received(WakeRequest(origin: "mini"), from: "mini", now: 1000, links: [mini, mbp]))
        XCTAssertEqual(actions, [.wakeDisplay, .send(WakeRequest(origin: "mini"), to: mbp)])
    }

    func testAnchorDoesNotLetAClientSpeakForAnotherMachine() {
        var studio = anchor()
        let actions = effects(studio.received(WakeRequest(origin: "mbp"), from: "mini", now: 1000, links: [mini, mbp]))
        XCTAssertEqual(actions, [.wakeDisplay, .send(WakeRequest(origin: "mini"), to: mbp)])
    }

    func testOwnWakeComingBackIsIgnored() {
        var mini = client()
        XCTAssertEqual(mini.received(WakeRequest(origin: "mini"), from: "studio", now: 1000, links: [studio]), [])
    }

    // MARK: Loops

    func testMacWokenByAnotherDoesNotWakeTheOthersAgain() {
        var mini = client()
        _ = mini.received(WakeRequest(origin: "studio"), from: "studio", now: 1000, links: [studio])
        XCTAssertEqual(effects(mini.displayWoke(now: 1400, links: [studio])), [])
        XCTAssertEqual(effects(mini.displayWoke(now: 1000 + WakeCoordinator.echoWindowMs - 1, links: [studio])), [])
        // Later on its display waking is news again.
        XCTAssertEqual(effects(mini.displayWoke(now: 1000 + WakeCoordinator.echoWindowMs, links: [studio])).count, 1)
    }

    func testAnchorWokenByAClientDoesNotWakeTheOthersAgain() {
        var studio = anchor()
        _ = studio.received(WakeRequest(origin: "mini"), from: "mini", now: 1000, links: [mini, mbp])
        XCTAssertEqual(effects(studio.displayWoke(now: 1300, links: [mini, mbp])), [])
    }

    /// Three machines wired as the star they are. Every display that is told to wake reports its
    /// own wake shortly after, as a real one does.
    func testOneWakeCrossesTheStarOnceAndStops() {
        for origin in ["studio", "mini", "mbp"] {
            var machines = ["studio": anchor(), "mini": client("mini"), "mbp": client("mbp")]
            func links(of name: String) -> [WakeLink] { name == "studio" ? [mini, mbp] : [studio] }
            var displaysWoken: [String] = []
            var sent = 0
            // (time, machine, what happens there)
            var queue: [(UInt64, String, WakeRequest?, String)] = [(1000, origin, nil, "")]
            while !queue.isEmpty {
                let (now, name, request, sender) = queue.removeFirst()
                let actions = request.map { machines[name]!.received($0, from: sender, now: now, links: links(of: name)) }
                    ?? machines[name]!.displayWoke(now: now, links: links(of: name))
                for action in actions {
                    switch action {
                    case .wakeDisplay:
                        displaysWoken.append(name)
                        queue.append((now + 400, name, nil, ""))
                    case let .send(request, to):
                        sent += 1
                        XCTAssertLessThan(sent, 10, "the wake keeps going round")
                        queue.append((now + 20, to.name, request, name))
                    case .log:
                        break
                    }
                }
                queue.sort { $0.0 < $1.0 }
            }
            XCTAssertEqual(displaysWoken.sorted(), ["mbp", "mini", "studio"].filter { $0 != origin }, "from \(origin)")
            XCTAssertEqual(sent, 2, "from \(origin)")
        }
    }

    // MARK: Links that come and go

    func testWakeWaitsForTheLinkAfterWakingFromSleep() {
        var mini = client()
        XCTAssertEqual(effects(mini.displayWoke(now: 1000, links: [])), [])
        XCTAssertTrue(mini.hasPending(now: 1000))
        XCTAssertEqual(effects(mini.linksChanged(now: 1500, links: [])), [])
        XCTAssertEqual(effects(mini.linksChanged(now: 4000, links: [studio])), [.send(WakeRequest(origin: "mini"), to: studio)])
        XCTAssertEqual(effects(mini.linksChanged(now: 4500, links: [studio])), [])
    }

    func testWakeSentIntoADeadLinkIsSentAgainOverItsReplacement() {
        var mini = client()
        // Right after sleep the old connection still looks alive.
        XCTAssertEqual(effects(mini.displayWoke(now: 1000, links: [studio])).count, 1)
        XCTAssertEqual(effects(mini.linksChanged(now: 2000, links: [studio])), [])
        XCTAssertEqual(effects(mini.linksChanged(now: 4000, links: [])), [])
        let reconnected = WakeLink(name: "studio", session: 8)
        XCTAssertEqual(effects(mini.linksChanged(now: 5000, links: [reconnected])), [.send(WakeRequest(origin: "mini"), to: reconnected)])
    }

    func testStaleWakeIsNotSentToALateArrival() {
        var studio = anchor()
        _ = studio.displayWoke(now: 1000, links: [mini])
        let late = 1000 + WakeCoordinator.pendingWindowMs + 1
        XCTAssertFalse(studio.hasPending(now: late))
        XCTAssertEqual(studio.linksChanged(now: late, links: [mini, mbp]), [])
    }

    func testClientThatConnectsLateStillGetsTheAnchorsWake() {
        var studio = anchor()
        _ = studio.displayWoke(now: 1000, links: [mini])
        XCTAssertEqual(effects(studio.linksChanged(now: 3000, links: [mini, mbp])), [.send(WakeRequest(origin: "studio"), to: mbp)])
    }

    func testPassedOnWakeNeverReturnsToWhereItCameFrom() {
        var studio = anchor()
        _ = studio.received(WakeRequest(origin: "mini"), from: "mini", now: 1000, links: [mini])
        // The mini reconnects while its own wake is still fresh.
        let again = WakeLink(name: "mini", session: 9)
        XCTAssertEqual(effects(studio.linksChanged(now: 3000, links: [again, mbp])), [.send(WakeRequest(origin: "mini"), to: mbp)])
    }

    // MARK: Hotkey

    let controlOptionCommand = CGEventFlags([.maskControl, .maskAlternate, .maskCommand]).rawValue

    func testHotKeyNeedsExactlyItsModifiers() {
        let hotKey = WakeHotKey.standard
        XCTAssertEqual(hotKey.display, "⌃⌥⌘W")
        XCTAssertTrue(hotKey.matches(code: 13, flags: controlOptionCommand))
        // Caps Lock and the like are not modifiers of a shortcut.
        XCTAssertTrue(hotKey.matches(code: 13, flags: controlOptionCommand | CGEventFlags.maskAlphaShift.rawValue | 0x100))
        XCTAssertFalse(hotKey.matches(code: 13, flags: controlOptionCommand | CGEventFlags.maskShift.rawValue))
        XCTAssertFalse(hotKey.matches(code: 13, flags: CGEventFlags([.maskControl, .maskCommand]).rawValue))
        XCTAssertFalse(hotKey.matches(code: 53, flags: controlOptionCommand))
    }

    func testHotKeyWithoutARealModifierNeverMatches() {
        XCTAssertFalse(WakeHotKey(keyCode: 13, key: "W", modifiers: []).matches(code: 13, flags: 0))
        XCTAssertFalse(WakeHotKey(keyCode: 13, key: "W", modifiers: [.shift]).matches(code: 13, flags: CGEventFlags.maskShift.rawValue))
    }

    func testHotKeyFiresOncePerPressAndSwallowsTheRest() {
        var recognizer = WakeHotKeyRecognizer()
        let hotKey = WakeHotKey.standard
        XCTAssertEqual(recognizer.process(hotKey, code: 13, down: true, autorepeat: false, flags: controlOptionCommand), .fire)
        XCTAssertEqual(recognizer.process(hotKey, code: 13, down: true, autorepeat: true, flags: controlOptionCommand), .swallow)
        // The modifiers may be let go before the key is.
        XCTAssertEqual(recognizer.process(hotKey, code: 13, down: false, autorepeat: false, flags: 0), .swallow)
        XCTAssertEqual(recognizer.process(hotKey, code: 13, down: false, autorepeat: false, flags: 0), .pass)
        XCTAssertEqual(recognizer.process(hotKey, code: 13, down: true, autorepeat: false, flags: controlOptionCommand), .fire)
    }

    func testOrdinaryTypingPassesThrough() {
        var recognizer = WakeHotKeyRecognizer()
        let hotKey = WakeHotKey.standard
        XCTAssertEqual(recognizer.process(hotKey, code: 13, down: true, autorepeat: false, flags: 0), .pass)
        XCTAssertEqual(recognizer.process(hotKey, code: 13, down: false, autorepeat: false, flags: 0), .pass)
        XCTAssertEqual(recognizer.process(hotKey, code: 12, down: true, autorepeat: false, flags: controlOptionCommand), .pass)
        // The key was already held when the modifiers went down: that is not a press of the hotkey.
        XCTAssertEqual(recognizer.process(hotKey, code: 13, down: true, autorepeat: true, flags: controlOptionCommand), .pass)
        XCTAssertEqual(recognizer.process(nil, code: 13, down: true, autorepeat: false, flags: controlOptionCommand), .pass)
    }

    // MARK: Settings and the wire

    func testSettingsDefaultWhenFieldsAreMissing() throws {
        let settings = try JSONDecoder().decode(WakeSettings.self, from: Data(#"{"wakeOthers": false}"#.utf8))
        XCTAssertFalse(settings.wakeOthers)
        XCTAssertTrue(settings.keepAwake)
        XCTAssertTrue(settings.keepAwakeOnlyOnPower)
        XCTAssertEqual(settings.hotKey, .standard)
    }

    func testSettingsRoundTripIncludingNoHotKey() throws {
        var settings = WakeSettings()
        settings.keepAwakeOnlyOnPower = false
        settings.hotKey = nil
        let decoded = try JSONDecoder().decode(WakeSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
        XCTAssertNil(decoded.hotKey)

        settings.hotKey = WakeHotKey(keyCode: 40, key: "K", modifiers: [.control, .shift])
        XCTAssertEqual(try JSONDecoder().decode(WakeSettings.self, from: JSONEncoder().encode(settings)), settings)
    }

    func testWakeMessageRoundTripsOverTheWire() throws {
        let frame = try Wire.encode(.wake(WakeRequest(origin: "mbp")))
        guard case let .wake(request) = try Wire.decode(frame.dropFirst(4)) else { return XCTFail("not a wake") }
        XCTAssertEqual(request, WakeRequest(origin: "mbp"))
    }
}
