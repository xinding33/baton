import AppKit
import BatonCore
import XCTest
@testable import Baton

final class MediaKeysTests: XCTestCase {
    func testAReplayedKeyReadsBackAsTheKeyThatWasSent() throws {
        for key in [
            MediaKey(code: MediaKey.soundUp, down: true),
            MediaKey(code: MediaKey.brightnessDown, down: true, autorepeat: true),
            MediaKey(code: MediaKey.play, down: false),
        ] {
            let event = try XCTUnwrap(key.makeEvent())
            XCTAssertEqual(event.type, EventTap.systemDefined)
            XCTAssertEqual(MediaKey(event), key)
            // The mark that keeps Baton's taps from capturing it again stays on it.
            event.setIntegerValueField(.eventSourceUserData, value: Injector.marker)
            XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), Injector.marker)
            XCTAssertEqual(MediaKey(event), key)
        }
    }

    func testOtherSystemEventsAreLeftAlone() throws {
        // Caps Lock comes in the same kind of event, and so do the mouse buttons, as subtype 7.
        XCTAssertNil(MediaKey(try XCTUnwrap(MediaKey(code: 4, down: true).makeEvent())))
        let buttons = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 7, data1: 0x0000_0A00, data2: 1)
        XCTAssertNil(MediaKey(try XCTUnwrap(buttons?.cgEvent)))
        let click = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left))
        XCTAssertNil(MediaKey(click))
    }
}
