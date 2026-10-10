import Foundation

// The clipboard travels on its own connection, apart from the one that carries input and the
// heartbeat. A copy is sent as a header, chunks and an end mark, so a newer copy can cut in
// between two chunks instead of waiting behind megabytes of an image nobody wants any more.

public let clipboardProtocolVersion = 1

public enum ClipboardWire {
    public static let chunkSize = 256 * 1024
    public static let maxFrame = chunkSize + 64 * 1024
    public static let maxParts = 64
}

public enum ClipboardWireError: Error, Equatable {
    case badFrame
    case badHeader
    case tooLarge(Int)
    case overrun
    case incomplete
    case digestMismatch
}

public struct ClipboardHello: Codable, Equatable, Sendable {
    public var name: String
    public var version: Int
    /// The newest shared copy the sender holds, so only the side that is ahead sends its copy.
    public var have: ClipboardStamp?

    public init(name: String, version: Int = clipboardProtocolVersion, have: ClipboardStamp?) {
        self.name = name
        self.version = version
        self.have = have
    }
}

/// Anchor to client: the settings every Mac follows.
public struct ClipboardSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var maxBytes: Int

    public init(enabled: Bool, maxBytes: Int) {
        self.enabled = enabled
        self.maxBytes = maxBytes
    }
}

public struct ClipboardHeader: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var type: String
        public var length: Int
    }

    /// Tells this transfer's chunks from those of one it replaced.
    public var transfer: UInt32
    public var stamp: ClipboardStamp
    public var digest: Data
    public var parts: [Entry]

    public var total: Int { parts.reduce(0) { $0 + max($1.length, 0) } }
}

public enum ClipboardFrame: Equatable, Sendable {
    case hello(ClipboardHello)
    case settings(ClipboardSettings)
    /// Client to anchor: someone switched sharing on or off in that client's menu.
    case setEnabled(Bool)
    case begin(ClipboardHeader)
    /// The parts' bytes, one part after another.
    case chunk(transfer: UInt32, Data)
    case end(transfer: UInt32)
    /// The sender gave this transfer up for a newer copy.
    case cancel(transfer: UInt32)
    /// Client to anchor: whether Universal Clipboard is on on the client.
    case universalClipboard(Bool)
    /// Anchor to client: the Macs on which Handoff should be turned off.
    case turnOffHandoff([String])
    /// Anchor to client: someone asked, in the anchor's menu, to see the client's Handoff setting.
    case showHandoffSetting

    private var kind: UInt8 {
        switch self {
        case .hello: return 1
        case .settings: return 2
        case .setEnabled: return 3
        case .begin: return 4
        case .chunk: return 5
        case .end: return 6
        case .cancel: return 7
        case .universalClipboard: return 8
        case .turnOffHandoff: return 9
        case .showHandoffSetting: return 10
        }
    }

    /// Four bytes of length, one byte of kind, then the payload.
    public func encoded() -> Data {
        var payload = Data()
        var transferId: UInt32?
        switch self {
        case let .hello(hello): payload = (try? JSONEncoder().encode(hello)) ?? Data()
        case let .settings(settings): payload = (try? JSONEncoder().encode(settings)) ?? Data()
        case let .setEnabled(enabled), let .universalClipboard(enabled): payload = Data([enabled ? 1 : 0])
        case let .turnOffHandoff(machines): payload = (try? JSONEncoder().encode(machines)) ?? Data()
        case .showHandoffSetting: break
        case let .begin(header): payload = (try? JSONEncoder().encode(header)) ?? Data()
        case let .chunk(transfer, data):
            transferId = transfer
            payload = data
        case let .end(transfer), let .cancel(transfer): transferId = transfer
        }
        let length = 1 + (transferId == nil ? 0 : 4) + payload.count
        var frame = Data(capacity: 4 + length)
        frame.appendBigEndian(UInt32(length))
        frame.append(kind)
        if let transferId { frame.appendBigEndian(transferId) }
        frame.append(payload)
        return frame
    }

    init(body: Data) throws {
        guard let kind = body.first else { throw ClipboardWireError.badFrame }
        let payload = Data(body.dropFirst())
        func transfer() throws -> UInt32 {
            guard payload.count >= 4 else { throw ClipboardWireError.badFrame }
            return payload.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
        }
        func json<T: Decodable>(_ type: T.Type) throws -> T {
            guard let value = try? JSONDecoder().decode(type, from: payload) else { throw ClipboardWireError.badFrame }
            return value
        }
        func flag() throws -> Bool {
            guard payload.count == 1 else { throw ClipboardWireError.badFrame }
            return payload[0] != 0
        }
        switch kind {
        case 1: self = .hello(try json(ClipboardHello.self))
        case 2: self = .settings(try json(ClipboardSettings.self))
        case 3: self = .setEnabled(try flag())
        case 4: self = .begin(try json(ClipboardHeader.self))
        case 5: self = .chunk(transfer: try transfer(), Data(payload.dropFirst(4)))
        case 6: self = .end(transfer: try transfer())
        case 7: self = .cancel(transfer: try transfer())
        case 8: self = .universalClipboard(try flag())
        case 9: self = .turnOffHandoff(try json([String].self))
        case 10: self = .showHandoffSetting
        default: throw ClipboardWireError.badFrame
        }
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        var n = value.bigEndian
        Swift.withUnsafeBytes(of: &n) { append(contentsOf: $0) }
    }
}

/// Cuts a byte stream, delivered in pieces of any size, back into frames.
public struct ClipboardFrameParser {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) {
        buffer.append(data)
    }

    public mutating func next() throws -> ClipboardFrame? {
        guard buffer.count >= 4 else { return nil }
        let length = buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
        guard length >= 1, length <= ClipboardWire.maxFrame else { throw ClipboardWireError.badFrame }
        guard buffer.count >= 4 + length else { return nil }
        let body = Data(buffer.dropFirst(4).prefix(length))
        buffer = Data(buffer.dropFirst(4 + length))
        return try ClipboardFrame(body: body)
    }
}

/// One copy on its way out, handed over a frame at a time.
public struct ClipboardOutgoing {
    public let content: ClipboardContent
    public let transfer: UInt32
    private var started = false
    private var part = 0
    private var offset = 0
    public private(set) var isFinished = false

    public init(_ content: ClipboardContent, transfer: UInt32) {
        self.content = content
        self.transfer = transfer
    }

    public mutating func next() -> ClipboardFrame? {
        guard !isFinished else { return nil }
        if !started {
            started = true
            let entries = content.parts.map { ClipboardHeader.Entry(type: $0.type, length: $0.data.count) }
            return .begin(ClipboardHeader(transfer: transfer, stamp: content.stamp, digest: content.digest, parts: entries))
        }
        while part < content.parts.count {
            let data = content.parts[part].data
            guard offset < data.count else {
                part += 1
                offset = 0
                continue
            }
            let count = min(ClipboardWire.chunkSize, data.count - offset)
            let start = data.startIndex + offset
            offset += count
            return .chunk(transfer: transfer, data.subdata(in: start..<start + count))
        }
        isFinished = true
        return .end(transfer: transfer)
    }
}

/// One copy on its way in, checked against its header as it arrives.
public struct ClipboardIncoming {
    public let header: ClipboardHeader
    private var parts: [Data]
    private var part = 0

    public init(_ header: ClipboardHeader, maxBytes: Int) throws {
        guard !header.parts.isEmpty, header.parts.count <= ClipboardWire.maxParts,
              header.parts.allSatisfy({ $0.length >= 0 && !$0.type.isEmpty })
        else { throw ClipboardWireError.badHeader }
        guard header.total <= maxBytes else { throw ClipboardWireError.tooLarge(header.total) }
        self.header = header
        parts = header.parts.map { entry in
            var data = Data()
            data.reserveCapacity(entry.length)
            return data
        }
    }

    public mutating func append(_ chunk: Data) throws {
        var rest = chunk[...]
        while !rest.isEmpty {
            while part < parts.count, parts[part].count == header.parts[part].length { part += 1 }
            guard part < parts.count else { throw ClipboardWireError.overrun }
            let room = header.parts[part].length - parts[part].count
            parts[part].append(rest.prefix(room))
            rest = rest.dropFirst(room)
        }
    }

    public func finish() throws -> ClipboardContent {
        guard zip(parts, header.parts).allSatisfy({ $0.count == $1.length }) else { throw ClipboardWireError.incomplete }
        let content = ClipboardContent(stamp: header.stamp, parts: zip(header.parts, parts).map { ClipboardPart(type: $0.type, data: $1) })
        guard content.digest == header.digest else { throw ClipboardWireError.digestMismatch }
        return content
    }
}
