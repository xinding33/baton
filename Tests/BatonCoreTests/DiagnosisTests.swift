import XCTest
@testable import BatonCore

final class DiagnosisTests: XCTestCase {
    func facts(connected: Bool = false, discovered: String? = "studio", failures: [String] = [], discovery: String = "ready") -> LinkFacts {
        LinkFacts(name: "mini", connected: connected, anchorName: connected ? "studio" : "", discovered: discovered, failures: failures, discovery: discovery)
    }

    // MARK: Why a client is not connected

    func testAConnectedClientHasNothingToPutRight() {
        // Whatever went wrong on the way no longer matters.
        let diagnosis = facts(connected: true, failures: ["unreachable: -9820: bad MAC"]).diagnosis
        XCTAssertEqual(diagnosis, .connected("studio"))
        XCTAssertFalse(diagnosis.needsAttention)
    }

    func testANetworkThatIsDownWhileItIsNotMeansLocalNetworkIsOff() {
        // As `ClientAgent` logs it when macOS refuses the connection.
        let refused = "unreachable: POSIXErrorCode(rawValue: 50): Network is down"
        XCTAssertEqual(facts(failures: [refused]).diagnosis, .localNetworkBlocked)
        XCTAssertEqual(facts(discovered: nil, discovery: "waiting(-65570: PolicyDenied)").diagnosis, .localNetworkBlocked)
        // It outranks what the other address said in the meantime.
        XCTAssertEqual(facts(failures: [refused, "connect timed out"]).diagnosis, .localNetworkBlocked)
        XCTAssertTrue(LinkDiagnosis.localNetworkBlocked.needsAttention)
        XCTAssertTrue(LinkDiagnosis.localNetworkBlocked.advice.contains("Privacy & Security › Local Network"))
    }

    func testAMacThatIsOnNoNetworkIsNotBlamedOnAPermission() {
        // With Wi-Fi off a connection fails with the very error a refusal gives.
        let refused = "unreachable: POSIXErrorCode(rawValue: 50): Network is down"
        var offline = facts(failures: [refused])
        offline.online = false
        XCTAssertEqual(offline.diagnosis, .offline)
        XCTAssertFalse(offline.diagnosis.needsAttention)
        XCTAssertEqual(LocalNetworkAccess(.offline), .unknown)
    }

    func testAnotherCodeIsToldFromAMacThatIsAway() {
        // What the link reports when the two Macs hold different keys; see PairingLinkTests.
        XCTAssertEqual(facts(failures: ["connect timed out", "unreachable: -9820: bad MAC"]).diagnosis, .codeMismatch)
        XCTAssertTrue(LinkDiagnosis.codeMismatch.needsAttention)
        XCTAssertEqual(facts(failures: ["connect timed out"]).diagnosis, .unreachable(anchor: "studio", reason: "connect timed out"))
        XCTAssertEqual(facts(failures: ["unreachable: POSIXErrorCode(rawValue: 61): Connection refused"]).diagnosis.needsAttention, false)
    }

    func testAClientNamedLikeTheAnchorIsToldSo() {
        let diagnosis = LinkFacts(name: "studio", connected: false, discovered: "studio", failures: ["closed by peer"]).diagnosis
        XCTAssertEqual(diagnosis, .sameNameAsAnchor("studio"))
        XCTAssertTrue(diagnosis.advice.contains("a name of its own"))
    }

    func testWithNoAnchorInSightTheClientIsLooking() {
        XCTAssertEqual(facts(discovered: nil).diagnosis, .searching)
        XCTAssertEqual(facts(discovered: nil, failures: ["connect timed out"]).diagnosis, .searching, "the remembered address did not answer either")
        XCTAssertFalse(LinkDiagnosis.searching.needsAttention)
    }

    func testEveryDiagnosisHasWords() {
        let all: [LinkDiagnosis] = [.connected("studio"), .searching, .offline, .localNetworkBlocked, .codeMismatch, .sameNameAsAnchor("studio"), .unreachable(anchor: "studio", reason: ""), .unreachable(anchor: "studio", reason: "connect timed out")]
        for diagnosis in all {
            XCTAssertFalse(diagnosis.summary.isEmpty)
            XCTAssertTrue(diagnosis.advice.hasSuffix("."), diagnosis.advice)
        }
    }

    // MARK: Permissions

    func testTheAnchorNeedsAccessibilityAndBluetooth() {
        let rows = PermissionRow.rows(role: .anchor, accessibility: false, bluetooth: .notAsked, localNetwork: .unknown)
        XCTAssertEqual(rows.map(\.kind), [.accessibility, .bluetooth])
        XCTAssertEqual(rows[0].level, .missing)
        XCTAssertEqual(rows[0].button, "Open Settings…")
        XCTAssertTrue(rows[0].detail.contains("Privacy & Security › Accessibility"))
        XCTAssertEqual(rows[1].level, .undecided)
        XCTAssertEqual(rows[1].button, "Ask Now…")
    }

    func testAClientAlsoNeedsTheLocalNetwork() {
        let rows = PermissionRow.rows(role: .client, accessibility: true, bluetooth: .denied, localNetwork: .blocked)
        XCTAssertEqual(rows.map(\.kind), [.accessibility, .bluetooth, .localNetwork])
        XCTAssertEqual(rows[0].level, .granted)
        XCTAssertNil(rows[0].button, "nothing to do where it is allowed")
        XCTAssertEqual(rows[1].level, .missing)
        XCTAssertEqual(rows[1].button, "Open Settings…")
        XCTAssertTrue(rows[1].detail.contains("Privacy & Security › Bluetooth"))
        XCTAssertEqual(rows[2].level, .missing)
        XCTAssertTrue(rows[2].detail.contains("Privacy & Security › Local Network"))
    }

    func testTheLocalNetworkIsOnlyCalledAllowedOnEvidence() {
        func row(_ access: LocalNetworkAccess) -> PermissionRow {
            PermissionRow.rows(role: .client, accessibility: true, bluetooth: .allowed, localNetwork: access)[2]
        }
        XCTAssertEqual(row(.working("studio")).level, .granted)
        XCTAssertEqual(row(.working("studio")).state, "Allowed: found “studio”")
        for access in [LocalNetworkAccess.unknown, .searching] {
            XCTAssertEqual(row(access).level, .undecided)
            XCTAssertEqual(row(access).button, "Open Settings…", "the pane stays within reach while it cannot be read")
        }
        XCTAssertEqual(LocalNetworkAccess(.connected("studio")), .working("studio"))
        XCTAssertEqual(LocalNetworkAccess(.localNetworkBlocked), .blocked)
        XCTAssertEqual(LocalNetworkAccess(.searching), .searching)
        // A Mac that was found and then turned this one away was still found.
        XCTAssertEqual(row(LocalNetworkAccess(.codeMismatch)).level, .granted)
        XCTAssertEqual(row(LocalNetworkAccess(.codeMismatch)).state, "Allowed")
    }

    func testARestrictedBluetoothHasNoButton() {
        let row = PermissionRow.rows(role: .anchor, accessibility: true, bluetooth: .restricted, localNetwork: .unknown)[1]
        XCTAssertEqual(row.level, .missing)
        XCTAssertNil(row.button)
    }

    func testEachPermissionOpensItsOwnPane() {
        XCTAssertEqual(PermissionKind.accessibility.settingsURL.absoluteString, "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        XCTAssertEqual(PermissionKind.bluetooth.settingsURL.absoluteString, "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")
        XCTAssertEqual(PermissionKind.localNetwork.settingsURL.absoluteString, "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")
    }

    func testAMacWithoutAPlaceIsPointedOut() {
        XCTAssertEqual(AnchorAttention.unplaced(online: ["studio", "mini", "air"], placed: ["studio", "mini"], anchor: "studio"), ["air"])
        XCTAssertEqual(AnchorAttention.unplaced(online: ["studio"], placed: [], anchor: "studio"), [])
    }

    // MARK: Keyboards

    func testBluetoothAddresses() {
        XCTAssertEqual(BluetoothAddress.normalize("00-11-22-AA-bb-CC"), "00-11-22-aa-bb-cc")
        XCTAssertEqual(BluetoothAddress.normalize(" 00:11:22:aa:bb:cc\n"), "00-11-22-aa-bb-cc")
        for bad in ["", "none", "00-11-22-aa-bb", "00-11-22-aa-bb-cc-dd", "0-11-22-aa-bb-cc", "00-11-22-aa-bb-zz", "00--11-22-aa-bb"] {
            XCTAssertNil(BluetoothAddress.normalize(bad), bad)
        }
    }

    func testKeyboardsAreToldFromOtherBluetoothDevices() {
        XCTAssertTrue(KeyboardChoices.isKeyboard(majorClass: 5, minorClass: 0x10), "a keyboard")
        XCTAssertTrue(KeyboardChoices.isKeyboard(majorClass: 5, minorClass: 0x30), "a keyboard with a trackpad")
        XCTAssertFalse(KeyboardChoices.isKeyboard(majorClass: 5, minorClass: 0x20), "a mouse")
        XCTAssertFalse(KeyboardChoices.isKeyboard(majorClass: 4, minorClass: 0x10), "headphones")
    }

    func testTheChoicesForTheSharedKeyboard() {
        let paired = [
            BluetoothKeyboard(address: "00-11-22-33-44-66", name: "Magic Keyboard"),
            BluetoothKeyboard(address: "00-11-22-33-44-55", name: "Magic Keyboard"),
            BluetoothKeyboard(address: "00:11:22:33:44:77", name: ""),
            BluetoothKeyboard(address: "00-11-22-33-44-88", name: "Desk Keys"),
        ]
        let entries = KeyboardChoices.entries(paired: paired, configured: "00-11-22-33-44-55")
        XCTAssertEqual(entries.map(\.title), ["None", "Desk Keys", "Keyboard", "Magic Keyboard (…44-55)", "Magic Keyboard (…44-66)"])
        XCTAssertEqual(entries.map(\.address), [nil, "00-11-22-33-44-88", "00-11-22-33-44-77", "00-11-22-33-44-55", "00-11-22-33-44-66"])

        // While another Mac holds the keyboard's pairing, this one does not list it.
        let away = KeyboardChoices.entries(paired: [], configured: "00:11:22:33:44:AA")
        XCTAssertEqual(away.map(\.address), [nil, "00-11-22-33-44-aa"])
        XCTAssertEqual(away.last?.title, "Keyboard …44-AA, not paired with this Mac right now")
        XCTAssertEqual(KeyboardChoices.entries(paired: [], configured: nil).map(\.title), ["None"])
    }
}
