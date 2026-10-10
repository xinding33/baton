import BatonCore
import CoreBluetooth
import CoreGraphics
import Foundation
import IOBluetooth
import IOKit

/// The shared keyboard as this Mac sees it.
enum SharedKeyboard {
    private static func bytes(of address: String) -> [UInt8] {
        address.split(whereSeparator: { $0 == "-" || $0 == ":" }).compactMap { UInt8($0, radix: 16) }
    }

    /// Whether the keyboard is attached here as an input device, i.e. its keys arrive on this Mac.
    static func isAttached(address: String) -> Bool {
        let bytes = bytes(of: address)
        guard bytes.count == 6 else { return false }
        // A Bluetooth HID device's location is the low 31 bits of its address.
        let location = (UInt32(bytes[2]) << 24 | UInt32(bytes[3]) << 16 | UInt32(bytes[4]) << 8 | UInt32(bytes[5])) & 0x7FFF_FFFF
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDDevice"), &iterator) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(iterator) }
        var found = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            let id = IORegistryEntryCreateCFProperty(service, "LocationID" as CFString, nil, 0)?.takeRetainedValue() as? NSNumber
            let transport = IORegistryEntryCreateCFProperty(service, "Transport" as CFString, nil, 0)?.takeRetainedValue() as? String
            IOObjectRelease(service)
            if id?.uint32Value == location, transport?.hasPrefix("Bluetooth") == true { found = true }
        }
        return found
    }

    static var bluetoothPermission: String {
        switch CBManager.authorization {
        case .allowedAlways: return "granted"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not asked yet"
        @unknown default: return "unknown"
        }
    }
}

/// Reports when the shared keyboard attaches to or detaches from this Mac.
final class KeyboardPresence {
    private var timer: DispatchSourceTimer?
    private(set) var isPresent = false
    private(set) var address: String?
    var onChange: ((Bool) -> Void)?

    func watch(address: String?) {
        self.address = address
        timer?.cancel()
        timer = nil
        guard let address else { return update(false) }
        update(SharedKeyboard.isAttached(address: address))
        timer = repeatingTimer(every: 0.25) { [weak self] in
            self?.update(SharedKeyboard.isAttached(address: address))
        }
    }

    private func update(_ present: Bool) {
        guard present != isPresent else { return }
        isPresent = present
        log(present ? "shared keyboard attached" : "shared keyboard detached")
        onChange?(present)
    }
}

/// A thread with its own run loop for Bluetooth calls. They can block for seconds, and the main
/// thread carries every mouse and key event, so none of them may run there.
private final class BluetoothThread: Thread {
    static let shared: BluetoothThread = {
        let thread = BluetoothThread()
        thread.name = "baton.bluetooth"
        thread.start()
        return thread
    }()

    override func main() {
        // A port keeps the run loop alive while it waits for work.
        RunLoop.current.add(NSMachPort(), forMode: .default)
        RunLoop.current.run()
    }

    func async(_ work: @escaping () -> Void) {
        perform(#selector(execute(_:)), on: self, with: work as AnyObject, waitUntilDone: false)
    }

    @objc private func execute(_ work: AnyObject) {
        (work as? () -> Void)?()
    }
}

/// Moves the shared keyboard's Bluetooth link to or away from this Mac.
final class KeyboardMover: NSObject, IOBluetoothDevicePairDelegate, CBCentralManagerDelegate {
    typealias Completion = (Bool, String) -> Void

    private var permissionRequest: CBCentralManager?
    private var snapshot: [String: Any] = [:]

    /// Shows the system's Bluetooth permission prompt if it has not been answered yet.
    func requestPermission() {
        guard CBManager.authorization == .notDetermined, permissionRequest == nil else { return }
        permissionRequest = CBCentralManager(delegate: self, queue: DispatchQueue(label: "baton.bluetooth.permission"))
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {}

    /// The single steps a handoff is made of, also usable one at a time for diagnosis.
    enum Step: String {
        case disconnect, forget, connect, pair
    }

    /// Runs `command`, reporting the outcome on the main thread.
    func perform(_ command: KeyboardCommand, completion: @escaping Completion) {
        let steps: [Step]
        switch (command.action, command.strategy) {
        case (.release, .reconnect): steps = [.disconnect]
        case (.release, .repair): steps = [.forget]
        case (.take, .reconnect): steps = [.connect]
        // A pairing record left from an earlier turn is stale once another Mac has paired.
        case (.take, .repair): steps = [.forget, .pair, .connect]
        }
        run(steps, address: command.address, completion: completion)
    }

    /// Runs `steps` in order on the Bluetooth thread, stopping at the first that fails.
    func run(_ steps: [Step], address: String, completion: @escaping Completion) {
        guard CBManager.authorization == .allowedAlways else {
            requestPermission()
            return completion(false, "Bluetooth permission is \(SharedKeyboard.bluetoothPermission) on this Mac")
        }
        BluetoothThread.shared.async {
            var notes: [String] = []
            var ok = true
            for step in steps {
                guard let device = IOBluetoothDevice(addressString: address) else {
                    ok = false
                    notes.append("bad address \(address)")
                    break
                }
                let started = Net.monotonicMillis()
                let (succeeded, note) = self.execute(step, device)
                notes.append("\(step.rawValue): \(note) (\(Net.monotonicMillis() - started) ms)")
                if !succeeded {
                    ok = false
                    break
                }
            }
            let detail = notes.joined(separator: "; ")
            DispatchQueue.main.async { completion(ok, detail) }
        }
    }

    private func code(_ result: IOReturn) -> String {
        "0x" + String(UInt32(bitPattern: result), radix: 16)
    }

    /// Polls until `condition` holds, for at most `seconds`. Runs on the Bluetooth thread.
    private func wait(_ seconds: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    private func execute(_ step: Step, _ device: IOBluetoothDevice) -> (Bool, String) {
        let address = device.addressString ?? ""
        switch step {
        case .disconnect:
            guard device.isConnected() else { return (true, "was not connected") }
            let result = device.closeConnection()
            guard result == kIOReturnSuccess else { return (false, "failed \(code(result))") }
            // The call returns before the link is down; the next Mac must not start until it is.
            let gone = wait(4) { !device.isConnected() && !SharedKeyboard.isAttached(address: address) }
            return (gone, gone ? "done" : "still attached after 4 s")

        case .forget:
            guard device.isPaired() else { return (true, "was not paired") }
            let remove = Selector(("remove"))
            guard device.responds(to: remove) else { return (false, "this macOS cannot unpair devices programmatically") }
            device.perform(remove)
            let gone = wait(4) { !SharedKeyboard.isAttached(address: address) }
            return (gone, gone ? "done" : "still attached after 4 s")

        case .pair:
            // Just after its old host forgets it, the keyboard refuses for a few seconds. Keep asking.
            // A pairing that works takes about a second, so an attempt that hasn't finished in three
            // is abandoned and started again rather than waited out.
            let deadline = Date().addingTimeInterval(18)
            var attempts: [String] = []
            while Date() < deadline {
                let started = Net.monotonicMillis()
                guard let pair = IOBluetoothDevicePair(device: device) else { break }
                pairingResult = nil
                pair.delegate = self
                let result = pair.start()
                var outcome = "failed to start \(code(result))"
                if result == kIOReturnSuccess {
                    if wait(3, until: { pairingResult != nil }), let finished = pairingResult {
                        outcome = finished == kIOReturnSuccess ? "ok" : "failed \(code(finished))"
                    } else {
                        pair.stop()
                        outcome = "abandoned"
                    }
                }
                attempts.append("\(outcome) in \(Net.monotonicMillis() - started) ms")
                if outcome == "ok" { return (true, attempts.joined(separator: ", ")) }
                _ = wait(0.3) { false }
            }
            return (false, attempts.isEmpty ? "could not start" : attempts.joined(separator: ", "))

        case .connect:
            if !device.isConnected() {
                // Page for 5 s (the unit is 0.625 ms) rather than the much longer default.
                let result = device.openConnection(nil, withPageTimeout: 8000, authenticationRequired: false)
                guard result == kIOReturnSuccess else { return (false, "failed \(code(result))") }
            }
            // A Bluetooth link is not enough; the keyboard is here once its keys can arrive.
            let attached = wait(6) { SharedKeyboard.isAttached(address: address) }
            return (attached, attached ? "attached" : "connected over Bluetooth but never appeared as a keyboard")
        }
    }

    // Pairing callbacks, delivered on the Bluetooth thread's run loop.
    private var pairingResult: IOReturn?

    func devicePairingPINCodeRequest(_ sender: Any!) {
        var pin = BluetoothPINCode()
        withUnsafeMutableBytes(of: &pin) { $0.copyBytes(from: Array("0000".utf8)) }
        (sender as? IOBluetoothDevicePair)?.replyPINCode(4, pinCode: &pin)
    }

    func devicePairingUserConfirmationRequest(_ sender: Any!, numericValue: BluetoothNumericValue) {
        (sender as? IOBluetoothDevicePair)?.replyUserConfirmation(true)
    }

    func devicePairingFinished(_ sender: Any!, error: IOReturn) {
        pairingResult = error
    }

    /// What this Mac knows about the keyboard. The Bluetooth details are read in the background,
    /// so they describe the moment of the previous call.
    func describe(address: String) -> [String: Any] {
        var report = snapshot
        report["attached"] = SharedKeyboard.isAttached(address: address)
        report["bluetoothPermission"] = SharedKeyboard.bluetoothPermission
        guard CBManager.authorization == .allowedAlways else {
            requestPermission()
            return report
        }
        BluetoothThread.shared.async { [weak self] in
            guard let device = IOBluetoothDevice(addressString: address) else { return }
            let fresh: [String: Any] = ["name": device.name ?? "", "paired": device.isPaired(), "connected": device.isConnected()]
            DispatchQueue.main.async { self?.snapshot = fresh }
        }
        return report
    }
}

/// Decides, key by key, whether a keystroke stays on this Mac or is forwarded elsewhere.
final class KeyCapture {
    enum Outcome {
        case pass
        case forward(Key)
    }

    /// Keys that went down while input stayed local; their releases must stay local too.
    private var keysDownLocally: Set<UInt16> = []
    private var modifiersDownLocally: Set<UInt16> = []
    private var keysDown: Set<UInt16> = []
    private var modifiersDown: Set<UInt16> = []
    private(set) var lastActivityAt: UInt64 = 0

    var anyKeyDown: Bool { !keysDown.isEmpty || !modifiersDown.isEmpty }

    func process(_ type: CGEventType, _ event: CGEvent, forwarding: Bool) -> Outcome {
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        lastActivityAt = Net.monotonicMillis()
        if type == .flagsChanged {
            guard let flag = Modifier.flag(forKeyCode: code) else { return .pass }
            let down = event.flags.contains(flag) && !modifiersDown.contains(code)
            if down { modifiersDown.insert(code) } else { modifiersDown.remove(code) }
            guard forwarding else {
                if down { modifiersDownLocally.insert(code) } else { modifiersDownLocally.remove(code) }
                return .pass
            }
            if !down, modifiersDownLocally.remove(code) != nil { return .pass }
            return .forward(Key(code: code, down: down, isModifier: true, autorepeat: false, flags: event.flags.rawValue))
        }
        let down = type == .keyDown
        if down { keysDown.insert(code) } else { keysDown.remove(code) }
        guard forwarding else {
            if down { keysDownLocally.insert(code) } else { keysDownLocally.remove(code) }
            return .pass
        }
        if !down, keysDownLocally.remove(code) != nil { return .pass }
        let autorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        return .forward(Key(code: code, down: down, isModifier: false, autorepeat: autorepeat, flags: event.flags.rawValue))
    }

    /// Control-Option-Command-Escape, which always brings the cursor home.
    static func isPanic(code: UInt16, down: Bool, flags: UInt64) -> Bool {
        let wanted: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        return down && code == 53 && CGEventFlags(rawValue: flags).isSuperset(of: wanted)
    }
}

func runBluetoothSteps(_ words: [String], address: String, mover: KeyboardMover) -> String {
    let steps = words.compactMap(KeyboardMover.Step.init(rawValue:))
    guard !steps.isEmpty, steps.count == words.count else { return "usage: bt disconnect|forget|pair|connect ..." }
    mover.run(steps, address: address) { ok, detail in
        log("bt \(words.joined(separator: " ")): \(ok ? "ok" : "FAILED") - \(detail)")
    }
    return "started; see the log"
}
