import BatonCore
import CoreGraphics
import Foundation
import IOKit.pwr_mgt
import SystemConfiguration

/// Counts another Mac being in use as activity on this one. The display then stays on for as long
/// as this Mac's own display sleep setting says, counted from the last report, and the screen
/// saver is held off for as long as `ScreenSaverHold` says. Whether to is decided by
/// `StayAwakeConditions` in BatonCore; this is the part that touches the Mac.
final class StayAwake: NSObject {
    /// What loginwindow posts once the screen is locked.
    static let screenLocked = Notification.Name("com.apple.screenIsLocked")
    static let screenSaverHoldName = "Baton: another of your Macs is in use; screen saver held off"

    /// Asking about the display, the lock and the power source, and declaring the activity, are
    /// calls into other processes. They are made here, so a slow answer cannot hold up the input.
    let queue = DispatchQueue(label: "baton.stay-awake", qos: .utility)
    /// Used on `queue` only. One assertion is extended by each report rather than adding another.
    private var assertion: IOPMAssertionID = 0
    /// Used on `queue` only. Holds the screen saver off; each report starts its timeout again.
    private var screenSaverHold: IOPMAssertionID = 0
    private var heldFor: Int?
    private let center: NotificationCenter

    /// `center` is where the lock is announced; a test passes its own.
    init(center: NotificationCenter = DistributedNotificationCenter.default()) {
        self.center = center
        super.init()
        // The lock screen turns the display off after half a minute unless something holds it
        // on, and the reports that would end the hold stop when the other Mac is left alone.
        if let distributed = center as? DistributedNotificationCenter {
            // Delivery otherwise waits until the app is the active one, which Baton never is.
            distributed.addObserver(self, selector: #selector(screenDidLock), name: Self.screenLocked, object: nil, suspensionBehavior: .deliverImmediately)
        } else {
            center.addObserver(self, selector: #selector(screenDidLock), name: Self.screenLocked, object: nil)
        }
    }

    deinit {
        center.removeObserver(self)
    }

    @objc private func screenDidLock() {
        standDown("the screen is locked")
    }

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
            self.holdScreenSaverOff(for: heldBackBy == nil ? ScreenSaverHold.seconds(screenSaverAfter: Self.screenSaverSeconds, displaySleepsAfterMinutes: Self.displaySleepMinutes) : nil)
            DispatchQueue.main.async { done(heldBackBy) }
        }
    }

    /// Gives up at once what the last report left running, so this Mac is back on its own timers
    /// now and not when the hold runs out.
    func standDown(_ why: String) {
        queue.async {
            if self.heldFor != nil { log("wake: no longer holding the screen saver off: \(why)") }
            if self.assertion != 0 { IOPMAssertionRelease(self.assertion) }
            self.assertion = 0
            self.holdScreenSaverOff(for: nil)
        }
    }

    /// Starts the hold's timeout again, or ends the hold when `seconds` is nil. On `queue` only.
    func holdScreenSaverOff(for seconds: Int?) {
        defer {
            // A report comes every few seconds; the log gets only what changed.
            if seconds != heldFor, let seconds { log("wake: holding the screen saver off for \(seconds) s after the last input at another Mac") }
            heldFor = seconds
        }
        guard let seconds else {
            if screenSaverHold != 0 { IOPMAssertionRelease(screenSaverHold) }
            screenSaverHold = 0
            return
        }
        // Setting the timeout starts it again, and switches a hold that ran out back on.
        if screenSaverHold != 0, IOPMAssertionSetProperty(screenSaverHold, kIOPMAssertionTimeoutKey as CFString, seconds as CFNumber) == kIOReturnSuccess { return }
        // What a video player holds, and what the screen saver looks for before it starts.
        let result = IOPMAssertionCreateWithDescription(
            kIOPMAssertPreventUserIdleDisplaySleep as CFString,
            Self.screenSaverHoldName as CFString,
            nil, nil, nil,
            CFTimeInterval(seconds),
            kIOPMAssertionTimeoutActionTurnOff as CFString,
            &screenSaverHold
        )
        if result != kIOReturnSuccess {
            screenSaverHold = 0
            log("wake: cannot hold the screen saver off (\(result))")
        }
    }

    /// When this Mac starts its screen saver, in seconds: 0 for never, nil when never set.
    private static var screenSaverSeconds: Int? {
        let domain = "com.apple.screensaver" as CFString
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        return CFPreferencesCopyValue("idleTime" as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) as? Int
    }

    /// When this Mac's display sleeps on its current power source, in minutes: 0 for never.
    private static var displaySleepMinutes: Int? {
        let settings = SCDynamicStoreCopyValue(nil, "State:/IOKit/PowerManagement/CurrentSettings" as CFString) as? [String: Any]
        return settings?["Display Sleep Timer"] as? Int
    }
}
