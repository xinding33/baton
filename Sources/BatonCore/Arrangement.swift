import CoreGraphics
import Foundation

/// The layout as the arrangement editor sees it: every known machine as a block on the virtual
/// plane that can be dragged and dropped against the others.
public struct Arrangement: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public let name: String
        /// Display frames in the machine's own coordinates.
        public let displays: [CGRect]
        public let scale: Double
        /// Virtual-plane position of the top-left corner of the machine's bounding box.
        public var position: CGPoint

        var localBounds: CGRect {
            displays.dropFirst().reduce(displays.first ?? .zero) { $0.union($1) }
        }

        /// The machine's bounding box on the virtual plane.
        public var frame: CGRect {
            CGRect(x: position.x, y: position.y, width: localBounds.width * scale, height: localBounds.height * scale)
        }

        /// Each display's frame on the virtual plane.
        public var displayFrames: [CGRect] {
            let bounds = localBounds
            return displays.map {
                CGRect(
                    x: position.x + ($0.minX - bounds.minX) * scale,
                    y: position.y + ($0.minY - bounds.minY) * scale,
                    width: $0.width * scale,
                    height: $0.height * scale
                )
            }
        }
    }

    public let root: String
    public private(set) var items: [Item] = []

    /// Builds the arrangement the placements describe. Machines the placements don't reach are
    /// attached to the right of everything else, so nothing is ever left floating.
    public init(root: String, displays: [String: [CGRect]], placements: [Placement]) {
        self.root = root
        let layout = Layout.resolve(root: root, displays: displays, placements: placements)
        let scales = Dictionary(placements.map { ($0.machine, $0.scale) }, uniquingKeysWith: { first, _ in first })
        for name in displays.keys.sorted() {
            guard let rects = displays[name], !rects.isEmpty, let machine = layout.machines[name] else { continue }
            items.append(Item(name: name, displays: rects, scale: machine.scale, position: machine.virtualBounds.origin))
        }
        for name in displays.keys.sorted() where layout.machines[name] == nil {
            guard let rects = displays[name], !rects.isEmpty else { continue }
            let right = items.map(\.frame.maxX).max() ?? 0
            let top = items.first { $0.name == root }?.frame.minY ?? 0
            items.append(Item(name: name, displays: rects, scale: scales[name] ?? 1, position: CGPoint(x: right, y: top)))
        }
        items.sort { $0.name < $1.name }
    }

    public func item(named name: String) -> Item? {
        items.first { $0.name == name }
    }

    public func item(at point: CGPoint) -> Item? {
        items.last { $0.displayFrames.contains { $0.contains(point) } }
    }

    // MARK: Dropping

    private static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let i = a.intersection(b)
        return !i.isNull && i.width > 0.5 && i.height > 0.5
    }

    /// Whether two frames share a stretch of edge, i.e. the cursor can cross between them.
    static func touches(_ a: CGRect, _ b: CGRect) -> Bool {
        let sharedY = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        let sharedX = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        let sideBySide = abs(a.maxX - b.minX) < 1 || abs(b.maxX - a.minX) < 1
        let stacked = abs(a.maxY - b.minY) < 1 || abs(b.maxY - a.minY) < 1
        return (sideBySide && sharedY > 1) || (stacked && sharedX > 1)
    }

    /// The closest spot to `desired` where a block of `size` touches one of `anchors` without
    /// overlapping any of `obstacles`. Edges within `snap` of lining up are made to line up.
    static func landing(for size: CGSize, near desired: CGPoint, anchors: [CGRect], obstacles: [CGRect], snap: Double) -> CGPoint? {
        func along(_ wanted: Double, _ length: Double, _ lo: Double, _ hi: Double) -> Double {
            // Keep a tenth of the shorter edge in contact, so there is always room to cross.
            let contact = max(min(length, hi - lo) * 0.1, 1)
            var value = min(max(wanted, lo - length + contact), hi - contact)
            let lineUps = [lo, hi - length, (lo + hi) / 2 - length / 2]
            if let best = lineUps.min(by: { abs($0 - value) < abs($1 - value) }), abs(best - value) <= snap {
                value = best
            }
            return value
        }
        var best: (point: CGPoint, distance: Double)?
        for anchor in anchors {
            let candidates = [
                CGPoint(x: anchor.minX - size.width, y: along(desired.y, size.height, anchor.minY, anchor.maxY)),
                CGPoint(x: anchor.maxX, y: along(desired.y, size.height, anchor.minY, anchor.maxY)),
                CGPoint(x: along(desired.x, size.width, anchor.minX, anchor.maxX), y: anchor.minY - size.height),
                CGPoint(x: along(desired.x, size.width, anchor.minX, anchor.maxX), y: anchor.maxY),
            ]
            for point in candidates {
                let frame = CGRect(origin: point, size: size)
                guard !obstacles.contains(where: { overlaps(frame, $0) }) else { continue }
                let distance = Double(hypot(point.x - desired.x, point.y - desired.y))
                if best == nil || distance < best!.distance { best = (point, distance) }
            }
        }
        return best?.point
    }

    /// Where `name` would land if dropped with its top-left corner at `desired`.
    public func landing(of name: String, at desired: CGPoint, snap: Double) -> CGPoint? {
        guard let item = item(named: name) else { return nil }
        let others = items.filter { $0.name != name }.map(\.frame)
        guard !others.isEmpty else { return item.position }
        return Arrangement.landing(for: item.frame.size, near: desired, anchors: others, obstacles: others, snap: snap)
    }

    /// Drops `name` near `desired`, then re-attaches any machine the move left stranded.
    public mutating func drop(_ name: String, at desired: CGPoint, snap: Double) {
        guard let index = items.firstIndex(where: { $0.name == name }), let point = landing(of: name, at: desired, snap: snap) else { return }
        items[index].position = point
        reattachStranded()
        normalize()
    }

    private func reachable() -> Set<String> {
        var reached: Set<String> = items.contains { $0.name == root } ? [root] : []
        var grew = true
        while grew {
            grew = false
            for item in items where !reached.contains(item.name) {
                if items.contains(where: { reached.contains($0.name) && Arrangement.touches($0.frame, item.frame) }) {
                    reached.insert(item.name)
                    grew = true
                }
            }
        }
        return reached
    }

    private mutating func reattachStranded() {
        while true {
            let reached = reachable()
            guard let index = items.firstIndex(where: { !reached.contains($0.name) }) else { return }
            let anchors = items.filter { reached.contains($0.name) }.map(\.frame)
            let obstacles = items.enumerated().filter { $0.offset != index }.map(\.element.frame)
            guard !anchors.isEmpty, let point = Arrangement.landing(for: items[index].frame.size, near: items[index].position, anchors: anchors, obstacles: obstacles, snap: 0) else { return }
            items[index].position = point
        }
    }

    /// Keeps the root machine's local origin at the virtual origin, as `Layout` does.
    private mutating func normalize() {
        guard let rootItem = item(named: root) else { return }
        let wanted = CGPoint(x: rootItem.localBounds.minX * rootItem.scale, y: rootItem.localBounds.minY * rootItem.scale)
        let dx = wanted.x - rootItem.position.x, dy = wanted.y - rootItem.position.y
        for index in items.indices {
            items[index].position.x += dx
            items[index].position.y += dy
        }
    }

    // MARK: Saving

    /// Placements that reproduce this arrangement, each machine described against a neighbour
    /// that is closer to the root.
    public func placements() -> [Placement] {
        var result: [Placement] = []
        var placed: [Item] = items.filter { $0.name == root }
        var pending = items.filter { $0.name != root }
        var grew = true
        while grew {
            grew = false
            for item in pending {
                guard let neighbour = placed.first(where: { Arrangement.touches($0.frame, item.frame) }) else { continue }
                result.append(Arrangement.placement(of: item, against: neighbour))
                placed.append(item)
                pending.removeAll { $0.name == item.name }
                grew = true
            }
        }
        return result
    }

    private static func placement(of item: Item, against neighbour: Item) -> Placement {
        let a = item.frame, b = neighbour.frame
        let side: Side
        if abs(a.maxX - b.minX) < 1 {
            side = .left
        } else if abs(a.minX - b.maxX) < 1 {
            side = .right
        } else if abs(a.maxY - b.minY) < 1 {
            side = .above
        } else {
            side = .below
        }
        let horizontal = side == .left || side == .right
        let start = horizontal ? a.minY - b.minY : a.minX - b.minX
        let end = horizontal ? a.maxY - b.maxY : a.maxX - b.maxX
        let center = horizontal ? a.midY - b.midY : a.midX - b.midX
        // Prefer the alignment that survives a resolution change over a raw offset.
        let align: Align, offset: Double
        if abs(end) < 0.5 {
            (align, offset) = (.end, 0)
        } else if abs(start) < 0.5 {
            (align, offset) = (.start, 0)
        } else if abs(center) < 0.5 {
            (align, offset) = (.center, 0)
        } else {
            (align, offset) = (.start, start.rounded())
        }
        return Placement(machine: item.name, side: side, of: neighbour.name, align: align, offset: offset, scale: item.scale)
    }
}
