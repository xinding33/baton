import AppKit
import BatonCore
import XCTest
@testable import Baton

/// The app's own wiring of the updater: the update link over the real TLS and port, the menu
/// items and the control command. Nothing here downloads or installs anything.
final class UpdatesTests: XCTestCase {
    static let home = FileManager.default.temporaryDirectory.appendingPathComponent("baton-tests-\(UUID().uuidString)")
    private let secret = Data((0..<32).map { _ in UInt8.random(in: 0...255) })

    override func setUp() {
        // Keeps this process's settings and log out of the installed Baton's.
        try? FileManager.default.removeItem(at: UpdatesTests.home)
        try? FileManager.default.createDirectory(at: UpdatesTests.home, withIntermediateDirectories: true)
        setenv("BATON_HOME", UpdatesTests.home.path, 1)
    }

    override class func tearDown() {
        try? FileManager.default.removeItem(at: home)
    }

    /// Long enough for a listener that found its port taken to try again.
    private func wait(_ what: String, timeout: TimeInterval = 25, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out waiting for \(what)") }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func status(_ updates: Updates) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(updates.command([]).utf8))) as? [String: Any] ?? [:]
    }

    /// What can be pressed in the Updates pane: Check for Updates…, then the automatic switch.
    private func controls(_ updates: Updates) -> [SettingsRow] {
        updates.settingsPane.rows.filter { $0.act != nil }
    }

    private func notes(_ updates: Updates) -> [String] {
        updates.settingsPane.rows.filter { $0.kind == .note(warning: true) }.map(\.title)
    }

    /// An anchor and a client on this Mac, each with its own updater and nothing else.
    private func pair(anchor: Build, client: Build) -> (anchor: Updates, client: Updates) {
        var anchorConfig = Config(name: "studio", role: .anchor)
        // Below the range outgoing connections take their ports from, which other tests fill.
        anchorConfig.port = UInt16.random(in: 20000..<40000)
        var clientConfig = Config(name: "mini", role: .client)
        clientConfig.port = anchorConfig.port
        clientConfig.anchorHost = "127.0.0.1"
        let pair = (anchor: Updates(), client: Updates())
        for (updates, config, build) in [(pair.anchor, anchorConfig, anchor), (pair.client, clientConfig, client)] {
            updates.harness = Updates.Harness(together: true)
            updates.start(as: config, secret: secret, anchor: nil, client: nil, build: build)
        }
        return pair
    }

    func testTheAnchorsSwitchCountsForEveryMacAndAClientCanFlipIt() throws {
        let release = Build(version: try XCTUnwrap(Version("1.2.0")), kind: .release)
        let (anchor, client) = pair(anchor: release, client: release)
        var redraws = 0
        client.onStateChanged = { redraws += 1 }
        wait("the update link") { self.status(client)["anchor"] as? String == "studio, Baton 1.2.0" && self.status(client)["automatic"] as? Bool == true }
        XCTAssertGreaterThan(redraws, 0)
        XCTAssertEqual(((status(anchor)["macs"] as? [String: Any])?["mini"] as? [String: Any])?["version"] as? String, "1.2.0")
        XCTAssertEqual(status(anchor)["sharingInput"] as? [String], ["mini"])

        XCTAssertEqual(controls(client).map(\.title), ["Check for Updates…", "Install updates automatically"])
        XCTAssertEqual(controls(anchor).map(\.title), ["Check for Updates…", "Install updates automatically"])
        XCTAssertEqual(controls(client)[1].isOn, true, "on by default")
        XCTAssertNil(client.menuLine, "nothing for the menu to say while every Mac is on one version")
        XCTAssertEqual(client.settingsPane.rows.press("Install updates automatically"), "pressed “Install updates automatically”")
        wait("the anchor's switch") { self.status(anchor)["automatic"] as? Bool == false }
        wait("the client's pane") { self.controls(client)[1].isOn == false }
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: UpdatesTests.home.appendingPathComponent("update.json"))) as? [String: Any]
        XCTAssertEqual(saved?["automatic"] as? Bool, false)

        XCTAssertEqual(anchor.command(["auto", "on"]), "install updates automatically: true")
        wait("the client's pane") { self.controls(client)[1].isOn == true }
        XCTAssertEqual(client.command(["auto", "off"]), "the anchor's switch counts for every Mac; run this there")
        XCTAssertEqual(anchor.command(["install", "1.2.0"]), "This Mac already has version 1.2.0.")
        XCTAssertEqual(client.command(["install", "1.1"]), "This Mac already has version 1.2.0.")
        XCTAssertEqual(anchor.command(["install", "soon"]), "soon is not a version")
    }

    func testMacsOnDifferentVersionsSaySoAndADevelopmentBuildOffersNoUpdates() throws {
        // A development build on the anchor, as after scripts/deploy.sh, and a release behind it.
        let (anchor, client) = pair(anchor: Build(version: try XCTUnwrap(Version("1.3.0")), kind: .development),
                                    client: Build(version: try XCTUnwrap(Version("1.2.0")), kind: .release))
        wait("the update link") { self.status(client)["anchor"] as? String == "studio, Baton 1.3.0 (development build)" }
        // Each menu says which Mac has which version, and so does the pane.
        wait("the anchor's menu") { anchor.menuLine != nil }
        XCTAssertEqual(anchor.menuLine, "mini has Baton 1.2.0, this Mac 1.3.0")
        XCTAssertEqual(client.menuLine, "studio has Baton 1.3.0, this Mac 1.2.0")
        XCTAssertEqual(notes(anchor), ["mini has Baton 1.2.0, this Mac 1.3.0. Macs on different versions cannot share input."])
        XCTAssertEqual(notes(client), ["studio has Baton 1.3.0, this Mac 1.2.0. Macs on different versions cannot share input."])
        for updates in [anchor, client] {
            let toggle = controls(updates)[1]
            XCTAssertEqual(toggle.isOn, false)
            XCTAssertFalse(toggle.enabled, "nothing to switch while the anchor does not update itself")
            XCTAssertTrue(controls(updates)[0].enabled)
        }
        XCTAssertEqual(status(anchor)["updatesItself"] as? String, "This copy was built from source, so it doesn't update itself.")
        XCTAssertEqual(anchor.command(["install", "9.0.0"]), "This Mac runs a development build, which doesn't update itself.")
        XCTAssertEqual(anchor.command(["check"]), "This copy was built from source, so it doesn't update itself.")
        // Nothing was asked of the client: it stays as it is.
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertEqual(status(client)["ready"] as? String, "nothing")
        XCTAssertEqual(status(anchor)["movingTo"] as? String, "nothing")
    }
}
