import XCTest
@testable import BatonCore

final class KeyboardCustodyTests: XCTestCase {
    func testMissingKeyboardIsLeftAloneWhileAMacHoldsItsPairing() {
        var custody = KeyboardCustody()
        custody.attached(to: "studio")
        // Switched off for the night: it will come back to the Studio by itself.
        XCTAssertFalse(custody.shouldClaim(now: 1000, pairedSomewhere: true))
        XCTAssertFalse(custody.shouldClaim(now: 8 * 3_600_000, pairedSomewhere: true))
    }

    func testClaimedSoonAfterTheLastPairingIsLost() {
        var custody = KeyboardCustody()
        custody.attached(to: "studio")
        XCTAssertFalse(custody.shouldClaim(now: 1000, pairedSomewhere: true))
        // The Studio's pairing turned out to be gone, so the keyboard cannot return by itself.
        XCTAssertFalse(custody.shouldClaim(now: 2000, pairedSomewhere: false))
        XCTAssertTrue(custody.shouldClaim(now: 2000 + KeyboardCustody.unknownGrace, pairedSomewhere: false))
    }

    func testClaimedAtOnceWhenItsMacSaysGoodbye() {
        var custody = KeyboardCustody()
        custody.attached(to: "mbp")
        custody.departed("mbp", saidGoodbye: true, now: 1000)
        XCTAssertNil(custody.holder)
        XCTAssertTrue(custody.shouldClaim(now: 1000, pairedSomewhere: false))
    }

    func testAStalePairingElsewhereDoesNotStopTheClaim() {
        var custody = KeyboardCustody()
        custody.attached(to: "mbp")
        custody.departed("mbp", saidGoodbye: true, now: 1000)
        // The mini still lists the keyboard from an earlier turn; the keyboard no longer answers to it.
        XCTAssertTrue(custody.shouldClaim(now: 1000, pairedSomewhere: true))
    }

    func testClaimWaitsForAMacThatVanished() {
        var custody = KeyboardCustody()
        custody.attached(to: "mbp")
        custody.departed("mbp", saidGoodbye: false, now: 1000)
        XCTAssertFalse(custody.shouldClaim(now: 1000 + KeyboardCustody.lostGrace - 1, pairedSomewhere: false))
        XCTAssertTrue(custody.shouldClaim(now: 1000 + KeyboardCustody.lostGrace, pairedSomewhere: false))
    }

    func testAMacThatComesBackWithTheKeyboardKeepsIt() {
        var custody = KeyboardCustody()
        custody.attached(to: "mbp")
        custody.departed("mbp", saidGoodbye: false, now: 1000)
        custody.attached(to: "mbp")
        XCTAssertEqual(custody.holder, "mbp")
        XCTAssertFalse(custody.shouldClaim(now: 60000, pairedSomewhere: true))
    }

    func testAnotherMacLeavingChangesNothing() {
        var custody = KeyboardCustody()
        custody.attached(to: "studio")
        custody.departed("mbp", saidGoodbye: true, now: 1000)
        XCTAssertEqual(custody.holder, "studio")
        XCTAssertFalse(custody.shouldClaim(now: 60000, pairedSomewhere: true))
    }

    func testNeverSeenAndUnpairedKeyboardIsClaimedAfterAShortWait() {
        var custody = KeyboardCustody()
        XCTAssertFalse(custody.shouldClaim(now: 1000, pairedSomewhere: false))
        XCTAssertFalse(custody.shouldClaim(now: 1000 + KeyboardCustody.unknownGrace - 1, pairedSomewhere: false))
        XCTAssertTrue(custody.shouldClaim(now: 1000 + KeyboardCustody.unknownGrace, pairedSomewhere: false))
    }

    func testFailedClaimsBackOffAndResetOnceAttached() {
        var custody = KeyboardCustody()
        XCTAssertEqual((0..<6).map { _ in custody.claimFailed() }, [60000, 120_000, 240_000, 480_000, 600_000, 600_000])
        custody.attached(to: "studio")
        XCTAssertEqual(custody.claimFailed(), 60000)
    }

    func testNewMessagesSurviveTheWire() throws {
        for message in [Message.sleeping, .keyboardPaired(false), .localInput(Motion(x: 12, y: 34, seq: 0))] {
            let frame = try Wire.encode(message)
            let decoded = try Wire.decode(frame.dropFirst(4))
            switch (message, decoded) {
            case (.sleeping, .sleeping):
                break
            case let (.keyboardPaired(sent), .keyboardPaired(received)):
                XCTAssertEqual(sent, received)
            case let (.localInput(sent), .localInput(received)):
                XCTAssertEqual(sent.x, received.x)
                XCTAssertEqual(sent.y, received.y)
            default:
                XCTFail("\(message) came back as \(decoded)")
            }
        }
    }
}
