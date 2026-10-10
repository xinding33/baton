import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Whether macOS lets this app read what other apps copied ("Paste from Other Apps" in
/// Privacy & Security).
public enum ClipboardAccess: String, Sendable {
    case allowed
    /// Never asked: the first read makes macOS ask, and lists the app in System Settings.
    case notAskedYet
    /// macOS would put up an alert for every single read.
    case asks
    case denied
}

/// The types on a pasteboard. Getting it reads no data.
public struct ClipboardListing: Equatable, Sendable {
    /// Every type anywhere on the pasteboard.
    public var markers: [String]
    /// The types of the first item.
    public var item: [String]

    public init(markers: [String], item: [String]) {
        self.markers = markers
        self.item = item
    }
}

public enum ClipboardReading: Equatable, Sendable {
    case parts([ClipboardPart])
    /// Over the limit; the number is how far reading got.
    case tooLarge(Int)
    /// The pasteboard changed again while it was being read.
    case changed
}

/// The pasteboard as the shared clipboard uses it. It is handed to `ClipboardService`, so tests
/// give each side a pasteboard of its own.
public protocol ClipboardBoard: AnyObject {
    var changeCount: Int { get }
    var access: ClipboardAccess { get }
    func listing() -> ClipboardListing
    func read(_ types: [String], limit: Int) -> ClipboardReading
    /// Replaces the contents and returns the change count that results.
    func write(_ content: ClipboardContent) -> Int
}

public final class SystemClipboard: ClipboardBoard {
    private let pasteboard: NSPasteboard

    /// A TIFF this large is sent as PNG instead: screenshots and copied pictures arrive as
    /// uncompressed TIFF of tens of megabytes.
    static let tiffConversionThreshold = 256 * 1024

    public init(_ pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
    }

    public var changeCount: Int { pasteboard.changeCount }

    public var access: ClipboardAccess {
        guard #available(macOS 15.4, *) else { return .allowed }
        switch pasteboard.accessBehavior {
        case .alwaysAllow: return .allowed
        case .default: return .notAskedYet
        case .ask: return .asks
        case .alwaysDeny: return .denied
        @unknown default: return .asks
        }
    }

    public func listing() -> ClipboardListing {
        let items = pasteboard.pasteboardItems ?? []
        let markers = (pasteboard.types ?? []).map(\.rawValue) + items.flatMap { $0.types.map(\.rawValue) }
        return ClipboardListing(markers: markers, item: items.first?.types.map(\.rawValue) ?? [])
    }

    public func read(_ types: [String], limit: Int) -> ClipboardReading {
        let before = pasteboard.changeCount
        guard let item = pasteboard.pasteboardItems?.first else { return .changed }
        var parts: [ClipboardPart] = []
        var total = 0
        for type in types {
            guard let data = item.data(forType: NSPasteboard.PasteboardType(type)), !data.isEmpty else { continue }
            var part = ClipboardPart(type: type, data: data)
            if type == UTType.tiff.identifier, data.count > SystemClipboard.tiffConversionThreshold,
               let png = ClipboardImage.png(fromTIFF: data), png.count < data.count {
                part = ClipboardPart(type: UTType.png.identifier, data: png)
            }
            total += part.data.count
            if total > limit { return .tooLarge(total) }
            parts.append(part)
        }
        return pasteboard.changeCount == before ? .parts(parts) : .changed
    }

    public func write(_ content: ClipboardContent) -> Int {
        // Kept off Universal Clipboard: the other Macs get this copy from Baton, and Handoff
        // offering it to them a second time would replace theirs with its slower one.
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        let item = NSPasteboardItem()
        for part in content.parts {
            item.setData(part.data, forType: NSPasteboard.PasteboardType(part.type))
        }
        item.setString(content.stamp.origin, forType: NSPasteboard.PasteboardType(ClipboardFilter.batonMarker))
        pasteboard.writeObjects([item])
        return pasteboard.changeCount
    }
}

public enum ClipboardImage {
    /// Re-encodes a single-image TIFF as PNG, keeping its size, resolution and colour profile.
    public static func png(fromTIFF data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1 else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImageFromSource(destination, source, 0, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
