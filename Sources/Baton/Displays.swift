import AppKit
import BatonCore
import CoreGraphics

func currentDisplays() -> [DisplayInfo] {
    // Online rather than active displays, so a sleeping screen stays in the layout.
    var count: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &ids, &count)
    var names: [CGDirectDisplayID: String] = [:]
    for screen in NSScreen.screens {
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            names[number.uint32Value] = screen.localizedName
        }
    }
    return ids.prefix(Int(count)).compactMap { id in
        // A mirror shows another display's contents and has no area of its own.
        guard CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay else { return nil }
        let uuid = CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? ""
        let mm = CGDisplayScreenSize(id)
        return DisplayInfo(
            id: id,
            uuid: uuid,
            name: names[id] ?? "Display \(id)",
            frame: CGDisplayBounds(id),
            pixelWidth: CGDisplayPixelsWide(id),
            pixelHeight: CGDisplayPixelsHigh(id),
            mmWidth: mm.width,
            mmHeight: mm.height,
            isMain: CGDisplayIsMain(id) != 0
        )
    }
}

func cursorLocation() -> CGPoint {
    CGEvent(source: nil)?.location ?? .zero
}

/// Calls `handler` on the main queue shortly after the display arrangement settles.
final class DisplayWatcher {
    private var pending: DispatchWorkItem?
    private var observer: NSObjectProtocol?

    init(handler: @escaping () -> Void) {
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.pending?.cancel()
            let work = DispatchWorkItem(block: handler)
            self?.pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
