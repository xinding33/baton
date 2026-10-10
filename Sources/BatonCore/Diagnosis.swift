import Foundation

/// What a client knows about its way to the anchor.
public struct LinkFacts: Equatable, Sendable {
    /// This Mac's own name.
    public var name: String
    public var connected: Bool
    public var anchorName: String
    /// The name the anchor advertises on the network, once discovery has found it.
    public var discovered: String?
    /// Why the last attempts to connect failed, as the link reported it.
    public var failures: [String]
    /// The state of the search for the anchor, as the browser describes it.
    public var discovery: String
    /// Whether this Mac is on any network at all.
    public var online: Bool

    public init(name: String, connected: Bool, anchorName: String = "", discovered: String? = nil, failures: [String] = [], discovery: String = "", online: Bool = true) {
        self.name = name
        self.connected = connected
        self.anchorName = anchorName
        self.discovered = discovered
        self.failures = failures
        self.discovery = discovery
        self.online = online
    }

    public var diagnosis: LinkDiagnosis {
        if connected { return .connected(anchorName) }
        // Without a network the calls below fail the same way as without permission.
        if !online { return .offline }
        // macOS gives no way to ask whether Local Network is allowed. A browse it refuses on
        // policy grounds, and a connection told that the network is down while it is not, are
        // how the refusal shows.
        let blocked = (failures + [discovery]).contains { $0.contains("Network is down") || $0.contains("-65570") || $0.contains("PolicyDenied") }
        if blocked { return .localNetworkBlocked }
        // The anchor closes the connection of a Mac that gives the anchor's own name.
        if let discovered, discovered == name { return .sameNameAsAnchor(name) }
        // With a different code the two Macs hold different keys, and the first protected
        // record of the handshake fails its check.
        if failures.contains(where: { $0.contains("bad MAC") || $0.contains("-9820") || $0.contains("-9824") || $0.contains("-9825") }) {
            return .codeMismatch
        }
        guard let discovered else { return .searching }
        return .unreachable(anchor: discovered, reason: failures.last ?? "")
    }
}

/// Why a client is or is not connected, in a form that can be shown.
public enum LinkDiagnosis: Equatable, Sendable {
    case connected(String)
    case searching
    /// This Mac is on no network, which is its user's to see in the menu bar.
    case offline
    case localNetworkBlocked
    case codeMismatch
    case sameNameAsAnchor(String)
    case unreachable(anchor: String, reason: String)

    /// True when there is something for the person at this Mac to put right.
    public var needsAttention: Bool {
        switch self {
        case .connected, .searching, .offline, .unreachable: return false
        case .localNetworkBlocked, .codeMismatch, .sameNameAsAnchor: return true
        }
    }

    /// One line, for the menu.
    public var summary: String {
        switch self {
        case let .connected(anchor): return "Connected to \(anchor)"
        case .searching: return "Looking for the Mac with the mouse"
        case .offline: return "This Mac is not on a network"
        case .localNetworkBlocked: return "Local Network access seems to be off for Baton"
        case .codeMismatch: return "The pairing code does not match the other Mac’s"
        case .sameNameAsAnchor: return "This Mac has the same name as the Mac with the mouse"
        case let .unreachable(anchor, _): return "Found \(anchor), but cannot connect to it yet"
        }
    }

    /// What to do about it, for the settings window.
    public var advice: String {
        switch self {
        case let .connected(anchor):
            return "Connected to “\(anchor)”."
        case .searching:
            return "Looking for the Mac with the mouse. Baton has to be running there, and both Macs have to be on the same network."
        case .offline:
            return "This Mac is not connected to a network, so it cannot reach the Mac with the mouse."
        case .localNetworkBlocked:
            return "This Mac cannot reach the network around it, which usually means Local Network access is off for Baton. Turn Baton on in System Settings › Privacy & Security › Local Network."
        case .codeMismatch:
            return "The Mac with the mouse was found, but it holds a different pairing code. Enter the code shown in Baton’s settings there."
        case let .sameNameAsAnchor(name):
            return "The Mac with the mouse is also called “\(name)”, so it turns this one away. Give this Mac a name of its own."
        case let .unreachable(anchor, reason):
            return "Found “\(anchor)”, but cannot connect to it yet" + (reason.isEmpty ? "." : " (\(reason)).")
        }
    }
}

public enum PermissionKind: String, Sendable, CaseIterable {
    case accessibility, bluetooth, localNetwork

    /// The pane of System Settings › Privacy & Security where this permission is given.
    public var settingsURL: URL {
        let anchor: String
        switch self {
        case .accessibility: anchor = "Privacy_Accessibility"
        case .bluetooth: anchor = "Privacy_Bluetooth"
        case .localNetwork: anchor = "Privacy_LocalNetwork"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

public enum BluetoothAccess: String, Sendable {
    case allowed, denied, restricted, notAsked
}

/// Local Network access cannot be read, only inferred from what the network calls report.
public enum LocalNetworkAccess: Equatable, Sendable {
    /// Nothing has been tried yet.
    case unknown
    /// A search is running and nothing has refused it or answered it.
    case searching
    /// The anchor was found or reached, which only works with access. With its name, if known.
    case working(String?)
    case blocked

    public init(_ diagnosis: LinkDiagnosis) {
        switch diagnosis {
        case let .connected(anchor): self = .working(anchor)
        case .localNetworkBlocked: self = .blocked
        case .searching: self = .searching
        case .offline: self = .unknown
        // Finding the anchor at all takes Local Network access.
        case .codeMismatch: self = .working(nil)
        case let .sameNameAsAnchor(name): self = .working(name)
        case let .unreachable(anchor, _): self = .working(anchor)
        }
    }
}

/// One permission as the setup window lists it: its state, why Baton wants it, and where to
/// change it.
public struct PermissionRow: Equatable, Sendable {
    public enum Level: Sendable { case granted, missing, undecided }

    public var kind: PermissionKind
    public var title: String
    public var level: Level
    public var state: String
    public var detail: String
    /// The button's title, or nil when there is nothing to do.
    public var button: String?

    /// The permissions a Mac in `role` needs: Accessibility and Bluetooth everywhere, and Local
    /// Network on a client, which is the one that goes looking for the other.
    public static func rows(role: Role, accessibility: Bool, bluetooth: BluetoothAccess, localNetwork: LocalNetworkAccess) -> [PermissionRow] {
        var rows = [
            PermissionRow(
                kind: .accessibility,
                title: "Accessibility",
                level: accessibility ? .granted : .missing,
                state: accessibility ? "Allowed" : "Not allowed yet",
                detail: (role == .anchor
                    ? "Lets Baton follow the mouse and keyboard on this Mac and pass them on to the others."
                    : "Lets Baton move the cursor and type on this Mac.")
                    + (accessibility ? "" : " Turn Baton on in System Settings › Privacy & Security › Accessibility."),
                button: accessibility ? nil : "Open Settings…"
            ),
        ]

        let bluetoothPurpose = "Lets Baton see which Mac a shared Bluetooth keyboard is attached to, and move it."
        switch bluetooth {
        case .allowed:
            rows.append(PermissionRow(kind: .bluetooth, title: "Bluetooth", level: .granted, state: "Allowed", detail: bluetoothPurpose, button: nil))
        case .notAsked:
            rows.append(PermissionRow(kind: .bluetooth, title: "Bluetooth", level: .undecided, state: "Not asked yet",
                                      detail: bluetoothPurpose + " macOS asks once; choose Allow.", button: "Ask Now…"))
        case .denied:
            rows.append(PermissionRow(kind: .bluetooth, title: "Bluetooth", level: .missing, state: "Not allowed",
                                      detail: bluetoothPurpose + " Turn Baton on in System Settings › Privacy & Security › Bluetooth.", button: "Open Settings…"))
        case .restricted:
            rows.append(PermissionRow(kind: .bluetooth, title: "Bluetooth", level: .missing, state: "Restricted on this Mac",
                                      detail: bluetoothPurpose + " Bluetooth is restricted here, by a profile or by Screen Time, and Baton cannot ask for it.", button: nil))
        }

        guard role == .client else { return rows }
        let localPurpose = "Lets Baton find the Mac with the mouse and connect to it."
        switch localNetwork {
        case let .working(anchor):
            rows.append(PermissionRow(kind: .localNetwork, title: "Local Network", level: .granted, state: anchor.map { "Allowed: found “\($0)”" } ?? "Allowed", detail: localPurpose, button: nil))
        case .blocked:
            rows.append(PermissionRow(kind: .localNetwork, title: "Local Network", level: .missing, state: "Seems to be off",
                                      detail: localPurpose + " Turn Baton on in System Settings › Privacy & Security › Local Network.", button: "Open Settings…"))
        case .searching, .unknown:
            rows.append(PermissionRow(
                kind: .localNetwork,
                title: "Local Network",
                level: .undecided,
                state: localNetwork == .searching ? "Looking for the other Mac…" : "Not checked yet",
                detail: localPurpose + " macOS does not show Baton this setting; it is known to be on once the other Mac is found. If macOS asks whether Baton may find devices on your local network, choose Allow.",
                button: "Open Settings…"
            ))
        }
        return rows
    }
}

/// Something the anchor's menu should point out, with the Macs it concerns.
public enum AnchorAttention {
    /// Macs that are connected but have no place next to another, so the cursor cannot reach them.
    public static func unplaced(online: Set<String>, placed: Set<String>, anchor: String) -> [String] {
        online.subtracting(placed).subtracting([anchor]).sorted()
    }
}
