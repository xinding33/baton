import Foundation

/// A press or release of a key that macOS does not report as a key: volume, brightness, playback.
/// These arrive as "system-defined" events, with the key and what happened to it packed into one
/// number.
public struct MediaKey: Codable, Equatable, Sendable {
    /// Which key, one of `NX_KEYTYPE_...` in IOKit's `ev_keymap.h`.
    public var code: Int
    public var down: Bool
    public var autorepeat: Bool
    public var flags: UInt64

    /// `NX_SYSDEFINED`, the type of the events these keys come in, and
    /// `NX_SUBTYPE_AUX_CONTROL_BUTTONS`, their subtype.
    public static let eventType: UInt32 = 14
    public static let eventSubtype: Int16 = 8

    public static let soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
    public static let play = 16, next = 17, previous = 18, fast = 19, rewind = 20

    /// The keys that act on the Mac the cursor is on. The rest stay with the Mac the keyboard is
    /// attached to: Caps Lock, which travels as a modifier, the keyboard's own backlight, Eject
    /// and the power key.
    public static let shared: Set<Int> = [soundUp, soundDown, mute, brightnessUp, brightnessDown, play, next, previous, fast, rewind]

    public init(code: Int, down: Bool, autorepeat: Bool = false, flags: UInt64 = 0) {
        self.code = code
        self.down = down
        self.autorepeat = autorepeat
        self.flags = flags
    }

    /// Reads the event's `data1`: the key in the high half, then 0xA for a press or 0xB for a
    /// release, then whether it is a repeat. Nil if it is neither a press nor a release.
    public init?(data1: Int, flags: UInt64) {
        let state = (data1 >> 8) & 0xFF
        guard state == 0xA || state == 0xB else { return nil }
        self.init(code: (data1 >> 16) & 0xFFFF, down: state == 0xA, autorepeat: data1 & 1 != 0, flags: flags)
    }

    public var data1: Int {
        code << 16 | (down ? 0xA : 0xB) << 8 | (autorepeat ? 1 : 0)
    }

    public var isShared: Bool { MediaKey.shared.contains(code) }
}

/// Decides, press by press, whether a media key stays on this Mac or is forwarded elsewhere.
public struct MediaKeyCapture: Sendable {
    /// Keys that went down while input stayed local; their releases must stay local too.
    private var downLocally: Set<Int> = []

    public init() {}

    public mutating func forwards(_ key: MediaKey, forwarding: Bool) -> Bool {
        guard forwarding else {
            if key.down { downLocally.insert(key.code) } else { downLocally.remove(key.code) }
            return false
        }
        if !key.down, downLocally.remove(key.code) != nil { return false }
        return true
    }
}
