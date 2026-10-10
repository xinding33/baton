import BatonCore
import CoreGraphics
import Foundation
import IOKit.pwr_mgt

/// Counts another Mac being in use as activity on this one. The display then stays on for as long
/// as this Mac's own display sleep setting says, counted from the last report. Whether to is
/// decided by `StayAwakeConditions` in BatonCore; this is the part that touches the Mac.
final class StayAwake {
    /// Asking about the display, the lock and the power source, and declaring the activity, are
    /// calls into other processes. They are made here, so a slow answer cannot hold up the input.
    private let queue = DispatchQueue(label: "baton.stay-awake", qos: .utility)
    /// Used on `queue` only. One assertion is extended by each report rather than adding another.
    private var assertion: IOPMAssertionID = 0

    private static var screenIsLocked: Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// Another Mac is in use. `done` is called on the main queue with what held this Mac back
    /// from counting it, or nil when it was counted.
    func heard(enabled: Bool, onlyOnPower: Bool, done: @escaping (String?) -> Void) {
        queue.async {
            let conditions = StayAwakeConditions(
                enabled: enabled,
                onlyOnPower: onlyOnPower,
                onPowerAdapter: KeepAwake.onPowerAdapter,
                displayAsleep: CGDisplayIsAsleep(CGMainDisplayID()) != 0,
                locked: Self.screenIsLocked
            )
            var heldBackBy = conditions.heldBackBy
            if heldBackBy == nil {
                // What a key press does for the idle timers, without being input: it does not
                // show up in the event taps, so it is never reported back to the others.
                let result = IOPMAssertionDeclareUserActivity("Baton: another of your Macs is in use" as CFString, kIOPMUserActiveLocal, &self.assertion)
                if result != kIOReturnSuccess { heldBackBy = "the system refused (\(result))" }
            }
            DispatchQueue.main.async { done(heldBackBy) }
        }
    }
}
