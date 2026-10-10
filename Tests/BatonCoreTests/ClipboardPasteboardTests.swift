import AppKit
import XCTest
@testable import BatonCore

/// These run against named pasteboards made for the test, never the general one.
final class ClipboardPasteboardTests: XCTestCase {
    var pasteboard: NSPasteboard!
    var board: SystemClipboard!

    override func setUp() {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("baton-test-\(UUID().uuidString)"))
        board = SystemClipboard(pasteboard)
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
    }

    func verdict() -> ClipboardFilter.Verdict {
        let listing = board.listing()
        return ClipboardFilter.verdict(markers: listing.markers, item: listing.item)
    }

    func bitmap(_ side: Int) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<side {
            for x in 0..<side {
                rep.setColor(NSColor(deviceRed: CGFloat(x) / CGFloat(side), green: CGFloat(y) / CGFloat(side), blue: 0.5, alpha: 1), atX: x, y: y)
            }
        }
        return rep
    }

    func testACopiedStringIsListedAndRead() {
        pasteboard.clearContents()
        pasteboard.setString("hello", forType: .string)
        XCTAssertEqual(verdict(), .share(["public.utf8-plain-text"]))
        XCTAssertEqual(board.read(["public.utf8-plain-text"], limit: 100), .parts([ClipboardPart(type: "public.utf8-plain-text", data: Data("hello".utf8))]))
    }

    func testReadingStopsAtTheLimit() {
        pasteboard.clearContents()
        pasteboard.setString(String(repeating: "x", count: 500), forType: .string)
        pasteboard.setData(Data(count: 600), forType: .png)
        XCTAssertEqual(board.read(["public.utf8-plain-text", "public.png"], limit: 1000), .tooLarge(1100))
        XCTAssertNotEqual(board.read(["public.utf8-plain-text", "public.png"], limit: 1100), .tooLarge(1100))
    }

    func testWhatBatonWritesIsMarkedAndReadableByOtherApps() {
        let rtf = Data(#"{\rtf1\ansi hello}"#.utf8)
        let content = ClipboardContent(stamp: ClipboardStamp(time: 1, origin: "mini"), parts: [
            ClipboardPart(type: "public.rtf", data: rtf),
            ClipboardPart(type: "public.utf8-plain-text", data: Data("hello".utf8)),
        ])
        let before = pasteboard.changeCount
        let after = board.write(content)
        XCTAssertGreaterThan(after, before)
        XCTAssertEqual(after, pasteboard.changeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "hello")
        XCTAssertEqual(pasteboard.data(forType: .rtf), rtf)
        XCTAssertEqual(pasteboard.string(forType: NSPasteboard.PasteboardType(ClipboardFilter.batonMarker)), "mini")
        XCTAssertEqual(verdict(), .skip(.fromBaton))
    }

    func testFilesAndPasswordsAreRecognisedOnARealPasteboard() {
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/some file.txt") as NSURL])
        XCTAssertEqual(verdict(), .skip(.files))

        pasteboard.clearContents()
        pasteboard.setString("hunter2", forType: .string)
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        XCTAssertEqual(verdict(), .skip(.secret))

        pasteboard.clearContents()
        XCTAssertEqual(verdict(), .skip(.empty))
    }

    func testALargeTiffTravelsAsPng() throws {
        let rep = bitmap(400)
        rep.size = NSSize(width: 200, height: 200)  // 144 dpi, as a Retina screenshot has
        let tiff = try XCTUnwrap(rep.representation(using: .tiff, properties: [.compressionMethod: NSBitmapImageRep.TIFFCompression.none]))
        XCTAssertGreaterThan(tiff.count, SystemClipboard.tiffConversionThreshold)
        pasteboard.clearContents()
        pasteboard.setData(tiff, forType: .tiff)
        XCTAssertEqual(verdict(), .share(["public.tiff"]))

        guard case let .parts(parts) = board.read(["public.tiff"], limit: 1 << 30) else { return XCTFail("not read") }
        XCTAssertEqual(parts.map(\.type), ["public.png"])
        XCTAssertLessThan(parts[0].data.count, tiff.count / 4)
        let png = try XCTUnwrap(NSBitmapImageRep(data: parts[0].data))
        XCTAssertEqual(png.pixelsWide, 400)
        XCTAssertEqual(png.pixelsHigh, 400)
        XCTAssertEqual(png.size.width, 200, accuracy: 0.5)
        XCTAssertEqual(png.colorAt(x: 300, y: 100)?.redComponent ?? 0, 0.75, accuracy: 0.01)

        // On the receiving Mac the pasteboard offers TIFF again to apps that ask for it.
        let other = NSPasteboard(name: NSPasteboard.Name("baton-test-\(UUID().uuidString)"))
        defer { other.releaseGlobally() }
        _ = SystemClipboard(other).write(ClipboardContent(stamp: ClipboardStamp(time: 1, origin: "mini"), parts: parts))
        XCTAssertNotNil(other.data(forType: .tiff))
        XCTAssertNotNil(NSImage(pasteboard: other))
    }

    func testASmallTiffIsLeftAlone() throws {
        let tiff = try XCTUnwrap(bitmap(16).tiffRepresentation)
        pasteboard.clearContents()
        pasteboard.setData(tiff, forType: .tiff)
        XCTAssertEqual(board.read(["public.tiff"], limit: 1 << 20), .parts([ClipboardPart(type: "public.tiff", data: tiff)]))
    }

    func testNamedPasteboardsAreAlwaysReadable() {
        XCTAssertEqual(board.access, .allowed)
    }
}
