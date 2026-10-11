import XCTest
@testable import BatonCore

/// Pause Sharing's settings, and the naming and reading of the hotkey that goes with them.
final class SharingPauseTests: XCTestCase {
    let controlOptionCommand = CGEventFlags([.maskControl, .maskAlternate, .maskCommand]).rawValue

    // MARK: Settings

    func testSettingsDefaultWhenFieldsAreMissing() throws {
        let settings = try JSONDecoder().decode(SharingSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings, SharingSettings())
        XCTAssertEqual(settings.hotKey?.display, "⌃⌥⌘P")
        XCTAssertTrue(HotKey.pauseSharing.matches(code: 35, flags: controlOptionCommand))
        XCTAssertFalse(settings.startPaused)
    }

    func testSettingsRoundTripIncludingNoHotKey() throws {
        var settings = SharingSettings()
        settings.startPaused = true
        settings.hotKey = nil
        let data = try JSONEncoder().encode(settings)
        // Written out, or the usual hotkey would be back at the next start.
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""hotKey":null"#))
        XCTAssertEqual(try JSONDecoder().decode(SharingSettings.self, from: data), settings)

        settings.hotKey = HotKey(keyCode: 96, key: "F5", modifiers: [.control, .shift])
        XCTAssertEqual(try JSONDecoder().decode(SharingSettings.self, from: JSONEncoder().encode(settings)), settings)
    }

    func testARestartBatonMadeItselfCountsForMoreThanTheSetting() {
        var settings = SharingSettings()
        XCTAssertFalse(settings.startsPaused(carried: nil))
        XCTAssertTrue(settings.startsPaused(carried: true), "an update does not resume a pause")
        settings.startPaused = true
        XCTAssertTrue(settings.startsPaused(carried: nil))
        XCTAssertFalse(settings.startsPaused(carried: false), "nor does it pause what was being shared")
    }

    // MARK: Which combinations will do

    func testAHotKeyThatBatonAlreadyActsOnIsRefused() {
        let home = HotKey(keyCode: 53, key: "⎋", modifiers: [.control, .option, .command])
        XCTAssertEqual(SharingSettings.problem(with: home, wakeAll: .wakeAll), "⌃⌥⌘⎋ is already Bring Cursor Home.")
        // That one is taken with Shift held too.
        XCTAssertNotNil(SharingSettings.problem(with: HotKey(keyCode: 53, key: "⎋", modifiers: [.control, .option, .shift, .command]), wakeAll: nil))
        XCTAssertNil(SharingSettings.problem(with: HotKey(keyCode: 53, key: "⎋", modifiers: [.control, .command]), wakeAll: nil))

        // Whatever this Mac's Wake All Macs is, and whatever each calls the key.
        let wake = HotKey(keyCode: 13, key: "w", modifiers: [.command, .option, .control])
        XCTAssertEqual(SharingSettings.problem(with: wake, wakeAll: .wakeAll), "⌃⌥⌘w is already Wake All Macs.")
        XCTAssertNil(SharingSettings.problem(with: wake, wakeAll: nil))
        XCTAssertNil(SharingSettings.problem(with: .pauseSharing, wakeAll: .wakeAll))
    }

    func testAHotKeyNeedsARealModifier() {
        XCTAssertNotNil(SharingSettings.problem(with: HotKey(keyCode: 35, key: "P", modifiers: []), wakeAll: nil))
        XCTAssertNotNil(SharingSettings.problem(with: HotKey(keyCode: 35, key: "P", modifiers: [.shift]), wakeAll: nil))
        XCTAssertNil(SharingSettings.problem(with: HotKey(keyCode: 35, key: "P", modifiers: [.option]), wakeAll: nil))
    }

    // MARK: Naming and reading

    func testAKeyIsNamedByWhatItTypesOnTheKeyboardInUse() {
        // On a German keyboard the key next to T types Z.
        XCTAssertEqual(HotKey.name(forKeyCode: 16, types: "z"), "Z")
        XCTAssertEqual(HotKey.name(forKeyCode: 16), "Y")
        XCTAssertEqual(HotKey.name(forKeyCode: 27, types: "-"), "-")
        // What types nothing printable has a name of its own.
        XCTAssertEqual(HotKey.name(forKeyCode: 96, types: "\u{F708}"), "F5")
        XCTAssertEqual(HotKey.name(forKeyCode: 49, types: " "), "Space")
        XCTAssertEqual(HotKey.name(forKeyCode: 123, types: "\u{F702}"), "←")
        XCTAssertEqual(HotKey.name(forKeyCode: 10, types: "\u{F8FF}"), "key 10")
        XCTAssertEqual(HotKey.name(forKeyCode: 200), "key 200")
    }

    func testModifiersAreReadFromAnEventsFlags() {
        XCTAssertEqual(HotKey.modifiers(in: controlOptionCommand | CGEventFlags.maskAlphaShift.rawValue | 0x100), [.control, .option, .command])
        XCTAssertEqual(HotKey.modifiers(in: 0), [])
    }

    func testACombinationIsReadAsItIsWrittenOut() {
        XCTAssertEqual(HotKey.parse("control+option+command+p"), .pauseSharing)
        XCTAssertEqual(HotKey.parse("⌃⌥⌘P"), .pauseSharing)
        XCTAssertEqual(HotKey.parse("Cmd+Ctrl+Alt+P"), .pauseSharing)
        XCTAssertEqual(HotKey.parse("ctrl shift f5"), HotKey(keyCode: 96, key: "F5", modifiers: [.control, .shift]))
        XCTAssertEqual(HotKey.parse("option+f"), HotKey(keyCode: 3, key: "F", modifiers: [.option]))
        XCTAssertEqual(HotKey.parse("⌃⌥space")?.display, "⌃⌥Space")
        XCTAssertEqual(HotKey.parse("command+esc")?.keyCode, 53)
        XCTAssertEqual(HotKey.parse("control+-")?.keyCode, 27)
        XCTAssertEqual(HotKey.parse("p"), HotKey(keyCode: 35, key: "P", modifiers: []))
        for nonsense in ["", "control+", "control+option", "hyper+p", "control+control+p", "control+f99", "control+pp"] {
            XCTAssertNil(HotKey.parse(nonsense), nonsense)
        }
        // Every key that has a name is read back from it.
        for code in UInt16(0)...126 {
            let name = HotKey.name(forKeyCode: code)
            guard !name.hasPrefix("key ") else { continue }
            XCTAssertEqual(HotKey.parse("⌘" + name)?.keyCode, code, name)
        }
    }

    // MARK: The wire

    func testTheHotKeyAndItsPressGoOverTheWire() throws {
        let named = try Wire.encode(.sharingHotKey(.pauseSharing))
        guard case let .sharingHotKey(hotKey) = try Wire.decode(named.dropFirst(4)) else { return XCTFail("not a hotkey") }
        XCTAssertEqual(hotKey, .pauseSharing)
        let none = try Wire.encode(.sharingHotKey(nil))
        guard case let .sharingHotKey(off) = try Wire.decode(none.dropFirst(4)) else { return XCTFail("not a hotkey") }
        XCTAssertNil(off)
        guard case .toggleSharing = try Wire.decode(Wire.encode(.toggleSharing).dropFirst(4)) else { return XCTFail("not a press") }
    }
}
