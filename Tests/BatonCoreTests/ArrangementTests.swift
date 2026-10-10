import CoreGraphics
import XCTest
@testable import BatonCore

final class ArrangementTests: XCTestCase {
    let displays: [String: [CGRect]] = [
        "studio": [CGRect(x: 0, y: 0, width: 2560, height: 1707)],
        "mini": [CGRect(x: 0, y: 0, width: 2560, height: 1440)],
        "mbp": [CGRect(x: 0, y: 0, width: 1512, height: 982)],
    ]
    let standard = [
        Placement(machine: "mini", side: .left, of: "studio", align: .end),
        Placement(machine: "mbp", side: .right, of: "studio", align: .end),
    ]

    func arrangement(_ placements: [Placement]? = nil) -> Arrangement {
        Arrangement(root: "studio", displays: displays, placements: placements ?? standard)
    }

    func assertSameLayout(_ a: Arrangement, file: StaticString = #filePath, line: UInt = #line) {
        let rebuilt = Arrangement(root: "studio", displays: displays, placements: a.placements())
        XCTAssertEqual(rebuilt.items, a.items, file: file, line: line)
    }

    func testPlacementsRoundTrip() {
        let a = arrangement()
        XCTAssertEqual(a.item(named: "mini")?.frame, CGRect(x: -2560, y: 267, width: 2560, height: 1440))
        XCTAssertEqual(Set(a.placements()), Set(standard))
        assertSameLayout(a)
    }

    func testDropSnapsToTheNearestEdgeAndLinesUp() {
        var a = arrangement()
        // Dropped roughly above the studio, a little off its left edge.
        a.drop("mbp", at: CGPoint(x: 30, y: -900), snap: 60)
        XCTAssertEqual(a.item(named: "mbp")?.frame, CGRect(x: 0, y: -982, width: 1512, height: 982))
        XCTAssertTrue(a.placements().contains(Placement(machine: "mbp", side: .above, of: "studio", align: .start)))
        assertSameLayout(a)
    }

    func testDropKeepsAnOffsetWhenNothingLinesUp() {
        var a = arrangement()
        a.drop("mbp", at: CGPoint(x: 2700, y: 300), snap: 20)
        XCTAssertEqual(a.item(named: "mbp")?.frame.origin, CGPoint(x: 2560, y: 300))
        XCTAssertTrue(a.placements().contains(Placement(machine: "mbp", side: .right, of: "studio", align: .start, offset: 300)))
        assertSameLayout(a)
    }

    func testDropNeverOverlapsAndAlwaysTouches() {
        var a = arrangement()
        // Dropped right on top of the mini.
        a.drop("mbp", at: CGPoint(x: -2000, y: 500), snap: 40)
        let frames = a.items.map(\.frame)
        for (i, f) in frames.enumerated() {
            for g in frames[(i + 1)...] {
                let overlap = f.intersection(g)
                XCTAssertTrue(overlap.isNull || overlap.width < 1 || overlap.height < 1, "\(f) overlaps \(g)")
            }
        }
        XCTAssertEqual(a.placements().count, 2)
        assertSameLayout(a)
    }

    func testChainsAndReattachesStrandedMachines() {
        var a = arrangement()
        // Hang the mbp off the far side of the mini, then pull the mini out from between.
        a.drop("mbp", at: CGPoint(x: -4200, y: 700), snap: 40)
        XCTAssertTrue(a.placements().contains { $0.machine == "mbp" && $0.of == "mini" && $0.side == .left })
        a.drop("mini", at: CGPoint(x: 100, y: 1800), snap: 40)
        XCTAssertEqual(a.item(named: "mini")?.frame.minY, 1707)
        XCTAssertEqual(a.placements().count, 2, "every machine is reachable from the root")
        assertSameLayout(a)
    }

    func testDraggingTheRootMovesEverythingElseInstead() {
        var a = arrangement([Placement(machine: "mini", side: .left, of: "studio", align: .start)])
        a.drop("studio", at: CGPoint(x: -5200, y: 0), snap: 40)
        XCTAssertEqual(a.item(named: "studio")?.position, .zero)
        XCTAssertEqual(a.item(named: "mini")?.frame.minX, 2560)
        assertSameLayout(a)
    }

    func testUnplacedMachinesAreAttached() {
        let a = arrangement([Placement(machine: "mini", side: .left, of: "studio", align: .end)])
        XCTAssertEqual(a.item(named: "mbp")?.frame.minX, 2560)
        XCTAssertEqual(a.placements().count, 2)
    }

    func testAwayMachinesKeepTheirPlace() {
        let chained = [
            Placement(machine: "mini", side: .left, of: "studio", align: .end),
            Placement(machine: "mbp", side: .left, of: "mini", align: .end),
        ]
        let layout = Layout.resolve(root: "studio", displays: displays, placements: chained).keeping(["studio", "mbp"])
        XCTAssertEqual(layout.machines["mbp"]?.virtualBounds.minX, -4072)
        XCTAssertNil(layout.machines["mini"])
        // With the mini away there is a gap, so the studio's left edge is a wall.
        XCTAssertEqual(layout.move(on: "studio", from: CGPoint(x: 2, y: 1000), dx: -30, dy: 0), .stay(CGPoint(x: 0, y: 1000)))
    }
}

extension Placement: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(machine)
        hasher.combine(of)
    }
}
