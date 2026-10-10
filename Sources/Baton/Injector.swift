import BatonCore
import CoreGraphics
import Foundation
import IOKit.pwr_mgt

/// Replays the anchor's input on this machine as if a mouse and keyboard were attached.
final class Injector {
    /// Stamped on every replayed event so the event taps can tell it from real input.
    static let marker: Int64 = 0x4261_746F_6E

    private let source = CGEventSource(stateID: .hidSystemState)
    private var buttonsDown: Set<Int> = []
    private var keysDown: Set<UInt16> = []
    private var modifiersDown: Set<UInt16> = []
    private var position: CGPoint = cursorLocation()
    private(set) var injected = 0

    private func post(_ event: CGEvent?, flags: UInt64) {
        guard let event else { return }
        event.flags = CGEventFlags(rawValue: flags)
        event.setIntegerValueField(.eventSourceUserData, value: Injector.marker)
        event.post(tap: .cghidEventTap)
        injected += 1
    }

    private func mouseButton(_ number: Int) -> CGMouseButton {
        CGMouseButton(rawValue: UInt32(number)) ?? .center
    }

    func wake() {
        var assertion: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("Baton cursor arrived" as CFString, kIOPMUserActiveLocal, &assertion)
    }

    func move(to motion: Motion) {
        let target = CGPoint(x: motion.x, y: motion.y)
        let type: CGEventType
        let button: Int
        if buttonsDown.contains(0) {
            (type, button) = (.leftMouseDragged, 0)
        } else if buttonsDown.contains(1) {
            (type, button) = (.rightMouseDragged, 1)
        } else if let other = buttonsDown.min() {
            (type, button) = (.otherMouseDragged, other)
        } else {
            (type, button) = (.mouseMoved, 0)
        }
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: target, mouseButton: mouseButton(button))
        event?.setIntegerValueField(.mouseEventDeltaX, value: Int64((target.x - position.x).rounded()))
        event?.setIntegerValueField(.mouseEventDeltaY, value: Int64((target.y - position.y).rounded()))
        position = target
        post(event, flags: motion.flags)
    }

    func button(_ b: Button) {
        let target = CGPoint(x: b.at.x, y: b.at.y)
        let type: CGEventType
        switch (b.button, b.down) {
        case (0, true): type = .leftMouseDown
        case (0, false): type = .leftMouseUp
        case (1, true): type = .rightMouseDown
        case (1, false): type = .rightMouseUp
        case (_, true): type = .otherMouseDown
        case (_, false): type = .otherMouseUp
        }
        if b.down { buttonsDown.insert(b.button) } else { buttonsDown.remove(b.button) }
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: target, mouseButton: mouseButton(b.button))
        event?.setIntegerValueField(.mouseEventClickState, value: b.clickState)
        position = target
        post(event, flags: b.at.flags)
    }

    func scroll(_ s: Scroll) {
        let units: CGScrollEventUnit = s.continuous ? .pixel : .line
        let wheel1 = Int32(clamping: s.continuous ? s.points1 : s.lines1)
        let wheel2 = Int32(clamping: s.continuous ? s.points2 : s.lines2)
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: units, wheelCount: 2, wheel1: wheel1, wheel2: wheel2, wheel3: 0) else { return }
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: s.lines1)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: s.lines2)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: s.fixed1)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: s.fixed2)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: s.points1)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: s.points2)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: s.continuous ? 1 : 0)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: s.phase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: s.momentumPhase)
        event.location = CGPoint(x: s.at.x, y: s.at.y)
        post(event, flags: s.at.flags)
    }

    func key(_ k: Key) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: k.code, keyDown: k.down) else { return }
        if k.isModifier {
            event.type = .flagsChanged
            if k.down { modifiersDown.insert(k.code) } else { modifiersDown.remove(k.code) }
        } else {
            event.setIntegerValueField(.keyboardEventAutorepeat, value: k.autorepeat ? 1 : 0)
            if k.down { keysDown.insert(k.code) } else { keysDown.remove(k.code) }
        }
        post(event, flags: k.flags)
    }

    /// Lets go of everything still held, so nothing sticks when the cursor leaves or the link drops.
    func releaseAll() {
        for code in keysDown {
            key(Key(code: code, down: false, isModifier: false, autorepeat: false, flags: 0))
        }
        for code in modifiersDown {
            key(Key(code: code, down: false, isModifier: true, autorepeat: false, flags: 0))
        }
        for number in buttonsDown {
            button(Button(at: Motion(x: position.x, y: position.y, seq: 0), button: number, down: false, clickState: 1))
        }
    }
}
