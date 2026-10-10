import Foundation

/// The name a Mac goes by in the layout, the menus and `ctl` commands.
public enum MachineName {
    public static let maxLength = 24

    /// What is wrong with a name, or nil. Names are single words because `ctl` commands and the
    /// layout refer to Macs by them.
    public static func problem(with name: String) -> String? {
        if name.isEmpty { return "Give this Mac a name, such as “studio” or “laptop”." }
        if name.count > maxLength { return "Keep the name to \(maxLength) characters or fewer." }
        let allowed = name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") }
        return allowed ? nil : "Use letters, digits and hyphens only, without spaces."
    }

    /// A name to offer for a Mac, made from the one it has in Sharing settings: "Ana’s MacBook
    /// Pro" becomes "anas-macbook-pro". Those are already different on every Mac of a network.
    public static func suggestion(fromComputerName computerName: String?) -> String {
        let plain = (computerName ?? "").folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        var name = ""
        for scalar in plain.unicodeScalars where !"'’`".unicodeScalars.contains(scalar) {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                name.unicodeScalars.append(scalar)
            } else if !name.isEmpty, !name.hasSuffix("-") {
                name += "-"
            }
        }
        name = String(name.prefix(maxLength))
        while name.hasSuffix("-") { name.removeLast() }
        return name.isEmpty ? "mac" : name
    }
}

extension Config {
    /// What is wrong with a config that could be read, in words for whoever edits the file.
    /// Nothing here stops Baton from starting; it is said in the log and in Settings.
    public var problems: [String] {
        var found: [String] = []
        if let problem = MachineName.problem(with: name) {
            found.append("name “\(name)”: \(problem)")
        }
        if port == 0 || port == UInt16.max {
            found.append("port \(port) cannot be used: the clipboard needs the port above it as well")
        }
        if let host = anchorHost, host.trimmingCharacters(in: .whitespaces).isEmpty {
            found.append("anchorHost is empty; leave it out to find the anchor by itself")
        }
        if let address = keyboardAddress, BluetoothAddress.normalize(address) == nil {
            found.append("keyboardAddress “\(address)” is not a Bluetooth address, which is six pairs of hex digits")
        }
        if defaultTimeoutMs <= 0 {
            found.append("defaultTimeoutMs must be more than 0")
        }
        for (machine, timeout) in timeoutMs.sorted(by: { $0.key < $1.key }) where timeout <= 0 {
            found.append("timeoutMs for “\(machine)” must be more than 0")
        }
        if clipboardMaxMB <= 0 {
            found.append("clipboardMaxMB must be more than 0")
        }
        guard role == .anchor else { return found }
        var placed: Set<String> = []
        let known = Set(placements.map(\.machine)).union([name])
        for placement in placements {
            if placement.machine == name {
                found.append("placements: “\(name)” is this Mac, which the others are placed around")
            } else if !placed.insert(placement.machine).inserted {
                found.append("placements: “\(placement.machine)” is placed more than once")
            }
            if !known.contains(placement.of) {
                found.append("placements: “\(placement.machine)” sits next to “\(placement.of)”, which has no place itself")
            }
        }
        return found
    }
}

extension Config {
    /// Gives this Mac another name. On the anchor the other Macs are placed around it by name,
    /// so their placements follow.
    public mutating func rename(to newName: String) {
        guard newName != name else { return }
        for index in placements.indices {
            if placements[index].of == name { placements[index].of = newName }
            if placements[index].machine == name { placements[index].machine = newName }
        }
        name = newName
    }
}

/// Why a Mac cannot start sharing and shows the setup window first.
public enum SetupNeed: Equatable, Sendable {
    /// There is no `config.json`: Baton has not been set up on this Mac.
    case firstRun
    /// `config.json` is there but cannot be used as it is.
    case unreadableConfig(String)
    /// `config.json` is fine and `secret.key` is missing.
    case notPaired
    /// `secret.key` is there and does not hold a key.
    case unreadableSecret

    /// What the setup window says at its top.
    public var explanation: String? {
        switch self {
        case .firstRun:
            return nil
        case let .unreadableConfig(reason):
            return "Baton could not read its settings file (config.json): \(reason). Setting this Mac up again replaces the file; the old one is kept next to it as config.unreadable.json."
        case .notPaired:
            return "This Mac has its settings but no pairing code yet."
        case .unreadableSecret:
            return "This Mac’s key file (secret.key) is damaged. Enter the pairing code again."
        }
    }
}

/// Baton's files on one Mac: `config.json`, `secret.key` and the pairing code the key came from.
public struct Installation {
    public let directory: URL

    public init(directory: URL = Paths.support) {
        self.directory = directory
    }

    public var configURL: URL { directory.appendingPathComponent("config.json") }
    public var secretURL: URL { directory.appendingPathComponent("secret.key") }
    /// Kept so that Settings can show the code again when another Mac is added. It opens nothing
    /// that `secret.key`, next to it, does not.
    public var codeURL: URL { directory.appendingPathComponent("pairing.code") }
    var unreadableConfigURL: URL { directory.appendingPathComponent("config.unreadable.json") }

    public struct Contents {
        public var config: Config?
        public var secret: Data?
        /// Nil when this Mac is set up and can start.
        public var need: SetupNeed?
    }

    public func load() -> Contents {
        let secret = try? loadSecret(from: secretURL)
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return Contents(config: nil, secret: secret, need: .firstRun)
        }
        let config: Config
        do {
            config = try loadConfig(from: configURL)
        } catch {
            return Contents(config: nil, secret: secret, need: .unreadableConfig(Installation.describe(error)))
        }
        if secret != nil { return Contents(config: config, secret: secret, need: nil) }
        let missing = !FileManager.default.fileExists(atPath: secretURL.path)
        return Contents(config: config, secret: nil, need: missing ? .notPaired : .unreadableSecret)
    }

    /// A decoding failure in words that point at the line to fix.
    static func describe(_ error: Error) -> String {
        func field(_ path: [CodingKey]) -> String {
            path.isEmpty ? "the file" : "“" + path.map(\.stringValue).joined(separator: ".") + "”"
        }
        switch error {
        case let DecodingError.keyNotFound(key, context):
            return "“\((context.codingPath + [key]).map(\.stringValue).joined(separator: "."))” is missing"
        case let DecodingError.typeMismatch(_, context), let DecodingError.valueNotFound(_, context):
            return "\(field(context.codingPath)) holds the wrong kind of value"
        case let DecodingError.dataCorrupted(context):
            return context.codingPath.isEmpty ? "it is not valid JSON" : "\(field(context.codingPath)) has a value Baton does not know"
        default:
            return "\(error)"
        }
    }

    // MARK: Writing

    /// The folder is private to its user: it holds the key.
    public func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    /// Writes `config.json`, in the form the anchor rewrites it in.
    public func save(_ config: Config) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try prepare()
        try encoder.encode(config).write(to: configURL, options: .atomic)
    }

    /// Changes the config on disk. Not for the anchor while it runs: it rewrites the whole file
    /// from its own copy, so changes there go through `Anchor.updateConfig`.
    public func updateConfig(_ edit: (inout Config) -> Void) throws {
        var config = try loadConfig(from: configURL)
        edit(&config)
        try save(config)
    }

    /// The anchor remembers every Mac's displays by name (`known-displays.json`), so that a Mac
    /// that is away keeps its place. After the anchor itself is renamed, its old name would stay
    /// behind there as a Mac that never comes back.
    public func renameKnownDisplays(from old: String, to new: String) {
        let url = directory.appendingPathComponent("known-displays.json")
        guard old != new, let data = try? Data(contentsOf: url),
              var known = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let displays = known.removeValue(forKey: old)
        else { return }
        known[new] = displays
        try? JSONSerialization.data(withJSONObject: known).write(to: url, options: .atomic)
    }

    /// Moves a config that cannot be read out of the way of a new one.
    public func setAsideUnreadableConfig() throws {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return }
        try? FileManager.default.removeItem(at: unreadableConfigURL)
        try FileManager.default.moveItem(at: configURL, to: unreadableConfigURL)
    }

    /// Pairs this Mac: turns the code into `secret.key` and keeps the code beside it.
    public func pair(with code: String) throws {
        let secret = try PairingCode.secret(from: code)
        try prepare()
        try writePrivately(Data((secret.map { String(format: "%02x", $0) }.joined() + "\n").utf8), to: secretURL)
        try writePrivately(Data((PairingCode.format(code) + "\n").utf8), to: codeURL)
    }

    /// The code this Mac was paired with, as long as `secret.key` still comes from it. A key that
    /// was copied over the file since, as `scripts/deploy.sh` does, has no code.
    public var pairingCode: String? {
        guard let text = try? String(contentsOf: codeURL, encoding: .utf8),
              let derived = try? PairingCode.secret(from: text),
              let secret = try? loadSecret(from: secretURL), derived == secret
        else { return nil }
        return PairingCode.format(text)
    }

    /// Readable by its owner alone from the moment it exists.
    private func writePrivately(_ data: Data, to url: URL) throws {
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: temporary.path]) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
            guard rename(temporary.path, url.path) == 0 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}
