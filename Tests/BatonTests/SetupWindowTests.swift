import AppKit
import BatonCore
import XCTest
@testable import Baton

/// The setup and settings window, driven the way `ctl settings` drives it. Everything it would
/// read from or change on the Mac is replaced: its files and launch agent live in a temporary
/// folder, its permissions are made up, and it neither searches the network nor restarts.
final class SetupWindowTests: XCTestCase {
    var home: URL!
    var relaunches = 0
    var quits = 0
    var opened: [URL] = []
    var copied: [String] = []
    var accessibility = false
    var bluetooth = BluetoothAccess.notAsked

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("baton-setup-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // Keeps this process's log, and anything that goes by `Paths`, out of the installed Baton's.
        setenv("BATON_HOME", home.path, 1)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
    }

    var installation: Installation { Installation(directory: home) }
    var agent: LaunchAgent { LaunchAgent(directory: home.appendingPathComponent("LaunchAgents")) }
    let app = "/Applications/Baton.app/Contents/MacOS/Baton"

    func makeController(executable: String? = nil) -> SetupWindowController {
        var environment = SetupWindowController.Environment()
        environment.installation = installation
        environment.login = LoginItem(agent: agent, executable: executable ?? app)
        environment.computerName = { "Ana’s Mac mini" }
        environment.accessibility = { [unowned self] in self.accessibility }
        environment.bluetooth = { [unowned self] in self.bluetooth }
        environment.askForAccessibility = {}
        environment.askForBluetooth = {}
        environment.open = { [unowned self] in self.opened.append($0) }
        environment.present = { _ in }
        environment.copy = { [unowned self] in self.copied.append($0) }
        environment.searchesNetwork = false
        environment.relaunch = { [unowned self] in self.relaunches += 1 }
        environment.quit = { [unowned self] in self.quits += 1 }
        return SetupWindowController(environment: environment)
    }

    func report(_ controller: SetupWindowController, _ words: String = "") -> [String: Any] {
        let reply = controller.command(words.split(separator: " ").map(String.init))
        return (try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any] ?? ["reply": reply]
    }

    /// Where the pictures of the window go: `BATON_SNAPSHOTS`, or nowhere that outlives the test.
    func snapshot(_ state: SetupState, _ name: String) {
        let folder = ProcessInfo.processInfo.environment["BATON_SNAPSHOTS"].map { URL(fileURLWithPath: $0) } ?? home!
        let url = folder.appendingPathComponent("\(name).png")
        XCTAssertTrue(SetupView.writeSnapshot(of: state, to: url), "could not render \(name)")
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 10000, "\(name) is not a picture of a window")
    }

    // MARK: The first run

    func testAMacWithoutAConfigIsSetUpBeforeAnythingStarts() throws {
        let controller = makeController()
        var started: [(Config, Data)] = []
        controller.whenSetUp { started.append(($0, $1)) }
        XCTAssertTrue(started.isEmpty, "nothing starts on a Mac that is not set up")

        var status = report(controller)
        XCTAssertEqual(status["mode"] as? String, "first run")
        XCTAssertEqual(status["needs"] as? String, "firstRun")
        XCTAssertEqual(status["name"] as? String, "anas-mac-mini", "the name is offered from the Mac's own")
        XCTAssertEqual(status["role"] as? String, "anchor")
        XCTAssertEqual(status["openAtLogin"] as? Bool, true)
        snapshot(controller.makeState(), "1-first-run")

        // Start without a code is refused, and says what is missing.
        status = report(controller, "apply")
        XCTAssertNotNil(status["codeProblem"])
        XCTAssertTrue(started.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installation.configURL.path))

        status = report(controller, "name studio")
        status = report(controller, "generate")
        XCTAssertEqual(status["code"] as? String, "entered")
        XCTAssertNil(status["codeProblem"])
        let code = controller.makeState().code
        snapshot(controller.makeState(), "2-first-run-anchor-ready")

        status = report(controller, "apply")
        XCTAssertEqual(started.count, 1)
        XCTAssertEqual(started.first?.0.name, "studio")
        XCTAssertEqual(started.first?.0.role, .anchor)
        XCTAssertEqual(started.first?.1, try PairingCode.secret(from: code))
        XCTAssertEqual(status["mode"] as? String, "settings", "the same window carries on as Settings")

        // What was written is what the app reads at its next launch.
        let contents = installation.load()
        XCTAssertNil(contents.need)
        XCTAssertEqual(contents.config?.name, "studio")
        XCTAssertEqual(contents.secret, try PairingCode.secret(from: code))
        XCTAssertEqual(installation.pairingCode, code)
        let mode = try FileManager.default.attributesOfItem(atPath: installation.secretURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertEqual(agent.executable, app, "Open at Login was left ticked")
        XCTAssertEqual(quits, 0)
        XCTAssertEqual(relaunches, 0)
    }

    func testAClientIsSetUpWithTheCodeFromTheOtherMac() throws {
        let code = PairingCode.generate()
        let controller = makeController()
        var started: [(Config, Data)] = []
        controller.whenSetUp { started.append(($0, $1)) }
        _ = report(controller, "role client")
        _ = report(controller, "login off")

        // A slip of the finger is caught here, and not later as a Mac that cannot be reached.
        var typed = Array(PairingCode.normalize(code))
        typed[7] = typed[7] == "A" ? "B" : "A"
        var status = report(controller, "code \(String(typed))")
        XCTAssertEqual(status["codeProblem"] as? String, PairingCode.Problem.mistyped.description)
        snapshot(controller.makeState(), "3-first-run-client-mistyped")
        status = report(controller, "apply")
        XCTAssertTrue(started.isEmpty)

        // The Mac with the mouse turns out to have the name this one was going to take.
        _ = report(controller, "code \(code.lowercased())")
        controller.found("anas-mac-mini")
        status = report(controller)
        XCTAssertNotNil(status["nameProblem"])
        XCTAssertEqual((status["permissions"] as? [String: String])?["localNetwork"], "Allowed: found “anas-mac-mini”")
        _ = report(controller, "name mini")

        controller.searchFailed("-65570: PolicyDenied")
        XCTAssertEqual((report(controller)["permissions"] as? [String: String])?["localNetwork"], "Seems to be off")
        snapshot(controller.makeState(), "4-first-run-client-local-network-off")
        controller.found("studio")

        status = report(controller, "apply")
        XCTAssertEqual(started.count, 1)
        XCTAssertEqual(started.first?.0.role, .client)
        XCTAssertEqual(started.first?.1, try PairingCode.secret(from: code), "both Macs hold the same key")
        XCTAssertFalse(agent.isInstalled, "Open at Login was unticked")
    }

    func testClosingTheSetupWindowQuitsAndWritesNothing() {
        let controller = makeController()
        controller.whenSetUp { _, _ in XCTFail("nothing was set up") }
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        XCTAssertEqual(quits, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installation.configURL.path))
        XCTAssertFalse(agent.isInstalled)
    }

    // MARK: Macs that are already set up

    /// What `scripts/deploy.sh` has left on the owner's Macs: a config, a key that came from
    /// `openssl` and not from a code, and the launch agent of `scripts/install-agent.sh`.
    func deploy(name: String, role: String, extra: String = "") throws -> (config: Data, secret: Data, plist: Data) {
        let config = Data("{\n  \"name\": \"\(name)\",\n  \"role\": \"\(role)\"\(extra)\n}\n".utf8)
        let secret = Data((String(repeating: "5a", count: 32) + "\n").utf8)
        try config.write(to: installation.configURL)
        try secret.write(to: installation.secretURL)
        let plist = Data(LaunchAgentTests.installAgentScriptPlist(home: "/Users/someone").utf8)
        try FileManager.default.createDirectory(at: agent.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try plist.write(to: agent.url)
        return (config, secret, plist)
    }

    func testAMacThatIsSetUpStartsAtOnceAndNothingIsRewritten() throws {
        let before = try deploy(name: "studio", role: "anchor", extra: ",\n  \"placements\": [{ \"machine\": \"mini\", \"side\": \"left\", \"of\": \"studio\", \"align\": \"end\" }]")
        let controller = makeController(executable: "/Users/someone/Applications/Baton.app/Contents/MacOS/Baton")
        var started: [(Config, Data)] = []
        controller.whenSetUp { started.append(($0, $1)) }

        XCTAssertEqual(started.count, 1, "no setup window in the way")
        XCTAssertEqual(started.first?.0.name, "studio")
        XCTAssertEqual(started.first?.0.placements.count, 1)
        XCTAssertEqual(started.first?.1, Data(repeating: 0x5a, count: 32))
        let status = report(controller)
        XCTAssertEqual(status["mode"] as? String, "settings")
        XCTAssertEqual(status["window"] as? String, "closed")
        XCTAssertEqual(status["openAtLogin"] as? Bool, true, "the agent that was there is Open at Login, already on")

        XCTAssertEqual(try Data(contentsOf: installation.configURL), before.config)
        XCTAssertEqual(try Data(contentsOf: installation.secretURL), before.secret)
        XCTAssertEqual(try Data(contentsOf: agent.url), before.plist)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installation.codeURL.path))
    }

    func testAnAgentLeftPointingAtTheOldPlaceIsCorrected() throws {
        _ = try deploy(name: "mini", role: "client")
        let controller = makeController()
        controller.whenSetUp { _, _ in }
        XCTAssertEqual(agent.executable, app, "Baton moved from ~/Applications to /Applications")
        XCTAssertEqual(report(controller)["openAtLogin"] as? Bool, true)
    }

    func testABuildRunFromTheSourceTreeNeverBecomesTheLoginItem() throws {
        let before = try deploy(name: "studio", role: "anchor")
        // Unlike in the other tests, this agent stands for the real one in ~/Library/LaunchAgents.
        let login = LoginItem(agent: agent, executable: "/Users/someone/code/baton/.build/debug/Baton")
        XCTAssertNotNil(LaunchAgent.problem(withExecutable: login.executable, redirected: false))
        XCTAssertNil(try agent.correct(executable: "/Users/someone/Applications/Baton.app/Contents/MacOS/Baton"))
        XCTAssertEqual(try Data(contentsOf: agent.url), before.plist)
    }

    func testSettingsOnAClientChangeTheFileAndRestart() throws {
        _ = try deploy(name: "mini", role: "client", extra: ",\n  \"port\": 47900")
        let controller = makeController()
        controller.whenSetUp { _, _ in }

        var status = report(controller)
        XCTAssertEqual(status["unappliedChanges"] as? Bool, false)
        XCTAssertEqual(controller.makeState().actionEnabled, false)
        XCTAssertNotNil(controller.makeState().codeNote, "a key that was copied over has no code to show")

        // The code can be left alone while something else changes.
        status = report(controller, "name mac-mini")
        XCTAssertEqual(status["unappliedChanges"] as? Bool, true)
        status = report(controller, "apply")
        XCTAssertEqual(relaunches, 1)
        var contents = installation.load()
        XCTAssertEqual(contents.config?.name, "mac-mini")
        XCTAssertEqual(contents.config?.port, 47900, "what Settings does not show is kept")
        XCTAssertEqual(contents.secret, Data(repeating: 0x5a, count: 32))

        // A new code replaces the key.
        let code = PairingCode.generate()
        status = report(controller, "code \(code)")
        status = report(controller, "apply")
        XCTAssertEqual(relaunches, 2)
        contents = installation.load()
        XCTAssertEqual(contents.secret, try PairingCode.secret(from: code))
        XCTAssertEqual(installation.pairingCode, code)
    }

    func testSettingsOnTheAnchorGoThroughTheAnchor() throws {
        _ = try deploy(name: "studio", role: "anchor", extra: ",\n  \"placements\": [{ \"machine\": \"mini\", \"side\": \"left\", \"of\": \"studio\", \"align\": \"end\" }]")
        let controller = makeController()
        var anchor: Anchor?
        controller.whenSetUp { config, secret in
            // Made and never started: no event tap, no listener.
            anchor = Anchor(config: config, secret: secret)
            controller.attach(anchor: anchor, client: nil)
        }
        accessibility = true
        bluetooth = .allowed
        controller.keyboards = [BluetoothKeyboard(address: "00-11-22-33-44-55", name: "Magic Keyboard")]

        var status = report(controller)
        XCTAssertEqual(status["keyboards"] as? [String], ["none", "00-11-22-33-44-55"])
        snapshot(controller.makeState(), "5-settings-anchor")

        status = report(controller, "keyboard 00:11:22:33:44:55")
        status = report(controller, "name desk")
        XCTAssertEqual(status["unappliedChanges"] as? Bool, true)
        snapshot(controller.makeState(), "6-settings-anchor-changed")
        status = report(controller, "apply")
        XCTAssertEqual(relaunches, 1)

        // The anchor's own copy changed, and it wrote the file. Its next save keeps the change.
        XCTAssertEqual(anchor?.currentConfig.keyboardAddress, "00-11-22-33-44-55")
        anchor?.setShareClipboard(false)
        let config = try XCTUnwrap(installation.load().config)
        XCTAssertEqual(config.name, "desk")
        XCTAssertEqual(config.keyboardAddress, "00-11-22-33-44-55")
        XCTAssertEqual(config.placements.map(\.of), ["desk"], "the other Macs stay where they were, around the renamed one")
        XCTAssertFalse(config.shareClipboard)
    }

    func testOpenAtLoginIsSwitchedFromTheMenu() throws {
        _ = try deploy(name: "mini", role: "client")
        try agent.remove()
        let controller = makeController()
        controller.whenSetUp { _, _ in }

        let menu = NSMenu()
        menu.addItem(withTitle: "Looking for the anchor…", action: nil, keyEquivalent: "")
        controller.addItems(to: menu)
        let titles = menu.items.map(\.title)
        XCTAssertEqual(titles.suffix(2), ["Settings…", "Open at Login"])
        let item = try XCTUnwrap(menu.items.last)
        XCTAssertEqual(item.state, .off)
        XCTAssertNotNil(item.action)

        _ = item.target?.perform(item.action)
        XCTAssertEqual(agent.executable, app)
        XCTAssertEqual(report(controller)["openAtLogin"] as? Bool, true)
        _ = report(controller, "login off")
        XCTAssertFalse(agent.isInstalled)
    }

    func testAnUnreadableConfigIsExplainedAndKept() throws {
        try Data("{ \"name\": \"studio\", \"role\": \"boss\" }".utf8).write(to: installation.configURL)
        let controller = makeController()
        var started = 0
        controller.whenSetUp { _, _ in started += 1 }
        XCTAssertEqual(started, 0)
        let banner = try XCTUnwrap(controller.makeState().banner)
        XCTAssertTrue(banner.contains("“role” has a value Baton does not know"), banner)
        snapshot(controller.makeState(), "7-first-run-unreadable-config")

        _ = report(controller, "generate")
        _ = report(controller, "apply")
        XCTAssertEqual(started, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("config.unreadable.json").path))
    }

    // MARK: Pictures of the states that need a running agent

    func testPicturesOfSettings() {
        var state = SetupState()
        state.mode = .settings
        state.name = "mini"
        state.role = .client
        state.code = PairingCode.generate()
        state.status = LinkDiagnosis.localNetworkBlocked.advice
        state.statusNeedsAttention = true
        state.permissions = PermissionRow.rows(role: .client, accessibility: true, bluetooth: .denied, localNetwork: .blocked)
        state.actionTitle = "Apply and Restart"
        state.actionEnabled = false
        state.cancelTitle = "Close"
        snapshot(state, "8-settings-client-local-network-off")

        state.status = LinkDiagnosis.codeMismatch.advice
        state.permissions = PermissionRow.rows(role: .client, accessibility: true, bluetooth: .allowed, localNetwork: LocalNetworkAccess(.codeMismatch))
        snapshot(state, "9-settings-client-wrong-code")

        state.status = LinkDiagnosis.connected("studio").advice
        state.statusNeedsAttention = false
        state.permissions = PermissionRow.rows(role: .client, accessibility: true, bluetooth: .allowed, localNetwork: .working("studio"))
        snapshot(state, "10-settings-client-connected")
    }
}
