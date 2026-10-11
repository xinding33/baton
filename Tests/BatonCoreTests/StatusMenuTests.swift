import XCTest
@testable import BatonCore

/// The menu bar item's menu: short, with only what is done in a hurry or needs attention now.
final class StatusMenuTests: XCTestCase {
    /// An anchor on an ordinary day: two clients, a shared keyboard, nothing wrong.
    var anchor: StatusMenu.Facts {
        var facts = StatusMenu.Facts(role: .anchor)
        facts.peers = ["mini", "mbp"]
        facts.online = ["mbp", "mini", "studio"]
        facts.sharesKeyboard = true
        facts.keyboardOwner = "studio"
        facts.canWakeAll = true
        facts.wakeHotKey = "⌃⌥⌘W"
        facts.pauseHotKey = "⌃⌥⌘P"
        return facts
    }

    func entries(_ facts: StatusMenu.Facts) -> [StatusMenu.Item] {
        StatusMenu.items(facts).filter { !$0.isSeparator }
    }

    func testTheAnchorsMenuHasSevenItemsOnAnOrdinaryDay() {
        XCTAssertEqual(StatusMenu.items(anchor), [
            .status("Connected: mbp, mini"),
            .pause(resume: false, hotKey: "⌃⌥⌘P"),
            .home,
            .keyboard(owner: "studio", destinations: ["mbp", "mini"]),
            .wakeAll(hotKey: "⌃⌥⌘W"),
            .separator,
            .settings,
            .quit,
        ])
        XCTAssertEqual(entries(anchor).count, 7)
    }

    func testAClientsMenuHasFour() {
        var facts = StatusMenu.Facts(role: .client)
        facts.canWakeAll = true
        XCTAssertEqual(StatusMenu.items(facts), [.status("Looking for the anchor…"), .wakeAll(hotKey: nil), .separator, .settings, .quit])
        facts.connected = true
        XCTAssertEqual(entries(facts).first, .status("Connected to the anchor"))
        XCTAssertEqual(entries(facts).count, 4)
    }

    func testWhatIsNotInUseIsLeftOut() {
        var facts = anchor
        facts.sharesKeyboard = false
        facts.canWakeAll = false
        facts.peers = []
        facts.pauseHotKey = nil
        XCTAssertEqual(entries(facts), [.status("No other Macs connected"), .pause(resume: false, hotKey: nil), .home, .settings, .quit])
    }

    func testTheKeyboardCanGoToEveryMacButTheOneThatHasIt() {
        var facts = anchor
        facts.keyboardOwner = "mini"
        XCTAssertTrue(entries(facts).contains(.keyboard(owner: "mini", destinations: ["mbp", "studio"])))
        facts.keyboardOwner = nil
        XCTAssertTrue(entries(facts).contains(.keyboard(owner: nil, destinations: ["mbp", "mini", "studio"])))
    }

    func testWhatNeedsAttentionComesFirstAndPassingThingsOnlyWhileTheyLast() {
        var facts = anchor
        let accessibility = StatusMenu.Attention(summary: "Accessibility is not allowed yet", detail: "…", pane: StatusMenu.Pane.general)
        facts.attention = [accessibility]
        facts.update = "Installing Baton 1.4.0…"
        facts.paused = true
        XCTAssertEqual(StatusMenu.items(facts), [
            .attention(accessibility),
            .separator,
            .status("Connected: mbp, mini"),
            .pause(resume: true, hotKey: "⌃⌥⌘P"),
            .home,
            .keyboard(owner: "studio", destinations: ["mbp", "mini"]),
            .wakeAll(hotKey: "⌃⌥⌘W"),
            .separator,
            .notice("Installing Baton 1.4.0…", pane: StatusMenu.Pane.updates),
            .separator,
            .settings,
            .quit,
        ])
        // One thing wrong and one thing passing still leaves the menu under ten.
        XCTAssertEqual(entries(facts).count, 9)
        facts.update = nil
        XCTAssertEqual(entries(facts).count, 8)
    }

    func testTheMenuBarItemSaysWhereTheCursorIs() {
        var facts = anchor
        XCTAssertEqual(StatusMenu.title(facts), "⇄")
        facts.focus = "mini"
        XCTAssertEqual(StatusMenu.title(facts), "⇄ mini")
        facts.paused = true
        XCTAssertEqual(StatusMenu.title(facts), "⇄ paused")

        var client = StatusMenu.Facts(role: .client)
        XCTAssertEqual(StatusMenu.title(client), "⇄ ?")
        client.connected = true
        XCTAssertEqual(StatusMenu.title(client), "⇄")
        client.active = true
        XCTAssertEqual(StatusMenu.title(client), "⇄ ●")
    }

    func testMacsWithoutAPlaceShareOneLine() {
        XCTAssertNil(AnchorAttention.unplacedSummary([]))
        XCTAssertEqual(AnchorAttention.unplacedSummary(["mini"]), "mini has no place yet")
        XCTAssertEqual(AnchorAttention.unplacedSummary(["mbp", "mini"]), "mbp, mini have no place yet")
    }
}
