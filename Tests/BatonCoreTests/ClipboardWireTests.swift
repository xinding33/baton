import XCTest
@testable import BatonCore

final class ClipboardWireTests: XCTestCase {
    func bytes(_ count: Int, seed: UInt8 = 1) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
    }

    func content(_ sizes: [Int]) -> ClipboardContent {
        ClipboardContent(
            stamp: ClipboardStamp(time: 42, origin: "mini"),
            parts: sizes.enumerated().map { ClipboardPart(type: "type.\($0.offset)", data: bytes($0.element, seed: UInt8($0.offset))) }
        )
    }

    func frames(of content: ClipboardContent, transfer: UInt32 = 7) -> [ClipboardFrame] {
        var outgoing = ClipboardOutgoing(content, transfer: transfer)
        var frames: [ClipboardFrame] = []
        while let frame = outgoing.next() { frames.append(frame) }
        XCTAssertTrue(outgoing.isFinished)
        return frames
    }

    func testEveryFrameSurvivesEncoding() throws {
        let header = ClipboardHeader(transfer: 9, stamp: ClipboardStamp(time: 5, origin: "mbp"), digest: bytes(32), parts: [.init(type: "public.png", length: 3)])
        let all: [ClipboardFrame] = [
            .hello(ClipboardHello(name: "mini", have: ClipboardStamp(time: 1, origin: "studio"))),
            .hello(ClipboardHello(name: "mini", have: nil)),
            .settings(ClipboardSettings(enabled: true, maxBytes: 1 << 25)),
            .setEnabled(false),
            .begin(header),
            .chunk(transfer: 9, bytes(1000)),
            .chunk(transfer: 9, Data()),
            .end(transfer: 9),
            .cancel(transfer: 0xFFFF_FFFF),
            .universalClipboard(true),
            .turnOffHandoff(["mbp", "mini"]),
            .turnOffHandoff([]),
            .showHandoffSetting,
        ]
        var parser = ClipboardFrameParser()
        for frame in all { parser.append(frame.encoded()) }
        for frame in all { XCTAssertEqual(try parser.next(), frame) }
        XCTAssertNil(try parser.next())
    }

    func testParserTakesTheStreamInPiecesOfAnySize() throws {
        let sent = frames(of: content([10, 300_000, 1]))
        let stream = sent.reduce(Data()) { $0 + $1.encoded() }
        for piece in [1, 3, 4, 5, 1000, 65_536, stream.count] where piece == 1 ? stream.count < 400_000 : true {
            var parser = ClipboardFrameParser()
            var received: [ClipboardFrame] = []
            var offset = 0
            while offset < stream.count {
                let end = min(offset + piece, stream.count)
                parser.append(stream.subdata(in: offset..<end))
                offset = end
                while let frame = try parser.next() { received.append(frame) }
            }
            XCTAssertEqual(received, sent, "pieces of \(piece)")
        }
    }

    func testParserRefusesAFrameThatIsTooLongOrUnknown() {
        var parser = ClipboardFrameParser()
        parser.append(Data([0x7F, 0, 0, 0]))
        XCTAssertThrowsError(try parser.next())
        parser = ClipboardFrameParser()
        parser.append(Data([0, 0, 0, 0]))
        XCTAssertThrowsError(try parser.next())
        parser = ClipboardFrameParser()
        parser.append(Data([0, 0, 0, 1, 99]))
        XCTAssertThrowsError(try parser.next())
    }

    func testACopyIsCutIntoChunksAndPutBackTogether() throws {
        let chunk = ClipboardWire.chunkSize
        for sizes in [[5], [chunk], [chunk + 1], [1, chunk * 2 + 17, 0, 3], [chunk - 1, 1, chunk * 3]] {
            let original = content(sizes)
            let sent = frames(of: original)
            guard case let .begin(header) = sent.first, case .end(7) = sent.last else { return XCTFail("no header or end") }
            XCTAssertEqual(header.total, sizes.reduce(0, +))
            var incoming = try ClipboardIncoming(header, maxBytes: 1 << 30)
            for frame in sent.dropFirst().dropLast() {
                guard case let .chunk(7, data) = frame else { return XCTFail("unexpected \(frame)") }
                XCTAssertLessThanOrEqual(data.count, chunk)
                XCTAssertLessThanOrEqual(frame.encoded().count, ClipboardWire.maxFrame + 4)
                try incoming.append(data)
            }
            XCTAssertEqual(try incoming.finish(), original)
        }
    }

    func testACopyOverTheLimitIsRefusedFromItsHeader() {
        guard case let .begin(header) = frames(of: content([600, 500])).first else { return XCTFail() }
        XCTAssertThrowsError(try ClipboardIncoming(header, maxBytes: 1000)) {
            XCTAssertEqual($0 as? ClipboardWireError, .tooLarge(1100))
        }
        XCTAssertNoThrow(try ClipboardIncoming(header, maxBytes: 1100))
    }

    func testMoreOrFewerBytesThanAnnouncedAreRefused() throws {
        guard case let .begin(header) = frames(of: content([100])).first else { return XCTFail() }
        var short = try ClipboardIncoming(header, maxBytes: 1000)
        try short.append(bytes(99))
        XCTAssertThrowsError(try short.finish()) { XCTAssertEqual($0 as? ClipboardWireError, .incomplete) }
        var long = try ClipboardIncoming(header, maxBytes: 1000)
        XCTAssertThrowsError(try long.append(bytes(101))) { XCTAssertEqual($0 as? ClipboardWireError, .overrun) }
    }

    func testDamagedDataIsRefused() throws {
        guard case let .begin(header) = frames(of: content([100])).first else { return XCTFail() }
        var incoming = try ClipboardIncoming(header, maxBytes: 1000)
        try incoming.append(bytes(100, seed: 99))
        XCTAssertThrowsError(try incoming.finish()) { XCTAssertEqual($0 as? ClipboardWireError, .digestMismatch) }
    }

    func testANonsenseHeaderIsRefused() {
        let stamp = ClipboardStamp(time: 1, origin: "mini")
        XCTAssertThrowsError(try ClipboardIncoming(ClipboardHeader(transfer: 1, stamp: stamp, digest: Data(), parts: []), maxBytes: 10))
        XCTAssertThrowsError(try ClipboardIncoming(ClipboardHeader(transfer: 1, stamp: stamp, digest: Data(), parts: [.init(type: "a", length: -1)]), maxBytes: 10))
        XCTAssertThrowsError(try ClipboardIncoming(ClipboardHeader(transfer: 1, stamp: stamp, digest: Data(), parts: [.init(type: "", length: 1)]), maxBytes: 10))
    }
}
