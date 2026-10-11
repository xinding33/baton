import AppKit
import BatonCore
import XCTest
@testable import Baton

/// Pause Sharing's hotkey and how Baton starts, as the app has them: the Sharing pane, the event
/// tap's question about each key, and what is kept across a restart. The anchors are made and
/// never started, so there is no event tap and no listener, and the key events are made and
/// never posted.
final class SharingPauseTests: XCTestCase {
    var home: URL!
    let controlOptionCommand: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
    let shortcut = "Pause or resume sharing"

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("baton-sharing-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // Keeps `sharing.json` and the log out of the installed Baton's folder.
        setenv("BATON_HOME", home.path, 1)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
    }

    func makeAnchor() -> Anchor {
        Anchor(config: Config(name: "studio", role: .anchor), secret: Data(repeating: 0x5a, count: 32))
    }

    /// Pause Sharing on an anchor, started the way the app starts it.
    func started(on anchor: Anchor) -> SharingPause {
        let sharing = SharingPause()
        sharing.wakeAllHotKey = { .wakeAll }
        sharing.start(anchor: anchor)
        return sharing
    }

    func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    /// A key going down or up as an event tap would see it.
    func key(_ code: CGKeyCode, down: Bool = true, _ flags: CGEventFlags) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down))
        event.flags = flags
        return event
    }

    func options(_ rows: [SettingsRow], _ title: String) -> [String] {
        guard case let .choice(options, _)? = rows.first(where: { $0.title == title })?.kind else { return [] }
        return options
    }

    var savedSettings: SharingSettings? {
        (try? Data(contentsOf: home.appendingPathComponent("sharing.json"))).flatMap { try? JSONDecoder().decode(SharingSettings.self, from: $0) }
    }

    // MARK: The pane

    func testTheShortcutIsRemovedAndRecordedInItsPane() throws {
        let sharing = started(on: makeAnchor())
        var redraws = 0
        sharing.onStateChanged = { redraws += 1 }
        XCTAssertEqual(sharing.rows().filter { $0.kind == .header }.map(\.title), ["Shortcut", "Starting"])
        XCTAssertEqual(options(sharing.rows(), shortcut), ["⌃⌥⌘P", "None", "Record a New Shortcut…"])
        XCTAssertNil(savedSettings, "nothing is written until something is changed")

        XCTAssertEqual(sharing.rows().choose("None", for: shortcut), "chose “None”")
        XCTAssertNil(sharing.hotKey)
        XCTAssertEqual(savedSettings?.hotKey, .some(nil))
        XCTAssertEqual(options(sharing.rows(), shortcut), ["None", "Record a New Shortcut…"])
        XCTAssertEqual(redraws, 1)

        // Recording: the pane waits for keys, and says what is wrong with the ones it cannot take.
        XCTAssertNotNil(sharing.rows().choose("Record a New Shortcut…", for: shortcut))
        XCTAssertTrue(sharing.recording)
        XCTAssertEqual(options(sharing.rows(), shortcut), ["Press the new shortcut…", "Cancel"])
        XCTAssertTrue(sharing.typed(code: 35, flags: 0, types: "p"))
        XCTAssertTrue(sharing.rows().contains { $0.kind == .note(warning: true) && $0.title.contains("at least one of ⌃, ⌥ and ⌘") })
        XCTAssertTrue(sharing.typed(code: 13, flags: controlOptionCommand.rawValue, types: "w"))
        XCTAssertTrue(sharing.rows().contains { $0.title == "⌃⌥⌘W is already Wake All Macs." })
        XCTAssertTrue(sharing.recording)
        try snapshot(sharing, "24-pane-sharing-recording")

        // The key is named by what it types on the keyboard in use.
        XCTAssertTrue(sharing.typed(code: 40, flags: CGEventFlags([.maskControl, .maskAlternate]).rawValue, types: "k"))
        XCTAssertFalse(sharing.recording)
        XCTAssertEqual(sharing.hotKey, HotKey(keyCode: 40, key: "K", modifiers: [.control, .option]))
        XCTAssertEqual(savedSettings?.hotKey, sharing.hotKey)
        XCTAssertEqual(options(sharing.rows(), shortcut), ["⌃⌥K", "None", "Record a New Shortcut…"])
        XCTAssertFalse(sharing.rows().contains { $0.kind == .note(warning: true) })
        XCTAssertFalse(sharing.typed(code: 35, flags: controlOptionCommand.rawValue, types: "p"), "nothing is being recorded any more")

        // Esc, Cancel and closing the window all leave the shortcut as it was.
        for cancel in [{ _ = sharing.typed(code: 53, flags: 0, types: "\u{1B}") }, { _ = sharing.rows().choose("Cancel", for: self.shortcut) }, { sharing.settingsPane.windowDidClose() }] {
            XCTAssertNotNil(sharing.rows().choose("Record a New Shortcut…", for: shortcut))
            XCTAssertTrue(sharing.recording)
            XCTAssertNil(sharing.offered, "no Mac acts on the old shortcut while a new one is typed")
            cancel()
            XCTAssertFalse(sharing.recording)
            XCTAssertEqual(sharing.offered?.display, "⌃⌥K")
        }
        try snapshot(sharing, "25-pane-sharing")

        // It is there again the next time Baton starts.
        XCTAssertEqual(started(on: makeAnchor()).hotKey?.display, "⌃⌥K")
    }

    /// The keys get to a recording the way they come from a keyboard: as events the
    /// application hands to the Settings window.
    func testAKeyTypedInThePaneIsTheNewShortcutAndOneTypedElsewhereIsNot() throws {
        func window(showing view: NSView) -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            return window
        }
        func type(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags, in window: NSWindow) throws {
            NSApplication.shared.sendEvent(try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
            )))
        }
        let anchor = makeAnchor()
        let sharing = started(on: anchor)
        let settings = window(showing: sharing.settingsPane.view)
        let other = window(showing: NSView())
        defer {
            settings.close()
            other.close()
        }

        XCTAssertNotNil(sharing.rows().choose("Record a New Shortcut…", for: shortcut))
        try type(40, "k", [.control, .option], in: settings)
        XCTAssertFalse(sharing.recording)
        XCTAssertEqual(sharing.hotKey?.keyCode, 40)
        XCTAssertEqual(sharing.hotKey?.modifiers, [.control, .option])

        // Typing in another window was not meant for the pane, and ends the recording.
        XCTAssertNotNil(sharing.rows().choose("Record a New Shortcut…", for: shortcut))
        try type(38, "j", [.control, .option], in: other)
        XCTAssertFalse(sharing.recording)
        XCTAssertEqual(sharing.hotKey?.keyCode, 40)
        // And with nothing being recorded, the pane's window takes no key for itself.
        try type(38, "j", [.control, .option], in: settings)
        XCTAssertEqual(sharing.hotKey?.keyCode, 40)
    }

    func snapshot(_ sharing: SharingPause, _ name: String) throws {
        let folder = ProcessInfo.processInfo.environment["BATON_SNAPSHOTS"].map { URL(fileURLWithPath: $0) } ?? home!
        sharing.settingsPane.refresh()
        XCTAssertTrue(sharing.settingsPane.view.writeSnapshot(to: folder.appendingPathComponent("\(name).png")), "could not render \(name)")
    }

    // MARK: The hotkey

    func testTheHotKeyPausesAndResumesAndIsSwallowedWhole() throws {
        let anchor = makeAnchor()
        let sharing = started(on: anchor)
        var switched: [Bool] = []
        anchor.onPausedChanged = { switched.append($0) }

        XCTAssertFalse(sharing.consumes(.keyDown, try key(35, [])), "ordinary typing passes")
        XCTAssertFalse(sharing.consumes(.keyDown, try key(35, [.maskControl, .maskAlternate, .maskCommand, .maskShift])))
        XCTAssertFalse(sharing.consumes(.flagsChanged, try key(55, controlOptionCommand)))
        XCTAssertTrue(sharing.consumes(.keyDown, try key(35, controlOptionCommand)))
        XCTAssertFalse(anchor.paused, "not inside the tap's callback")
        settle()
        XCTAssertTrue(anchor.paused)
        // Its release goes no further either, even with the modifiers already let go.
        XCTAssertTrue(sharing.consumes(.keyUp, try key(35, down: false, [])))
        XCTAssertFalse(sharing.consumes(.keyUp, try key(35, down: false, [])))

        XCTAssertTrue(sharing.consumes(.keyDown, try key(35, controlOptionCommand)))
        XCTAssertTrue(sharing.consumes(.keyUp, try key(35, down: false, controlOptionCommand)))
        settle()
        XCTAssertFalse(anchor.paused)
        // Pressed at a client, which asks the anchor.
        sharing.pressed(on: "mini")
        XCTAssertTrue(anchor.paused)
        XCTAssertEqual(switched, [true, false, true])

        // While a new one is being recorded the keys belong to the window, apart from what
        // Baton would act on before the window ever saw it.
        XCTAssertNotNil(sharing.rows().choose("Record a New Shortcut…", for: shortcut))
        XCTAssertFalse(sharing.consumes(.keyDown, try key(35, controlOptionCommand)))
        sharing.pressed(on: "mini")
        XCTAssertTrue(sharing.consumes(.keyDown, try key(13, controlOptionCommand)))
        XCTAssertTrue(sharing.consumes(.keyDown, try key(53, controlOptionCommand)))
        settle()
        XCTAssertEqual(switched, [true, false, true])
        XCTAssertTrue(sharing.rows().contains { $0.title == "⌃⌥⌘⎋ is already Bring Cursor Home." })
        XCTAssertTrue(sharing.recording)
    }

    func testWithoutAHotKeyNothingIsSwallowed() throws {
        let anchor = makeAnchor()
        let sharing = started(on: anchor)
        XCTAssertNotNil(sharing.rows().choose("None", for: shortcut))
        XCTAssertFalse(sharing.consumes(.keyDown, try key(35, controlOptionCommand)))
        settle()
        XCTAssertFalse(anchor.paused)
        // Nor on a Mac where Pause Sharing has not started.
        XCTAssertFalse(SharingPause().consumes(.keyDown, try key(35, controlOptionCommand)))
    }

    func testAClientListensForTheHotKeyTheAnchorNamesAndAsksTheAnchor() throws {
        let client = SharingPause()
        var asked = 0
        XCTAssertFalse(client.consumes(.keyDown, try key(40, [.maskControl, .maskAlternate])))
        client.follow(HotKey(keyCode: 40, key: "K", modifiers: [.control, .option])) { asked += 1 }
        XCTAssertFalse(client.consumes(.keyDown, try key(35, controlOptionCommand)))
        XCTAssertTrue(client.consumes(.keyDown, try key(40, [.maskControl, .maskAlternate])))
        XCTAssertTrue(client.consumes(.keyUp, try key(40, down: false, [.maskControl, .maskAlternate])))
        settle()
        XCTAssertEqual(asked, 1)
        XCTAssertTrue(client.command([]).contains("⌃⌥K"))
        XCTAssertEqual(client.command(["start", "paused"]), "only the anchor has these settings")

        // The link is gone: the keys are this Mac's own again.
        client.follow(nil)
        XCTAssertFalse(client.consumes(.keyDown, try key(40, [.maskControl, .maskAlternate])))
        settle()
        XCTAssertEqual(asked, 1)

        // An anchor is not told its hotkey by anyone.
        let anchor = makeAnchor()
        let sharing = started(on: anchor)
        sharing.follow(nil)
        XCTAssertEqual(sharing.hotKey, .pauseSharing)
    }

    // MARK: Starting

    func testBatonStartsPausedWhenItIsSetTo() throws {
        var anchor = makeAnchor()
        var sharing = started(on: anchor)
        XCTAssertFalse(anchor.paused)
        guard case let .choice(starts, selected)? = sharing.rows().first(where: { $0.title == "When Baton starts" })?.kind else { return XCTFail("no choice of how to start") }
        XCTAssertEqual(starts, ["Start sharing", "Stay paused"])
        XCTAssertEqual(selected, 0)
        XCTAssertEqual(sharing.rows().choose("Stay paused", for: "When Baton starts"), "chose “Stay paused”")
        XCTAssertFalse(anchor.paused, "it is about the next start, not about now")
        XCTAssertEqual(savedSettings?.startPaused, true)
        XCTAssertEqual(savedSettings?.hotKey, .pauseSharing)

        // What pauses along with the cursor is told, as when the menu pauses.
        anchor = makeAnchor()
        var told: [Bool] = []
        anchor.onPausedChanged = { told.append($0) }
        sharing = started(on: anchor)
        XCTAssertTrue(anchor.paused)
        XCTAssertEqual(told, [true])
        guard case .choice(_, 1)? = sharing.rows().first(where: { $0.title == "When Baton starts" })?.kind else { return XCTFail("the pane does not show the setting") }

        XCTAssertNotNil(sharing.rows().choose("Start sharing", for: "When Baton starts"))
        anchor = makeAnchor()
        _ = started(on: anchor)
        XCTAssertFalse(anchor.paused)
    }

    func testARestartBatonMakesItselfLeavesSharingAsItWas() throws {
        let restartFile = home.appendingPathComponent("sharing-restart.json")
        var anchor = makeAnchor()
        var sharing = started(on: anchor)

        // Paused by hand, then an update restarts Baton: still paused, though it starts sharing.
        anchor.setPaused(true)
        sharing.willRestart()
        anchor = makeAnchor()
        sharing = started(on: anchor)
        XCTAssertTrue(anchor.paused)
        XCTAssertFalse(FileManager.default.fileExists(atPath: restartFile.path), "it counts for one start")
        anchor = makeAnchor()
        sharing = started(on: anchor)
        XCTAssertFalse(anchor.paused, "the next start goes by the setting again")

        // Set to start paused and resumed by hand, then an update: still sharing.
        XCTAssertTrue(sharing.command(["start", "paused"]).contains(#""startPaused" : true"#))
        sharing.willRestart()
        anchor = makeAnchor()
        sharing = started(on: anchor)
        XCTAssertFalse(anchor.paused)

        // Baton that was stopped and is opened again much later is starting, not carrying on.
        sharing.willRestart()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * SharingPause.restartWindow)], ofItemAtPath: restartFile.path)
        anchor = makeAnchor()
        sharing = started(on: anchor)
        XCTAssertTrue(anchor.paused)
        XCTAssertFalse(FileManager.default.fileExists(atPath: restartFile.path))

        // A client has no pause to carry over.
        SharingPause().willRestart()
        XCTAssertFalse(FileManager.default.fileExists(atPath: restartFile.path))
    }

    // MARK: ctl sharing

    func testTheSettingsAreChangedFromTheCommandLine() throws {
        let anchor = makeAnchor()
        let sharing = started(on: anchor)
        XCTAssertTrue(sharing.command([]).contains(#""hotKey" : "⌃⌥⌘P""#))
        XCTAssertTrue(sharing.command(["hotkey", "control", "option", "f5"]).contains(#""hotKey" : "⌃⌥F5""#))
        XCTAssertEqual(savedSettings?.hotKey, HotKey(keyCode: 96, key: "F5", modifiers: [.control, .option]))
        XCTAssertEqual(sharing.command(["hotkey", "control+option+command+w"]), "⌃⌥⌘W is already Wake All Macs.")
        XCTAssertTrue(sharing.command(["hotkey", "p"]).contains("at least one of"))
        XCTAssertTrue(sharing.command(["hotkey", "hyper+p"]).hasPrefix("cannot read “hyper+p”"))
        XCTAssertEqual(sharing.hotKey?.display, "⌃⌥F5")
        XCTAssertTrue(sharing.command(["hotkey", "none"]).contains(#""hotKey" : "none""#))
        XCTAssertEqual(savedSettings?.hotKey, .some(nil))
        XCTAssertTrue(sharing.command(["start", "paused"]).contains(#""startPaused" : true"#))
        XCTAssertTrue(sharing.command(["start", "sharing"]).contains(#""startPaused" : false"#))
        XCTAssertTrue(sharing.command(["start", "later"]).hasPrefix("usage: sharing"))
        anchor.setPaused(true)
        XCTAssertTrue(sharing.command([]).contains(#""paused" : true"#))
    }
}
