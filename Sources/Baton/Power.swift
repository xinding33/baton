import Foundation
import IOKit
import IOKit.pwr_mgt

/// Tells the app when this Mac is about to sleep, and holds sleep off until the app is ready.
final class SleepWatcher {
    // IOKit's power messages; the header defines them with a macro Swift does not import.
    private static let canSleep: UInt32 = 0xE000_0270
    private static let willSleep: UInt32 = 0xE000_0280
    private static let hasPoweredOn: UInt32 = 0xE000_0300

    private var root: io_connect_t = 0
    private var notifier: io_object_t = 0
    private var notifyPort: IONotificationPortRef?

    /// Called on the main thread before sleep. Sleep waits until `ready` is called, for at most
    /// `patience` seconds; the system itself gives up waiting after thirty.
    var onWillSleep: ((_ ready: @escaping () -> Void) -> Void)?
    var onDidWake: (() -> Void)?
    private let patience: TimeInterval = 8

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        root = IORegisterForSystemPower(context, &notifyPort, { context, _, type, argument in
            guard let context else { return }
            Unmanaged<SleepWatcher>.fromOpaque(context).takeUnretainedValue().handle(type, argument)
        }, &notifier)
        guard root != 0, let notifyPort else { return log("cannot watch for sleep") }
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue(), .commonModes)
    }

    private func handle(_ type: UInt32, _ argument: UnsafeMutableRawPointer?) {
        let token = Int(bitPattern: argument)
        switch type {
        case SleepWatcher.canSleep:
            IOAllowPowerChange(root, token)
        case SleepWatcher.willSleep:
            var allowed = false
            let ready = { [root] in
                guard !allowed else { return }
                allowed = true
                IOAllowPowerChange(root, token)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + patience, execute: ready)
            if let onWillSleep { onWillSleep(ready) } else { ready() }
        case SleepWatcher.hasPoweredOn:
            onDidWake?()
        default:
            break
        }
    }
}
