import CoreGraphics
import Foundation

/// An active tap on the HID event stream. The handler returns true to swallow an event.
final class EventTap {
    typealias Handler = (CGEventType, CGEvent) -> Bool

    static let pointerAndKeys: [CGEventType] = [
        .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
        .scrollWheel,
    ] + keys
    static let keys: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]

    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private let types: [CGEventType]
    private let handler: Handler

    init(types: [CGEventType], handler: @escaping Handler) {
        self.types = types
        self.handler = handler
    }

    var isActive: Bool {
        port.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
    }

    /// Fails until the app has been granted Accessibility and Input Monitoring.
    func start() -> Bool {
        guard port == nil else { return true }
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let tap = Unmanaged<EventTap>.fromOpaque(refcon!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                log("event tap disabled (\(type.rawValue)), re-enabling")
                if let port = tap.port { CGEvent.tapEnable(tap: port, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            // Events this app replayed are not input to capture again.
            if event.getIntegerValueField(.eventSourceUserData) == Injector.marker {
                return Unmanaged.passUnretained(event)
            }
            // Wake All Macs is the same hotkey on every Mac, whichever role its tap serves.
            if WakeTogether.shared.consumes(type, event) { return nil }
            return tap.handler(type, event) ? nil : Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.port = port
        source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }
}

/// Hides the cursor even though this app is never frontmost, which the public API alone won't do.
enum CursorVisibility {
    private static var hidden = false
    static var isHidden: Bool { hidden }
    private static let allowBackgroundControl: Void = {
        typealias DefaultConnection = @convention(c) () -> Int32
        typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        guard let handle = dlopen(nil, RTLD_NOW),
              let connectionSymbol = dlsym(handle, "_CGSDefaultConnection"),
              let propertySymbol = dlsym(handle, "CGSSetConnectionProperty")
        else { return log("cursor hiding unavailable: private symbols not found") }
        let connection = unsafeBitCast(connectionSymbol, to: DefaultConnection.self)()
        _ = unsafeBitCast(propertySymbol, to: SetProperty.self)(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }()

    static func hide() {
        guard !hidden else { return }
        _ = allowBackgroundControl
        hidden = CGDisplayHideCursor(CGMainDisplayID()) == .success
    }

    static func show() {
        guard hidden else { return }
        CGDisplayShowCursor(CGMainDisplayID())
        hidden = false
    }
}

enum Modifier {
    /// The flag a modifier key controls, by virtual key code.
    static func flag(forKeyCode code: UInt16) -> CGEventFlags? {
        switch code {
        case 54, 55: return .maskCommand
        case 56, 60: return .maskShift
        case 58, 61: return .maskAlternate
        case 59, 62: return .maskControl
        case 57: return .maskAlphaShift
        case 63: return .maskSecondaryFn
        default: return nil
        }
    }
}
