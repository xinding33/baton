import XCTest
@testable import BatonCore

final class LoginItemTests: XCTestCase {
    var folder: URL!
    var agent: LaunchAgent { LaunchAgent(directory: folder) }
    let home = "/Users/someone/Applications/Baton.app/Contents/MacOS/Baton"
    let applications = "/Applications/Baton.app/Contents/MacOS/Baton"

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("baton-agents-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    func testTheAgentStartsBatonAtLoginAndAfterACrashButNotAfterQuit() {
        let plist = LaunchAgent.propertyList(executable: applications)
        XCTAssertEqual(plist["Label"] as? String, "com.xinding.baton")
        XCTAssertEqual(plist["ProgramArguments"] as? [String], [applications])
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["KeepAlive"] as? [String: Bool], ["SuccessfulExit": false])
        XCTAssertEqual(plist["AssociatedBundleIdentifiers"] as? String, "com.xinding.baton")
        XCTAssertEqual(plist["LimitLoadToSessionType"] as? String, "Aqua")
        XCTAssertEqual(plist["ProcessType"] as? String, "Interactive")
        XCTAssertEqual(plist["ThrottleInterval"] as? Int, 5)
        XCTAssertEqual(plist["StandardErrorPath"] as? String, "/dev/null")
        XCTAssertEqual(plist.count, 9)
    }

    func testTheAgentGoesToTheRealFolderUnlessRedirected() {
        let userHome = URL(fileURLWithPath: "/Users/someone")
        XCTAssertEqual(LaunchAgent.directory(environment: [:], home: userHome).path, "/Users/someone/Library/LaunchAgents")
        XCTAssertEqual(LaunchAgent.directory(environment: ["BATON_HOME": "/tmp/x"], home: userHome).path, "/tmp/x/LaunchAgents")
        XCTAssertEqual(LaunchAgent.directory(environment: ["BATON_HOME": "/tmp/x", "BATON_LAUNCH_AGENTS": "/tmp/y"], home: userHome).path, "/tmp/y")
        XCTAssertFalse(LaunchAgent.isRedirected(environment: [:]))
        XCTAssertTrue(LaunchAgent.isRedirected(environment: ["BATON_HOME": "/tmp/x"]))
        XCTAssertEqual(LaunchAgent(directory: userHome).url.lastPathComponent, "com.xinding.baton.plist")
    }

    func testInstallingAndRemoving() throws {
        XCTAssertFalse(agent.isInstalled)
        XCTAssertNil(agent.executable)
        try agent.remove()

        try agent.install(executable: applications)
        XCTAssertTrue(agent.isInstalled)
        XCTAssertEqual(agent.executable, applications)
        let written = try PropertyListSerialization.propertyList(from: Data(contentsOf: agent.url), format: nil) as? NSDictionary
        XCTAssertEqual(written, LaunchAgent.propertyList(executable: applications) as NSDictionary)

        try agent.remove()
        XCTAssertFalse(agent.isInstalled)
    }

    func testAnAgentThatStartsThisCopyIsLeftAsItIs() throws {
        try agent.install(executable: home)
        let before = try FileManager.default.attributesOfItem(atPath: agent.url.path)[.modificationDate] as? Date
        XCTAssertNil(try agent.correct(executable: home))
        XCTAssertNil(try agent.correct(executable: "/Users/someone/Applications/../Applications/Baton.app/Contents/MacOS/Baton"))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: agent.url.path)[.modificationDate] as? Date, before)
        XCTAssertEqual(agent.executable, home)
    }

    func testAnAgentThatStartsAnotherCopyIsCorrected() throws {
        try agent.install(executable: home)
        XCTAssertEqual(try agent.correct(executable: applications), home)
        XCTAssertEqual(agent.executable, applications)

        try Data("not a property list".utf8).write(to: agent.url)
        XCTAssertNotNil(try agent.correct(executable: applications))
        XCTAssertEqual(agent.executable, applications)
    }

    func testOpenAtLoginThatIsOffStaysOff() throws {
        XCTAssertNil(try agent.correct(executable: applications))
        XCTAssertFalse(agent.isInstalled)
    }

    func testOnlyACopyThatStaysWhereItIsMayOpenAtLogin() {
        XCTAssertNil(LaunchAgent.problem(withExecutable: applications, redirected: false))
        XCTAssertNil(LaunchAgent.problem(withExecutable: home, redirected: false))
        let translocated = "/private/var/folders/ab/T/AppTranslocation/1234/d/Baton.app/Contents/MacOS/Baton"
        XCTAssertTrue(LaunchAgent.isTranslocated(translocated))
        XCTAssertNotNil(LaunchAgent.problem(withExecutable: translocated, redirected: false))
        XCTAssertNotNil(LaunchAgent.problem(withExecutable: translocated, redirected: true))
        let build = "/Users/someone/code/baton/.build/debug/Baton"
        XCTAssertNotNil(LaunchAgent.problem(withExecutable: build, redirected: false), "a build must not take the installed app's place")
        XCTAssertNil(LaunchAgent.problem(withExecutable: build, redirected: true), "its own folder is its own business")
        // Nor may a build switch the installed app's Open at Login off.
        XCTAssertFalse(LaunchAgent.belongs(toExecutable: build, redirected: false))
        XCTAssertTrue(LaunchAgent.belongs(toExecutable: build, redirected: true))
        XCTAssertTrue(LaunchAgent.belongs(toExecutable: translocated, redirected: false), "a copy in the wrong place can still switch it off")
    }
}
