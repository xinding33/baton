import Foundation
import XCTest
@testable import BatonCore

private func v(_ string: String) -> Version { Version(string)! }

/// An anchor and its clients, with the network, the downloads and the restarts played out in
/// memory. `events` records what each Mac did, in order.
private final class Fleet {
    var leader: UpdateLeader
    var followers: [String: UpdateFollower] = [:]
    /// The clients sharing input with the anchor.
    var inSession: Set<String> = []
    /// Macs that cannot download anything, and why.
    var offline: [String: String] = [:]
    var cannotSwap: Set<String> = []
    var conditions = RestartConditions.idle
    var now: UInt64 = 1000
    var events: [String] = []
    var failures: [(UpdateLeader.Origin, String)] = []

    init(anchor: Build) {
        leader = UpdateLeader(own: anchor)
    }

    /// A client connects its update link. `sharing` says whether the input link took it too.
    func join(_ name: String, _ version: String, kind: BuildKind = .release, sharing: Bool = true) {
        followers[name] = UpdateFollower(own: Build(version: v(version), kind: kind))
        if sharing { inSession.insert(name) }
        run(leader.joined(name, version: v(version), kind: kind, now: now))
    }

    func leave(_ name: String) {
        followers[name] = nil
        inSession.remove(name)
        leader.left(name)
    }

    func begin(_ version: String, origin: UpdateLeader.Origin = .automatic, urgency: RestartUrgency = .whenIdle) {
        run(leader.begin(v(version), origin: origin, urgency: urgency, now: now))
    }

    func tick(after ms: UInt64 = 1000) {
        now += ms
        run(leader.tick(now: now, inSession: inSession, conditions: conditions))
    }

    private func run(_ actions: [UpdateLeader.Action]) {
        for action in actions {
            switch action {
            case let .send(name, message):
                guard var follower = followers[name] else { continue }
                let replies = follower.received(message)
                followers[name] = follower
                follow(name, replies)
            case let .prepareSelf(version):
                events.append("anchor downloads \(version)")
                run(leader.selfPrepared(version, error: offline["anchor"]))
            case let .installSelf(version):
                if cannotSwap.contains("anchor") {
                    run(leader.selfInstallFailed(version, error: "Baton can't replace itself."))
                } else {
                    events.append("anchor swaps in \(version)")
                    run(leader.selfInstalled(version))
                }
            case .restart:
                events.append("anchor restarts")
            case let .failed(origin, _, detail):
                failures.append((origin, detail))
            }
        }
    }

    private func follow(_ name: String, _ actions: [UpdateFollower.Action]) {
        for action in actions {
            switch action {
            case let .send(message):
                guard case let .prepared(version, ok, detail) = message else { continue }
                leader.prepared(name, version: version, ok: ok, detail: detail, now: now)
            case let .prepare(version):
                events.append("\(name) downloads \(version)")
                guard var follower = followers[name] else { continue }
                let replies = follower.finishedPreparing(version, error: offline[name])
                followers[name] = follower
                follow(name, replies)
            case let .install(version):
                guard var follower = followers[name] else { continue }
                if cannotSwap.contains(name) {
                    let replies = follower.installFailed(version, error: "Baton can't replace itself.")
                    followers[name] = follower
                    follow(name, replies)
                } else {
                    events.append("\(name) swaps in \(version) and restarts")
                }
            }
        }
    }
}

final class UpdateLeaderTests: XCTestCase {
    private let release = Build(version: v("1.0.0"), kind: .release)

    // MARK: Moving together

    func testEveryConnectedMacHasTheReleaseBeforeAnyOfThemInstallsIt() {
        let fleet = Fleet(anchor: release)
        fleet.join("mini", "1.0.0")
        fleet.join("mbp", "1.0.0")
        fleet.begin("1.1.0")
        XCTAssertEqual(fleet.events, ["anchor downloads 1.1.0", "mbp downloads 1.1.0", "mini downloads 1.1.0"])
        XCTAssertEqual(fleet.leader.activity, "Downloading Baton 1.1.0…")

        fleet.tick()
        // The anchor swaps first, so a client is only told to once the anchor certainly follows.
        XCTAssertEqual(fleet.events.suffix(4), ["anchor swaps in 1.1.0", "mbp swaps in 1.1.0 and restarts", "mini swaps in 1.1.0 and restarts", "anchor restarts"])
        XCTAssertEqual(fleet.leader.activity, "Installing Baton 1.1.0…")
        XCTAssertTrue(fleet.failures.isEmpty)

        // Nothing more is started while the restart is on its way.
        fleet.tick()
        fleet.begin("1.2.0")
        XCTAssertEqual(fleet.events.count, 7)
    }

    func testIfOneConnectedMacCannotGetTheReleaseNoneIsUpdated() {
        let fleet = Fleet(anchor: release)
        fleet.join("mini", "1.0.0")
        fleet.join("mbp", "1.0.0")
        fleet.offline["mbp"] = "The Internet connection appears to be offline."
        fleet.begin("1.1.0", origin: .here, urgency: .soon)
        fleet.tick()
        XCTAssertFalse(fleet.events.contains { $0.contains("swaps") || $0.contains("restarts") })
        XCTAssertEqual(fleet.failures.count, 1)
        XCTAssertEqual(fleet.failures.first?.0, .here)
        XCTAssertEqual(fleet.failures.first?.1, "mbp couldn't get the update: The Internet connection appears to be offline. No Mac was updated.")
        XCTAssertNil(fleet.leader.target)
        XCTAssertNil(fleet.leader.activity)

        // The next attempt asks the Mac again, and goes through once it can download.
        fleet.offline = [:]
        fleet.begin("1.1.0")
        fleet.tick()
        XCTAssertEqual(fleet.events.last, "anchor restarts")
        XCTAssertEqual(fleet.events.filter { $0 == "mini downloads 1.1.0" }.count, 1, "mini kept the download it had")
    }

    func testAMacThatNeverAnswersHoldsTheUpdateUntilItIsCalledOff() {
        let fleet = Fleet(anchor: release)
        fleet.join("mini", "1.0.0")
        // Shares input, but its update link is not connected.
        fleet.inSession.insert("mbp")
        fleet.begin("1.1.0", origin: .peer("mini"), urgency: .soon)
        fleet.tick(after: UpdateLeader.manualPatienceMs - 2000)
        XCTAssertTrue(fleet.failures.isEmpty)
        XCTAssertFalse(fleet.events.contains("anchor swaps in 1.1.0"))
        fleet.tick(after: 2000)
        XCTAssertEqual(fleet.failures.first?.0, .peer("mini"))
        XCTAssertEqual(fleet.failures.first?.1, "mbp is connected, but its updater isn't answering. No Mac was updated.")

        // An update nobody is waiting for is given longer.
        fleet.begin("1.1.0")
        fleet.tick(after: UpdateLeader.manualPatienceMs)
        XCTAssertEqual(fleet.failures.count, 1)
        fleet.tick(after: UpdateLeader.automaticPatienceMs)
        XCTAssertEqual(fleet.failures.count, 2)
    }

    func testTheAnchorsOwnFailureEndsTheUpdateBeforeAnyClientIsTouched() {
        let fleet = Fleet(anchor: release)
        fleet.join("mini", "1.0.0")
        fleet.offline["anchor"] = "GitHub responded with HTTP status 404."
        fleet.begin("1.1.0", origin: .here, urgency: .soon)
        XCTAssertEqual(fleet.failures.first?.1, "GitHub responded with HTTP status 404.")
        XCTAssertNil(fleet.leader.target)

        fleet.offline = [:]
        fleet.cannotSwap = ["anchor"]
        fleet.begin("1.1.0", origin: .here, urgency: .soon)
        fleet.tick()
        XCTAssertEqual(fleet.failures.last?.1, "Baton can't replace itself.")
        XCTAssertFalse(fleet.events.contains { $0.hasPrefix("mini swaps") }, "no client restarts into a version the anchor cannot follow")
    }

    // MARK: Catching up

    func testAMacThatWasAwayDoesNotHoldTheOthersBackAndCatchesUpWhenItReturns() {
        let before = Fleet(anchor: release)
        before.join("mini", "1.0.0")
        // mbp is asleep: on no link at all.
        before.begin("1.1.0")
        before.tick()
        XCTAssertEqual(before.events.last, "anchor restarts")

        // After the restart the anchor runs 1.1.0. The input link refuses mbp's old version, so it
        // is not sharing input; the update link still hears it.
        let after = Fleet(anchor: Build(version: v("1.1.0"), kind: .release))
        after.join("mini", "1.1.0")
        // Someone is typing on the other Macs. That is no reason to keep a cut-off Mac waiting.
        after.conditions = RestartConditions(handoffInProgress: false, keysDown: true, buttonsDown: false, msSinceKey: 0, msSincePointer: 0)
        after.join("mbp", "1.0.0", sharing: false)
        XCTAssertEqual(after.events, ["mbp downloads 1.1.0"])
        after.tick()
        XCTAssertEqual(after.events, ["mbp downloads 1.1.0", "mbp swaps in 1.1.0 and restarts"])
        XCTAssertTrue(after.failures.isEmpty)
        // It is not told twice while it restarts.
        after.tick()
        XCTAssertEqual(after.events.count, 2)
    }

    func testAMacBehindButStillSharingInputRestartsAtAPauseInTyping() {
        let fleet = Fleet(anchor: Build(version: v("1.1.0"), kind: .release))
        fleet.conditions = RestartConditions(handoffInProgress: false, keysDown: false, buttonsDown: false, msSinceKey: 500, msSincePointer: 0)
        fleet.join("mbp", "1.0.0", sharing: true)
        fleet.tick()
        XCTAssertEqual(fleet.events, ["mbp downloads 1.1.0"])
        fleet.conditions.msSinceKey = RestartMoment.typingPauseMs
        fleet.tick()
        XCTAssertEqual(fleet.events.last, "mbp swaps in 1.1.0 and restarts")
    }

    func testAMacWhoseDownloadFailedIsAskedAgainLater() {
        let fleet = Fleet(anchor: Build(version: v("1.1.0"), kind: .release))
        fleet.offline["mbp"] = "offline"
        fleet.join("mbp", "1.0.0", sharing: false)
        fleet.tick()
        XCTAssertEqual(fleet.events, ["mbp downloads 1.1.0"])
        XCTAssertEqual(fleet.leader.peers["mbp"]?.failure, "offline")
        fleet.offline = [:]
        fleet.tick(after: UpdateLeader.retryMs - 2000)
        XCTAssertEqual(fleet.events.count, 1)
        fleet.tick(after: 2000)
        fleet.tick()
        XCTAssertEqual(fleet.events, ["mbp downloads 1.1.0", "mbp downloads 1.1.0", "mbp swaps in 1.1.0 and restarts"])
    }

    func testAClientThatCannotSwapStaysAndIsToldAgainLater() {
        let fleet = Fleet(anchor: Build(version: v("1.1.0"), kind: .release))
        fleet.cannotSwap = ["mbp"]
        fleet.join("mbp", "1.0.0", sharing: false)
        fleet.tick()
        XCTAssertEqual(fleet.events, ["mbp downloads 1.1.0"])
        XCTAssertEqual(fleet.leader.peers["mbp"]?.failure, "Baton can't replace itself.")
        fleet.tick(after: 60000)
        XCTAssertEqual(fleet.events.count, 1, "not told to install what it no longer has ready")

        fleet.cannotSwap = []
        fleet.tick(after: UpdateLeader.retryMs)
        fleet.tick()
        XCTAssertEqual(fleet.events, ["mbp downloads 1.1.0", "mbp downloads 1.1.0", "mbp swaps in 1.1.0 and restarts"])
    }

    func testAMacOnANewerReleasePullsEveryoneUpToIt() {
        let fleet = Fleet(anchor: release)
        fleet.join("mini", "1.0.0")
        // mbp was updated by hand while it was away.
        fleet.join("mbp", "1.2.0", sharing: false)
        XCTAssertEqual(fleet.events, ["anchor downloads 1.2.0", "mini downloads 1.2.0"])
        XCTAssertEqual(fleet.leader.target?.urgency, .soon)
        fleet.tick()
        XCTAssertEqual(fleet.events.suffix(3), ["anchor swaps in 1.2.0", "mini swaps in 1.2.0 and restarts", "anchor restarts"])
        XCTAssertFalse(fleet.events.contains { $0.hasPrefix("mbp") }, "versions only go up: the newer Mac is left as it is")
    }

    func testAHigherReleaseReplacesTheOneOnItsWay() {
        let fleet = Fleet(anchor: release)
        fleet.join("mini", "1.0.0")
        fleet.conditions.msSinceKey = 0
        fleet.begin("1.1.0")
        fleet.tick()
        fleet.begin("1.2.0")
        XCTAssertEqual(fleet.leader.target?.version, v("1.2.0"))
        // An older one does not replace a newer one.
        fleet.begin("1.1.0", origin: .here, urgency: .soon)
        XCTAssertEqual(fleet.leader.target?.version, v("1.2.0"))
        XCTAssertEqual(fleet.failures.first?.1, "Baton 1.2.0 is already being installed.")
        fleet.conditions = .idle
        fleet.tick()
        XCTAssertEqual(fleet.events.suffix(3), ["anchor swaps in 1.2.0", "mini swaps in 1.2.0 and restarts", "anchor restarts"])
    }

    // MARK: Development builds and old releases

    func testADevelopmentBuildOnTheAnchorNeverMovesAnyone() {
        let fleet = Fleet(anchor: Build(version: v("1.0.0"), kind: .development))
        fleet.join("mini", "0.9.0")
        fleet.join("mbp", "1.2.0")
        fleet.begin("1.1.0", origin: .here, urgency: .soon)
        fleet.begin("1.0.0")
        fleet.begin("0.9.0")
        fleet.tick()
        fleet.tick(after: UpdateLeader.retryMs)
        XCTAssertEqual(fleet.events, [])
        XCTAssertNil(fleet.leader.target)
        XCTAssertEqual(fleet.failures.map(\.1), Array(repeating: "This Mac runs a development build, which doesn't update itself.", count: 4))
    }

    func testAnOlderOrEqualReleaseIsNeverInstalled() {
        let fleet = Fleet(anchor: Build(version: v("1.2.0"), kind: .release))
        fleet.join("mini", "1.2.0")
        for old in ["1.2.0", "1.2", "1.1.9", "0.9"] {
            fleet.begin(old, origin: .here, urgency: .soon)
        }
        fleet.tick()
        XCTAssertEqual(fleet.events, [])
        XCTAssertEqual(fleet.failures.map(\.1), Array(repeating: "This Mac already has version 1.2.0.", count: 4))
    }

    func testADevelopmentBuildOnAClientIsNeverSentAReleaseAndHoldsTheOthersBackWhileItSharesInput() {
        let fleet = Fleet(anchor: release)
        fleet.join("mini", "1.0.0", kind: .development)
        fleet.join("mbp", "1.0.0")
        fleet.begin("1.1.0", origin: .here, urgency: .soon)
        fleet.tick()
        XCTAssertEqual(fleet.events, ["anchor downloads 1.1.0", "mbp downloads 1.1.0"])
        XCTAssertEqual(fleet.failures.first?.1, "mini runs a development build, which doesn't update itself. No Mac was updated.")

        // Once it is out of the picture, the rest move on without it.
        fleet.inSession.remove("mini")
        fleet.begin("1.1.0")
        fleet.tick()
        XCTAssertEqual(fleet.events.suffix(3), ["anchor swaps in 1.1.0", "mbp swaps in 1.1.0 and restarts", "anchor restarts"])
        XCTAssertFalse(fleet.events.contains { $0.hasPrefix("mini") })
    }

    func testADevelopmentBuildBehindAReleaseAnchorIsLeftAlone() {
        let fleet = Fleet(anchor: Build(version: v("1.1.0"), kind: .release))
        fleet.join("mini", "1.0.0", kind: .development, sharing: false)
        fleet.tick()
        fleet.tick(after: UpdateLeader.retryMs)
        XCTAssertEqual(fleet.events, [])
        // And a newer development build does not pull releases anywhere.
        fleet.join("mbp", "9.0.0", kind: .development)
        XCTAssertNil(fleet.leader.target)
    }

    // MARK: When to restart

    func testAnUpdateNobodyAskedForWaitsUntilTheMacsAreLeftAlone() {
        let fleet = Fleet(anchor: release)
        fleet.join("mini", "1.0.0")
        fleet.conditions = RestartConditions(handoffInProgress: false, keysDown: false, buttonsDown: false, msSinceKey: 30000, msSincePointer: 100)
        fleet.begin("1.1.0")
        fleet.tick()
        XCTAssertEqual(fleet.leader.activity, "Waiting to Install Baton 1.1.0…")
        XCTAssertFalse(fleet.events.contains("anchor swaps in 1.1.0"))

        // Someone asks for it by hand: now a pause in typing is enough.
        fleet.begin("1.1.0", origin: .here, urgency: .soon)
        fleet.tick()
        XCTAssertEqual(fleet.events.last, "anchor restarts")
    }

    func testAGoodMoment() {
        let idle = RestartConditions.idle
        XCTAssertTrue(RestartMoment.isGood(idle, urgency: .whenIdle, waitedMs: 0))
        XCTAssertTrue(RestartMoment.isGood(idle, urgency: .soon, waitedMs: 0))

        // Never during a keyboard handoff, however long it has been or however quiet it is.
        var handoff = idle
        handoff.handoffInProgress = true
        XCTAssertFalse(RestartMoment.isGood(handoff, urgency: .soon, waitedMs: 0))
        XCTAssertFalse(RestartMoment.isGood(handoff, urgency: .whenIdle, waitedMs: .max))

        var held = idle
        held.keysDown = true
        XCTAssertFalse(RestartMoment.isGood(held, urgency: .soon, waitedMs: .max))
        held = idle
        held.buttonsDown = true
        XCTAssertFalse(RestartMoment.isGood(held, urgency: .soon, waitedMs: .max))

        // Mouse moving, nothing typed for a few seconds.
        let working = RestartConditions(handoffInProgress: false, keysDown: false, buttonsDown: false, msSinceKey: 5000, msSincePointer: 50)
        XCTAssertTrue(RestartMoment.isGood(working, urgency: .soon, waitedMs: 0))
        XCTAssertFalse(RestartMoment.isGood(working, urgency: .whenIdle, waitedMs: 0))
        XCTAssertFalse(RestartMoment.isGood(working, urgency: .whenIdle, waitedMs: RestartMoment.patienceMs - 1))
        XCTAssertTrue(RestartMoment.isGood(working, urgency: .whenIdle, waitedMs: RestartMoment.patienceMs), "Macs that are never idle are not left behind for ever")

        let typing = RestartConditions(handoffInProgress: false, keysDown: false, buttonsDown: false, msSinceKey: 300, msSincePointer: 90000)
        XCTAssertFalse(RestartMoment.isGood(typing, urgency: .soon, waitedMs: 0))
        XCTAssertFalse(RestartMoment.isGood(typing, urgency: .whenIdle, waitedMs: RestartMoment.patienceMs))

        let away = RestartConditions(handoffInProgress: false, keysDown: false, buttonsDown: false, msSinceKey: 60000, msSincePointer: 60000)
        XCTAssertTrue(RestartMoment.isGood(away, urgency: .whenIdle, waitedMs: 0))
    }

    func testAHandoffHoldsTheWholeFleet() {
        let fleet = Fleet(anchor: release)
        fleet.join("mini", "1.0.0")
        fleet.conditions.handoffInProgress = true
        fleet.begin("1.1.0", origin: .here, urgency: .soon)
        for _ in 0..<600 { fleet.tick() }
        XCTAssertFalse(fleet.events.contains { $0.contains("swaps") })
        XCTAssertTrue(fleet.failures.isEmpty, "waiting for the keyboard is not a failure")
        fleet.conditions.handoffInProgress = false
        fleet.tick()
        XCTAssertEqual(fleet.events.last, "anchor restarts")
    }

    // MARK: The client's side

    func testAClientDownloadsWhatItIsToldToAndInstallsOnlyThat() {
        var follower = UpdateFollower(own: release)
        XCTAssertEqual(follower.received(.install(v("1.1.0"))), [.send(.prepared(v("1.1.0"), ok: false, detail: "The release hasn't been downloaded there."))])
        XCTAssertEqual(follower.received(.prepare(v("1.1.0"))), [.prepare(v("1.1.0"))])
        XCTAssertEqual(follower.received(.prepare(v("1.1.0"))), [], "one download at a time")
        XCTAssertEqual(follower.finishedPreparing(v("1.1.0"), error: nil), [.send(.prepared(v("1.1.0"), ok: true, detail: ""))])
        XCTAssertEqual(follower.received(.prepare(v("1.1.0"))), [.send(.prepared(v("1.1.0"), ok: true, detail: ""))])
        XCTAssertEqual(follower.received(.install(v("1.2.0"))), [.send(.prepared(v("1.2.0"), ok: false, detail: "The release hasn't been downloaded there."))])
        XCTAssertEqual(follower.received(.install(v("1.1.0"))), [.install(v("1.1.0"))])
        XCTAssertEqual(follower.received(.install(v("1.1.0"))), [], "already installing")
        XCTAssertEqual(follower.installFailed(v("1.1.0"), error: "no"), [.send(.prepared(v("1.1.0"), ok: false, detail: "no"))])
        XCTAssertEqual(follower.received(.prepare(v("1.1.0"))), [.prepare(v("1.1.0"))])
    }

    func testAClientRefusesWhatWouldNotBeAnUpdate() {
        var follower = UpdateFollower(own: Build(version: v("1.2.0"), kind: .release))
        XCTAssertEqual(follower.received(.prepare(v("1.2.0"))), [.send(.prepared(v("1.2.0"), ok: false, detail: "It already has version 1.2.0."))])
        XCTAssertEqual(follower.received(.prepare(v("1.1.0"))), [.send(.prepared(v("1.1.0"), ok: false, detail: "It already has version 1.2.0."))])
        XCTAssertEqual(follower.received(.install(v("1.1.0"))), [])

        var development = UpdateFollower(own: Build(version: v("1.0.0"), kind: .development))
        XCTAssertEqual(development.received(.prepare(v("9.0.0"))), [.send(.prepared(v("9.0.0"), ok: false, detail: "It runs a development build, which doesn't update itself."))])
        XCTAssertEqual(development.received(.install(v("9.0.0"))), [])
    }
}
