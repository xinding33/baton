import Foundation

extension HotKey {
    /// The key combination for Pause Sharing, unless Settings names another.
    public static let pauseSharing = HotKey(keyCode: 35, key: "P", modifiers: [.control, .option, .command])

    /// What already answers to this combination, if anything does. Control-Option-Command-Escape
    /// brings the cursor home with any other modifier held too.
    public func taken(wakeAll: HotKey?) -> String? {
        if keyCode == 53, Set([Modifier.control, .option, .command]).isSubset(of: modifiers) { return "Bring Cursor Home" }
        if let wakeAll, isSameCombination(as: wakeAll) { return "Wake All Macs" }
        return nil
    }
}

/// The anchor's settings for Pause Sharing, kept in `sharing.json` beside its config.
public struct SharingSettings: Codable, Equatable, Sendable {
    /// Pauses sharing, and resumes it. Nil switches the hotkey off.
    public var hotKey: HotKey? = .pauseSharing
    /// Sharing is paused when Baton starts, and waits to be resumed.
    public var startPaused = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A missing key means the usual hotkey; an explicit null means none.
        hotKey = c.contains(.hotKey) ? try c.decode(HotKey?.self, forKey: .hotKey) : .pauseSharing
        startPaused = try c.decodeIfPresent(Bool.self, forKey: .startPaused) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(hotKey, forKey: .hotKey)
        try c.encode(startPaused, forKey: .startPaused)
    }

    private enum CodingKeys: String, CodingKey {
        case hotKey, startPaused
    }

    /// Whether sharing starts out paused. `carried` is how a restart that Baton made itself left
    /// it, and counts for more than the setting: an update must not switch sharing on or off.
    public func startsPaused(carried: Bool?) -> Bool {
        carried ?? startPaused
    }

    /// Why `hotKey` cannot be the one for Pause Sharing, or nil if it can.
    public static func problem(with hotKey: HotKey, wakeAll: HotKey?) -> String? {
        if let taken = hotKey.taken(wakeAll: wakeAll) { return "\(hotKey.display) is already \(taken)." }
        if !hotKey.hasRealModifier { return "A shortcut needs at least one of ⌃, ⌥ and ⌘, or it would get in the way of typing." }
        return nil
    }
}
