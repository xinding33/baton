import Foundation

public enum Role: String, Codable, Sendable { case anchor, client }

public struct Config: Codable, Sendable {
    /// This machine's name in the layout, e.g. "studio".
    public var name: String
    public var role: Role
    public var port: UInt16
    /// Client only: connect to this host instead of discovering the anchor.
    public var anchorHost: String?
    /// Anchor only: where each client sits relative to another machine.
    public var placements: [Placement]
    /// Anchor only: how long a client may stay silent before the cursor comes home.
    public var timeoutMs: [String: Int]
    public var defaultTimeoutMs: Int
    /// Anchor only: Bluetooth address of the keyboard shared between the machines.
    public var keyboardAddress: String?
    /// Anchor only: move the keyboard to whichever machine the cursor settles on.
    public var keyboardFollows: Bool
    public var handoffStrategy: HandoffStrategy
    /// Anchor only: share what is copied on one Mac with the others.
    public var shareClipboard: Bool
    /// Anchor only: a copy larger than this many megabytes is not shared.
    public var clipboardMaxMB: Int

    public init(name: String, role: Role) {
        self.name = name
        self.role = role
        port = 47800
        anchorHost = nil
        placements = []
        timeoutMs = [:]
        defaultTimeoutMs = 800
        keyboardAddress = nil
        keyboardFollows = false
        handoffStrategy = .reconnect
        shareClipboard = true
        clipboardMaxMB = 32
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        role = try c.decode(Role.self, forKey: .role)
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? 47800
        anchorHost = try c.decodeIfPresent(String.self, forKey: .anchorHost)
        placements = try c.decodeIfPresent([Placement].self, forKey: .placements) ?? []
        timeoutMs = try c.decodeIfPresent([String: Int].self, forKey: .timeoutMs) ?? [:]
        defaultTimeoutMs = try c.decodeIfPresent(Int.self, forKey: .defaultTimeoutMs) ?? 800
        keyboardAddress = try c.decodeIfPresent(String.self, forKey: .keyboardAddress)
        keyboardFollows = try c.decodeIfPresent(Bool.self, forKey: .keyboardFollows) ?? false
        handoffStrategy = try c.decodeIfPresent(HandoffStrategy.self, forKey: .handoffStrategy) ?? .reconnect
        shareClipboard = try c.decodeIfPresent(Bool.self, forKey: .shareClipboard) ?? true
        clipboardMaxMB = try c.decodeIfPresent(Int.self, forKey: .clipboardMaxMB) ?? 32
    }

    public func timeout(for peer: String) -> TimeInterval {
        TimeInterval(timeoutMs[peer] ?? defaultTimeoutMs) / 1000
    }
}

public enum Paths {
    /// `BATON_HOME` points a second instance at its own config, for testing on one machine.
    public static var support: URL {
        if let override = ProcessInfo.processInfo.environment["BATON_HOME"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Baton", isDirectory: true)
    }
    public static var config: URL { support.appendingPathComponent("config.json") }
    public static var secret: URL { support.appendingPathComponent("secret.key") }
    public static var state: URL { support.appendingPathComponent("state.json") }
    public static var controlSocket: URL { support.appendingPathComponent("ctl.sock") }
    public static var log: URL {
        if ProcessInfo.processInfo.environment["BATON_HOME"] != nil {
            return support.appendingPathComponent("baton.log")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Baton/baton.log")
    }
}

public enum ConfigError: Error, CustomStringConvertible {
    case missing(URL)
    case badSecret

    public var description: String {
        switch self {
        case let .missing(url): return "missing \(url.path)"
        case .badSecret: return "secret.key must hold at least 32 hex-encoded bytes"
        }
    }
}

public func loadConfig() throws -> Config {
    guard let data = try? Data(contentsOf: Paths.config) else { throw ConfigError.missing(Paths.config) }
    return try JSONDecoder().decode(Config.self, from: data)
}

/// The shared secret every paired machine holds, hex-encoded on disk.
public func loadSecret() throws -> Data {
    guard let text = try? String(contentsOf: Paths.secret, encoding: .utf8) else { throw ConfigError.missing(Paths.secret) }
    let hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
    var bytes = Data()
    var index = hex.startIndex
    while index < hex.endIndex {
        guard let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex), let byte = UInt8(hex[index..<next], radix: 16) else {
            throw ConfigError.badSecret
        }
        bytes.append(byte)
        index = next
    }
    guard bytes.count >= 32 else { throw ConfigError.badSecret }
    return bytes
}
