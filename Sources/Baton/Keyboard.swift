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

    // Touched only on the Bluetooth thread.
    private var pending: Completion?
    private var pair: IOBluetoothDevicePair?
    private var deadline: Timer?
    // Touched only on the main thread.
    private var permissionRequest: CBCentralManager?
    private var snapshot: [String: Any] = [:]

    /// Shows the system's Bluetooth permission prompt if it has not been answered yet.
    func requestPermission() {
        guard CBManager.authorization == .notDetermined, permissionRequest == nil else { return }
        permissionRequest = CBCentralManager(delegate: self, queue: DispatchQueue(label: "baton.bluetooth.permission"))
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {}

    /// Runs `command`, reporting the outcome on the main thread.
    func perform(_ command: KeyboardCommand, completion: @escaping Completion) {
        guard CBManager.authorization == .allowedAlways else {
            requestPermission()
            return completion(false, "Bluetooth permission is \(SharedKeyboard.bluetoothPermission) on this Mac")
        }
        let reply: Completion = { ok, detail in DispatchQueue.main.async { completion(ok, detail) } }
        BluetoothThread.shared.async {
            guard let device = IOBluetoothDevice(addressString: command.address) else {
                return reply(false, "bad address \(command.address)")
            }
            switch (command.action, command.strategy) {
            case (.release, .reconnect): self.disconnect(device, reply)
            case (.release, .repair): self.forget(device, reply)
            case (.take, .reconnect): self.connect(device, reply)
            case (.take, .repair): self.pairAndConnect(device, reply)
            }
        }
    }

    private func finish(_ ok: Bool, _ detail: String) {
        deadline?.invalidate()
        deadline = nil
        pair = nil
        let completion = pending
        pending = nil
        completion?(ok, detail)
    }

    private func begin(_ completion: @escaping Completion, timeout: TimeInterval) -> Bool {
        guard pending == nil else {
            completion(false, "another keyboard operation is in progress")
            return false
        }
        pending = completion
        deadline = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            self?.finish(false, "timed out")
        }
        return true
    }

    private func disconnect(_ device: IOBluetoothDevice, _ completion: @escaping Completion) {
        guard device.isConnected() else { return completion(true, "already disconnected") }
        let result = device.closeConnection()
        completion(result == kIOReturnSuccess, result == kIOReturnSuccess ? "disconnected" : "disconnect failed (\(String(result, radix: 16)))")
    }

    /// Removes the pairing, after which the keyboard accepts a new host.
    private func forget(_ device: IOBluetoothDevice, _ completion: @escaping Completion) {
        let remove = Selector(("remove"))
        guard device.responds(to: remove) else { return completion(false, "this macOS cannot unpair devices programmatically") }
        device.perform(remove)
        completion(true, "unpaired")
    }

    private func connect(_ device: IOBluetoothDevice, _ completion: @escaping Completion) {
        if device.isConnected() { return waitUntilAttached(device, completion) }
        guard begin(completion, timeout: 12) else { return }
        let result = device.openConnection(self)
        if result != kIOReturnSuccess { finish(false, "connect failed to start (\(String(result, radix: 16)))") }
    }

    @objc func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        guard let completion = pending else { return }
        guard status == kIOReturnSuccess else { return finish(false, "connect failed (\(String(status, radix: 16)))") }
        deadline?.invalidate()
        pending = nil
        waitUntilAttached(device, completion)
    }

    private func pairAndConnect(_ device: IOBluetoothDevice, _ completion: @escaping Completion) {
        if device.isPaired() { return connect(device, completion) }
        guard begin(completion, timeout: 20), let pair = IOBluetoothDevicePair(device: device) else { return }
        pair.delegate = self
        self.pair = pair
        let result = pair.start()
        if result != kIOReturnSuccess { finish(false, "pairing failed to start (\(String(result, radix: 16)))") }
    }

    func devicePairingPINCodeRequest(_ sender: Any!) {
        var pin = BluetoothPINCode()
        withUnsafeMutableBytes(of: &pin) { $0.copyBytes(from: Array("0000".utf8)) }
        (sender as? IOBluetoothDevicePair)?.replyPINCode(4, pinCode: &pin)
    }

    func devicePairingUserConfirmationRequest(_ sender: Any!, numericValue: BluetoothNumericValue) {
        (sender as? IOBluetoothDevicePair)?.replyUserConfirmation(true)
    }

    func devicePairingFinished(_ sender: Any!, error: IOReturn) {
        guard let completion = pending, let device = (sender as? IOBluetoothDevicePair)?.device() else { return }
        guard error == kIOReturnSuccess else { return finish(false, "pairing failed (\(String(error, radix: 16)))") }
        deadline?.invalidate()
        pending = nil
        pair = nil
        connect(device, completion)
    }

    /// A Bluetooth link is not enough; the keyboard counts as here once its keys can arrive.
    private func waitUntilAttached(_ device: IOBluetoothDevice, _ completion: @escaping Completion) {
        let address = device.addressString ?? ""
        let started = Net.monotonicMillis()
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            if SharedKeyboard.isAttached(address: address) {
                timer.invalidate()
                completion(true, "attached")
            } else if Net.monotonicMillis() - started > 6000 {
                timer.invalidate()
                completion(false, "connected over Bluetooth but never appeared as a keyboard")
            }
        }
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
