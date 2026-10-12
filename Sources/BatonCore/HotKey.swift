import CoreGraphics
import Foundation

/// A key combination that Baton acts on wherever it is typed, such as the one for Wake All Macs.
public struct HotKey: Codable, Equatable, Sendable {
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

        /// What `HotKey.parse` takes for it.
        var words: [String] {
            switch self {
            case .control: return ["control", "ctrl", "⌃"]
            case .option: return ["option", "opt", "alt", "⌥"]
            case .shift: return ["shift", "⇧"]
            case .command: return ["command", "cmd", "⌘"]
            }
        }
    }

    /// The virtual key code, e.g. 13 for W.
    public var keyCode: UInt16
    /// The key's name, for the menu.
    public var key: String
    public var modifiers: [Modifier]

    public init(keyCode: UInt16, key: String, modifiers: [Modifier]) {
        self.keyCode = keyCode
        self.key = key
        self.modifiers = modifiers
    }

    public var display: String {
        Modifier.allCases.filter(modifiers.contains).map(\.symbol).joined() + key
    }

    /// Without Control, Option or Command a hotkey would swallow ordinary typing.
    public var hasRealModifier: Bool {
        modifiers.contains { $0 != .shift }
    }

    /// The modifiers held in an event's flags. Caps Lock and the like are not among them.
    public static func modifiers(in flags: UInt64) -> [Modifier] {
        Modifier.allCases.filter { CGEventFlags(rawValue: flags).contains($0.flag) }
    }

    /// Whether a key going down with these flags is the hotkey. The modifiers have to match
    /// exactly, so the same key with another modifier added stays free for apps.
    public func matches(code: UInt16, flags: UInt64) -> Bool {
        guard code == keyCode, hasRealModifier else { return false }
        return Set(HotKey.modifiers(in: flags)) == Set(modifiers)
    }

    /// Whether the two are the same combination, whatever each calls its key.
    public func isSameCombination(as other: HotKey) -> Bool {
        keyCode == other.keyCode && Set(modifiers) == Set(other.modifiers)
    }

    // MARK: Naming keys

    /// Keys that type nothing to name them by, and what the menu calls them.
    private static let symbols: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 117: "⌦",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    /// What `parse` takes for those keys.
    private static let words: [String: UInt16] = [
        "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53, "esc": 53,
        "left": 123, "right": 124, "down": 125, "up": 126,
    ]

    private static let functionKeys: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

    /// The letters, digits and signs, where the US keyboard has them.
    private static let printed: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 50: "`",
    ]

    /// The name of a key that types nothing, such as F5 or an arrow. Nil for one that types a
    /// character, which is named by what it types on the keyboard in use.
    public static func fixedName(forKeyCode code: UInt16) -> String? {
        if let index = functionKeys.firstIndex(of: code) { return "F\(index + 1)" }
        return symbols[code]
    }

    /// A key's name: fixed, or what it `types` without modifiers, or where the US keyboard has it.
    public static func name(forKeyCode code: UInt16, types: String? = nil) -> String {
        if let fixed = fixedName(forKeyCode: code) { return fixed }
        if let types, types.count == 1, let scalar = types.unicodeScalars.first, scalar.value > 0x20, !(0xF700...0xF8FF).contains(scalar.value) {
            return types.uppercased()
        }
        return printed[code] ?? "key \(code)"
    }

    /// Reads a combination written out, such as `control+option+command+p` or `⌃⌥⌘P`. Keys are
    /// named as on the US keyboard.
    public static func parse(_ text: String) -> HotKey? {
        var rest = text.lowercased()
        var modifiers: [Modifier] = []
        // The symbols need no separator.
        for modifier in Modifier.allCases {
            guard let symbol = modifier.words.last, rest.contains(symbol) else { continue }
            rest = rest.replacingOccurrences(of: symbol, with: "")
            modifiers.append(modifier)
        }
        var parts = rest.split(whereSeparator: { $0 == "+" || $0 == " " }).map(String.init)
        guard let key = parts.popLast() else { return nil }
        for part in parts {
            guard let modifier = Modifier.allCases.first(where: { $0.words.contains(part) }), !modifiers.contains(modifier) else { return nil }
            modifiers.append(modifier)
        }
        let code: UInt16
        if let named = words[key] {
            code = named
        } else if key.hasPrefix("f"), let number = Int(key.dropFirst()), functionKeys.indices.contains(number - 1) {
            code = functionKeys[number - 1]
        } else if let fixed = symbols.first(where: { $0.value.lowercased() == key }) {
            code = fixed.key
        } else if let typed = printed.first(where: { $0.value.lowercased() == key }) {
            code = typed.key
        } else {
            return nil
        }
        return HotKey(keyCode: code, key: name(forKeyCode: code), modifiers: Modifier.allCases.filter(modifiers.contains))
    }
}

/// Follows a hotkey through one press, so that its auto-repeats and its release are swallowed
/// along with the press and no application sees half of it.
public struct HotKeyRecognizer {
    public enum Outcome: Equatable {
        /// Not the hotkey: the event goes on as usual.
        case pass
        /// Part of a press that already fired.
        case swallow
        case fire
    }

    private var held: UInt16?

    public init() {}

    public mutating func process(_ hotKey: HotKey?, code: UInt16, down: Bool, autorepeat: Bool, flags: UInt64) -> Outcome {
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
