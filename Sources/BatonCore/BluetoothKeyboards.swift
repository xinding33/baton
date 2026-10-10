import Foundation

public enum BluetoothAddress {
    /// The address in the form IOBluetooth uses, "aa-bb-cc-dd-ee-ff", or nil if `text` is not
    /// six pairs of hex digits. Colons are accepted in place of the dashes.
    public static func normalize(_ text: String) -> String? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(omittingEmptySubsequences: false, whereSeparator: { $0 == "-" || $0 == ":" })
        guard parts.count == 6, parts.allSatisfy({ $0.count == 2 && UInt8($0, radix: 16) != nil }) else { return nil }
        return parts.map { $0.lowercased() }.joined(separator: "-")
    }
}

/// A Bluetooth keyboard this Mac is paired with.
public struct BluetoothKeyboard: Equatable, Sendable {
    public var address: String
    public var name: String

    public init(address: String, name: String) {
        self.address = address
        self.name = name
    }
}

/// The choices Settings offers for the shared keyboard.
public enum KeyboardChoices {
    /// Whether a Bluetooth class of device is a keyboard, alone or combined with a pointing
    /// device. `major` and `minor` are the fields as IOBluetooth returns them.
    public static func isKeyboard(majorClass: UInt32, minorClass: UInt32) -> Bool {
        majorClass == 5 && minorClass & 0x10 != 0
    }

    public struct Entry: Equatable, Sendable {
        public var title: String
        /// Nil for "no shared keyboard".
        public var address: String?
    }

    /// "None", then the paired keyboards by name, then the configured one if this Mac does not
    /// hold its pairing at the moment. That is its usual state while another Mac has it.
    public static func entries(paired: [BluetoothKeyboard], configured: String?) -> [Entry] {
        var entries = [Entry(title: "None", address: nil)]
        var seen: Set<String> = []
        let keyboards = paired.compactMap { keyboard -> BluetoothKeyboard? in
            guard let address = BluetoothAddress.normalize(keyboard.address), seen.insert(address).inserted else { return nil }
            return BluetoothKeyboard(address: address, name: keyboard.name.isEmpty ? "Keyboard" : keyboard.name)
        }.sorted { ($0.name.lowercased(), $0.address) < ($1.name.lowercased(), $1.address) }
        for keyboard in keyboards {
            // Two keyboards of one model are told apart by the end of their address.
            let twins = keyboards.filter { $0.name == keyboard.name }.count > 1
            entries.append(Entry(title: twins ? "\(keyboard.name) (…\(ending(of: keyboard.address)))" : keyboard.name, address: keyboard.address))
        }
        if let configured {
            let address = BluetoothAddress.normalize(configured) ?? configured
            if !seen.contains(address) {
                entries.append(Entry(title: "Keyboard …\(ending(of: address)), not paired with this Mac right now", address: address))
            }
        }
        return entries
    }

    private static func ending(of address: String) -> String {
        String(address.suffix(5)).uppercased()
    }
}
