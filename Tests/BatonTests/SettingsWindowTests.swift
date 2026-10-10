import AppKit
import BatonCore
import XCTest
@testable import Baton

/// The Settings window and what is in it besides the setup form: rows, panes, the toolbar, and
/// the menu that everything moved out of. No window is ever put on screen.
final class SettingsWindowTests: XCTestCase {
    var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("baton-settings-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // Keeps this process's log, and anything that goes by `Paths`, out of the installed Baton's.
        setenv("BATON_HOME", home.path, 1)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
    }

    /// Where the pictures of the panes go: `BATON_SNAPSHOTS`, or nowhere that outlives the test.
    func snapshot(_ pane: SettingsPane, _ name: String) {
        let folder = ProcessInfo.processInfo.environment["BATON_SNAPSHOTS"].map { URL(fileURLWithPath: $0) } ?? home!
        let url = folder.appendingPathComponent("\(name).png")
        pane.refresh()
        XCTAssertTrue(pane.view.writeSnapshot(to: url), "could not render \(name)")
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 5000, "\(name) is not a picture of a pane")
    }

    func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    /// Every control in a view, in the order they are drawn.
    func controls(in view: NSView) -> [NSControl] {
        view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? ($0 as? NSPopUpButton).map { [$0] } ?? controls(in: $0) }
    }

    // MARK: Rows

    func testRowsAreDrawnAndAClickReachesTheNewestClosure() throws {
        var wheel = true
        var strategy = 0
        var presses = 0
        let pane = FormPane(id: "mouse", title: "Mouse", symbol: "computermouse") {
            [
                .header("Mouse wheel"),
                .toggle("Reverse the mouse wheel", on: wheel, detail: "Trackpads are left alone.") { wheel = $0 },
                .toggle("Vertical", on: true, enabled: wheel, indent: 1) { _ in },
                .choice("To move it", options: ["Reconnect", "Forget and pair again"], selected: strategy) { strategy = $0 },
                .button("Check for Updates…") { presses += 1 },
                .note("Needs Accessibility."),
                .text("For this Mac only."),
            ]
        }
        pane.refresh()
        var found = controls(in: pane.view)
        XCTAssertEqual(found.count, 4)
        let box = try XCTUnwrap(found[0] as? NSButton)
        XCTAssertEqual(box.title, "Reverse the mouse wheel")
        XCTAssertEqual(box.state, .on)
        XCTAssertTrue(found[1].isEnabled)
        snapshot(pane, "20-pane-rows")

        // The click is answered after it is over, and the pane is then drawn from what is so.
        box.performClick(nil)
        XCTAssertTrue(wheel, "not in the middle of the click")
        settle()
        XCTAssertFalse(wheel)
        pane.refresh()
        found = controls(in: pane.view)
        XCTAssertEqual((found[0] as? NSButton)?.state, .off)
        XCTAssertFalse(found[1].isEnabled, "the axes are greyed out while reversing is off")

        let popup = try XCTUnwrap(found[2] as? NSPopUpButton)
        popup.selectItem(at: 1)
        _ = popup.sendAction(popup.action, to: popup.target)
        (found[3] as? NSButton)?.performClick(nil)
        settle()
        XCTAssertEqual(strategy, 1)
        XCTAssertEqual(presses, 1)

        // The same rows, as `ctl settings pane` prints them and as `press` and `choose` work them.
        XCTAssertEqual(pane.rows.map(\.line).joined(separator: "\n"), """
            Mouse wheel:
              [ ] Reverse the mouse wheel
                  Trackpads are left alone.
                [x] Vertical  [greyed out]
              To move it: Forget and pair again (of Reconnect, Forget and pair again)
              <Check for Updates…>
              ⚠︎ Needs Accessibility.
              For this Mac only.
            """)
        XCTAssertEqual(pane.rows.press("reverse the mouse wheel"), "pressed “Reverse the mouse wheel”")
        XCTAssertTrue(wheel)
        XCTAssertEqual(pane.rows.choose("reconnect", for: "To move it"), "chose “Reconnect”")
        XCTAssertEqual(strategy, 0)
        XCTAssertEqual(pane.rows.choose("sideways", for: "To move it"), "“To move it” is one of: Reconnect, Forget and pair again")
        XCTAssertNil(pane.rows.press("Mouse wheel"), "a header is not for pressing")
        wheel = false
        XCTAssertEqual(pane.rows.press("Vertical"), "“Vertical” is greyed out")
    }

    func testAClickThatChangesNothingIsUndoneOnScreen() throws {
        // A display that could not be turned off stays ticked, whatever the click made the box show.
        let pane = FormPane(id: "displays", title: "Displays", symbol: "display") { [.toggle("LG UltraFine", on: true) { _ in }] }
        pane.refresh()
        let form = try XCTUnwrap(pane.view as? FormView)
        (controls(in: form)[0] as? NSButton)?.performClick(nil)
        settle()
        pane.refresh()
        XCTAssertEqual((controls(in: form)[0] as? NSButton)?.state, .off, "left alone while Baton may still be at it")
        form.settleNow()
        pane.refresh()
        XCTAssertEqual((controls(in: form)[0] as? NSButton)?.state, .on)
    }

    // MARK: The window

    func testTheWindowHasNoToolbarUntilThereIsMoreThanOnePane() throws {
        var opened = 0
        var presented: [NSWindow] = []
        let general = FormPane(id: "general", title: "General", symbol: "gearshape") { [.header("This Mac")] }
        general.onOpen = { opened += 1 }
        var on = false
        let mouse = FormPane(id: "mouse", title: "Mouse", symbol: "computermouse") {
            [.toggle("Reverse the mouse wheel", on: on) { on = $0 }, .text(on ? "Wheels scroll the traditional way." : "Wheels scroll as trackpads do.\nSecond line.")]
        }
        let controller = SettingsWindowController()
        controller.present = { presented.append($0) }

        controller.setPanes([general])
        controller.show()
        let window = try XCTUnwrap(presented.first)
        XCTAssertNil(window.toolbar)
        XCTAssertEqual(window.title, "Set Up Baton")
        XCTAssertEqual(opened, 1)

        // Baton has started: the same window carries on with all its panes.
        controller.setPanes([general, mouse])
        XCTAssertEqual(window.title, "Baton Settings")
        XCTAssertEqual(window.toolbar?.items.map(\.label), ["General", "Mouse"])
        XCTAssertEqual(window.toolbar?.selectedItemIdentifier?.rawValue, "general")
        XCTAssertTrue(window.contentView === general.view)

        // The menu opens the pane that puts a thing right; the window takes the pane's size and
        // keeps its title bar where it was.
        let top = window.frame.maxY
        controller.show("mouse")
        XCTAssertTrue(window.contentView === mouse.view)
        XCTAssertEqual(window.toolbar?.selectedItemIdentifier?.rawValue, "mouse")
        XCTAssertEqual(window.contentLayoutRect.height, mouse.view.fittingSize.height, accuracy: 1)
        XCTAssertEqual(window.frame.maxY, top, accuracy: 1)
        XCTAssertEqual(presented.count, 2)
        controller.show()
        XCTAssertTrue(window.contentView === mouse.view, "it comes back on the pane it showed last")
        controller.show("nonsense")
        XCTAssertTrue(window.contentView === mouse.view)

        // `ctl settings`: the window's own words, and the rest for the setup form.
        let setup: ([String]) -> String = { "setup: \($0.joined(separator: " "))" }
        XCTAssertEqual(controller.command(["name", "studio"], setup: setup), "setup: name studio")
        XCTAssertEqual(controller.command(["show", "general"], setup: setup), "setup: ")
        XCTAssertTrue(window.contentView === general.view)
        XCTAssertEqual(controller.command(["show", "nonsense"], setup: setup), "the panes are: general, mouse")
        XCTAssertEqual(controller.command(["pane", "mouse"], setup: setup), "  [ ] Reverse the mouse wheel\n  Wheels scroll as trackpads do.\nSecond line.")
        XCTAssertEqual(controller.command(["press", "mouse", "Reverse", "the", "mouse", "wheel"], setup: setup), "pressed “Reverse the mouse wheel”")
        XCTAssertTrue(on)
        XCTAssertEqual(controller.command(["press", "mouse", "Horizontal"], setup: setup), "no “Horizontal” to press; see `settings pane mouse`")
        let picture = home.appendingPathComponent("mouse.png")
        XCTAssertEqual(controller.command(["snapshot", picture.path, "mouse"], setup: setup), "wrote \(picture.path)")

        // A pane that gets taller takes the window with it, downwards.
        controller.show("mouse")
        let before = window.frame
        on = false
        // `refresh` does this for the pane on show, once a second, while the window is on screen.
        mouse.refresh()
        controller.fit()
        XCTAssertGreaterThan(window.frame.height, before.height)
        XCTAssertEqual(window.frame.maxY, before.maxY, accuracy: 1)
        window.close()
    }

    // MARK: The menu

    func testTheMenuIsDrawnFromItsItemsAndAClickSaysWhatWasChosen() throws {
        var facts = StatusMenu.Facts(role: .anchor)
        facts.peers = ["mini"]
        facts.online = ["mini", "studio"]
        facts.sharesKeyboard = true
        facts.keyboardOwner = "studio"
        facts.canWakeAll = true
        facts.wakeHotKey = "⌃⌥⌘W"
        facts.attention = [.init(summary: "mini has no place yet", detail: "Drag it.", pane: StatusMenu.Pane.arrange)]
        var chosen: [String] = []
        let menu = MenuBarMenu.make(StatusMenu.items(facts)) { chosen.append("\($0)") }
        let items = menu.items.filter { !$0.isSeparatorItem }
        XCTAssertEqual(items.map(\.title), [
            "⚠︎ mini has no place yet", "Connected: mini", "Pause Sharing", "Bring Cursor Home (⌃⌥⌘⎋)", "Keyboard: studio", "Wake All Macs (⌃⌥⌘W)",
            "Settings…", "Quit Baton",
        ])
        XCTAssertNil(items[1].action, "a line to read")
        XCTAssertEqual(items[4].submenu?.items.map(\.title), ["Move to", "mini"])

        for item in [items[0], items[2], items[3], items[6]] + (items[4].submenu?.items.suffix(1) ?? []) {
            _ = item.target?.perform(try XCTUnwrap(item.action))
        }
        XCTAssertEqual(chosen.count, 5)
        XCTAssertEqual(chosen[0], "settings(pane: Optional(\"arrange\"))")
        XCTAssertEqual(chosen[1], "setPaused(true)")
        XCTAssertEqual(chosen[2], "home")
        XCTAssertEqual(chosen[3], "settings(pane: nil)")
        XCTAssertEqual(chosen[4], "moveKeyboard(to: \"mini\")")
    }

    // MARK: Every pane

    func testScrollAndWakeRowsChangeTheirSettings() {
        var scroll = ScrollSettings()
        var rows = ScrollReverser.rows(for: scroll, tapActive: false) { $0(&scroll) }
        XCTAssertEqual(rows.filter { $0.act != nil }.map(\.title), ["Reverse the mouse wheel", "Vertical", "Horizontal"])
        XCTAssertTrue(rows.contains { $0.kind == .note(warning: true) }, "says that it needs Accessibility")
        XCTAssertNotNil(rows.press("Horizontal"))
        XCTAssertNotNil(rows.press("Reverse the mouse wheel"))
        XCTAssertEqual(scroll, ScrollSettings(enabled: false, vertical: true, horizontal: false))
        rows = ScrollReverser.rows(for: scroll, tapActive: false) { $0(&scroll) }
        XCTAssertEqual(rows.press("Vertical"), "“Vertical” is greyed out")
        XCTAssertFalse(rows.contains { $0.kind == .note(warning: true) })

        var wake = WakeSettings()
        var logged: [String] = []
        let change: (String, (inout WakeSettings) -> Void) -> Void = { logged.append($0); $1(&wake) }
        rows = WakeTogether.rows(for: wake, holdingAwake: false, onPowerAdapter: false, change: change)
        XCTAssertEqual(rows.filter { $0.act != nil }.map(\.title), [
            "Wake the other Macs when this Mac wakes", "Keep this Mac awake (paused on battery)", "Stay awake while another Mac is in use (paused on battery)", "Only on power adapter",
        ])
        XCTAssertTrue(rows[1].detail?.contains("⌃⌥⌘W") == true)
        for title in ["Wake the other Macs when this Mac wakes", "Keep this Mac awake (paused on battery)", "Stay awake while another Mac is in use (paused on battery)"] {
            XCTAssertNotNil(rows.press(title))
        }
        XCTAssertEqual([wake.wakeOthers, wake.keepAwake, wake.stayAwakeWithOthers, wake.keepAwakeOnlyOnPower], [false, false, false, true])
        XCTAssertEqual(logged.first, "wake the others when this Mac wakes: false")
        rows = WakeTogether.rows(for: wake, holdingAwake: false, onPowerAdapter: true, change: change)
        XCTAssertEqual(rows.press("Only on power adapter"), "“Only on power adapter” is greyed out")
        // Pause Sharing, on the anchor, is said above the switches it overrides.
        XCTAssertFalse(rows.contains { $0.kind == .note(warning: false) })
        rows = WakeTogether.rows(for: wake, holdingAwake: false, onPowerAdapter: true, sharingPaused: true, change: change)
        XCTAssertEqual(rows.first?.kind, .note(warning: false))
        XCTAssertTrue(rows.first?.title.contains("Wake All Macs still works") == true)
    }

    /// The whole window as an anchor has it, a picture for each pane. `BATON_SNAPSHOTS` keeps them.
    func testPicturesOfEveryPaneInTheWindow() throws {
        try Data("""
            { "name": "studio", "role": "anchor", "keyboardAddress": "00-11-22-33-44-55", "keyboardFollows": true,
              "placements": [{ "machine": "mini", "side": "left", "of": "studio", "align": "end" }] }
            """.utf8).write(to: home.appendingPathComponent("config.json"))
        try Data((String(repeating: "5a", count: 32) + "\n").utf8).write(to: home.appendingPathComponent("secret.key"))
        var environment = SetupWindowController.Environment()
        environment.installation = Installation(directory: home)
        environment.login = LoginItem(agent: LaunchAgent(directory: home.appendingPathComponent("LaunchAgents")), executable: "/Applications/Baton.app/Contents/MacOS/Baton")
        environment.accessibility = { true }
        environment.bluetooth = { .allowed }
        environment.askForAccessibility = {}
        environment.askForBluetooth = {}
        environment.open = { _ in }
        environment.copy = { _ in }
        environment.showsMenuIcon = { true }
        environment.showMenuIcon = { _ in }
        environment.searchesNetwork = false
        environment.relaunch = {}
        environment.quit = {}
        let general = SetupWindowController(environment: environment)
        var anchor: Anchor?
        general.whenSetUp { config, secret in
            // Made and never started: no event tap, no listener.
            anchor = Anchor(config: config, secret: secret)
            general.attach(anchor: anchor, client: nil)
        }
        let studio = try XCTUnwrap(anchor)
        let keyboard = KeyboardSettings(anchor: studio)
        keyboard.bluetoothAllowed = { true }
        keyboard.keyboards = [BluetoothKeyboard(address: "00-11-22-33-44-55", name: "Magic Keyboard")]
        let board = NSPasteboard(name: NSPasteboard.Name("baton-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let clipboard = SharedClipboard(config: studio.currentConfig, secret: Data(repeating: 0x5a, count: 32), pasteboard: board, universalClipboard: { false })
        keyboard.clipboardRows = { clipboard.settingsRows() }
        let updates = Updates()
        let displays = DisplayPanel(rows: [
            DisplayRow(uuid: "A", name: "Studio Display", state: .on, staysOn: "The last active screen stays on."),
            DisplayRow(uuid: "B", name: "LG UltraFine", state: .off),
        ])
        let panes: [SettingsPane] = [
            general,
            FormPane(id: StatusMenu.Pane.mouse, title: "Mouse", symbol: "computermouse") { ScrollReverser.rows(for: ScrollSettings(), tapActive: true) { _ in } },
            keyboard.pane,
            FormPane(id: StatusMenu.Pane.displays, title: "Displays", symbol: "display") {
                [.header("This Mac")] + DisplayMenu.rows(for: displays) { _ in }
                    + [.header("mini")] + DisplayMenu.rows(for: DisplayPanel(rows: [DisplayRow(uuid: "C", name: "DELL U2723QE", state: .on)])) { _ in }
            },
            ArrangementPane(anchor: studio),
            FormPane(id: StatusMenu.Pane.wake, title: "Sleep & Wake", symbol: "moon") { WakeTogether.rows(for: WakeSettings(), holdingAwake: true, onPowerAdapter: true) { _, _ in } },
            updates.settingsPane,
        ]

        var presented: NSWindow?
        let controller = SettingsWindowController()
        controller.present = { presented = $0 }
        general.host = controller
        controller.setPanes(panes)
        let folder = ProcessInfo.processInfo.environment["BATON_SNAPSHOTS"].map { URL(fileURLWithPath: $0) } ?? home!
        for (index, pane) in panes.enumerated() {
            controller.show(pane.id)
            let window = try XCTUnwrap(presented)
            XCTAssertTrue(window.contentView === pane.view)
            XCTAssertEqual(window.contentLayoutRect.size.height, pane.view.fittingSize.height, accuracy: 1, "\(pane.id) fills the window")
            XCTAssertEqual(window.frame.width, SetupView.width, accuracy: 1, "\(pane.id) leaves the window as wide as the others")
            XCTAssertNotNil(NSImage(systemSymbolName: pane.symbol, accessibilityDescription: nil), "\(pane.symbol) is a symbol this macOS has")
            // The frame view draws the title bar and the toolbar as well as the pane.
            let frame = try XCTUnwrap(window.contentView?.superview)
            frame.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
            frame.cacheDisplay(in: frame.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("3\(index)-window-\(pane.id).png"))
        }
        XCTAssertEqual(presented?.toolbar?.items.map(\.label), ["General", "Mouse", "Keyboard", "Displays", "Arrange", "Sleep & Wake", "Updates"])
        XCTAssertEqual(keyboard.pane.rows.filter { $0.kind == .header }.map(\.title), ["Shared keyboard", "Moving between Macs", "Shared clipboard"])
        presented?.close()
    }

    // MARK: Displays

    func testDisplaysAreTickedWhileTheyAreOn() {
        var asked: [DisplayAction] = []
        var panel = DisplayPanel(rows: [
            DisplayRow(uuid: "A", name: "LG UltraFine", state: .on),
            DisplayRow(uuid: "B", name: "Built-in mirror", state: .on, staysOn: "The last active screen stays on."),
            DisplayRow(uuid: "C", name: "DELL", state: .off),
            DisplayRow(uuid: "D", name: "Projector", state: .offWhenConnected),
        ])
        var rows = DisplayMenu.rows(for: panel) { asked.append($0) }
        XCTAssertEqual(rows.map(\.title), ["LG UltraFine", "Built-in mirror", "DELL", "Projector", "Reconnect All"])
        XCTAssertEqual(rows.map(\.isOn), [true, true, false, false, nil])
        XCTAssertEqual(rows.map(\.enabled), [true, false, true, true, true])
        XCTAssertEqual(rows[1].detail, "The last active screen stays on.")
        for title in ["LG UltraFine", "DELL", "Projector", "Reconnect All"] { XCTAssertNotNil(rows.press(title)) }
        XCTAssertEqual(asked, [.turnOff("A"), .turnOn("C"), .turnOn("D"), .reconnectAll])

        // Where another app has the displays, they are shown and nothing can be turned off.
        panel = DisplayPanel(rows: [DisplayRow(uuid: "A", name: "LG UltraFine", state: .on)], unavailable: "Wink is running.\nQuit Wink.", lastError: "It did not go off.")
        rows = DisplayMenu.rows(for: panel) { asked.append($0) }
        XCTAssertEqual(rows.map(\.title), ["LG UltraFine", "Wink is running. Quit Wink.", "It did not go off."])
        XCTAssertFalse(rows[0].enabled)
        XCTAssertEqual(DisplayMenu.rows(for: DisplayPanel()) { _ in }.map(\.title), ["No external displays."])
    }

    // MARK: The shared keyboard

    func testTheSharedKeyboardIsChosenInItsPaneAndAppliedByRestarting() throws {
        var config = Config(name: "studio", role: .anchor)
        config.keyboardAddress = "AA-BB-CC-00-11-22"
        // Made and never started: no event tap, no listener.
        let anchor = Anchor(config: config, secret: Data(repeating: 0x5a, count: 32))
        let keyboard = KeyboardSettings(anchor: anchor)
        var relaunches = 0
        var redraws = 0
        keyboard.bluetoothAllowed = { true }
        keyboard.writtenConfig = { [home] in try? loadConfig(from: home!.appendingPathComponent("config.json")) }
        keyboard.relaunch = { relaunches += 1 }
        keyboard.onStateChanged = { redraws += 1 }
        keyboard.keyboards = [BluetoothKeyboard(address: "00:11:22:33:44:55", name: "Magic Keyboard")]

        var rows = keyboard.rows()
        // The one that is shared is offered even while another Mac holds its pairing.
        guard case let .choice(options, selected) = rows[1].kind else { return XCTFail("no choice of keyboard") }
        XCTAssertEqual(options.count, 3)
        XCTAssertEqual(options.prefix(2), ["None", "Magic Keyboard"])
        XCTAssertEqual(selected, 2)
        XCTAssertNil(rows.press("Apply and Restart"), "nothing to apply yet")
        snapshot(keyboard.pane, "21-pane-keyboard")

        XCTAssertEqual(rows.choose("Magic Keyboard", for: "Keyboard"), "chose “Magic Keyboard”")
        XCTAssertEqual(redraws, 1)
        XCTAssertEqual(anchor.currentConfig.keyboardAddress, "AA-BB-CC-00-11-22", "not until it is applied")
        rows = keyboard.rows()
        snapshot(keyboard.pane, "22-pane-keyboard-changed")
        XCTAssertEqual(rows.press("Apply and Restart"), "pressed “Apply and Restart”")
        XCTAssertEqual(relaunches, 1)
        // The anchor's own copy changed, and it wrote the file.
        XCTAssertEqual(anchor.currentConfig.keyboardAddress, "00-11-22-33-44-55")
        XCTAssertEqual(try loadConfig(from: home.appendingPathComponent("config.json")).keyboardAddress, "00-11-22-33-44-55")

        // How it moves is switched there and then, through the anchor, with no restart.
        rows = keyboard.rows()
        XCTAssertEqual(rows.first { $0.title == "Keyboard follows the cursor" }?.isOn, false)
        XCTAssertNotNil(rows.press("Keyboard follows the cursor"))
        XCTAssertEqual(rows.choose("Forget and pair again", for: "To move it"), "chose “Forget and pair again”")
        XCTAssertTrue(anchor.keyboardFollows)
        let written = try loadConfig(from: home.appendingPathComponent("config.json"))
        XCTAssertTrue(written.keyboardFollows)
        XCTAssertEqual(written.handoffStrategy, .repair)
        XCTAssertEqual(relaunches, 1)

        // A file that could not be written is said, and nothing restarts into the old keyboard.
        keyboard.writtenConfig = { nil }
        XCTAssertNotNil(keyboard.rows().choose("None", for: "Keyboard"))
        XCTAssertNotNil(keyboard.rows().press("Apply and Restart"))
        XCTAssertEqual(relaunches, 1)
        XCTAssertTrue(keyboard.rows().contains { $0.kind == .note(warning: true) && $0.title.contains("could not be written") })
    }

    func testWithoutASharedKeyboardThereIsNothingToMove() {
        let anchor = Anchor(config: Config(name: "studio", role: .anchor), secret: Data(repeating: 0x5a, count: 32))
        let keyboard = KeyboardSettings(anchor: anchor)
        keyboard.bluetoothAllowed = { false }
        let rows = keyboard.rows()
        XCTAssertEqual(rows[1].detail, "Allow Bluetooth under General to see the keyboards paired with this Mac.")
        XCTAssertEqual(rows.first { $0.title == "Keyboard follows the cursor" }?.enabled, false)
        XCTAssertEqual(rows.press("Keyboard follows the cursor"), "“Keyboard follows the cursor” is greyed out")
    }
}
