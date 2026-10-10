import Foundation
import XCTest
@testable import BatonCore

/// The update link is how a Mac on an old version learns which one to fetch, so what it carries
/// may never stop being readable. If a test here has to change, a Mac that slept through an
/// update can no longer catch up.
final class UpdateLinkTests: XCTestCase {
    private func version(_ string: String) -> Version { Version(string)! }

    private func body(_ message: UpdateMessage) -> Data {
        message.frame().dropFirst(4)
    }

    /// Frames exactly as the first release wrote them. Every later version must read them the same.
    func testTheFirstReleasesFramesStillRead() {
        let frames: [(String, UpdateMessage)] = [
            (#"{"build":"release","name":"mbp","type":"hello","version":"0.1.0"}"#, .hello(name: "mbp", version: version("0.1.0"), kind: .release)),
            (#"{"build":"development","name":"studio","type":"hello","version":"0.1.0"}"#, .hello(name: "studio", version: version("0.1.0"), kind: .development)),
            (#"{"type":"prepare","version":"0.2.0"}"#, .prepare(version("0.2.0"))),
            (#"{"detail":"","ok":true,"type":"prepared","version":"0.2.0"}"#, .prepared(version("0.2.0"), ok: true, detail: "")),
            (#"{"detail":"offline","ok":false,"type":"prepared","version":"0.2.0"}"#, .prepared(version("0.2.0"), ok: false, detail: "offline")),
            (#"{"type":"install","version":"0.2.0"}"#, .install(version("0.2.0"))),
        ]
        for (json, message) in frames {
            XCTAssertEqual(UpdateMessage(body: Data(json.utf8)), message, json)
            XCTAssertEqual(String(decoding: body(message), as: UTF8.self), json, "what this version writes must not drift either")
        }
    }

    func testAFrameIsItsLengthThenItsBody() {
        let frame = UpdateMessage.install(version("1.2.3")).frame()
        XCTAssertEqual(UpdateMessage.length(ofHeader: frame.prefix(4)), frame.count - 4)
        XCTAssertEqual(Array(frame.prefix(4)), [0, 0, 0, UInt8(frame.count - 4)])
        XCTAssertNil(UpdateMessage.length(ofHeader: Data([0, 1, 0, 1])), "longer than any update message")
        XCTAssertNil(UpdateMessage.length(ofHeader: Data([0, 0, 1])))
    }

    func testEveryMessageSurvivesTheTrip() {
        let messages: [UpdateMessage] = [
            .hello(name: "mini", version: version("1.10.0"), kind: .release),
            .prepare(version("2.0")), .prepared(version("2.0"), ok: false, detail: "GitHub responded with HTTP status 404."),
            .install(version("2.0")), .state(automatic: true, activity: "Downloading Baton 2.0…"), .state(automatic: false, activity: nil),
            .lead(version("2.0")), .result(ok: false, detail: "No Mac was updated."), .setAutomatic(false),
        ]
        for message in messages {
            XCTAssertEqual(UpdateMessage(body: body(message)), message)
        }
    }

    func testALaterVersionsAdditionsAreSkippedNotFatal() {
        // Keys this version has never heard of.
        let hello = #"{"type":"hello","name":"mbp","version":"3.0.0","build":"release","protocol":9,"arch":["arm64"]}"#
        XCTAssertEqual(UpdateMessage(body: Data(hello.utf8)), .hello(name: "mbp", version: version("3.0.0"), kind: .release))
        // A kind of build it has never heard of is not one to send releases to.
        let beta = #"{"type":"hello","name":"mbp","version":"3.0.0","build":"beta"}"#
        XCTAssertEqual(UpdateMessage(body: Data(beta.utf8)), .hello(name: "mbp", version: version("3.0.0"), kind: .development))
        // Types it has never heard of, and things that are not messages at all.
        XCTAssertNil(UpdateMessage(body: Data(#"{"type":"rollback","version":"3.0.0"}"#.utf8)))
        XCTAssertNil(UpdateMessage(body: Data(#"{"type":"prepare"}"#.utf8)))
        XCTAssertNil(UpdateMessage(body: Data(#"{"type":"prepare","version":"3.0.0-beta"}"#.utf8)))
        XCTAssertNil(UpdateMessage(body: Data(#"["hello"]"#.utf8)))
        XCTAssertNil(UpdateMessage(body: Data("not json".utf8)))
        XCTAssertNil(UpdateMessage(body: Data()))
    }
}
