import CryptoKit
import Foundation

/// Seals and opens the motion datagrams of one session.
///
/// Layout: [sessionId u32][seq u64][ChaCha20-Poly1305 ciphertext + tag]. The nonce is the
/// direction byte plus `seq`, so a key is never reused with the same nonce, and datagrams
/// that arrive out of order or twice are dropped.
public struct DatagramCodec {
    public enum Direction: UInt8, Sendable { case anchorToClient = 0, clientToAnchor = 1 }

    public static let headerSize = 12

    public let sessionId: UInt32
    private let key: SymmetricKey
    private let sendDirection: Direction
    private var sendSeq: UInt64 = 0
    private var recvSeq: UInt64 = 0

    public init(key: Data, sessionId: UInt32, sending: Direction) {
        self.key = SymmetricKey(data: key)
        self.sessionId = sessionId
        self.sendDirection = sending
    }

    public static func sessionId(of datagram: Data) -> UInt32? {
        guard datagram.count >= headerSize else { return nil }
        return datagram.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func nonce(_ direction: Direction, _ seq: UInt64) -> ChaChaPoly.Nonce {
        var bytes = Data([direction.rawValue, 0, 0, 0])
        withUnsafeBytes(of: seq.bigEndian) { bytes.append(contentsOf: $0) }
        return try! ChaChaPoly.Nonce(data: bytes)
    }

    public mutating func seal(_ payload: Data) -> Data {
        sendSeq += 1
        var header = Data(capacity: Self.headerSize)
        withUnsafeBytes(of: sessionId.bigEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: sendSeq.bigEndian) { header.append(contentsOf: $0) }
        let box = try! ChaChaPoly.seal(payload, using: key, nonce: Self.nonce(sendDirection, sendSeq), authenticating: header)
        return header + box.ciphertext + box.tag
    }

    /// Returns the payload, or nil if the datagram is forged, stale, or for another session.
    public mutating func open(_ datagram: Data) -> Data? {
        guard datagram.count >= Self.headerSize + 16, Self.sessionId(of: datagram) == sessionId else { return nil }
        let header = datagram.prefix(Self.headerSize)
        let seq = header.suffix(8).reduce(0) { ($0 << 8) | UInt64($1) }
        guard seq > recvSeq else { return nil }
        let body = datagram.dropFirst(Self.headerSize)
        let receiveDirection: Direction = sendDirection == .anchorToClient ? .clientToAnchor : .anchorToClient
        guard let box = try? ChaChaPoly.SealedBox(nonce: Self.nonce(receiveDirection, seq), ciphertext: body.dropLast(16), tag: body.suffix(16)),
              let payload = try? ChaChaPoly.open(box, using: key, authenticating: header)
        else { return nil }
        recvSeq = seq
        return payload
    }
}

/// Payloads carried inside motion datagrams.
public enum DatagramPayload: Equatable, Sendable {
    /// Client to anchor: opens and keeps alive the datagram path.
    case hello
    /// Anchor to client: an absolute cursor position.
    case motion(seq: UInt64, x: Double, y: Double)

    public func encoded() -> Data {
        switch self {
        case .hello:
            return Data([0])
        case let .motion(seq, x, y):
            var d = Data([1])
            withUnsafeBytes(of: seq.bigEndian) { d.append(contentsOf: $0) }
            withUnsafeBytes(of: x.bitPattern.bigEndian) { d.append(contentsOf: $0) }
            withUnsafeBytes(of: y.bitPattern.bigEndian) { d.append(contentsOf: $0) }
            return d
        }
    }

    public init?(_ data: Data) {
        guard let kind = data.first else { return nil }
        switch kind {
        case 0:
            self = .hello
        case 1:
            guard data.count == 25 else { return nil }
            let bytes = [UInt8](data.dropFirst())
            func u64(_ at: Int) -> UInt64 { bytes[at..<at + 8].reduce(0) { ($0 << 8) | UInt64($1) } }
            self = .motion(seq: u64(0), x: Double(bitPattern: u64(8)), y: Double(bitPattern: u64(16)))
        default:
            return nil
        }
    }
}
