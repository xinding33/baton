import CoreGraphics
import Foundation

/// Puts the cursor somewhere without the wait that follows a warp.
///
/// For a quarter of a second after one, the system ignores the mouse. A cursor that had just come
/// back to this Mac sat on the border while the hand moved on, and the first movement the other
/// way took it back across. Reconnecting the mouse and the cursor after the warp is one way to
/// end that wait, and did not end it here. The other is to set the wait to nothing first, with a
/// call that Swift no longer offers by name.
enum CursorPlacement {
    private typealias SetSuppressionInterval = @convention(c) (CFTimeInterval) -> Int32
    private static let setSuppressionInterval: SetSuppressionInterval? = {
        guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "CGSetLocalEventsSuppressionInterval") else {
            log("cursor: CGSetLocalEventsSuppressionInterval not found; the cursor may wait after it is placed")
            return nil
        }
        return unsafeBitCast(symbol, to: SetSuppressionInterval.self)
    }()

    static func warp(to point: CGPoint) {
        _ = setSuppressionInterval?(0)
        CGWarpMouseCursorPosition(point)
    }
}
