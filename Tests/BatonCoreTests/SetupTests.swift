import XCTest
@testable import BatonCore

final class SetupTests: XCTestCase {
    var folder: URL!
    var installation: Installation { Installation(directory: folder) }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("baton-core-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    // MARK: Names

    func testNamesAreSingleWords() {
        for name in ["studio", "mini", "mbp", "mac-mini_2", "A1"] {
            XCTAssertNil(MachineName.problem(with: name), name)
        }
        for name in ["", "mac mini", "ana’s", "büro", "a/b", String(repeating: "a", count: 25)] {
            XCTAssertNotNil(MachineName.problem(with: name), name)
        }
    }

    func testANameIsOfferedFromTheComputerName() {
        XCTAssertEqual(MachineName.suggestion(fromComputerName: "Ana’s MacBook Pro"), "anas-macbook-pro")
        XCTAssertEqual(MachineName.suggestion(fromComputerName: "Büro iMac (2)"), "buro-imac-2")
        XCTAssertEqual(MachineName.suggestion(fromComputerName: "  Mac Studio  "), "mac-studio")
        XCTAssertEqual(MachineName.suggestion(fromComputerName: "The Unreasonably Long Name Of A Mac"), "the-unreasonably-long-na")
        XCTAssertEqual(MachineName.suggestion(fromComputerName: "工作室"), "mac")
        XCTAssertEqual(MachineName.suggestion(fromComputerName: nil), "mac")
        for name in ["Ana’s MacBook Pro", "Büro iMac (2)", "The Unreasonably Long Name Of A Mac", "--x--", ""] {
            XCTAssertNil(MachineName.problem(with: MachineName.suggestion(fromComputerName: name)), name)
        }
    }

    // MARK: Checking a config

    func testTheConfigsInUseHaveNoProblems() throws {
        let anchor = """
            { "name": "studio", "role": "anchor",
              "placements": [
                { "machine": "mini", "side": "left", "of": "studio", "align": "end" },
                { "machine": "mbp", "side": "right", "of": "studio", "align": "end" },
                { "machine": "air", "side": "above", "of": "mbp" }
              ],
              "timeoutMs": { "mbp": 1500 }, "keyboardAddress": "00-11-22-AA-bb-cc", "keyboardFollows": true }
            """
        XCTAssertEqual(try JSONDecoder().decode(Config.self, from: Data(anchor.utf8)).problems, [])
        XCTAssertEqual(try JSONDecoder().decode(Config.self, from: Data(#"{ "name": "mini", "role": "client" }"#.utf8)).problems, [])
        XCTAssertEqual(Config(name: "mac", role: .anchor).problems, [])
    }

    func testWhatIsWrongWithAConfigIsSaid() {
        var config = Config(name: "my mac", role: .anchor)
        config.port = 65535
        config.keyboardAddress = "the keyboard"
        config.timeoutMs = ["mbp": 0]
        config.clipboardMaxMB = 0
        config.placements = [
            Placement(machine: "mini", side: .left, of: "studio"),
            Placement(machine: "mbp", side: .right, of: "my mac"),
            Placement(machine: "mbp", side: .left, of: "my mac"),
            Placement(machine: "my mac", side: .left, of: "mbp"),
        ]
        let problems = config.problems.joined(separator: "\n")
        for expected in [
            "name “my mac”", "port 65535", "keyboardAddress “the keyboard”", "timeoutMs for “mbp”", "clipboardMaxMB",
            "“mini” sits next to “studio”, which has no place itself", "“mbp” is placed more than once", "“my mac” is this Mac",
        ] {
            XCTAssertTrue(problems.contains(expected), "\(expected) is missing from:\n\(problems)")
        }
        // A client is not asked about the layout it does not use.
        config.role = .client
        XCTAssertFalse(config.problems.joined().contains("placements"))
    }

    func testRenamingTheAnchorKeepsTheOthersAroundIt() {
        var config = Config(name: "studio", role: .anchor)
        config.placements = [Placement(machine: "mini", side: .left, of: "studio"), Placement(machine: "mbp", side: .right, of: "mini")]
        config.rename(to: "desk")
        XCTAssertEqual(config.name, "desk")
        XCTAssertEqual(config.placements.map(\.of), ["desk", "mini"])
        XCTAssertEqual(config.problems, [])
    }

    // MARK: What is on disk

    func testAFolderWithNothingInItNeedsTheFirstRun() {
        let contents = installation.load()
        XCTAssertEqual(contents.need, .firstRun)
        XCTAssertNil(contents.config)
        XCTAssertNil(contents.secret)
        XCTAssertNil(SetupNeed.firstRun.explanation)
    }

    func testAConfigAndAKeyAreAllAMacNeeds() throws {
        try write(#"{ "name": "mini", "role": "client" }"#, to: installation.configURL)
        try write(String(repeating: "ab", count: 32) + "\n", to: installation.secretURL)
        let contents = installation.load()
        XCTAssertNil(contents.need)
        XCTAssertEqual(contents.config?.name, "mini")
        XCTAssertEqual(contents.secret, Data(repeating: 0xab, count: 32))
        XCTAssertNil(installation.pairingCode, "a key that did not come from a code has none")
    }

    func testWhatIsMissingOrBrokenIsNamed() throws {
        try write(#"{ "name": "mini", "role": "client" }"#, to: installation.configURL)
        XCTAssertEqual(installation.load().need, .notPaired)
        try write("not a key\n", to: installation.secretURL)
        XCTAssertEqual(installation.load().need, .unreadableSecret)
        try write(String(repeating: "ab", count: 16), to: installation.secretURL)
        XCTAssertEqual(installation.load().need, .unreadableSecret, "sixteen bytes are too few")

        let broken: [(String, String)] = [
            (#"{ "name": "mini" }"#, "“role” is missing"),
            (#"{ "name": "mini", "role": "boss" }"#, "“role” has a value Baton does not know"),
            (#"{ "name": 3, "role": "client" }"#, "“name” holds the wrong kind of value"),
            (#"{ "name": "mini", "role": "client", "#, "it is not valid JSON"),
            (#"{ "name": "s", "role": "anchor", "placements": [{ "machine": "m", "side": "left" }] }"#, "“placements.Index 0.of” is missing"),
        ]
        for (text, reason) in broken {
            try write(text, to: installation.configURL)
            XCTAssertEqual(installation.load().need, .unreadableConfig(reason), text)
        }
        XCTAssertTrue(SetupNeed.unreadableConfig("it is not valid JSON").explanation?.contains("it is not valid JSON") == true)
    }

    // MARK: Writing

    func testPairingWritesTheKeyThatTheCodeGives() throws {
        let code = PairingCode.generate()
        try installation.save(Config(name: "studio", role: .anchor))
        try installation.pair(with: PairingCode.normalize(code).lowercased())

        XCTAssertEqual(try loadSecret(from: installation.secretURL), try PairingCode.secret(from: code))
        XCTAssertEqual(installation.pairingCode, code)
        XCTAssertNil(installation.load().need)
        for url in [installation.secretURL, installation.codeURL] {
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600, url.lastPathComponent)
        }
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), ["config.json", "pairing.code", "secret.key"], "nothing temporary is left behind")

        // Pairing again replaces both files.
        let second = PairingCode.generate()
        try installation.pair(with: second)
        XCTAssertEqual(installation.pairingCode, second)
        XCTAssertThrowsError(try installation.pair(with: "ABCDE"))
        XCTAssertEqual(installation.pairingCode, second, "a code that is refused changes nothing")
    }

    func testACodeIsForgottenOnceTheKeyIsReplacedBehindIt() throws {
        try installation.pair(with: PairingCode.generate())
        XCTAssertNotNil(installation.pairingCode)
        // As `scripts/deploy.sh` does when it copies the anchor's key to a client.
        try write(String(repeating: "cd", count: 32) + "\n", to: installation.secretURL)
        XCTAssertNil(installation.pairingCode)
    }

    func testAConfigThatIsSavedReadsBackTheSame() throws {
        var config = Config(name: "studio", role: .anchor)
        config.placements = [Placement(machine: "mini", side: .left, of: "studio", align: .end)]
        config.keyboardAddress = "00-11-22-33-44-55"
        try installation.save(config)
        let read = try loadConfig(from: installation.configURL)
        XCTAssertEqual(read.name, "studio")
        XCTAssertEqual(read.placements, config.placements)
        XCTAssertEqual(read.keyboardAddress, "00-11-22-33-44-55")

        try installation.updateConfig { $0.rename(to: "desk") }
        XCTAssertEqual(try loadConfig(from: installation.configURL).placements.first?.of, "desk")
    }

    func testAnUnreadableConfigIsSetAside() throws {
        try write("{ nonsense", to: installation.configURL)
        try installation.setAsideUnreadableConfig()
        XCTAssertEqual(installation.load().need, .firstRun)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("config.unreadable.json"), encoding: .utf8), "{ nonsense")
    }

    func testTheAnchorsDisplaysFollowItsNewName() throws {
        let url = folder.appendingPathComponent("known-displays.json")
        try write(#"{"studio":[{"id":1}],"mini":[{"id":2}]}"#, to: url)
        installation.renameKnownDisplays(from: "studio", to: "desk")
        let known = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: [[String: Int]]]
        XCTAssertEqual(known, ["desk": [["id": 1]], "mini": [["id": 2]]])
    }
}
