import CoreGraphics
import Foundation

public enum Side: String, Codable, Sendable { case left, right, above, below }
public enum Align: String, Codable, Sendable { case start, center, end }

/// Where one machine's desktop sits relative to another's, e.g. "mini is left of studio".
public struct Placement: Codable, Equatable, Sendable {
    public var machine: String
    public var side: Side
    public var of: String
    /// Alignment along the shared edge: start = top/left, end = bottom/right.
    public var align: Align
    /// Extra shift along the shared edge, in virtual points.
    public var offset: Double
    /// Virtual points per local point. Use it to make edges of unequal displays line up.
    public var scale: Double

    public init(machine: String, side: Side, of: String, align: Align = .center, offset: Double = 0, scale: Double = 1) {
        self.machine = machine
        self.side = side
        self.of = of
        self.align = align
        self.offset = offset
        self.scale = scale
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        machine = try c.decode(String.self, forKey: .machine)
        side = try c.decode(Side.self, forKey: .side)
        of = try c.decode(String.self, forKey: .of)
        align = try c.decodeIfPresent(Align.self, forKey: .align) ?? .center
        offset = try c.decodeIfPresent(Double.self, forKey: .offset) ?? 0
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1
    }
}

public struct PlacedMachine: Equatable, Sendable {
    public let name: String
    /// Display frames in the machine's own global coordinates (points, origin top-left of its main display).
    public let displays: [CGRect]
    public let scale: Double
    /// Virtual-plane position of the machine's local origin.
    public let origin: CGPoint

    public func toVirtual(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * scale + origin.x, y: p.y * scale + origin.y)
    }

    public func toLocal(_ v: CGPoint) -> CGPoint {
        CGPoint(x: (v.x - origin.x) / scale, y: (v.y - origin.y) / scale)
    }

    public var localBounds: CGRect {
        displays.dropFirst().reduce(displays.first ?? .zero) { $0.union($1) }
    }

    public var virtualBounds: CGRect {
        let b = localBounds
        let o = toVirtual(b.origin)
        return CGRect(x: o.x, y: o.y, width: b.width * scale, height: b.height * scale)
    }

    public func display(containing p: CGPoint) -> CGRect? {
        displays.first { Layout.contains($0, p) }
    }

    public func nearestDisplay(to p: CGPoint) -> CGRect {
        func distance(_ r: CGRect) -> Double {
            let dx = max(r.minX - p.x, 0, p.x - r.maxX)
            let dy = max(r.minY - p.y, 0, p.y - r.maxY)
            return dx * dx + dy * dy
        }
        return displays.min { distance($0) < distance($1) } ?? .zero
    }

    /// The closest point to `p` that is on one of this machine's displays.
    public func clamp(_ p: CGPoint) -> CGPoint {
        Layout.clamp(p, into: display(containing: p) ?? nearestDisplay(to: p))
    }
}

public enum MoveResult: Equatable, Sendable {
    /// The cursor stays on the same machine, at this point.
    case stay(CGPoint)
    /// The cursor crosses to another machine, entering at this point in that machine's coordinates.
    case cross(machine: String, point: CGPoint)
}

/// Every connected machine's displays arranged on one shared virtual plane.
public struct Layout: Equatable, Sendable {
    public private(set) var machines: [String: PlacedMachine] = [:]
    /// Machines that have displays but could not be placed (their reference machine is missing).
    public private(set) var unplaced: [String] = []
    /// How far apart two edges may be and still count as touching, in virtual points.
    public var gapTolerance: Double = 2

    public init() {}

    public static func resolve(root: String, displays: [String: [CGRect]], placements: [Placement]) -> Layout {
        var layout = Layout()
        if let d = displays[root], !d.isEmpty {
            layout.machines[root] = PlacedMachine(name: root, displays: d, scale: 1, origin: .zero)
        }
        var pending = placements.filter { $0.machine != root && displays[$0.machine]?.isEmpty == false }
        var progress = true
        while progress {
            progress = false
            var remaining: [Placement] = []
            for p in pending {
                guard layout.machines[p.machine] == nil else { continue }
                guard let ref = layout.machines[p.of], let rects = displays[p.machine] else {
                    remaining.append(p)
                    continue
                }
                layout.machines[p.machine] = place(p, rects: rects, against: ref)
                progress = true
            }
            pending = remaining
        }
        layout.unplaced = Array(Set(pending.map(\.machine))).sorted()
        return layout
    }

    private static func place(_ p: Placement, rects: [CGRect], against ref: PlacedMachine) -> PlacedMachine {
        let local = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
        let w = local.width * p.scale, h = local.height * p.scale
        let rb = ref.virtualBounds
        func along(_ lo: Double, _ hi: Double, _ size: Double) -> Double {
            switch p.align {
            case .start: return lo + p.offset
            case .center: return (lo + hi) / 2 - size / 2 + p.offset
            case .end: return hi - size + p.offset
            }
        }
        let vx: Double, vy: Double
        switch p.side {
        case .left: vx = rb.minX - w; vy = along(rb.minY, rb.maxY, h)
        case .right: vx = rb.maxX; vy = along(rb.minY, rb.maxY, h)
        case .above: vx = along(rb.minX, rb.maxX, w); vy = rb.minY - h
        case .below: vx = along(rb.minX, rb.maxX, w); vy = rb.maxY
        }
        let origin = CGPoint(x: vx - local.minX * p.scale, y: vy - local.minY * p.scale)
        return PlacedMachine(name: p.machine, displays: rects, scale: p.scale, origin: origin)
    }

    /// Half-open containment, so adjacent displays never both contain a point.
    static func contains(_ r: CGRect, _ p: CGPoint) -> Bool {
        p.x >= r.minX && p.x < r.maxX && p.y >= r.minY && p.y < r.maxY
    }

    static func clamp(_ p: CGPoint, into r: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, r.minX), r.maxX - 1), y: min(max(p.y, r.minY), r.maxY - 1))
    }

    /// Moves the cursor on `name` from `pos` by (dx, dy), both in that machine's points.
    public func move(on name: String, from pos: CGPoint, dx: Double, dy: Double, allowCross: Bool = true) -> MoveResult {
        guard let m = machines[name], !m.displays.isEmpty else { return .stay(pos) }
        let cand = CGPoint(x: pos.x + dx, y: pos.y + dy)
        if m.display(containing: cand) != nil { return .stay(cand) }
        let cur = m.display(containing: pos) ?? m.nearestDisplay(to: pos)

        var exits: [(side: Side, overshoot: Double)] = []
        if cand.x < cur.minX { exits.append((.left, cur.minX - cand.x)) }
        if cand.x >= cur.maxX { exits.append((.right, cand.x - cur.maxX + 1)) }
        if cand.y < cur.minY { exits.append((.above, cur.minY - cand.y)) }
        if cand.y >= cur.maxY { exits.append((.below, cand.y - cur.maxY + 1)) }
        exits.sort { $0.overshoot > $1.overshoot }

        for exit in exits {
            let y = min(max(cand.y, cur.minY), cur.maxY - 1)
            let x = min(max(cand.x, cur.minX), cur.maxX - 1)
            let edge: CGPoint, unit: CGVector
            switch exit.side {
            case .left: edge = CGPoint(x: cur.minX, y: y); unit = CGVector(dx: -1, dy: 0)
            case .right: edge = CGPoint(x: cur.maxX, y: y); unit = CGVector(dx: 1, dy: 0)
            case .above: edge = CGPoint(x: x, y: cur.minY); unit = CGVector(dx: 0, dy: -1)
            case .below: edge = CGPoint(x: x, y: cur.maxY); unit = CGVector(dx: 0, dy: 1)
            }
            // Another display of the same machine sits across this edge.
            let justOutside = CGPoint(x: edge.x + unit.dx * 0.5, y: edge.y + unit.dy * 0.5)
            if let r = m.display(containing: justOutside) {
                return .stay(Layout.clamp(cand, into: r))
            }
            guard allowCross else { continue }
            let vEdge = m.toVirtual(edge)
            var d = 0.5
            while d <= gapTolerance + 0.5 {
                let v = CGPoint(x: vEdge.x + unit.dx * d, y: vEdge.y + unit.dy * d)
                for other in machines.values.sorted(by: { $0.name < $1.name }) where other.name != name {
                    let l = other.toLocal(v)
                    if let r = other.display(containing: l) {
                        // Enter exactly on the facing edge, whatever the gap that was bridged.
                        var entry = l
                        switch exit.side {
                        case .left: entry.x = r.maxX - 1
                        case .right: entry.x = r.minX
                        case .above: entry.y = r.maxY - 1
                        case .below: entry.y = r.minY
                        }
                        return .cross(machine: other.name, point: Layout.clamp(entry, into: r))
                    }
                }
                d += 1
            }
        }
        return .stay(Layout.clamp(cand, into: cur))
    }
}
