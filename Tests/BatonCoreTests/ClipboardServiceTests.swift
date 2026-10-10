import AppKit
import CryptoKit
import Network
import XCTest
@testable import BatonCore

/// A pasteboard of the test's own. The test thread plays the apps that copy and paste, so it
/// shares a lock with the service.
final class TestBoard: ClipboardBoard {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("baton-test-\(UUID().uuidString)"))
    private lazy var system = SystemClipboard(pasteboard)
    private let lock = NSLock()
    var simulatedAccess = ClipboardAccess.allowed
    private(set) var reads = 0

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var changeCount: Int { locked { system.changeCount } }
    var access: ClipboardAccess { locked { simulatedAccess } }
    func listing() -> ClipboardListing { locked { system.listing() } }
    func read(_ types: [String], limit: Int) -> ClipboardReading {
        locked {
            reads += 1
            return system.read(types, limit: limit)
        }
    }
    func write(_ content: ClipboardContent) -> Int { locked { system.write(content) } }

    // What an app does when the user copies.
    func copy(_ parts: [(String, Data)]) {
        locked {
            pasteboard.clearContents()
            for (type, data) in parts { pasteboard.setData(data, forType: NSPasteboard.PasteboardType(type)) }
        }
    }

    func copy(_ text: String) { copy([("public.utf8-plain-text", Data(text.utf8))]) }

    // What an app sees when the user pastes.
    var text: String? { locked { pasteboard.string(forType: .string) } }
    func data(_ type: String) -> Data? { locked { pasteboard.data(forType: NSPasteboard.PasteboardType(type)) } }
    var marker: String? { locked { pasteboard.string(forType: NSPasteboard.PasteboardType(ClipboardFilter.batonMarker)) } }
    var readCount: Int { locked { reads } }
}

final class Machine {
    let name: String
    let board = TestBoard()
    let service: ClipboardService
    private let lock = NSLock()
    private var lines: [String] = []
    private var handoff = false
    private var shown = 0

    /// What this Mac's Handoff switch says.
    var handoffSetting: Bool {
        get { lock.lock(); defer { lock.unlock() }; return handoff }
        set { lock.lock(); handoff = newValue; lock.unlock() }
    }

    /// How often this Mac was asked to show its Handoff setting.
    var settingShown: Int { lock.lock(); defer { lock.unlock() }; return shown }

    init(_ name: String, hub: Bool, enabled: Bool = true, maxBytes: Int) {
        self.name = name
        let lock = self.lock
        var sink: ((String) -> Void)!
        var setting: (() -> Bool)!
        service = ClipboardService(
            name: name, hub: hub, board: board, enabled: enabled, maxBytes: maxBytes, pollInterval: 0.02,
            universalClipboard: { setting() }, settingCheckInterval: 0.04, log: { sink($0) }
        )
        setting = { [weak self] in self?.handoffSetting ?? false }
        service.onShowHandoffSetting = { [weak self] in
            lock.lock()
            self?.shown += 1
            lock.unlock()
        }
        sink = { [weak self] line in
            lock.lock()
            self?.lines.append(line)
            lock.unlock()
        }
    }

    var log: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}

final class ClipboardServiceTests: XCTestCase {
    var studio: Machine!
    var mini: Machine!
    var mbp: Machine!
    var parameters: () -> NWParameters = { ClipboardServiceTests.loopback(NWParameters.tcp) }
    var port: NWEndpoint.Port { NWEndpoint.Port(rawValue: studio.service.status.port!)! }

    static func loopback(_ parameters: NWParameters) -> NWParameters {
        parameters.requiredInterfaceType = .loopback
        return parameters
    }

    override func tearDown() {
        for machine in [studio, mini, mbp].compactMap({ $0 }) {
            machine.service.disconnect()
            machine.board.pasteboard.releaseGlobally()
        }
    }

    func wait(_ what: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out waiting for \(what)", file: file, line: line) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
    }

    /// Lets everything that is going to happen, happen.
    func settle(_ seconds: TimeInterval = 0.4) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    func join(_ machine: Machine) {
        machine.service.connect(to: "127.0.0.1", port: port, using: parameters())
        wait("\(machine.name) to connect") { machine.service.status.connected && studio.service.status.peers.contains(machine.name) }
    }

    /// The three Macs, connected in a star around the Studio.
    func start(maxBytes: Int = 32 << 20, enabled: Bool = true, clients: Bool = true) {
        studio = Machine("studio", hub: true, enabled: enabled, maxBytes: maxBytes)
        mini = Machine("mini", hub: false, maxBytes: maxBytes)
        mbp = Machine("mbp", hub: false, maxBytes: maxBytes)
        studio.service.listen(on: .any, using: parameters())
        wait("the listener") { studio.service.status.port != nil }
        if clients {
            join(mini)
            join(mbp)
        }
    }

    func random(_ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, count) }
        return data
    }

    // MARK: Copy here, paste there

    func testTextCopiedOnOneClientCanBePastedOnTheOtherMacs() {
        start()
        mini.board.copy("from the mini")
        wait("the text on the others") { studio.board.text == "from the mini" && mbp.board.text == "from the mini" }
        XCTAssertEqual(studio.board.marker, "mini")
        XCTAssertEqual(mbp.board.marker, "mini")

        studio.board.copy("from the studio")
        wait("the text on the clients") { mini.board.text == "from the studio" && mbp.board.text == "from the studio" }
        print([studio, mini, mbp].flatMap { $0!.log }.filter { $0.contains("ms after the copy") }.joined(separator: "\n"))
        mbp.board.copy("from the mbp")
        wait("the text everywhere") { studio.board.text == "from the mbp" && mini.board.text == "from the mbp" }
    }

    func testAReceivedClipboardIsNotSentBack() {
        start()
        mini.board.copy("once")
        wait("the text on the others") { studio.board.text == "once" && mbp.board.text == "once" }
        let counts = [studio, mini, mbp].map { $0!.board.changeCount }
        settle()
        XCTAssertEqual([studio, mini, mbp].map { $0!.board.changeCount }, counts, "a pasteboard was written again")
        // The Mac where the copy was made keeps the app's own clipboard, untouched.
        XCTAssertNil(mini.board.marker)
        // Only the Mac where the copy was made ever read a pasteboard.
        XCTAssertEqual(studio.board.readCount, 0)
        XCTAssertEqual(mbp.board.readCount, 0)
        XCTAssertEqual(studio.service.status.shared, "from mini: public.utf8-plain-text 4 B")
        XCTAssertEqual([studio, mini, mbp].flatMap { $0!.log }.filter { $0.contains("copied here") }.count, 1)
    }

    func testAnotherProgramRewritingTheSameContentDoesNotStartALoop() {
        start()
        mini.board.copy("again")
        wait("the text on the others") { studio.board.text == "again" && mbp.board.text == "again" }
        // A clipboard manager on the MacBook puts back what it just saw, without Baton's marker.
        mbp.board.copy("again")
        settle()
        XCTAssertEqual(studio.board.marker, "mini")
        XCTAssertEqual(studio.service.status.shared, "from mini: public.utf8-plain-text 5 B")
        XCTAssertFalse(mbp.log.contains { $0.contains("copied here") })
    }

    func testRichTextAndAnImageArriveInEveryFormat() {
        start()
        let rtf = Data(#"{\rtf1\ansi{\b bold} text}"#.utf8)
        let html = Data("<b>bold</b> text".utf8)
        let png = random(700_000)
        studio.board.copy([("public.rtf", rtf), ("public.html", html), ("public.png", png), ("public.utf8-plain-text", Data("bold text".utf8))])
        for machine in [mini!, mbp!] {
            wait("the copy on \(machine.name)") { machine.board.data("public.png") == png }
            XCTAssertEqual(machine.board.data("public.rtf"), rtf)
            XCTAssertEqual(machine.board.data("public.html"), html)
            XCTAssertEqual(machine.board.text, "bold text")
        }
    }

    func testTheLogNamesTypesAndSizesButNeverTheData() {
        start()
        mini.board.copy("a phrase nobody should log")
        wait("the text on the others") { studio.board.text != nil && mbp.board.text != nil }
        let lines = [studio, mini, mbp].flatMap { $0!.log }
        XCTAssertTrue(lines.contains { $0.contains("public.utf8-plain-text 26 B") })
        XCTAssertFalse(lines.contains { $0.contains("phrase") })
    }

    // MARK: What stays on its Mac

    func testFilesAndPasswordsStayOnTheirMac() {
        start()
        studio.board.copy("before")
        wait("the text on the clients") { mini.board.text == "before" && mbp.board.text == "before" }

        studio.board.copy([("public.file-url", Data("file:///Users/someone/report.pdf".utf8)), ("public.utf8-plain-text", Data("report.pdf".utf8))])
        wait("the file to be noticed") { studio.log.contains { $0.contains("not shared (files)") } }
        studio.board.copy([("public.utf8-plain-text", Data("hunter2".utf8)), ("org.nspasteboard.ConcealedType", Data())])
        wait("the password to be noticed") { studio.log.contains { $0.contains("not shared (secret)") } }
        settle()
        XCTAssertEqual(mini.board.text, "before")
        XCTAssertEqual(mbp.board.text, "before")
        // Neither was even read.
        XCTAssertEqual(studio.board.readCount, 1)

        studio.board.copy("after")
        wait("the text on the clients") { mini.board.text == "after" && mbp.board.text == "after" }
    }

    func testACopyOverTheLimitIsNotShared() {
        start(maxBytes: 1 << 20)
        mini.board.copy("small")
        wait("the text on the others") { studio.board.text == "small" && mbp.board.text == "small" }
        mini.board.copy([("public.png", random((1 << 20) + 1))])
        wait("the refusal") { mini.service.status.lastEvent == "copy not shared: larger than 1.0 MB" }
        settle()
        XCTAssertEqual(studio.board.text, "small")
        XCTAssertEqual(mbp.board.text, "small")
        // Exactly at the limit still goes.
        let most = random(1 << 20)
        mini.board.copy([("public.png", most)])
        wait("the image on the others") { studio.board.data("public.png") == most && mbp.board.data("public.png") == most }
    }

    func testNothingIsReadWhereMacOSWouldAskEachTime() {
        start()
        mbp.board.simulatedAccess = .asks
        mbp.board.copy("not readable")
        wait("the refusal") { mbp.service.status.lastEvent.contains("does not let Baton read") }
        XCTAssertEqual(mbp.board.readCount, 0)
        XCTAssertEqual(mbp.service.status.access, .asks)
        // It still receives.
        studio.board.copy("incoming")
        wait("the text on the mbp") { mbp.board.text == "incoming" }
        // Once allowed, copies made there go out again.
        mbp.board.simulatedAccess = .allowed
        mbp.board.copy("readable now")
        wait("the text on the others") { studio.board.text == "readable now" && mini.board.text == "readable now" }
        XCTAssertEqual(mbp.service.status.access, .allowed)
    }

    // MARK: Large copies

    func testALargeImageCrossesWithoutHoldingUpTheMainQueue() {
        start()
        // The main queue carries the event tap and the heartbeat; watch how long it ever stalls.
        var last = DispatchTime.now().uptimeNanoseconds
        var worst: UInt64 = 0
        let watch = DispatchSource.makeTimerSource(queue: .main)
        watch.schedule(deadline: .now(), repeating: .milliseconds(2))
        watch.setEventHandler {
            let now = DispatchTime.now().uptimeNanoseconds
            worst = max(worst, now - last)
            last = now
        }
        watch.resume()
        settle(0.1)
        worst = 0

        let image = random(24 << 20)
        let started = Date()
        mbp.board.copy([("public.png", image)])
        wait("the image on the others", timeout: 30) { studio.board.changeCount > 0 && mini.board.changeCount > 0 }
        let took = Date().timeIntervalSince(started)
        watch.cancel()
        XCTAssertEqual(studio.board.data("public.png"), image)
        XCTAssertEqual(mini.board.data("public.png"), image)
        print("24 MB: client -> anchor -> client in \(Int(took * 1000)) ms; longest main-queue stall \(worst / 1_000_000) ms")
        XCTAssertLessThan(worst, 100_000_000, "the main queue stalled")
    }

    func testANewerCopyOvertakesALargeOneStillOnItsWay() {
        start()
        let image = random(30 << 20)
        mbp.board.copy([("public.png", image)])
        wait("the image to start out") { mbp.log.contains { $0.contains("copied here: public.png") } }
        mbp.board.copy("the text I actually want")
        wait("the text on the others", timeout: 30) { studio.board.text == "the text I actually want" && mini.board.text == "the text I actually want" }
        settle(1)
        for machine in [studio!, mini!] {
            XCTAssertEqual(machine.board.text, "the text I actually want")
            XCTAssertNil(machine.board.data("public.png"))
        }
    }

    func testACopyMadeElsewhereWinsOverAnOlderOneStillArriving() {
        start()
        // The MacBook starts uploading a large image; a moment later text is copied on the Studio.
        mbp.board.copy([("public.png", random(30 << 20))])
        wait("the image to start out") { mbp.log.contains { $0.contains("copied here: public.png") } }
        studio.board.copy("copied later")
        wait("the text on the clients", timeout: 30) { mini.board.text == "copied later" && mbp.board.text == "copied later" }
        settle(1.5)
        for machine in [studio!, mini!, mbp!] {
            XCTAssertEqual(machine.board.text, "copied later", machine.name)
            XCTAssertNil(machine.board.data("public.png"), machine.name)
        }
    }

    func testCopiesMadeAtTheSameMomentEndTheSameEverywhere() {
        start()
        for round in 0..<5 {
            mini.board.copy("mini \(round)")
            mbp.board.copy("mbp \(round)")
            studio.board.copy("studio \(round)")
            wait("agreement in round \(round)") {
                let texts = Set([studio, mini, mbp].map { $0!.board.text })
                return texts.count == 1 && texts.first??.hasSuffix(" \(round)") == true
            }
            settle(0.2)
            XCTAssertEqual(Set([studio, mini, mbp].map { $0!.board.text }).count, 1)
        }
    }

    // MARK: Joining and leaving

    func testAMacThatJoinsLaterGetsTheCurrentClipboard() {
        start(clients: false)
        join(mini)
        studio.board.copy("copied before the mbp was there")
        wait("the text on the mini") { mini.board.text == "copied before the mbp was there" }
        join(mbp)
        wait("the text on the mbp") { mbp.board.text == "copied before the mbp was there" }
    }

    func testACopyMadeWhileDisconnectedIsSharedOnReconnecting() {
        start()
        mbp.service.disconnect()
        wait("the mbp to leave") { !studio.service.status.peers.contains("mbp") }
        studio.board.copy("older, on the studio")
        wait("the text on the mini") { mini.board.text == "older, on the studio" }
        settle(0.05)
        mbp.board.copy("newer, on the mbp")
        wait("the mbp to notice") { mbp.log.contains { $0.contains("sent to nobody") } }
        join(mbp)
        wait("the text on the others") { studio.board.text == "newer, on the mbp" && mini.board.text == "newer, on the mbp" }
        settle()
        XCTAssertEqual(mbp.board.text, "newer, on the mbp")
        XCTAssertNil(mbp.board.marker)
    }

    func testAnOlderSharedCopyDoesNotReplaceAFileCopiedSince() {
        start()
        mbp.service.disconnect()
        wait("the mbp to leave") { !studio.service.status.peers.contains("mbp") }
        studio.board.copy("older, on the studio")
        wait("the text on the mini") { mini.board.text == "older, on the studio" }
        settle(0.05)
        mbp.board.copy([("public.file-url", Data("file:///tmp/a".utf8))])
        wait("the file to be noticed") { mbp.log.contains { $0.contains("not shared (files)") } }
        join(mbp)
        settle()
        XCTAssertNotNil(mbp.board.data("public.file-url"))
        XCTAssertNil(mbp.board.marker)
        // The next copy anywhere is newer and does arrive.
        mini.board.copy("newest")
        wait("the text on the mbp") { mbp.board.text == "newest" }
    }

    func testTheClipboardOfAMacThatLeftStaysOnTheOthers() {
        start()
        mini.board.copy("still here")
        wait("the text on the others") { studio.board.text == "still here" && mbp.board.text == "still here" }
        mini.service.disconnect()
        wait("the mini to leave") { studio.service.status.peers == ["mbp"] }
        mbp.board.copy("two left")
        wait("the text on the studio") { studio.board.text == "two left" }
        XCTAssertEqual(mini.board.text, "still here")
    }

    // MARK: The switch

    func testSharingCanBeSwitchedOffAndOnFromAnyMac() {
        start()
        var saved: [Bool] = []
        let lock = NSLock()
        studio.service.onEnabledChanged = { value in
            lock.lock()
            saved.append(value)
            lock.unlock()
        }
        XCTAssertTrue(mini.service.status.enabled)
        mini.service.setEnabled(false)
        wait("everyone to switch off") { [studio, mini, mbp].allSatisfy { !$0!.service.status.enabled } }
        studio.board.copy("while off")
        mbp.board.copy("also while off")
        settle()
        XCTAssertNil(mini.board.text)
        XCTAssertEqual(studio.board.text, "while off")
        XCTAssertEqual([studio, mini, mbp].map { $0!.board.readCount }, [0, 0, 0])

        studio.service.setEnabled(true)
        wait("everyone to switch on") { [studio, mini, mbp].allSatisfy { $0!.service.status.enabled } }
        settle(0.1)
        // What was copied while it was off stays where it is.
        XCTAssertNil(mini.board.text)
        mbp.board.copy("back on")
        wait("the text on the others") { studio.board.text == "back on" && mini.board.text == "back on" }
        lock.lock()
        XCTAssertEqual(saved, [false, true])
        lock.unlock()
    }

    func testPauseSharingStopsEveryMacAndLeavesTheSettingOn() {
        start()
        var saved: [Bool] = []
        let lock = NSLock()
        studio.service.onEnabledChanged = { value in
            lock.lock()
            saved.append(value)
            lock.unlock()
        }
        mini.board.copy("before the pause")
        wait("the text on the others") { studio.board.text == "before the pause" && mbp.board.text == "before the pause" }
        let reads = [studio, mini, mbp].map { $0!.board.readCount }

        studio.service.setPaused(true)
        wait("everyone to pause") { [studio, mini, mbp].allSatisfy { $0!.service.status.paused } }
        XCTAssertTrue([studio, mini, mbp].allSatisfy { $0!.service.status.enabled })
        studio.board.copy("on the studio, while paused")
        mbp.board.copy("on the mbp, while paused")
        settle()
        XCTAssertEqual(mini.board.text, "before the pause")
        XCTAssertEqual(studio.board.text, "on the studio, while paused")
        XCTAssertEqual(mbp.board.text, "on the mbp, while paused")
        XCTAssertEqual([studio, mini, mbp].map { $0!.board.readCount }, reads, "nothing is read while paused")

        studio.service.setPaused(false)
        wait("everyone to resume") { [studio, mini, mbp].allSatisfy { !$0!.service.status.paused } }
        settle(0.1)
        // What was copied during the pause stays where it is.
        XCTAssertEqual(mini.board.text, "before the pause")
        XCTAssertEqual(studio.board.text, "on the studio, while paused")
        mini.board.copy("after the pause")
        wait("the text on the others") { studio.board.text == "after the pause" && mbp.board.text == "after the pause" }
        lock.lock()
        XCTAssertEqual(saved, [], "a pause is not the setting")
        lock.unlock()
        XCTAssertTrue(mbp.log.contains("sharing paused") && mbp.log.contains("sharing resumed"))
    }

    func testAMacThatJoinsDuringAPauseWaitsForItToEnd() {
        start(clients: false)
        join(mini)
        studio.board.copy("copied before the pause")
        wait("the text on the mini") { mini.board.text == "copied before the pause" }
        studio.service.setPaused(true)
        wait("the pause") { studio.service.status.paused && mini.service.status.paused }
        join(mbp)
        wait("the mbp to hear of the pause") { mbp.service.status.paused }
        mbp.board.copy("on the mbp, while paused")
        settle()
        XCTAssertEqual(mbp.board.text, "on the mbp, while paused")
        XCTAssertEqual(studio.board.text, "copied before the pause")

        // Reconnecting after the pause does not bring out what was copied during it.
        studio.service.setPaused(false)
        wait("the resume") { !mbp.service.status.paused }
        mbp.service.disconnect()
        wait("the mbp to leave") { !studio.service.status.peers.contains("mbp") }
        join(mbp)
        settle()
        XCTAssertEqual(studio.board.text, "copied before the pause")
        XCTAssertEqual(mbp.board.text, "on the mbp, while paused")
    }

    func testSharingSwitchedOffStaysOffThroughAPause() {
        start(enabled: false)
        studio.service.setPaused(true)
        wait("the pause") { studio.service.status.paused && mini.service.status.paused }
        studio.service.setPaused(false)
        wait("the resume") { !studio.service.status.paused && !mini.service.status.paused }
        mini.board.copy("nothing happens")
        settle()
        XCTAssertNil(studio.board.text)
        XCTAssertFalse(mini.service.status.enabled)
        XCTAssertEqual(mini.board.readCount, 0)
    }

    func testAnAnchorWithSharingOffTellsItsClients() {
        start(enabled: false)
        XCTAssertFalse(studio.service.status.enabled)
        XCTAssertFalse(mini.service.status.enabled)
        mini.board.copy("nothing happens")
        settle()
        XCTAssertNil(studio.board.text)
        XCTAssertEqual(mini.board.readCount, 0)
    }

    // MARK: Universal Clipboard

    func advice() -> [[String]] {
        [studio, mini, mbp].map { $0!.service.status.turnOffHandoffOn }
    }

    func testEveryMacLearnsWhereHandoffShouldBeTurnedOff() {
        start()
        XCTAssertEqual(advice(), [[], [], []])
        // As macOS ships: Handoff on everywhere.
        for machine in [studio!, mini!, mbp!] { machine.handoffSetting = true }
        wait("the advice") { advice() == Array(repeating: ["mbp", "mini"], count: 3) }
        XCTAssertTrue(mini.service.status.universalClipboard)

        // The owner turns it off on the mini, then on the MacBook; the Studio keeps it.
        mini.handoffSetting = false
        wait("the advice") { advice() == Array(repeating: ["mbp"], count: 3) }
        mbp.handoffSetting = false
        wait("the advice") { advice() == [[], [], []] }
        XCTAssertTrue(studio.service.status.universalClipboard)
        XCTAssertTrue(studio.log.contains { $0.contains("Handoff should be turned off on mbp, mini") })
    }

    func testNothingIsAskedWhileSharingIsOffOrAMacIsAway() {
        start()
        for machine in [studio!, mini!, mbp!] { machine.handoffSetting = true }
        wait("the advice") { advice() == Array(repeating: ["mbp", "mini"], count: 3) }
        mbp.service.disconnect()
        wait("the mbp to leave") { studio.service.status.turnOffHandoffOn == ["mini"] && mbp.service.status.turnOffHandoffOn == [] }
        studio.service.setEnabled(false)
        wait("the advice to go") { studio.service.status.turnOffHandoffOn == [] && mini.service.status.turnOffHandoffOn == [] }
        studio.service.setEnabled(true)
        wait("the advice to return") { studio.service.status.turnOffHandoffOn == ["mini"] && mini.service.status.turnOffHandoffOn == ["mini"] }
    }

    func testAHandoffClipboardArrivingCountsWhateverTheSettingSays() {
        start()
        studio.handoffSetting = true
        settle(0.2)
        XCTAssertEqual(advice(), [[], [], []])
        // The MacBook's setting says off, yet a clipboard arrives there through Handoff.
        mbp.board.copy([("public.utf8-plain-text", Data("from the phone".utf8)), (ClipboardFilter.handoffMarker, Data())])
        wait("the advice") { advice() == Array(repeating: ["mbp"], count: 3) }
        XCTAssertNotNil(mbp.service.status.handoffClipboardSeen)
        XCTAssertNil(studio.board.text, "a Handoff clipboard was passed on")
    }

    func testTheAnchorCanShowTheSettingOnAnyMac() {
        start()
        studio.service.showHandoffSetting(on: "mini")
        wait("the mini to show it") { mini.settingShown == 1 }
        studio.service.showHandoffSetting(on: "studio")
        wait("the studio to show it") { studio.settingShown == 1 }
        XCTAssertEqual(mbp.settingShown, 0)
    }

    // MARK: The real transport

    /// The same TLS with a pre-shared key that `Net.tlsParameters` sets up for the input link.
    func testItWorksOverTheSameTLSAsTheInputLink() {
        let secret = SymmetricKey(size: .bits256)
        parameters = {
            let tls = NWProtocolTLS.Options()
            let code = Data(HMAC<SHA256>.authenticationCode(for: Data("baton-psk-v1".utf8), using: secret))
            let psk = code.withUnsafeBytes { DispatchData(bytes: $0) }
            let identity = Data("baton".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
            let options = tls.securityProtocolOptions
            sec_protocol_options_add_pre_shared_key(options, psk as __DispatchData, identity as __DispatchData)
            sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
            sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
            sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
            return ClipboardServiceTests.loopback(NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
        }
        start()
        let image = random(5 << 20)
        mini.board.copy([("public.png", image), ("public.utf8-plain-text", Data("with a caption".utf8))])
        wait("the copy on the others") { studio.board.data("public.png") == image && mbp.board.data("public.png") == image }
        XCTAssertEqual(mbp.board.text, "with a caption")
    }

    func testAStrangerIsTurnedAway() {
        start(clients: false)
        // Someone who connects and talks nonsense is dropped, and the clients are unaffected.
        let stranger = NWConnection(host: "127.0.0.1", port: port, using: parameters())
        let closed = expectation(description: "closed")
        stranger.stateUpdateHandler = { state in
            if case .ready = state {
                stranger.send(content: Data([0, 0, 0, 3, 99, 1, 2]), completion: .contentProcessed { _ in })
                stranger.receive(minimumIncompleteLength: 1, maximumLength: 100) { _, _, isComplete, error in
                    if isComplete || error != nil { closed.fulfill() }
                }
            }
        }
        stranger.start(queue: .global())
        wait(for: [closed], timeout: 5)
        stranger.cancel()
        join(mini)
        studio.board.copy("still working")
        wait("the text on the mini") { mini.board.text == "still working" }
    }
}

final class ClipboardLinkTests: XCTestCase {
    /// On a fast network a large copy is across before anyone can copy again, so this hands the
    /// link two copies back to back: the second must cut the first short.
    func testANewerCopyCutsAnOlderOneShortBetweenChunks() throws {
        let queue = DispatchQueue(label: "test.clipboard.link")
        let listener = try NWListener(using: ClipboardServiceTests.loopback(NWParameters.tcp), on: .any)
        let lock = NSLock()
        var frames: [ClipboardFrame] = []
        var received: [ClipboardContent] = []
        var parser = ClipboardFrameParser()
        var server: ClipboardLink?
        let done = expectation(description: "the second copy arrives")

        // The receiving side, with a tap on the frames it is sent.
        listener.newConnectionHandler = { connection in
            let link = ClipboardLink(connection, queue: queue)
            link.maxBytes = { 1 << 30 }
            link.onContent = { content in
                lock.lock()
                received.append(content)
                lock.unlock()
                done.fulfill()
            }
            server = link
            link.start()
        }
        let ready = expectation(description: "listening")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: queue)
        wait(for: [ready], timeout: 5)

        var image = Data(count: 8 << 20)
        image.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, 8 << 20) }
        let large = ClipboardContent(stamp: ClipboardStamp(time: 1, origin: "mbp"), parts: [ClipboardPart(type: "public.png", data: image)])
        let small = ClipboardContent(stamp: ClipboardStamp(time: 2, origin: "mbp"), parts: [ClipboardPart(type: "public.utf8-plain-text", data: Data("text".utf8))])

        // The sending side goes through a relay that records every frame on its way.
        let relayListener = try NWListener(using: ClipboardServiceTests.loopback(NWParameters.tcp), on: .any)
        let relayReady = expectation(description: "relay listening")
        relayListener.stateUpdateHandler = { if case .ready = $0 { relayReady.fulfill() } }
        relayListener.newConnectionHandler = { inbound in
            let outbound = NWConnection(host: "127.0.0.1", port: listener.port!, using: ClipboardServiceTests.loopback(NWParameters.tcp))
            outbound.start(queue: queue)
            inbound.start(queue: queue)
            func pump() {
                inbound.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
                    if let data, !data.isEmpty {
                        lock.lock()
                        parser.append(data)
                        while let frame = try? parser.next() { frames.append(frame) }
                        lock.unlock()
                        outbound.send(content: data, completion: .contentProcessed { _ in })
                    }
                    if isComplete || error != nil { return outbound.cancel() }
                    pump()
                }
            }
            pump()
        }
        relayListener.start(queue: queue)
        wait(for: [relayReady], timeout: 5)

        let client = ClipboardLink(NWConnection(host: "127.0.0.1", port: relayListener.port!, using: ClipboardServiceTests.loopback(NWParameters.tcp)), queue: queue)
        client.onReady = {
            client.send(large)
            client.send(small)
        }
        client.start()
        wait(for: [done], timeout: 10)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        lock.lock()
        defer { lock.unlock() }
        XCTAssertEqual(received, [small])
        let chunksOfLarge = frames.filter { if case .chunk(1, _) = $0 { return true } else { return false } }.count
        XCTAssertLessThanOrEqual(chunksOfLarge, 2, "the large copy went on after it was replaced")
        XCTAssertTrue(frames.contains(.cancel(transfer: 1)))
        XCTAssertFalse(frames.contains(.end(transfer: 1)))
        XCTAssertEqual(frames.last, .end(transfer: 2))
        client.close("done")
        server?.close("done")
        listener.cancel()
        relayListener.cancel()
    }
}
