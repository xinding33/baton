import CoreGraphics
import Foundation

/// Asks the receiving machine to wake its display.
public struct WakeRequest: Codable, Equatable, Sendable {
    /// The machine whose display woke, or where Wake All Macs was chosen.
    public var origin: String
    /// Wake All Macs was chosen. A wake someone asked for goes through while sharing is paused.
    public var asked: Bool
    public init(origin: String, asked: Bool = false) {
        self.origin = origin
        self.asked = asked
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        origin = try c.decode(String.self, forKey: .origin)
        asked = try c.decodeIfPresent(Bool.self, forKey: .asked) ?? false
    }
}

/// One connection to another machine. A machine that reconnects gets a new `session`, so a wake
/// that went into a connection that was already dead is sent again over the one that replaces it.
public struct WakeLink: Hashable, Sendable {
    public var name: String
    public var session: UInt64
    public init(name: String, session: UInt64) {
        self.name = name
        self.session = session
    }
}

/// The key combination for Wake All Macs.
public struct WakeHotKey: Codable, Equatable, Sendable {
    public enum Modifier: String, Codable, CaseIterable, Sendable {
        case control, option, shift, command

        var flag: CGEventFlags {
            switch self {
            case .control: return .maskControl
            case .option: return .maskAlternate
            case .shift: return .maskShift
            case .command: return .maskCommand
            }
        }

        var symbol: String {
            switch self {
            case .control: return "⌃"
            case .option: return "⌥"
            case .shift: return "⇧"
            case .command: return "⌘"
            }
        }
    }

    /// The virtual key code, e.g. 13 for W.
    public var keyCode: UInt16
    /// The key's name, for the menu.
    public var key: String
    public var modifiers: [Modifier]

    public static let standard = WakeHotKey(keyCode: 13, key: "W", modifiers: [.control, .option, .command])

    public init(keyCode: UInt16, key: String, modifiers: [Modifier]) {
        self.keyCode = keyCode
        self.key = key
        self.modifiers = modifiers
    }

    public var display: String {
        Modifier.allCases.filter(modifiers.contains).map(\.symbol).joined() + key
    }

    /// Whether a key going down with these flags is the hotkey. The modifiers have to match
    /// exactly, so the same key with another modifier added stays free for apps.
    public func matches(code: UInt16, flags: UInt64) -> Bool {
        // Without Control, Option or Command this would swallow ordinary typing.
        guard code == keyCode, modifiers.contains(where: { $0 != .shift }) else { return false }
        let held = Modifier.allCases.filter { CGEventFlags(rawValue: flags).contains($0.flag) }
        return Set(held) == Set(modifiers)
    }
}

/// Follows the hotkey through one press, so that its auto-repeats and its release are swallowed
/// along with the press and no application sees half of it.
public struct WakeHotKeyRecognizer {
    public enum Outcome: Equatable {
        /// Not the hotkey: the event goes on as usual.
        case pass
        /// Part of a press that already fired.
        case swallow
        case fire
    }

    private var held: UInt16?

    public init() {}

    public mutating func process(_ hotKey: WakeHotKey?, code: UInt16, down: Bool, autorepeat: Bool, flags: UInt64) -> Outcome {
        guard down else {
            guard held == code else { return .pass }
            held = nil
            return .swallow
        }
        if held == code { return .swallow }
        guard let hotKey, !autorepeat, hotKey.matches(code: code, flags: flags) else { return .pass }
        held = code
        return .fire
    }
}

/// One Mac's wake settings, kept in `wake.json` beside its config.
public struct WakeSettings: Codable, Equatable, Sendable {
    /// Wake the other Macs when this Mac's display wakes.
    public var wakeOthers = true
    /// Hold off idle system sleep, so the link stays up and this Mac can be woken. Its display
    /// still sleeps on schedule.
    public var keepAwake = true
    public var keepAwakeOnlyOnPower = true
    /// Count another Mac being in use as activity here, so this Mac's display stays on with it.
    /// Follows `keepAwakeOnlyOnPower` too.
    public var stayAwakeWithOthers = true
    /// Nil switches the hotkey off.
    public var hotKey: WakeHotKey? = .standard

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        wakeOthers = try c.decodeIfPresent(Bool.self, forKey: .wakeOthers) ?? true
        keepAwake = try c.decodeIfPresent(Bool.self, forKey: .keepAwake) ?? true
        keepAwakeOnlyOnPower = try c.decodeIfPresent(Bool.self, forKey: .keepAwakeOnlyOnPower) ?? true
        stayAwakeWithOthers = try c.decodeIfPresent(Bool.self, forKey: .stayAwakeWithOthers) ?? true
        // A missing key means the usual hotkey; an explicit null means none.
        hotKey = c.contains(.hotKey) ? try c.decode(WakeHotKey?.self, forKey: .hotKey) : .standard
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(wakeOthers, forKey: .wakeOthers)
        try c.encode(keepAwake, forKey: .keepAwake)
        try c.encode(keepAwakeOnlyOnPower, forKey: .keepAwakeOnlyOnPower)
        try c.encode(stayAwakeWithOthers, forKey: .stayAwakeWithOthers)
        try c.encode(hotKey, forKey: .hotKey)
    }

    private enum CodingKeys: String, CodingKey {
        case wakeOthers, keepAwake, keepAwakeOnlyOnPower, stayAwakeWithOthers, hotKey
    }
}

/// Decides what a display wake, a Wake All Macs or an incoming wake request leads to on one
/// machine. The machines form a star: a client's only link is the anchor, and the anchor passes a
/// client's wake on to the other clients.
///
/// Times are milliseconds on a clock that keeps counting while the Mac sleeps. One that stops
/// would leave the windows below still open when the Mac wakes hours later.
public struct WakeCoordinator {
    public enum Action: Equatable {
        case wakeDisplay
        case send(WakeRequest, to: WakeLink)
        /// What was decided and why, for the log.
        case log(String)
    }

    /// A Mac woken by another Mac sees its own display wake a moment later. For this long, that
    /// is taken for the wake arriving rather than a reason to wake the others again.
    public static let echoWindowMs: UInt64 = 15000
    /// A display that flickers on twice does not wake the others twice.
    public static let minIntervalMs: UInt64 = 5000
    /// A wake is still sent to a machine that connects this long after it happened. A Mac that
    /// has just woken from sleep needs a few seconds to find its link dead and replace it.
    public static let pendingWindowMs: UInt64 = 20000

    public let name: String
    public let role: Role
    public var wakeOthers = true
    /// Anchor only: Pause Sharing is on. A display that wakes then wakes no other Mac, here or
    /// from a client. Wake All Macs is asked for, so it still does.
    public var paused = false

    private var ignoreDisplayWakeUntil: UInt64 = 0
    private var lastAutoWakeAt: UInt64?
    private var pending: (request: WakeRequest, until: UInt64, done: Set<WakeLink>, skipping: Set<String>)?

    public init(name: String, role: Role) {
        self.name = name
        self.role = role
    }

    /// This Mac's display woke.
    public mutating func displayWoke(now: UInt64, links: [WakeLink]) -> [Action] {
        if !wakeOthers { return [.log("display woke; waking the others is switched off")] }
        if paused { return [.log("display woke; sharing is paused")] }
        if now < ignoreDisplayWakeUntil { return [.log("display woke, as another Mac asked; not passing it on")] }
        if let last = lastAutoWakeAt, now >= last, now - last < Self.minIntervalMs {
            return [.log("display woke again; the others were woken a moment ago")]
        }
        lastAutoWakeAt = now
        return offer(WakeRequest(origin: name), skipping: [], now: now, links: links, what: "display woke")
    }

    /// Wake All Macs was chosen on this Mac.
    public mutating func wakeAll(now: UInt64, links: [WakeLink]) -> [Action] {
        return offer(WakeRequest(origin: name, asked: true), skipping: [], now: now, links: links, what: "wake all")
    }

    /// A wake request arrived from the machine called `sender`.
    public mutating func received(_ request: WakeRequest, from sender: String, now: UInt64, links: [WakeLink]) -> [Action] {
        var request = request
        // A client speaks for itself only; what the anchor passes on names where it began.
        if role == .anchor { request.origin = sender }
        guard request.origin != name else { return [] }
        if paused, !request.asked { return [.log("\(request.origin)'s display woke; sharing is paused")] }
        ignoreDisplayWakeUntil = now + Self.echoWindowMs
        var actions: [Action] = [.wakeDisplay, .log("woken by \(request.origin)")]
        if role == .anchor {
            // To the other clients, and never back to the one it came from.
            actions += offer(request, skipping: [sender], now: now, links: links, what: "passing on \(sender)'s wake")
        }
        return actions
    }

    /// Sends a wake that is still fresh over any link that has appeared since. Call this now and
    /// then while `hasPending` is true.
    public mutating func linksChanged(now: UInt64, links: [WakeLink]) -> [Action] {
        guard let current = pending else { return [] }
        guard now <= current.until else {
            pending = nil
            return []
        }
        // Sharing was paused while the wake was fresh.
        if paused, !current.request.asked {
            pending = nil
            return []
        }
        let fresh = links.filter { !current.done.contains($0) && !current.skipping.contains($0.name) }.sorted { $0.name < $1.name }
        guard !fresh.isEmpty else { return [] }
        pending?.done.formUnion(fresh)
        return fresh.map { .send(current.request, to: $0) } + [.log("\(Self.list(fresh)) connected; sent \(current.request.origin)'s wake")]
    }

    public func hasPending(now: UInt64) -> Bool {
        pending.map { now <= $0.until } ?? false
    }

    private mutating func offer(_ request: WakeRequest, skipping: Set<String>, now: UInt64, links: [WakeLink], what: String) -> [Action] {
        let targets = links.filter { !skipping.contains($0.name) }.sorted { $0.name < $1.name }
        pending = (request, now + Self.pendingWindowMs, Set(targets), skipping)
        let outcome = targets.isEmpty ? "no other Mac is connected" : "waking \(Self.list(targets))"
        return targets.map { .send(request, to: $0) } + [.log("\(what); \(outcome)")]
    }

    private static func list(_ links: [WakeLink]) -> String {
        links.map(\.name).joined(separator: ", ")
    }
}
