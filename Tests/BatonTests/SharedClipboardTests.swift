import AppKit
import BatonCore
import Network
import XCTest
@testable import Baton

/// The app's own wiring of the shared clipboard: the real TLS parameters and port, its pane of
/// Settings and the control command. The pasteboards are named ones made for the test.
final class SharedClipboardTests: XCTestCase {
    static let home = FileManager.default.temporaryDirectory.appendingPathComponent("baton-tests-\(UUID().uuidString)")

    override class func setUp() {
        // Keeps this process's log out of the installed Baton's.
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("BATON_HOME", home.path, 1)
    }

    override class func tearDown() {
        try? FileManager.default.removeItem(at: home)
    }

    func wait(_ what: String, timeout: TimeInterval = 10, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out waiting for \(what)") }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// What can be pressed in the Clipboard pane: the switch, then a button for each Mac that
    /// should turn Handoff off.
    func controls(_ clipboard: SharedClipboard) -> [SettingsRow] {
        clipboard.settingsPane.rows.filter { $0.act != nil }
    }

    func status(_ clipboard: SharedClipboard) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(clipboard.command([]).utf8))) as? [String: Any] ?? [:]
    }

    func testTheAnchorAndAClientShareAClipboardOverTheRealTransport() {
        XCTAssertEqual(Paths.log.deletingLastPathComponent().path, SharedClipboardTests.home.path)
        var anchorConfig = Config(name: "studio", role: .anchor)
        anchorConfig.port = UInt16.random(in: 40000..<60000)
        var clientConfig = Config(name: "mini", role: .client)
        clientConfig.port = anchorConfig.port
        let secret = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let here = NSPasteboard(name: NSPasteboard.Name("baton-test-\(UUID().uuidString)"))
        let there = NSPasteboard(name: NSPasteboard.Name("baton-test-\(UUID().uuidString)"))
        defer {
            here.releaseGlobally()
            there.releaseGlobally()
        }

        let anchor = SharedClipboard(config: anchorConfig, secret: secret, pasteboard: here, universalClipboard: { false })
        var saved: [Bool] = []
        var redraws = 0
        anchor.onSettingChanged = { saved.append($0) }
        anchor.onStateChanged = { redraws += 1 }
        anchor.start()
        wait("the listener") { self.status(anchor)["port"] as? Int == Int(anchorConfig.port) + 1 }

        let client = SharedClipboard(config: clientConfig, secret: secret, pasteboard: there, universalClipboard: { false })
        client.start()
        XCTAssertFalse(controls(client)[0].enabled, "a client that has not found the anchor cannot switch sharing")
        client.anchorChanged("127.0.0.1")
        wait("the client") { self.status(client)["connected"] as? Bool == true && self.status(client)["enabled"] as? Bool == true }
        XCTAssertEqual(status(anchor)["peers"] as? [String], ["mini"])
        XCTAssertEqual(status(anchor)["pasteAccess"] as? String, "allowed")
        XCTAssertGreaterThan(redraws, 0)

        here.clearContents()
        here.setString("across", forType: .string)
        wait("the text on the client") { there.string(forType: .string) == "across" }
        there.clearContents()
        there.setString("and back", forType: .string)
        wait("the text on the anchor") { here.string(forType: .string) == "and back" }

        // The switch, on both Macs, and switching it from the client's pane.
        XCTAssertEqual(controls(anchor).map(\.title), ["Share the clipboard between your Macs"])
        XCTAssertEqual(controls(client)[0].isOn, true)
        XCTAssertNil(anchor.attention)
        XCTAssertNotNil(client.settingsPane.rows.press("Share the clipboard between your Macs"))
        wait("sharing to switch off") { self.controls(anchor)[0].isOn == false && self.controls(client)[0].isOn == false }
        wait("the setting to be saved") { saved == [false] }
        XCTAssertEqual(anchor.command(["on"]), "sharing the clipboard: on")
        wait("sharing to switch on") { self.controls(client)[0].isOn == true && saved == [false, true] }

        // Pause Sharing on the anchor: both panes say so, and the switch stays as it is.
        XCTAssertFalse(client.settingsPane.rows.contains { $0.kind == .note(warning: false) })
        anchor.setPaused(true)
        wait("the pause on the client") { self.status(client)["paused"] as? Bool == true }
        XCTAssertEqual(status(anchor)["paused"] as? Bool, true)
        XCTAssertEqual(controls(anchor)[0].isOn, true)
        XCTAssertEqual(controls(client)[0].isOn, true)
        XCTAssertTrue(anchor.settingsPane.rows.first { $0.kind == .note(warning: false) }?.title.hasPrefix("Sharing is paused, in Baton’s menu.") == true)
        XCTAssertTrue(client.settingsPane.rows.first { $0.kind == .note(warning: false) }?.title.hasPrefix("Sharing is paused, in the menu of the anchor’s Baton.") == true)
        here.clearContents()
        here.setString("kept here", forType: .string)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(there.string(forType: .string), "and back")
        anchor.setPaused(false)
        wait("the resume on the client") { self.status(client)["paused"] as? Bool == false }
        XCTAssertFalse(anchor.settingsPane.rows.contains { $0.kind == .note(warning: false) })
        XCTAssertEqual(saved, [false, true], "a pause is not the setting")

        // The input link went away: the clipboard's connection goes with it.
        client.anchorChanged(nil)
        wait("the client to leave") { (self.status(anchor)["peers"] as? [String]) == [] }
        XCTAssertEqual(status(client)["connected"] as? Bool, false)
    }

    func testSettingsAskForHandoffToBeTurnedOffAndOpenTheSetting() {
        var anchorConfig = Config(name: "studio", role: .anchor)
        anchorConfig.port = UInt16.random(in: 40000..<60000)
        var clientConfig = Config(name: "mini", role: .client)
        clientConfig.port = anchorConfig.port
        let secret = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let here = NSPasteboard(name: NSPasteboard.Name("baton-test-\(UUID().uuidString)"))
        let there = NSPasteboard(name: NSPasteboard.Name("baton-test-\(UUID().uuidString)"))
        defer {
            here.releaseGlobally()
            there.releaseGlobally()
        }
        var handoffOnTheMini = true
        var openedOnTheAnchor: [URL] = []
        var openedOnTheMini: [URL] = []
        let anchor = SharedClipboard(config: anchorConfig, secret: secret, pasteboard: here, universalClipboard: { true })
        anchor.openSettings = { openedOnTheAnchor.append($0) }
        anchor.start()
        wait("the listener") { self.status(anchor)["port"] as? Int == Int(anchorConfig.port) + 1 }
        let client = SharedClipboard(config: clientConfig, secret: secret, pasteboard: there, universalClipboard: { handoffOnTheMini })
        client.openSettings = { openedOnTheMini.append($0) }
        client.start()
        client.anchorChanged("127.0.0.1")

        let share = "Share the clipboard between your Macs"
        wait("the request in both panes") { self.controls(anchor).count == 2 && self.controls(client).count == 2 }
        XCTAssertEqual(controls(anchor).map(\.title), [share, "Turn Off Handoff on mini…"])
        XCTAssertEqual(controls(client).map(\.title), [share, "Turn Off Handoff on This Mac…"])
        XCTAssertEqual(status(anchor)["turnOffHandoffOn"] as? [String], ["mini"])
        XCTAssertEqual(status(client)["universalClipboardHere"] as? Bool, true)
        let note = anchor.settingsPane.rows.first { $0.kind == .note(warning: true) }
        XCTAssertTrue(note?.title.contains("AirDrop") == true)
        // Each menu points at the pane, in one line.
        XCTAssertEqual(anchor.attention?.pane, StatusMenu.Pane.clipboard)
        XCTAssertEqual(client.attention?.summary, "Universal Clipboard gets in the way")

        // Pressed in the anchor's pane, the setting opens on the mini, where it has to be changed.
        XCTAssertNotNil(anchor.settingsPane.rows.press("Turn Off Handoff on mini…"))
        wait("the setting to open on the mini") { openedOnTheMini == [UniversalClipboard.settingsURL] }
        XCTAssertNotNil(client.settingsPane.rows.press("Turn Off Handoff on This Mac…"))
        wait("the setting to open again") { openedOnTheMini.count == 2 }
        XCTAssertEqual(openedOnTheAnchor, [])

        // Once it is off there, both panes stop asking. The real check runs every five seconds.
        handoffOnTheMini = false
        wait("the request to go") { self.controls(anchor).count == 1 && self.controls(client).count == 1 }
        XCTAssertNil(anchor.attention)
        client.anchorChanged(nil)
    }

    func testAWrongSecretDoesNotGetIn() {
        var anchorConfig = Config(name: "studio", role: .anchor)
        anchorConfig.port = UInt16.random(in: 40000..<60000)
        var clientConfig = Config(name: "mini", role: .client)
        clientConfig.port = anchorConfig.port
        let here = NSPasteboard(name: NSPasteboard.Name("baton-test-\(UUID().uuidString)"))
        let there = NSPasteboard(name: NSPasteboard.Name("baton-test-\(UUID().uuidString)"))
        defer {
            here.releaseGlobally()
            there.releaseGlobally()
        }
        let anchor = SharedClipboard(config: anchorConfig, secret: Data(repeating: 1, count: 32), pasteboard: here)
        anchor.start()
        wait("the listener") { self.status(anchor)["port"] as? Int == Int(anchorConfig.port) + 1 }
        let client = SharedClipboard(config: clientConfig, secret: Data(repeating: 2, count: 32), pasteboard: there)
        client.start()
        client.anchorChanged("127.0.0.1")
        here.clearContents()
        here.setString("private", forType: .string)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertEqual(status(client)["connected"] as? Bool, false)
        XCTAssertEqual(status(anchor)["peers"] as? [String], [])
        XCTAssertNil(there.string(forType: .string))
        client.anchorChanged(nil)
    }

    func testConfigFilesWithoutTheNewFieldsStillLoad() throws {
        let old = try JSONDecoder().decode(Config.self, from: Data(#"{"name":"studio","role":"anchor"}"#.utf8))
        XCTAssertTrue(old.shareClipboard)
        XCTAssertEqual(old.clipboardMaxMB, 32)
        let set = try JSONDecoder().decode(Config.self, from: Data(#"{"name":"studio","role":"anchor","shareClipboard":false,"clipboardMaxMB":8}"#.utf8))
        XCTAssertFalse(set.shareClipboard)
        XCTAssertEqual(set.clipboardMaxMB, 8)
        XCTAssertFalse(try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(set)).shareClipboard)
    }
}
