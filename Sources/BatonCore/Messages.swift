import CoreGraphics
import Foundation

public let batonProtocolVersion = 1
public let batonServiceType = "_baton._tcp"

public struct DisplayInfo: Codable, Equatable, Sendable {
    public var id: UInt32
    public var uuid: String
    public var name: String
    /// Frame in the machine's global coordinates, in points.
    public var frame: CGRect
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var mmWidth: Double
    public var mmHeight: Double
    public var isMain: Bool

    public init(id: UInt32, uuid: String, name: String, frame: CGRect, pixelWidth: Int, pixelHeight: Int, mmWidth: Double, mmHeight: Double, isMain: Bool) {
        self.id = id
        self.uuid = uuid
        self.name = name
        self.frame = frame
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.mmWidth = mmWidth
        self.mmHeight = mmHeight
        self.isMain = isMain
    }
}

public struct Hello: Codable, Sendable {
    public var name: String
    public var version: Int
    public var displays: [DisplayInfo]
    public init(name: String, version: Int, displays: [DisplayInfo]) {
        self.name = name
        self.version = version
        self.displays = displays
    }
}

public struct Welcome: Codable, Sendable {
    public var anchorName: String
    public var sessionId: UInt32
    /// Key for the motion datagrams of this session.
    public var udpKey: Data
    public var udpPort: UInt16
    /// Bluetooth address of the shared keyboard, if one is configured.
    public var keyboardAddress: String?
    public init(anchorName: String, sessionId: UInt32, udpKey: Data, udpPort: UInt16, keyboardAddress: String?) {
        self.anchorName = anchorName
        self.sessionId = sessionId
        self.udpKey = udpKey
        self.udpPort = udpPort
        self.keyboardAddress = keyboardAddress
    }
}

/// How the shared keyboard is moved from one Mac to another.
public enum HandoffStrategy: String, Codable, Sendable {
    /// The old Mac drops its connection and the new Mac connects, both keeping their pairing.
    case reconnect
    /// The old Mac forgets the keyboard and the new Mac pairs with it afresh.
    case repair
}

/// Asks a machine to let go of the shared keyboard or to take it.
public struct KeyboardCommand: Codable, Sendable {
    public enum Action: String, Codable, Sendable { case release, take }
    public var id: UInt32
    public var action: Action
    public var address: String
    public var strategy: HandoffStrategy
    public init(id: UInt32, action: Action, address: String, strategy: HandoffStrategy) {
        self.id = id
        self.action = action
        self.address = address
        self.strategy = strategy
    }
}

public struct KeyboardResult: Codable, Sendable {
    public var id: UInt32
    public var ok: Bool
    public var detail: String
    public init(id: UInt32, ok: Bool, detail: String) {
        self.id = id
        self.ok = ok
        self.detail = detail
    }
}

/// A cursor position on the receiving machine. `seq` orders it against motion datagrams.
public struct Motion: Codable, Sendable {
    public var x: Double
    public var y: Double
    public var seq: UInt64
    public var flags: UInt64
    public init(x: Double, y: Double, seq: UInt64, flags: UInt64 = 0) {
        self.x = x
        self.y = y
        self.seq = seq
        self.flags = flags
    }
}

public struct Button: Codable, Sendable {
    public var at: Motion
    public var button: Int
    public var down: Bool
    public var clickState: Int64
    public init(at: Motion, button: Int, down: Bool, clickState: Int64) {
        self.at = at
        self.button = button
        self.down = down
        self.clickState = clickState
    }
}

public struct Scroll: Codable, Sendable {
    public var at: Motion
    public var lines1: Int64
    public var lines2: Int64
    public var points1: Int64
    public var points2: Int64
    public var fixed1: Double
    public var fixed2: Double
    public var continuous: Bool
    public var phase: Int64
    public var momentumPhase: Int64
    public init(at: Motion, lines1: Int64, lines2: Int64, points1: Int64, points2: Int64, fixed1: Double, fixed2: Double, continuous: Bool, phase: Int64, momentumPhase: Int64) {
        self.at = at
        self.lines1 = lines1
        self.lines2 = lines2
        self.points1 = points1
        self.points2 = points2
        self.fixed1 = fixed1
        self.fixed2 = fixed2
        self.continuous = continuous
        self.phase = phase
        self.momentumPhase = momentumPhase
    }
}

public struct Key: Codable, Sendable {
    public var code: UInt16
    public var down: Bool
    public var isModifier: Bool
    public var autorepeat: Bool
    public var flags: UInt64
    public init(code: UInt16, down: Bool, isModifier: Bool, autorepeat: Bool, flags: UInt64) {
        self.code = code
        self.down = down
        self.isModifier = isModifier
        self.autorepeat = autorepeat
        self.flags = flags
    }
}

public enum Message: Codable, Sendable {
    case hello(Hello)
    case welcome(Welcome)
    case displays([DisplayInfo])
    /// The cursor arrives on the receiving machine.
    case enter(Motion)
    /// The cursor leaves the receiving machine.
    case leave
    /// Motion over the reliable channel, used until the datagram path is up.
    case move(Motion)
    case button(Button)
    case scroll(Scroll)
    /// Anchor to client: a key to replay. Client to anchor: a key typed on the shared keyboard
    /// while the cursor is elsewhere, to be passed on to the machine that has it.
    case key(Key)
    case ping(UInt64)
    case pong(UInt64)
    /// Client to anchor: whether the shared keyboard is attached to the client.
    case keyboardPresent(Bool)
    case keyboardCommand(KeyboardCommand)
    case keyboardResult(KeyboardResult)
    /// Client to anchor: the client's own trackpad, mouse or keyboard was used, and its cursor is here.
    case localInput(Motion)
    /// Client to anchor: the client is about to sleep, and has let go of the shared keyboard if it had it.
    case sleeping
    /// Client to anchor: whether the client still holds a pairing with the shared keyboard.
    case keyboardPaired(Bool)
    /// Client to anchor: the client's external displays, for the anchor's menu.
    case displayPanel(DisplayPanel)
    /// Anchor to client: turn one of the client's displays off or on.
    case displayAction(DisplayAction)
    /// Wake your display. A client sends it to the anchor, which passes it on to the other clients.
    case wake(WakeRequest)
}

public enum Wire {
    public static let maxFrame = 16 * 1024 * 1024

    public static func encode(_ message: Message) throws -> Data {
        let body = try JSONEncoder().encode(message)
        var frame = Data(capacity: body.count + 4)
        var length = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(body)
        return frame
    }

    public static func length(ofHeader header: Data) -> Int? {
        guard header.count == 4 else { return nil }
        let n = header.reduce(0) { ($0 << 8) | Int($1) }
        return n <= maxFrame ? n : nil
    }

    public static func decode(_ body: Data) throws -> Message {
        try JSONDecoder().decode(Message.self, from: body)
    }
}
