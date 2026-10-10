import AppKit
import BatonCore
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Runs on the Mac that owns the mouse: decides which machine the cursor is on and routes input there.
final class Anchor {
    enum Focus: Equatable {
        case local
        case remote(String)
    }

    private var config: Config
    let server: AnchorServer
    private var tap: EventTap!
    private var displayWatcher: DisplayWatcher?
    private var timer: DispatchSourceTimer?

    private(set) var focus: Focus = .local
    private(set) var layout = Layout()
    private(set) var paused = false
    private var displays = currentDisplays()
    /// The last displays seen on every machine, so a Mac that is away keeps its place in the layout.
    private var knownDisplays: [String: [DisplayInfo]] = [:]
    private static var knownDisplaysFile: URL { Paths.support.appendingPathComponent("known-displays.json") }
    /// Cursor position on the focused remote machine, in its coordinates.
    private var remotePosition: CGPoint = .zero
    /// Where the local cursor waits, frozen, while the focus is remote.
    private var parkPoint: CGPoint = .zero
    private var lastLocation = cursorLocation()
    private var buttonsDown: Set<Int> = []
    private let keyCapture = KeyCapture()
    private var mediaKeys = MediaKeyCapture()
    /// Replays keys that a client forwards while the cursor is on this Mac.
    private let injector = Injector()
    private var motionSeq: UInt64 = 0

    // The shared keyboard and its handoff between machines.
    private let mover = KeyboardMover()
    private lazy var presence = KeyboardPresence(mover: mover)
    private var focusSince = Net.monotonicMillis()
    private var forwardedKeysDown: Set<UInt16> = []
    private var lastForwardedKeyAt: UInt64 = 0
    private var handoffInProgress: (from: String?, to: String, startedAt: UInt64)?
    private var handoffBlockedUntil: UInt64 = 0
    private var custody = KeyboardCustody()
    private var sleepingPeer: String?
    private var lastPointerActivityAt: UInt64 = 0
    private(set) var lastHandoff = "none yet"
    private var capturing = false
    private var lastCrossingAt: UInt64 = 0
    /// After a crossing the cursor must settle this long before it may cross again, so a hand
    /// resting on the border doesn't bounce it between two machines.
    private let crossingLockoutMs: UInt64 = 150

    var onStateChanged: (() -> Void)?
    /// Pause Sharing was switched. What pauses along with the cursor is told here.
    var onPausedChanged: ((Bool) -> Void)?

    init(config: Config, secret: Data) {
        self.config = config
        server = AnchorServer(config: config, secret: secret)
        tap = EventTap(types: EventTap.pointerAndKeys) { [unowned self] type, event in self.handle(type, event) }
    }

    func start() throws {
        server.onPeersChanged = { [weak self] in self?.rebuildLayout() }
        server.onPeerSleeping = { [weak self] name in self?.sleepingPeer = name }
        server.onPeerLost = { [weak self] name in
            guard let self else { return }
            let asleep = self.sleepingPeer == name
            self.sleepingPeer = nil
            if self.custody.holder == name {
                log("keyboard: \(name) had it and \(asleep ? "went to sleep" : "was lost")")
            }
            self.custody.departed(name, saidGoodbye: asleep, now: Net.monotonicMillis())
            guard self.focus == .remote(name) else { return }
            log("\(name) \(asleep ? "went to sleep" : "was lost") while it had the cursor; bringing the cursor home")
            self.goLocal(at: nil)
        }
        server.onLocalInput = { [weak self] name, point in self?.usedDirectly(name, at: point) }
        server.onForwardedKey = { [weak self] name, key in self?.route(key, from: name) }
        server.onForwardedMediaKey = { [weak self] key in self?.route(key) }
        server.onKeyboardMoved = { [weak self] in self?.onStateChanged?() }
        server.onDisplayPanel = { [weak self] in self?.onStateChanged?() }
        presence.onChange = { [weak self] _ in self?.onStateChanged?() }
        presence.watch(address: config.keyboardAddress)
        if config.keyboardAddress != nil { mover.requestPermission() }
        try server.start()
        displays = currentDisplays()
        if let data = try? Data(contentsOf: Anchor.knownDisplaysFile),
           let known = try? JSONDecoder().decode([String: [DisplayInfo]].self, from: data) {
            knownDisplays = known
        }
        rebuildLayout()
        displayWatcher = DisplayWatcher { [weak self] in
            self?.displays = currentDisplays()
            self?.rebuildLayout()
        }
        startTapWhenPermitted()
        timer = repeatingTimer(every: 0.25) { [weak self] in self?.heartbeat() }
    }

    // MARK: Permissions and the tap

    private func startTapWhenPermitted() {
        if tap.start() {
            return log("event tap active")
        }
        log("event tap unavailable; waiting for Accessibility and Input Monitoring permission")
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        CGRequestListenEventAccess()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self, self.tap.start() else { return }
            timer.invalidate()
            log("event tap active")
            self.onStateChanged?()
        }
    }

    // MARK: Layout

    private func rebuildLayout() {
        var known = knownDisplays
        known[config.name] = displays
        for peer in server.peers.values { known[peer.name] = peer.displays }
        if known != knownDisplays {
            knownDisplays = known
            if let data = try? JSONEncoder().encode(known) {
                try? data.write(to: Anchor.knownDisplaysFile, options: .atomic)
            }
        }
        layout = Layout.resolve(root: config.name, displays: known.mapValues { $0.map(\.frame) }, placements: config.placements)
            .keeping(onlineMachines)
        if !layout.unplaced.isEmpty {
            log("no place in the layout for: \(layout.unplaced.joined(separator: ", "))")
        }
        if case let .remote(name) = focus {
            // The display the local cursor is parked on may have been turned off.
            if let here = layout.machines[config.name] { parkPoint = here.clamp(parkPoint) }
            if let machine = layout.machines[name] {
                remotePosition = machine.clamp(remotePosition)
                // So may the display under the shared cursor, which also shifts the client's
                // coordinates if it was the main one. Say where the cursor is now, or the client's
                // would sit where its system left it until the mouse next moves.
                server.send(name, .move(motion()))
            } else {
                goLocal(at: nil)
            }
        }
        onStateChanged?()
    }

    // MARK: Displays of the other Macs

    var displayPanels: [String: DisplayPanel] { server.peers.compactMapValues(\.displayPanel) }

    func send(_ action: DisplayAction, to machine: String) {
        server.send(machine, .displayAction(action))
    }

    // MARK: Arrangement editing

    var onlineMachines: Set<String> { Set(server.peers.keys).union([config.name]) }

    var knownDisplayNames: [String: [String]] {
        knownDisplays.mapValues { $0.map { "\($0.name) · \(Int($0.frame.width)) × \(Int($0.frame.height))" } }
    }

    func arrangement() -> Arrangement {
        Arrangement(root: config.name, displays: knownDisplays.mapValues { $0.map(\.frame) }, placements: config.placements)
    }

    /// Adopts an edited arrangement and saves it to the config file.
    func apply(_ arrangement: Arrangement) {
        config.placements = arrangement.placements()
        saveConfig()
        log("arrangement changed: " + config.placements.map { "\($0.machine) \($0.side.rawValue) of \($0.of)" }.joined(separator: ", "))
        rebuildLayout()
    }

    private func saveConfig() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(config).write(to: Paths.config, options: .atomic)
        } catch {
            log("could not save the config: \(error)")
        }
    }

    func setShareClipboard(_ value: Bool) {
        config.shareClipboard = value
        saveConfig()
    }

    // For the settings window (SetupWindow.swift).

    var currentConfig: Config { config }
    var handoffRunning: Bool { handoffInProgress != nil }

    /// Changes settings the layout editor does not cover. The file is rewritten whole from this
    /// copy, so whatever changes it goes through here or `apply`.
    func updateConfig(_ edit: (inout Config) -> Void) {
        edit(&config)
        saveConfig()
    }

    func pairedKeyboards(completion: @escaping ([BluetoothKeyboard]?) -> Void) {
        mover.pairedKeyboards(completion: completion)
    }

    // MARK: Focus changes

    private func motion(_ flags: CGEventFlags = []) -> Motion {
        motionSeq += 1
        return Motion(x: remotePosition.x, y: remotePosition.y, seq: motionSeq, flags: flags.rawValue)
    }

    private var mayCross: Bool {
        buttonsDown.isEmpty && Net.monotonicMillis() - lastCrossingAt >= crossingLockoutMs
    }

    private func enterRemote(_ name: String, at point: CGPoint, flags: CGEventFlags) {
        lastCrossingAt = Net.monotonicMillis()
        focusSince = lastCrossingAt
        if focus == .local {
            // Keys a client was holding down on this Mac must not stay down after the cursor leaves.
            injector.releaseAll()
            parkPoint = cursorLocation()
            // Only take the mouse away from the local cursor when its events can be forwarded.
            if tap.isActive {
                CGAssociateMouseAndMouseCursorPosition(0)
                CursorVisibility.hide()
                capturing = true
            }
        } else if case let .remote(previous) = focus {
            server.send(previous, .leave)
        }
        focus = .remote(name)
        remotePosition = point
        server.send(name, .enter(motion(flags)))
        log("cursor -> \(name) at (\(Int(point.x)), \(Int(point.y)))")
        onStateChanged?()
    }

    /// Brings the cursor back to this machine, at `point` or where it was parked.
    func goLocal(at point: CGPoint?) {
        guard case let .remote(name) = focus else { return }
        lastCrossingAt = Net.monotonicMillis()
        focusSince = lastCrossingAt
        server.send(name, .leave)
        focus = .local
        let target = point ?? parkPoint
        if capturing {
            CGWarpMouseCursorPosition(target)
            CGAssociateMouseAndMouseCursorPosition(1)
            CursorVisibility.show()
            capturing = false
        } else {
            CGWarpMouseCursorPosition(target)
        }
        lastLocation = target
        log("cursor -> \(config.name) at (\(Int(target.x)), \(Int(target.y)))")
        onStateChanged?()
    }

    /// A client's own trackpad, mouse or keyboard was used. That is the Mac its user is looking
    /// at, so the shared cursor goes there and carries on from where that Mac's cursor is.
    private func usedDirectly(_ name: String, at point: CGPoint) {
        guard let machine = layout.machines[name] else { return }
        let point = machine.clamp(point)
        if focus == .remote(name) {
            remotePosition = point
        } else if !paused, mayCross, !sharedInputInUse {
            log("\(name) was used directly")
            enterRemote(name, at: point, flags: [])
        }
    }

    /// The shared mouse and keyboard come first: while they are in use, a brush of another Mac's
    /// trackpad must not take the cursor away from under them.
    private var sharedInputInUse: Bool {
        let last = max(lastPointerActivityAt, keyCapture.lastActivityAt, lastForwardedKeyAt)
        return Net.monotonicMillis() - last < 2000
    }

    func setPaused(_ value: Bool) {
        paused = value
        if value { goLocal(at: nil) }
        log(value ? "paused" : "resumed")
        onPausedChanged?(value)
        onStateChanged?()
    }

    private func heartbeat() {
        server.pingAll()
        considerHandoff()
        guard case let .remote(name) = focus, let peer = server.peers[name] else { return }
        let silence = TimeInterval(Net.monotonicMillis() - peer.lastPongAt) / 1000
        if silence > config.timeout(for: name) {
            log("\(name) silent for \(Int(silence * 1000)) ms; bringing the cursor home")
            goLocal(at: nil)
            server.drop(name)
        }
    }

    // MARK: Input

    /// Applies a mouse movement. Returns true if the event that caused it should be swallowed.
    @discardableResult
    private func moved(dx: Double, dy: Double, location: CGPoint, flags: CGEventFlags) -> Bool {
        switch focus {
        case .local:
            let previous = lastLocation
            lastLocation = location
            guard !paused, mayCross else { return false }
            if case let .cross(name, point) = layout.move(on: config.name, from: previous, dx: dx, dy: dy),
               isPressed(location, against: name, dx: dx, dy: dy) {
                enterRemote(name, at: point, flags: flags)
            }
            return false
        case let .remote(name):
            switch layout.move(on: name, from: remotePosition, dx: dx, dy: dy, allowCross: mayCross) {
            case let .stay(point):
                remotePosition = point
                server.sendMotion(name, motion(flags))
            case let .cross(next, point):
                if next == config.name {
                    goLocal(at: point)
                } else {
                    enterRemote(next, at: point, flags: flags)
                }
            }
            // If the system moved the parked cursor anyway, put it back.
            if capturing, abs(location.x - parkPoint.x) > 2 || abs(location.y - parkPoint.y) > 2 {
                CGWarpMouseCursorPosition(parkPoint)
            }
            return true
        }
    }

    /// True if the cursor really is at the edge facing `name`. The remembered previous position goes
    /// stale when something else moves the cursor, and must not cause a crossing on its own.
    private func isPressed(_ location: CGPoint, against name: String, dx: Double, dy: Double) -> Bool {
        let nudge = layout.move(on: config.name, from: location, dx: dx.sign == .minus ? -2 : 2, dy: 0)
        let nudgeDown = layout.move(on: config.name, from: location, dx: 0, dy: dy.sign == .minus ? -2 : 2)
        for result in [nudge, nudgeDown] {
            if case let .cross(machine, _) = result, machine == name { return true }
        }
        return false
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == EventTap.systemDefined {
            var target: String?
            if case let .remote(name) = focus { target = name }
            guard let key = MediaKey(event), mediaKeys.forwards(key, forwarding: target != nil), let target else { return false }
            server.send(target, .mediaKey(key))
            return true
        }
        if type != .keyDown, type != .keyUp, type != .flagsChanged {
            lastPointerActivityAt = Net.monotonicMillis()
        }
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return moved(
                dx: event.getDoubleValueField(.mouseEventDeltaX),
                dy: event.getDoubleValueField(.mouseEventDeltaY),
                location: event.location,
                flags: event.flags
            )

        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp:
            let number = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            let down = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
            if down { buttonsDown.insert(number) } else { buttonsDown.remove(number) }
            guard case let .remote(name) = focus else { return false }
            let clicks = event.getIntegerValueField(.mouseEventClickState)
            server.send(name, .button(Button(at: motion(event.flags), button: number, down: down, clickState: clicks)))
            return true

        case .scrollWheel:
            guard case let .remote(name) = focus else { return false }
            server.send(name, .scroll(Scroll(
                at: motion(event.flags),
                lines1: event.getIntegerValueField(.scrollWheelEventDeltaAxis1),
                lines2: event.getIntegerValueField(.scrollWheelEventDeltaAxis2),
                points1: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),
                points2: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2),
                fixed1: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
                fixed2: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2),
                continuous: event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
                phase: event.getIntegerValueField(.scrollWheelEventScrollPhase),
                momentumPhase: event.getIntegerValueField(.scrollWheelEventMomentumPhase)
            )))
            return true

        case .keyDown, .keyUp, .flagsChanged:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if KeyCapture.isPanic(code: code, down: type == .keyDown, flags: event.flags.rawValue) {
                log("panic hotkey")
                goLocal(at: nil)
                return true
            }
            var target: String?
            if case let .remote(name) = focus { target = name }
            guard case let .forward(key) = keyCapture.process(type, event, forwarding: target != nil), let target else { return false }
            server.send(target, .key(key))
            return true

        default:
            return false
        }
    }

    // MARK: The shared keyboard

    /// A key typed on the shared keyboard while it is attached to a client other than the one
    /// with the cursor. It goes to whichever machine has the cursor.
    private func route(_ key: Key, from name: String) {
        lastForwardedKeyAt = Net.monotonicMillis()
        if !key.isModifier, !key.autorepeat {
            if key.down { forwardedKeysDown.insert(key.code) } else { forwardedKeysDown.remove(key.code) }
        }
        if KeyCapture.isPanic(code: key.code, down: key.down, flags: key.flags) {
            log("panic hotkey (from \(name))")
            return goLocal(at: nil)
        }
        switch focus {
        case .local: injector.key(key)
        case let .remote(target): server.send(target, .key(key))
        }
    }

    /// The same for a volume, brightness or playback key.
    private func route(_ key: MediaKey) {
        lastForwardedKeyAt = Net.monotonicMillis()
        switch focus {
        case .local: injector.mediaKey(key)
        case let .remote(target): server.send(target, .mediaKey(key))
        }
    }

    /// Whether a key forwarded by a client is still held there. A held key repeats, so one whose
    /// release never arrived stops counting once nothing has been heard of it for a while.
    private var forwardedKeyHeld: Bool {
        if !forwardedKeysDown.isEmpty, Net.monotonicMillis() - lastForwardedKeyAt > 3000 { forwardedKeysDown = [] }
        return !forwardedKeysDown.isEmpty
    }

    private var focusName: String {
        if case let .remote(name) = focus { return name }
        return config.name
    }

    /// The machine the shared keyboard is attached to, if it is attached anywhere.
    var keyboardOwner: String? {
        if presence.isPresent { return config.name }
        return server.peers.values.first { $0.keyboardPresent }?.name
    }

    var keyboardFollows: Bool { config.keyboardFollows }

    func setKeyboardFollows(_ value: Bool) {
        config.keyboardFollows = value
        handoffBlockedUntil = 0
        saveConfig()
        log("keyboard follows the cursor: \(value)")
        onStateChanged?()
    }

    /// Moves the keyboard to the machine with the cursor. The keyboard is unusable for the two
    /// seconds or so a handoff takes, and anything typed then is lost, so it only starts when the
    /// cursor has settled, typing has paused, and the mouse is in use: a hand on the mouse is a
    /// hand that is not about to type.
    private func considerHandoff() {
        let now = Net.monotonicMillis()
        let owner = keyboardOwner
        if let owner { custody.attached(to: owner) }
        guard config.keyboardAddress != nil, handoffInProgress == nil, now >= handoffBlockedUntil else { return }
        guard let owner else {
            // Attached nowhere. Nothing typed can be lost, so a claim does not wait for a quiet moment.
            let pairedSomewhere = presence.isPaired || server.peers.values.contains { $0.keyboardPaired }
            if custody.shouldClaim(now: now, pairedSomewhere: pairedSomewhere) {
                moveKeyboard(to: config.keyboardFollows ? focusName : config.name)
            }
            return
        }
        let target = focusName
        let lastKeyAt = max(keyCapture.lastActivityAt, lastForwardedKeyAt)
        guard config.keyboardFollows, !paused, owner != target, now - focusSince >= 1000, now - lastKeyAt >= 1500,
              now - lastPointerActivityAt <= 400, !keyCapture.anyKeyDown, !forwardedKeyHeld else { return }
        moveKeyboard(to: target)
    }

    private func keyboard(_ action: KeyboardCommand.Action, on machine: String, completion: @escaping (Bool, String) -> Void) {
        guard let address = config.keyboardAddress else { return completion(false, "no keyboard configured") }
        if machine == config.name {
            mover.perform(KeyboardCommand(id: 0, action: action, address: address, strategy: config.handoffStrategy), completion: completion)
        } else {
            server.sendKeyboardCommand(machine, action: action, address: address, strategy: config.handoffStrategy, completion: completion)
        }
    }

    /// Hands the keyboard to `target`. If the target cannot take it, the previous owner takes it back.
    @discardableResult
    func moveKeyboard(to target: String) -> String {
        guard config.keyboardAddress != nil else { return "no keyboardAddress in the config" }
        guard handoffInProgress == nil else { return "a handoff is already in progress" }
        guard onlineMachines.contains(target) else { return "\(target) is not connected" }
        let owner = keyboardOwner
        guard owner != target else { return "the keyboard is already on \(target)" }
        let startedAt = Net.monotonicMillis()
        handoffInProgress = (owner, target, startedAt)
        custody.handoffStarted()
        log("keyboard: \(owner ?? "nowhere") -> \(target) (\(config.handoffStrategy.rawValue))")
        onStateChanged?()

        let take = { [weak self] in
            guard let self else { return }
            self.keyboard(.take, on: target) { ok, detail in
                let elapsed = Net.monotonicMillis() - startedAt
                if ok {
                    log("keyboard: \(target) took it (\(detail))")
                    self.finishHandoff("moved to \(target) in \(elapsed) ms", blockFor: 0)
                } else if let owner {
                    log("keyboard: \(target) could not take it (\(detail)); returning it to \(owner)")
                    self.keyboard(.take, on: owner) { ok, back in
                        self.finishHandoff("\(target) failed (\(detail)); \(ok ? "returned to \(owner)" : "could not return it to \(owner): \(back)")", blockFor: 20000)
                    }
                } else {
                    // Probably switched off or out of range. Keep trying, but less and less often.
                    let wait = self.custody.claimFailed()
                    self.finishHandoff("\(target) failed (\(detail)); next try in \(wait / 1000) s", blockFor: wait)
                }
            }
        }
        if let owner {
            keyboard(.release, on: owner) { ok, detail in
                if !ok { log("keyboard: \(owner) could not release it (\(detail)); trying to take it anyway") }
                take()
            }
        } else {
            take()
        }
        return "moving the keyboard to \(target)"
    }

    private func finishHandoff(_ outcome: String, blockFor: UInt64) {
        handoffInProgress = nil
        handoffBlockedUntil = Net.monotonicMillis() + blockFor
        lastHandoff = outcome
        log("keyboard: \(outcome)")
        onStateChanged?()
    }

    /// What the updater looks at to pick a moment for a restart (Updates.swift).
    var restartConditions: RestartConditions {
        let now = Net.monotonicMillis()
        return RestartConditions(
            handoffInProgress: handoffInProgress != nil || mover.isBusy,
            keysDown: keyCapture.anyKeyDown || forwardedKeyHeld,
            buttonsDown: !buttonsDown.isEmpty,
            msSinceKey: now - max(keyCapture.lastActivityAt, lastForwardedKeyAt),
            msSincePointer: now - lastPointerActivityAt
        )
    }

    /// Runs single Bluetooth steps on this Mac; the outcome goes to the log.
    func bluetoothSteps(_ words: [String]) -> String {
        guard let address = config.keyboardAddress else { return "no keyboardAddress in the config" }
        return runBluetoothSteps(words, address: address, mover: mover)
    }

    func keyboardCommand(_ words: [String]) -> String {
        switch words.first {
        case "move":
            guard words.count == 2 else { return "usage: keyboard move <machine>" }
            return moveKeyboard(to: words[1])
        case "follow":
            guard words.count == 2, ["on", "off"].contains(words[1]) else { return "usage: keyboard follow on|off" }
            setKeyboardFollows(words[1] == "on")
        case nil:
            break
        default:
            return "usage: keyboard [move <machine> | follow on|off]"
        }
        var report: [String: Any] = [
            "owner": keyboardOwner ?? "nowhere",
            "pairedWith": ([config.name: presence.isPaired].merging(server.peers.mapValues(\.keyboardPaired)) { a, _ in a })
                .filter(\.value).keys.sorted(),
            "follows": config.keyboardFollows,
            "strategy": config.handoffStrategy.rawValue,
            "lastHandoff": lastHandoff,
            "handoffInProgress": handoffInProgress.map { "\($0.from ?? "nowhere") -> \($0.to)" } ?? "no",
        ]
        if let address = config.keyboardAddress { report["here"] = mover.describe(address: address) }
        return jsonString(report)
    }

    // MARK: Control commands

    /// Feeds synthetic input through the same paths as real input, for testing without touching the mouse.
    func simulate(_ words: [String]) -> String {
        switch words.first {
        case "move":
            guard words.count == 3, let dx = Double(words[1]), let dy = Double(words[2]) else { return "usage: sim move <dx> <dy>" }
            if focus == .local {
                let here = cursorLocation()
                lastLocation = here
                if case let .stay(point) = layout.move(on: config.name, from: here, dx: dx, dy: dy) {
                    CGWarpMouseCursorPosition(point)
                    lastLocation = point
                } else {
                    let edge = layout.machines[config.name]?.clamp(CGPoint(x: here.x + dx, y: here.y + dy)) ?? here
                    CGWarpMouseCursorPosition(edge)
                    moved(dx: dx, dy: dy, location: edge, flags: [])
                }
            } else {
                moved(dx: dx, dy: dy, location: parkPoint, flags: [])
            }
        case "enter":
            guard words.count == 2, let machine = layout.machines[words[1]], words[1] != config.name else { return "usage: sim enter <machine>" }
            let bounds = machine.displays[0]
            enterRemote(words[1], at: CGPoint(x: bounds.midX, y: bounds.midY), flags: [])
        case "click":
            guard case let .remote(name) = focus else { return "the cursor is local" }
            server.send(name, .button(Button(at: motion(), button: 0, down: true, clickState: 1)))
            server.send(name, .button(Button(at: motion(), button: 0, down: false, clickState: 1)))
        case "key":
            guard case let .remote(name) = focus else { return "the cursor is local" }
            guard words.count == 2, let code = UInt16(words[1]) else { return "usage: sim key <keycode>" }
            server.send(name, .key(Key(code: code, down: true, isModifier: false, autorepeat: false, flags: 0)))
            server.send(name, .key(Key(code: code, down: false, isModifier: false, autorepeat: false, flags: 0)))
        case "scroll":
            guard case let .remote(name) = focus else { return "the cursor is local" }
            guard words.count == 2, let lines = Int64(words[1]) else { return "usage: sim scroll <lines>" }
            server.send(name, .scroll(Scroll(at: motion(), lines1: lines, lines2: 0, points1: lines * 10, points2: 0, fixed1: Double(lines), fixed2: 0, continuous: false, phase: 0, momentumPhase: 0)))
        default:
            return "usage: sim move|enter|click|key|scroll ..."
        }
        return status()
    }

    func status() -> String {
        var focusName = config.name
        var position = cursorLocation()
        if case let .remote(name) = focus {
            focusName = name
            position = remotePosition
        }
        let peers = server.peers.values.sorted { $0.name < $1.name }.map { peer -> [String: Any] in
            [
                "name": peer.name,
                "rttMs": (peer.rttMs * 10).rounded() / 10,
                "datagrams": peer.datagramsUp,
                "displays": peer.displays.map { "\($0.name) \(Int($0.frame.width))x\(Int($0.frame.height)) at (\(Int($0.frame.minX)),\(Int($0.frame.minY)))" },
            ]
        }
        let placed = layout.machines.values.sorted { $0.name < $1.name }.map { machine -> String in
            let b = machine.virtualBounds
            return "\(machine.name): x \(Int(b.minX))..\(Int(b.maxX)), y \(Int(b.minY))..\(Int(b.maxY))"
        }
        let report: [String: Any] = [
            "name": config.name,
            "role": "anchor",
            "focus": focusName,
            "cursor": [Int(position.x), Int(position.y)],
            "paused": paused,
            "tapActive": tap.isActive,
            "accessibility": AXIsProcessTrusted(),
            "inputMonitoring": CGPreflightListenEventAccess(),
            "secureInput": IsSecureEventInputEnabled(),
            "keyboard": keyboardOwner ?? "nowhere",
            "displays": displays.map { "\($0.name) \(Int($0.frame.width))x\(Int($0.frame.height)) at (\(Int($0.frame.minX)),\(Int($0.frame.minY)))" },
            "peers": peers,
            "layout": placed,
            "unplaced": layout.unplaced,
        ]
        return jsonString(report)
    }

    var peerNames: [String] { server.peers.keys.sorted() }
}

func jsonString(_ object: Any) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    return String(decoding: data, as: UTF8.self)
}
