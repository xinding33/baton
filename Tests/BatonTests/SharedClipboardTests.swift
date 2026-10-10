import AppKit
import BatonCore
import Network
import XCTest
@testable import Baton

/// The app's own wiring of the shared clipboard: the real TLS parameters and port, the menu
/// items and the control command. The pasteboards are named ones made for the test.
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

        let anchor = SharedClipboard(config: anchorConfig, secret: secret, pasteboard: here)
        var saved: [Bool] = []
        var redraws = 0
        anchor.onSettingChanged = { saved.append($0) }
        anchor.onStateChanged = { redraws += 1 }
        anchor.start()
        wait("the listener") { self.status(anchor)["port"] as? Int == Int(anchorConfig.port) + 1 }

        let client = SharedClipboard(config: clientConfig, secret: secret, pasteboard: there)
        client.start()
        XCTAssertNil(client.menuItems()[0].action, "a client that has not found the anchor cannot switch sharing")
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

        // The menu item, on both Macs, and the switch from the client's.
        XCTAssertEqual(anchor.menuItems().map(\.title), ["Share clipboard"])
        XCTAssertEqual(client.menuItems()[0].state, .on)
        let item = client.menuItems()[0]
        _ = item.target?.perform(item.action)
        wait("sharing to switch off") { anchor.menuItems()[0].state == .off && client.menuItems()[0].state == .off }
        wait("the setting to be saved") { saved == [false] }
        XCTAssertEqual(anchor.command(["on"]), "sharing the clipboard: on")
        wait("sharing to switch on") { client.menuItems()[0].state == .on && saved == [false, true] }

        // The input link went away: the clipboard's connection goes with it.
        client.anchorChanged(nil)
        wait("the client to leave") { (self.status(anchor)["peers"] as? [String]) == [] }
        XCTAssertEqual(status(client)["connected"] as? Bool, false)
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
