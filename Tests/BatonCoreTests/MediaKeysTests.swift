import XCTest
@testable import BatonCore

final class MediaKeysTests: XCTestCase {
    func testAPressAndAReleaseAreReadFromTheEventsNumber() {
        // Volume up going down, as a keyboard sends it.
        let press = MediaKey(data1: 0x0000_0A00, flags: 0x100)
        XCTAssertEqual(press, MediaKey(code: MediaKey.soundUp, down: true, flags: 0x100))
        // Play coming up, and a held brightness key repeating.
        XCTAssertEqual(MediaKey(data1: 0x0010_0B00, flags: 0), MediaKey(code: MediaKey.play, down: false))
        XCTAssertEqual(MediaKey(data1: 0x0003_0A01, flags: 0), MediaKey(code: MediaKey.brightnessDown, down: true, autorepeat: true))
        // Anything else in the same kind of event is not a key.
        XCTAssertNil(MediaKey(data1: 0x0010_0000, flags: 0))
    }

    func testTheNumberIsWrittenTheWayItIsRead() {
        for code in MediaKey.shared.sorted() {
            for (down, autorepeat) in [(true, false), (true, true), (false, false)] {
                let key = MediaKey(code: code, down: down, autorepeat: autorepeat, flags: 0x20100)
                XCTAssertEqual(MediaKey(data1: key.data1, flags: key.flags), key)
            }
        }
        XCTAssertEqual(MediaKey(code: MediaKey.mute, down: true).data1, 0x0007_0A00)
    }

    func testOnlyKeysThatActOnAMacAreShared() {
        for code in [MediaKey.soundUp, MediaKey.soundDown, MediaKey.mute, MediaKey.brightnessUp, MediaKey.brightnessDown, MediaKey.play, MediaKey.next, MediaKey.previous] {
            XCTAssertTrue(MediaKey(code: code, down: true).isShared, "\(code)")
        }
        // Caps Lock, the power key, Eject and the keyboard's backlight belong to the keyboard's Mac.
        for code in [4, 6, 14, 21, 22, 23] {
            XCTAssertFalse(MediaKey(code: code, down: true).isShared, "\(code)")
        }
    }

    func testAKeyIsReleasedWhereItWasPressed() {
        var capture = MediaKeyCapture()
        let down = MediaKey(code: MediaKey.soundUp, down: true)
        let up = MediaKey(code: MediaKey.soundUp, down: false)
        XCTAssertTrue(capture.forwards(down, forwarding: true))
        XCTAssertTrue(capture.forwards(up, forwarding: true))
        XCTAssertFalse(capture.forwards(down, forwarding: false))
        XCTAssertFalse(capture.forwards(up, forwarding: false))

        // Pressed here, then the cursor left: the release stays here, and the next press travels.
        XCTAssertFalse(capture.forwards(down, forwarding: false))
        XCTAssertFalse(capture.forwards(up, forwarding: true))
        XCTAssertTrue(capture.forwards(down, forwarding: true))
        // Another key held here does not hold this one back.
        XCTAssertFalse(capture.forwards(MediaKey(code: MediaKey.mute, down: true), forwarding: false))
        XCTAssertTrue(capture.forwards(up, forwarding: true))
    }

    func testItTravelsAsAMessage() throws {
        let key = MediaKey(code: MediaKey.next, down: true, autorepeat: false, flags: 0x100)
        let frame = try Wire.encode(.mediaKey(key))
        guard case let .mediaKey(read) = try JSONDecoder().decode(Message.self, from: frame.dropFirst(4)) else { return XCTFail("not a media key") }
        XCTAssertEqual(read, key)
    }
}
