import Foundation

/// What two Macs say to each other on the update link: the anchor's listener one port above the
/// clipboard's (`port` + 2), with the input link's TLS and the same four-byte length before each
/// frame.
///
/// THIS FORMAT IS FROZEN. The input link refuses a Mac on another version, so this link is the
/// only place where a Mac that slept through an update can find out which version to fetch. Every
/// release ever published has to keep understanding `hello`, `prepare`, `prepared` and `install`
/// exactly as they are written here. New keys and new types may be added; a reader skips what it
/// does not know. Nothing here may be renamed, removed or given a new meaning, and versions stay
/// dotted numbers.
public enum UpdateMessage: Equatable, Sendable {
    /// Both ways, first: who this is and what it runs.
    case hello(name: String, version: Version, kind: BuildKind)
    /// Anchor to client: download this release and check it, but keep running.
    case prepare(Version)
    /// Client to anchor: the release is ready to install here, or why it is not.
    case prepared(Version, ok: Bool, detail: String)
    /// Anchor to client: swap the prepared release in and restart now.
    case install(Version)

    // What follows is only used between Macs on the same version.

    /// Anchor to client: whether updates install automatically, and what the updater is doing.
    case state(automatic: Bool, activity: String?)
    /// Client to anchor: someone at the client asked for this release.
    case lead(Version)
    /// Anchor to the client that asked: why its request came to nothing.
    case result(ok: Bool, detail: String)
    /// Client to anchor: switch Install Updates Automatically.
    case setAutomatic(Bool)

    public static let maxFrame = 64 * 1024

    /// The frame for this message: its length, then a flat JSON object.
    public func frame() -> Data {
        var object: [String: Any]
        switch self {
        case let .hello(name, version, kind):
            object = ["type": "hello", "name": name, "version": version.description, "build": kind.rawValue]
        case let .prepare(version):
            object = ["type": "prepare", "version": version.description]
        case let .prepared(version, ok, detail):
            object = ["type": "prepared", "version": version.description, "ok": ok, "detail": detail]
        case let .install(version):
            object = ["type": "install", "version": version.description]
        case let .state(automatic, activity):
            object = ["type": "state", "automatic": automatic]
            if let activity { object["activity"] = activity }
        case let .lead(version):
            object = ["type": "lead", "version": version.description]
        case let .result(ok, detail):
            object = ["type": "result", "ok": ok, "detail": detail]
        case let .setAutomatic(value):
            object = ["type": "setAutomatic", "automatic": value]
        }
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        var frame = Data(capacity: body.count + 4)
        var length = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(body)
        return frame
    }

    /// The body length a four-byte header announces, or nil if no update message is that long.
    public static func length(ofHeader header: Data) -> Int? {
        guard header.count == 4 else { return nil }
        let n = header.reduce(0) { ($0 << 8) | Int($1) }
        return n <= maxFrame ? n : nil
    }

    /// Reads a frame's body. Nil for anything this version does not know, which the caller skips.
    public init?(body: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let type = object["type"] as? String
        else { return nil }
        let version = (object["version"] as? String).flatMap(Version.init)
        let detail = object["detail"] as? String ?? ""
        switch type {
        case "hello":
            guard let name = object["name"] as? String, let version else { return nil }
            // A kind this version has not heard of is not one it should send releases to.
            self = .hello(name: name, version: version, kind: (object["build"] as? String).flatMap(BuildKind.init) ?? .development)
        case "prepare":
            guard let version else { return nil }
            self = .prepare(version)
        case "prepared":
            guard let version else { return nil }
            self = .prepared(version, ok: object["ok"] as? Bool ?? false, detail: detail)
        case "install":
            guard let version else { return nil }
            self = .install(version)
        case "state":
            self = .state(automatic: object["automatic"] as? Bool ?? false, activity: object["activity"] as? String)
        case "lead":
            guard let version else { return nil }
            self = .lead(version)
        case "result":
            self = .result(ok: object["ok"] as? Bool ?? false, detail: detail)
        case "setAutomatic":
            guard let value = object["automatic"] as? Bool else { return nil }
            self = .setAutomatic(value)
        default:
            return nil
        }
    }
}
