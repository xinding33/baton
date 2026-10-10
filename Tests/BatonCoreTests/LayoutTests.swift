import CoreGraphics
import XCTest
@testable import BatonCore

final class LayoutTests: XCTestCase {
    let studio = [CGRect(x: 0, y: 0, width: 2560, height: 1707)]
    let mini = [CGRect(x: 0, y: 0, width: 2560, height: 1440)]
    let mbp = [CGRect(x: 0, y: 0, width: 1512, height: 982)]

    func layout(_ placements: [Placement], displays: [String: [CGRect]]? = nil) -> Layout {
        Layout.resolve(root: "studio", displays: displays ?? ["studio": studio, "mini": mini, "mbp": mbp], placements: placements)
    }

    var standard: Layout {
        layout([
            Placement(machine: "mini", side: .left, of: "studio", align: .end),
            Placement(machine: "mbp", side: .right, of: "studio", align: .end),
        ])
    }

    func testPlacementAlignsBottomEdges() {
        let l = standard
        XCTAssertEqual(l.machines["mini"]!.virtualBounds, CGRect(x: -2560, y: 267, width: 2560, height: 1440))
        XCTAssertEqual(l.machines["mbp"]!.virtualBounds, CGRect(x: 2560, y: 725, width: 1512, height: 982))
        XCTAssertTrue(l.unplaced.isEmpty)
    }

    func testMoveInsideStays() {
        XCTAssertEqual(standard.move(on: "studio", from: CGPoint(x: 100, y: 100), dx: 50, dy: -20), .stay(CGPoint(x: 150, y: 80)))
    }

    func testCrossLeftMapsAlongSharedEdge() {
        let r = standard.move(on: "studio", from: CGPoint(x: 3, y: 1000), dx: -40, dy: 0)
        XCTAssertEqual(r, .cross(machine: "mini", point: CGPoint(x: 2559, y: 733)))
    }

    func testEdgeWithoutNeighbourIsAWall() {
        // The mini only covers the lower part of the studio's left edge.
        let r = standard.move(on: "studio", from: CGPoint(x: 3, y: 100), dx: -40, dy: 0)
        XCTAssertEqual(r, .stay(CGPoint(x: 0, y: 100)))
    }

    func testCrossBackAndThrough() {
        let l = standard
        XCTAssertEqual(l.move(on: "mini", from: CGPoint(x: 2550, y: 733), dx: 30, dy: 0), .cross(machine: "studio", point: CGPoint(x: 0, y: 1000)))
        XCTAssertEqual(l.move(on: "studio", from: CGPoint(x: 2555, y: 1700), dx: 30, dy: 0), .cross(machine: "mbp", point: CGPoint(x: 0, y: 975)))
        XCTAssertEqual(l.move(on: "mbp", from: CGPoint(x: 1500, y: 500), dx: 100, dy: 0), .stay(CGPoint(x: 1511, y: 500)))
    }

    func testCrossingCanBeDisallowed() {
        let r = standard.move(on: "studio", from: CGPoint(x: 3, y: 1000), dx: -40, dy: 0, allowCross: false)
        XCTAssertEqual(r, .stay(CGPoint(x: 0, y: 1000)))
    }

    func testDiagonalExitPrefersTheEdgeWithANeighbour() {
        // Pushing down-left at the bottom-left corner: below is a wall, left is the mini.
        let r = standard.move(on: "studio", from: CGPoint(x: 2, y: 1705), dx: -10, dy: 30)
        XCTAssertEqual(r, .cross(machine: "mini", point: CGPoint(x: 2559, y: 1439)))
    }

    func testMultipleDisplaysOnOneMachine() {
        let two = [CGRect(x: 0, y: 0, width: 1000, height: 800), CGRect(x: 1000, y: 0, width: 1000, height: 800)]
        let l = layout([Placement(machine: "mini", side: .right, of: "studio", align: .start)], displays: ["studio": two, "mini": mini])
        XCTAssertEqual(l.move(on: "studio", from: CGPoint(x: 990, y: 10), dx: 30, dy: 0), .stay(CGPoint(x: 1020, y: 10)))
        XCTAssertEqual(l.move(on: "studio", from: CGPoint(x: 1990, y: 10), dx: 30, dy: 0), .cross(machine: "mini", point: CGPoint(x: 0, y: 10)))
    }

    func testScaleStretchesTheSharedEdge() {
        let scale = 1707.0 / 1440.0
        let l = layout([Placement(machine: "mini", side: .left, of: "studio", align: .start, scale: scale)])
        guard case let .cross(machine, point) = l.move(on: "studio", from: CGPoint(x: 1, y: 1706), dx: -5, dy: 0) else {
            return XCTFail("expected a crossing")
        }
        XCTAssertEqual(machine, "mini")
        XCTAssertEqual(point.y, 1439, accuracy: 1)
    }

    func testChainedPlacementAndMissingReference() {
        let chained = [
            Placement(machine: "mbp", side: .below, of: "mini"),
            Placement(machine: "mini", side: .left, of: "studio"),
        ]
        XCTAssertEqual(layout(chained).machines.count, 3)
        let withoutMini = layout(chained, displays: ["studio": studio, "mbp": mbp])
        XCTAssertEqual(withoutMini.unplaced, ["mbp"])
        XCTAssertNil(withoutMini.machines["mbp"])
    }
}

final class DatagramTests: XCTestCase {
    func testRoundTripAndReplay() {
        let key = Data(repeating: 7, count: 32)
        var anchor = DatagramCodec(key: key, sessionId: 42, sending: .anchorToClient)
        var client = DatagramCodec(key: key, sessionId: 42, sending: .clientToAnchor)
        let first = anchor.seal(DatagramPayload.motion(seq: 1, x: 10.5, y: -3).encoded())
        let second = anchor.seal(DatagramPayload.motion(seq: 2, x: 11, y: -3).encoded())
        XCTAssertEqual(DatagramCodec.sessionId(of: first), 42)
        XCTAssertEqual(client.open(second).flatMap(DatagramPayload.init), .motion(seq: 2, x: 11, y: -3))
        XCTAssertNil(client.open(first), "older datagrams are dropped")
        XCTAssertNil(client.open(second), "replays are dropped")
        XCTAssertEqual(anchor.open(client.seal(DatagramPayload.hello.encoded())).flatMap(DatagramPayload.init), .hello)
    }

    func testRejectsTamperingAndWrongKey() {
        var anchor = DatagramCodec(key: Data(repeating: 7, count: 32), sessionId: 1, sending: .anchorToClient)
        var client = DatagramCodec(key: Data(repeating: 7, count: 32), sessionId: 1, sending: .clientToAnchor)
        var stranger = DatagramCodec(key: Data(repeating: 8, count: 32), sessionId: 1, sending: .clientToAnchor)
        var sealed = anchor.seal(DatagramPayload.hello.encoded())
        XCTAssertNil(stranger.open(sealed))
        sealed[sealed.count - 1] ^= 1
        XCTAssertNil(client.open(sealed))
    }

    func testWireRoundTrip() throws {
        let frame = try Wire.encode(.key(Key(code: 6, down: true, isModifier: false, autorepeat: false, flags: 256)))
        XCTAssertEqual(Wire.length(ofHeader: frame.prefix(4)), frame.count - 4)
        guard case let .key(key) = try Wire.decode(frame.dropFirst(4)) else { return XCTFail("wrong case") }
        XCTAssertEqual(key.code, 6)
    }
}
