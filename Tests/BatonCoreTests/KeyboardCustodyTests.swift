import XCTest
@testable import BatonCore

final class KeyboardCustodyTests: XCTestCase {
    private let everyone: Set<String> = ["studio", "mini", "mbp"]

    func testMissingKeyboardIsLeftAloneWhileItsMacIsConnected() {
        var custody = KeyboardCustody()
        custody.attached(to: "studio")
        // Switched off for the night: it will come back to the Studio by itself.
        XCTAssertFalse(custody.shouldClaim(now: 1000, online: everyone))
        XCTAssertFalse(custody.shouldClaim(now: 8 * 3_600_000, online: everyone))
    }

    func testClaimedAtOnceWhenItsMacSaysGoodbye() {
        var custody = KeyboardCustody()
        custody.attached(to: "mbp")
        custody.departed("mbp", saidGoodbye: true, now: 1000)
        XCTAssertNil(custody.holder)
        XCTAssertTrue(custody.shouldClaim(now: 1000, online: ["studio", "mini"]))
    }

    func testClaimWaitsForAMacThatVanished() {
        var custody = KeyboardCustody()
        custody.attached(to: "mbp")
        custody.departed("mbp", saidGoodbye: false, now: 1000)
        XCTAssertFalse(custody.shouldClaim(now: 1000 + KeyboardCustody.lostGrace - 1, online: ["studio", "mini"]))
        XCTAssertTrue(custody.shouldClaim(now: 1000 + KeyboardCustody.lostGrace, online: ["studio", "mini"]))
    }

    func testAMacThatComesBackWithTheKeyboardKeepsIt() {
        var custody = KeyboardCustody()
        custody.attached(to: "mbp")
        custody.departed("mbp", saidGoodbye: false, now: 1000)
        custody.attached(to: "mbp")
        XCTAssertEqual(custody.holder, "mbp")
        XCTAssertFalse(custody.shouldClaim(now: 60000, online: everyone))
    }

    func testAnotherMacLeavingChangesNothing() {
        var custody = KeyboardCustody()
        custody.attached(to: "studio")
        custody.departed("mbp", saidGoodbye: true, now: 1000)
        XCTAssertEqual(custody.holder, "studio")
        XCTAssertFalse(custody.shouldClaim(now: 60000, online: ["studio", "mini"]))
    }

    func testNeverSeenKeyboardIsClaimedAfterAShortWait() {
        var custody = KeyboardCustody()
        XCTAssertFalse(custody.shouldClaim(now: 1000, online: everyone))
        XCTAssertFalse(custody.shouldClaim(now: 1000 + KeyboardCustody.unknownGrace - 1, online: everyone))
        XCTAssertTrue(custody.shouldClaim(now: 1000 + KeyboardCustody.unknownGrace, online: everyone))
    }

    func testFailedHandoffLeavesTheKeyboardToBeClaimed() {
        var custody = KeyboardCustody()
        custody.attached(to: "studio")
        custody.handoffStarted()
        // The Studio forgot it and nobody managed to pair: no Mac holds it any more.
        XCTAssertFalse(custody.shouldClaim(now: 1000, online: everyone))
        XCTAssertTrue(custody.shouldClaim(now: 1000 + KeyboardCustody.unknownGrace, online: everyone))
    }

    func testFailedClaimsBackOffAndResetOnceAttached() {
        var custody = KeyboardCustody()
        XCTAssertEqual((0..<6).map { _ in custody.claimFailed() }, [60000, 120_000, 240_000, 480_000, 600_000, 600_000])
        custody.attached(to: "studio")
        XCTAssertEqual(custody.claimFailed(), 60000)
    }

    func testNewMessagesSurviveTheWire() throws {
        for message in [Message.sleeping, .localInput(Motion(x: 12, y: 34, seq: 0))] {
            let frame = try Wire.encode(message)
            let decoded = try Wire.decode(frame.dropFirst(4))
            switch (message, decoded) {
            case (.sleeping, .sleeping):
                break
            case let (.localInput(sent), .localInput(received)):
                XCTAssertEqual(sent.x, received.x)
                XCTAssertEqual(sent.y, received.y)
            default:
                XCTFail("\(message) came back as \(decoded)")
            }
        }
    }
}
