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

    private let config: Config
    private let server: AnchorServer
    private var tap: EventTap!
    private var displayWatcher: DisplayWatcher?
    private var timer: Timer?

    private(set) var focus: Focus = .local
    private(set) var layout = Layout()
    private(set) var paused = false
    private var displays = currentDisplays()
    /// Cursor position on the focused remote machine, in its coordinates.
    private var remotePosition: CGPoint = .zero
    /// Where the local cursor waits, frozen, while the focus is remote.
    private var parkPoint: CGPoint = .zero
    private var lastLocation = cursorLocation()
    private var buttonsDown: Set<Int> = []
    /// Keys that went down while the focus was local; their releases must stay local too.
    private var keysDownLocally: Set<UInt16> = []
    private var modifiersDownLocally: Set<UInt16> = []
    private var modifiersDown: Set<UInt16> = []
    private var motionSeq: UInt64 = 0
    private var capturing = false

    var onStateChanged: (() -> Void)?

    init(config: Config, secret: Data) {
        self.config = config
        server = AnchorServer(config: config, secret: secret)
        tap = EventTap { [unowned self] type, event in self.handle(type, event) }
    }

    func start() throws {
        server.onPeersChanged = { [weak self] in self?.rebuildLayout() }
        server.onPeerLost = { [weak self] name in
            guard let self, self.focus == .remote(name) else { return }
            log("\(name) was lost while it had the cursor; bringing the cursor home")
            self.goLocal(at: nil)
        }
        try server.start()
        displays = currentDisplays()
        rebuildLayout()
        displayWatcher = DisplayWatcher { [weak self] in
            self?.displays = currentDisplays()
            self?.rebuildLayout()
        }
        startTapWhenPermitted()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.heartbeat() }
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
        var rects = [config.name: displays.map(\.frame)]
        for peer in server.peers.values { rects[peer.name] = peer.displays.map(\.frame) }
        layout = Layout.resolve(root: config.name, displays: rects, placements: config.placements)
        if !layout.unplaced.isEmpty {
            log("no place in the layout for: \(layout.unplaced.joined(separator: ", "))")
        }
        if case let .remote(name) = focus {
            if let machine = layout.machines[name] {
                remotePosition = machine.clamp(remotePosition)
            } else {
                goLocal(at: nil)
            }
        }
        onStateChanged?()
    }

    // MARK: Focus changes

    private func motion(_ flags: CGEventFlags = []) -> Motion {
        motionSeq += 1
        return Motion(x: remotePosition.x, y: remotePosition.y, seq: motionSeq, flags: flags.rawValue)
    }

    private func enterRemote(_ name: String, at point: CGPoint, flags: CGEventFlags) {
        if focus == .local {
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

    func setPaused(_ value: Bool) {
        paused = value
        if value { goLocal(at: nil) }
        log(value ? "paused" : "resumed")
        onStateChanged?()
    }

    private func heartbeat() {
        server.pingAll()
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
            guard !paused, buttonsDown.isEmpty else { return false }
            if case let .cross(name, point) = layout.move(on: config.name, from: previous, dx: dx, dy: dy),
               isPressed(location, against: name, dx: dx, dy: dy) {
                enterRemote(name, at: point, flags: flags)
            }
            return false
        case let .remote(name):
            switch layout.move(on: name, from: remotePosition, dx: dx, dy: dy, allowCross: buttonsDown.isEmpty) {
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

        case .keyDown, .keyUp:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let down = type == .keyDown
            // Control-Option-Command-Escape always brings the cursor home.
            let panicFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
            if down, code == 53, event.flags.isSuperset(of: panicFlags) {
                log("panic hotkey")
                goLocal(at: nil)
                return true
            }
            guard case let .remote(name) = focus else {
                if down { keysDownLocally.insert(code) } else { keysDownLocally.remove(code) }
                return false
            }
            if !down, keysDownLocally.remove(code) != nil { return false }
            let autorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            server.send(name, .key(Key(code: code, down: down, isModifier: false, autorepeat: autorepeat, flags: event.flags.rawValue)))
            return true

        case .flagsChanged:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            guard let flag = Modifier.flag(forKeyCode: code) else { return false }
            let down = event.flags.contains(flag) && !modifiersDown.contains(code)
            if down { modifiersDown.insert(code) } else { modifiersDown.remove(code) }
            guard case let .remote(name) = focus else {
                if down { modifiersDownLocally.insert(code) } else { modifiersDownLocally.remove(code) }
                return false
            }
            if !down, modifiersDownLocally.remove(code) != nil { return false }
            server.send(name, .key(Key(code: code, down: down, isModifier: true, autorepeat: false, flags: event.flags.rawValue)))
            return true

        default:
            return false
        }
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
