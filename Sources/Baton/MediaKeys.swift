import AppKit
import BatonCore

extension EventTap {
    /// The type of the events the media keys come in. CoreGraphics has no name for it.
    static let systemDefined = CGEventType(rawValue: MediaKey.eventType)!
}

extension MediaKey {
    /// Reads a system-defined event. Nil unless it is a press or release of a key that is shared:
    /// the same type also carries mouse buttons and power events, which are not input to forward.
    init?(_ event: CGEvent) {
        guard let read = NSEvent(cgEvent: event), read.type == .systemDefined, read.subtype.rawValue == MediaKey.eventSubtype,
              let key = MediaKey(data1: read.data1, flags: event.flags.rawValue), key.isShared else { return nil }
        self = key
    }

    /// The event a keyboard attached to this Mac would have caused.
    func makeEvent() -> CGEvent? {
        NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(truncatingIfNeeded: flags)),
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: MediaKey.eventSubtype,
            data1: data1,
            data2: -1
        )?.cgEvent
    }
}
