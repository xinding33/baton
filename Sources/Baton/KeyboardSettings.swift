import AppKit
import BatonCore
import CoreBluetooth

/// The Keyboard pane of the anchor's Settings: which Bluetooth keyboard the Macs share, and how
/// it gets from one to the other. The shared clipboard's rows come after the keyboard's.
final class KeyboardSettings {
    private let anchor: Anchor

    // What a test replaces, so that it neither asks Bluetooth nor restarts.
    var bluetoothAllowed: () -> Bool = { CBManager.authorization == .allowedAlways }
    var writtenConfig: () -> Config? = { try? loadConfig() }
    var relaunch: () -> Void = { Relaunch.now() }

    /// The Bluetooth keyboards paired with this Mac, once they have been read.
    var keyboards: [BluetoothKeyboard]?
    private var reading = false
    /// The keyboard picked in the pane. It is the shared one only after Apply and Restart.
    private var picked: String?
    private var failure: String?
    /// What the pane shows has changed.
    var onStateChanged: (() -> Void)?
    /// The shared clipboard's rows, which end the pane.
    var clipboardRows: () -> [SettingsRow] = { [] }

    init(anchor: Anchor) {
        self.anchor = anchor
        picked = saved
    }

    private var saved: String? {
        anchor.currentConfig.keyboardAddress.map { BluetoothAddress.normalize($0) ?? $0 }
    }

    private(set) lazy var pane: FormPane = {
        let pane = FormPane(id: StatusMenu.Pane.keyboard, title: "Keyboard", symbol: "keyboard") { [unowned self] in self.rows() + self.clipboardRows() }
        // A choice that was not applied does not survive closing the window.
        pane.onOpen = { [unowned self] in
            self.picked = self.saved
            self.failure = nil
            self.keyboards = nil
        }
        return pane
    }()

    /// IOBluetooth is only asked on its own thread, and only once Bluetooth is allowed.
    private func readKeyboards() {
        guard keyboards == nil, !reading, bluetoothAllowed() else { return }
        reading = true
        anchor.pairedKeyboards { [weak self] keyboards in
            guard let self else { return }
            self.reading = false
            self.keyboards = keyboards
            if keyboards != nil { self.onStateChanged?() }
        }
    }

    private static let strategies: [(HandoffStrategy, title: String, detail: String)] = [
        (.reconnect, "Reconnect", "The Mac that has the keyboard drops its connection and the other one connects. Both stay paired with it."),
        (.repair, "Forget and pair again", "The Mac that has the keyboard forgets it, and the other one pairs with it afresh."),
    ]

    func rows() -> [SettingsRow] {
        readKeyboards()
        let config = anchor.currentConfig
        let saved = self.saved
        let entries = KeyboardChoices.entries(paired: keyboards ?? [], configured: picked ?? saved)
        let note: String
        if !bluetoothAllowed() {
            note = "Allow Bluetooth under General to see the keyboards paired with this Mac."
        } else if keyboards == nil {
            note = "Reading the keyboards paired with this Mac…"
        } else if keyboards?.isEmpty == true {
            note = "No Bluetooth keyboard is paired with this Mac. Pair it in System Settings › Bluetooth, then open this window again."
        } else {
            note = "Baton follows this keyboard from Mac to Mac, so that its keys reach the Mac the cursor is on."
        }
        var rows: [SettingsRow] = [
            .header("Shared keyboard"),
            .choice("Keyboard", options: entries.map(\.title), selected: entries.firstIndex { $0.address == picked } ?? 0, detail: note) { [unowned self] index in
                guard entries.indices.contains(index) else { return }
                self.picked = entries[index].address
                self.failure = nil
                self.onStateChanged?()
            },
        ]
        if picked != saved {
            rows.append(.button("Apply and Restart", detail: "Baton restarts on this Mac to use this keyboard. The cursor comes back to this Mac while it does.") { [unowned self] in
                self.apply()
            })
        }
        if let failure { rows.append(.note(failure)) }

        let strategy = KeyboardSettings.strategies.firstIndex { $0.0 == config.handoffStrategy } ?? 0
        rows += [
            .header("Moving between Macs"),
            .toggle("Keyboard follows the cursor", on: config.keyboardFollows, enabled: saved != nil,
                    detail: "Also moves the keyboard’s own Bluetooth connection to the Mac the cursor settles on. That takes about two seconds, and waits for a pause in typing.") { [unowned self] on in
                self.anchor.setKeyboardFollows(on)
            },
            .choice("To move it", options: KeyboardSettings.strategies.map(\.title), selected: strategy, enabled: saved != nil,
                    detail: KeyboardSettings.strategies[strategy].detail) { [unowned self] index in
                guard KeyboardSettings.strategies.indices.contains(index) else { return }
                let chosen = KeyboardSettings.strategies[index].0
                self.anchor.updateConfig { $0.handoffStrategy = chosen }
                log("keyboard: handoffs now \(chosen.rawValue)")
                self.onStateChanged?()
            },
            .text("For all your Macs, and kept on this one, which has the keyboard to begin with."),
        ]
        return rows
    }

    private func apply() {
        defer { onStateChanged?() }
        guard !anchor.handoffRunning else {
            failure = "The keyboard is moving between Macs just now. Try again in a moment."
            return
        }
        let address = picked
        // The anchor rewrites the whole file from its own copy, so its copy is what changes.
        anchor.updateConfig { $0.keyboardAddress = address }
        // It only logs a failure to write, and a restart would then bring the old keyboard back.
        guard let written = writtenConfig(), written.keyboardAddress == address else {
            failure = "That could not be saved: config.json could not be written. The log says why."
            return
        }
        log("shared keyboard changed; restarting to apply it")
        anchor.goLocal(at: nil)
        relaunch()
    }
}
