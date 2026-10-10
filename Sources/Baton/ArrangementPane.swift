import AppKit
import BatonCore

/// A canvas showing every known Mac as a block that can be dragged against the others,
/// in the manner of the Displays settings.
final class ArrangementView: NSView {
    var arrangement: Arrangement { didSet { needsDisplay = true } }
    var online: Set<String> = [] { didSet { needsDisplay = true } }
    var displayNames: [String: [String]] = [:] { didSet { needsDisplay = true } }
    /// Called when a drop changes the arrangement.
    var onChange: ((Arrangement) -> Void)?

    private struct Drag {
        let name: String
        let grab: CGSize
        var position: CGPoint
        /// The view transform is frozen for the length of a drag so blocks don't shift underfoot.
        let transform: Transform
    }

    private struct Transform {
        let scale: CGFloat
        let offset: CGPoint
        func toView(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX * scale + offset.x, y: r.minY * scale + offset.y, width: r.width * scale, height: r.height * scale)
        }
        func toVirtual(_ p: CGPoint) -> CGPoint {
            CGPoint(x: (p.x - offset.x) / scale, y: (p.y - offset.y) / scale)
        }
    }

    private var drag: Drag?
    var isDragging: Bool { drag != nil }

    init(frame: NSRect, arrangement: Arrangement) {
        self.arrangement = arrangement
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    private var fitTransform: Transform {
        let frames = arrangement.items.map(\.frame)
        let union = frames.dropFirst().reduce(frames.first ?? CGRect(x: 0, y: 0, width: 1, height: 1)) { $0.union($1) }
        let area = bounds.insetBy(dx: 48, dy: 40)
        let scale = min(area.width / union.width, area.height / union.height)
        let offset = CGPoint(x: area.midX - union.midX * scale, y: area.midY - union.midY * scale)
        return Transform(scale: scale, offset: offset)
    }

    private var transform: Transform { drag?.transform ?? fitTransform }
    /// Edges closer than this many screen points snap into line.
    private var snap: Double { 10 / Double(transform.scale) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        let t = transform
        for item in arrangement.items where item.name != drag?.name {
            draw(item, with: t, alpha: 1)
        }
        guard let drag, var item = arrangement.item(named: drag.name) else { return }
        if let landing = arrangement.landing(of: drag.name, at: drag.position, snap: snap) {
            var ghost = item
            ghost.position = landing
            for frame in ghost.displayFrames {
                let outline = NSBezierPath(roundedRect: t.toView(frame).insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6)
                outline.lineWidth = 2
                outline.setLineDash([6, 4], count: 2, phase: 0)
                NSColor.controlAccentColor.setStroke()
                outline.stroke()
            }
        }
        item.position = drag.position
        draw(item, with: t, alpha: 0.7)
    }

    private func draw(_ item: Arrangement.Item, with t: Transform, alpha: CGFloat) {
        let isOnline = online.contains(item.name)
        let fill = (isOnline ? NSColor.controlAccentColor : NSColor.systemGray).withAlphaComponent(alpha)
        for (index, frame) in item.displayFrames.enumerated() {
            let rect = t.toView(frame).insetBy(dx: 2, dy: 2)
            let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            fill.setFill()
            path.fill()
            NSColor.white.withAlphaComponent(0.35 * alpha).setStroke()
            path.lineWidth = 1
            path.stroke()

            let title = NSAttributedString(string: item.name, attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: NSColor.white.withAlphaComponent(alpha),
            ])
            let names = displayNames[item.name] ?? []
            var detail = index < names.count ? names[index] : ""
            if !isOnline { detail = detail.isEmpty ? "away" : "\(detail) · away" }
            let subtitleAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.white.withAlphaComponent(0.85 * alpha),
            ]
            // On a small block, drop the display's name and keep its size; failing that, show nothing.
            var subtitle = NSAttributedString(string: detail, attributes: subtitleAttributes)
            if subtitle.size().width > rect.width - 12, let short = detail.components(separatedBy: " · ").dropFirst().first {
                detail = isOnline ? short : "\(short) · away"
                subtitle = NSAttributedString(string: detail, attributes: subtitleAttributes)
            }
            if subtitle.size().width > rect.width - 12 {
                detail = ""
                subtitle = NSAttributedString(string: "", attributes: subtitleAttributes)
            }
            let titleSize = title.size(), subtitleSize = subtitle.size()
            let height = titleSize.height + (detail.isEmpty ? 0 : subtitleSize.height + 2)
            let top = rect.midY - height / 2
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            title.draw(at: CGPoint(x: rect.midX - titleSize.width / 2, y: top))
            subtitle.draw(at: CGPoint(x: rect.midX - subtitleSize.width / 2, y: top + titleSize.height + 2))
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    // MARK: Dragging

    override func mouseDown(with event: NSEvent) {
        let t = fitTransform
        let point = t.toVirtual(convert(event.locationInWindow, from: nil))
        guard let item = arrangement.item(at: point) else { return }
        drag = Drag(name: item.name, grab: CGSize(width: point.x - item.position.x, height: point.y - item.position.y), position: item.position, transform: t)
        NSCursor.closedHand.push()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard var current = drag else { return }
        let point = current.transform.toVirtual(convert(event.locationInWindow, from: nil))
        current.position = CGPoint(x: point.x - current.grab.width, y: point.y - current.grab.height)
        drag = current
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let finished = drag else { return }
        let snap = self.snap
        drag = nil
        NSCursor.pop()
        var updated = arrangement
        updated.drop(finished.name, at: finished.position, snap: snap)
        if updated != arrangement {
            arrangement = updated
            onChange?(updated)
        }
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}

/// The Arrange pane of the anchor's Settings: the canvas, and a line on how to use it.
final class ArrangementPane: SettingsPane {
    let id = StatusMenu.Pane.arrange
    let title = "Arrange"
    let symbol = "rectangle.3.group"
    private static let size = NSSize(width: 720, height: 460)
    private static let footerHeight: CGFloat = 52

    private let anchor: Anchor
    private var canvas: ArrangementView?
    private var content: NSView?

    init(anchor: Anchor) {
        self.anchor = anchor
    }

    func makeView(frame: NSRect) -> ArrangementView {
        let view = ArrangementView(frame: frame, arrangement: anchor.arrangement())
        view.online = anchor.onlineMachines
        view.displayNames = anchor.knownDisplayNames
        view.onChange = { [weak self] arrangement in self?.anchor.apply(arrangement) }
        return view
    }

    var view: NSView {
        if let content { return content }
        let size = ArrangementPane.size, footerHeight = ArrangementPane.footerHeight
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.widthAnchor.constraint(equalToConstant: size.width).isActive = true
        content.heightAnchor.constraint(equalToConstant: size.height).isActive = true
        let canvas = makeView(frame: NSRect(x: 0, y: footerHeight, width: size.width, height: size.height - footerHeight))
        canvas.autoresizingMask = [.width, .height]
        let hint = NSTextField(wrappingLabelWithString: "Drag a Mac to where it sits on your desk. Changes apply as soon as you drop it. To arrange the screens of a single Mac, use that Mac's Displays settings.")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        hint.frame = NSRect(x: 24, y: 8, width: size.width - 48, height: footerHeight - 14)
        hint.autoresizingMask = [.width, .maxYMargin]
        content.addSubview(canvas)
        content.addSubview(hint)
        self.content = content
        self.canvas = canvas
        return content
    }

    /// Picks up machines that joined, left, or changed displays while the pane shows.
    func refresh() {
        guard let canvas, !canvas.isDragging else { return }
        canvas.arrangement = anchor.arrangement()
        canvas.online = anchor.onlineMachines
        canvas.displayNames = anchor.knownDisplayNames
    }
}
