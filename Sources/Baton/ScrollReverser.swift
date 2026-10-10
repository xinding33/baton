import AppKit
import BatonCore
import CoreGraphics
import Foundation

/// Reverses the mouse wheel on this Mac and leaves trackpads alone, as Backspin does.
///
/// A scroll is reversed once, on the Mac it lands on. One made by a device attached to that Mac
/// passes through `tap`. One made on the anchor while the cursor is elsewhere is forwarded, and
/// is reversed as `Injector` replays it, because the taps skip the events Baton posts.
final class ScrollReverser: NSObject {
    static let shared = ScrollReverser()
    private static var settingsFile: URL { Paths.support.appendingPathComponent("scroll.json") }

    private(set) var settings = ScrollSettings()
    /// Another app reversing the wheel on this Mac right now.
    private(set) var rival: ScrollRival?
    private var tap: EventTap!
    private var appsObservation: NSKeyValueObservation?
    private var forwarding: () -> Bool = { false }
    private var counts: [String: Int] = [:]
    private var lastEvent: [String: Any] = [:]

    var onStateChanged: (() -> Void)?

    private override init() {
        super.init()
        tap = EventTap(types: [.scrollWheel]) { [unowned self] _, event in
            self.passing(event)
            return false
        }
    }

    /// `forwarding` is true while scrolls made on this Mac are sent to another one: on the anchor,
    /// while the cursor is away.
    func start(forwarding: @escaping () -> Bool) {
        self.forwarding = forwarding
        if let data = try? Data(contentsOf: Self.settingsFile), let saved = try? JSONDecoder().decode(ScrollSettings.self, from: data) {
            settings = saved
        }
        log("scroll: reversing the wheel is \(settings.enabled ? "on" : "off") (vertical \(settings.vertical), horizontal \(settings.horizontal))")
        watchRivals()
        startTapWhenPermitted()
    }

    /// Keeps `rival` current. Menu bar apps such as Backspin post no launch or quit notification;
    /// observing the list of running apps, which changes on the main run loop, is the only way
    /// to hear of them.
    func watchRivals() {
        appsObservation = NSWorkspace.shared.observe(\.runningApplications, options: [.initial]) { [weak self] workspace, _ in
            self?.update(rival: ScrollRival.running(among: workspace.runningApplications.compactMap(\.bundleIdentifier)))
        }
    }

    private func startTapWhenPermitted() {
        guard !tap.start() else { return log("scroll tap active") }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self, self.tap.start() else { return }
            timer.invalidate()
            log("scroll tap active")
            self.onStateChanged?()
        }
    }

    private func update(rival now: ScrollRival?) {
        guard now != rival else { return }
        rival = now
        log(now.map { "scroll: \($0.rawValue) is running; leaving the wheel to it" } ?? "scroll: no other app is reversing the wheel; Baton reverses it")
        onStateChanged?()
    }

    // MARK: Scroll events

    /// A scroll made on this Mac, on its way to the window server.
    private func passing(_ event: CGEvent) {
        // The Mac these are forwarded to reverses them.
        guard !forwarding() else { return }
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let axes = settings.axes(continuous: continuous, rival: rival)
        record("local", reversed: axes != nil, [
            "continuous": continuous,
            "lines": [event.getIntegerValueField(.scrollWheelEventDeltaAxis1), event.getIntegerValueField(.scrollWheelEventDeltaAxis2)],
            "phase": event.getIntegerValueField(.scrollWheelEventScrollPhase),
            "momentumPhase": event.getIntegerValueField(.scrollWheelEventMomentumPhase),
            "sourcePID": event.getIntegerValueField(.eventSourceUnixProcessID),
        ])
        axes?.reverse(event)
    }

    /// A scroll the anchor forwarded, as this Mac should replay it.
    func arriving(_ scroll: Scroll) -> Scroll {
        let axes = settings.axes(continuous: scroll.continuous, rival: rival)
        record("forwarded", reversed: axes != nil, [
            "continuous": scroll.continuous,
            "lines": [scroll.lines1, scroll.lines2],
            "phase": scroll.phase,
            "momentumPhase": scroll.momentumPhase,
        ])
        return axes.map { $0.reverse(scroll) } ?? scroll
    }

    /// Kept for `ctl scroll`, to check by hand what a device sent and what became of it.
    private func record(_ origin: String, reversed: Bool, _ event: [String: Any]) {
        counts[origin + (reversed ? "Reversed" : "Untouched"), default: 0] += 1
        lastEvent = event.merging(["from": origin, "reversed": reversed]) { $1 }
    }

    // MARK: Settings

    private func change(_ edit: (inout ScrollSettings) -> Void) {
        edit(&settings)
        do {
            try JSONEncoder().encode(settings).write(to: Self.settingsFile, options: .atomic)
        } catch {
            log("could not save the scroll settings: \(error)")
        }
        log("scroll: reversing the wheel is \(settings.enabled ? "on" : "off") (vertical \(settings.vertical), horizontal \(settings.horizontal))")
        onStateChanged?()
    }

    @objc private func toggleEnabled() { change { $0.enabled.toggle() } }
    @objc private func toggleVertical() { change { $0.vertical.toggle() } }
    @objc private func toggleHorizontal() { change { $0.horizontal.toggle() } }

    func addMenuItems(to menu: NSMenu) {
        menu.addItem(.separator())
        let toggles: [(String, Selector, Bool, Int)] = [
            ("Reverse Mouse Wheel", #selector(toggleEnabled), settings.enabled, 0),
            ("Vertical", #selector(toggleVertical), settings.vertical, 1),
            ("Horizontal", #selector(toggleHorizontal), settings.horizontal, 1),
        ]
        for (title, action, on, level) in toggles {
            // An item without an action is greyed out, as the axes are while reversing is off.
            let item = menu.addItem(withTitle: title, action: level == 0 || settings.enabled ? action : nil, keyEquivalent: "")
            item.target = self
            item.state = on ? .on : .off
            item.indentationLevel = level
        }
        if let note = settings.note(rival: rival, tapActive: tap.isActive) {
            menu.addItem(withTitle: note, action: nil, keyEquivalent: "")
        }
    }

    // MARK: Control commands

    func command(_ words: [String]) -> String {
        switch (words.first, words.count) {
        case (nil, _):
            break
        case ("on", 1), ("off", 1):
            change { $0.enabled = words[0] == "on" }
        case ("vertical", 2) where ["on", "off"].contains(words[1]):
            change { $0.vertical = words[1] == "on" }
        case ("horizontal", 2) where ["on", "off"].contains(words[1]):
            change { $0.horizontal = words[1] == "on" }
        default:
            return "usage: scroll [on|off | vertical on|off | horizontal on|off]"
        }
        return status()
    }

    func status() -> String {
        jsonString([
            "enabled": settings.enabled,
            "vertical": settings.vertical,
            "horizontal": settings.horizontal,
            "reversing": settings.axes(continuous: false, rival: rival) != nil,
            "standingDownFor": rival?.rawValue ?? "nothing",
            "tapActive": tap.isActive,
            "counts": counts,
            "lastEvent": lastEvent,
        ] as [String: Any])
    }
}
