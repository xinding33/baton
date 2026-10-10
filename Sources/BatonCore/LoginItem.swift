import Foundation

/// Open at Login is a launch agent in `~/Library/LaunchAgents`. launchd starts Baton with it at
/// login and again after a crash, and leaves it stopped after Quit.
///
/// It is the agent `scripts/install-agent.sh` has always written, under the same label, so a
/// Mac set up that way already has Open at Login on.
public struct LaunchAgent {
    public static let label = "com.xinding.baton"

    public let url: URL

    public init(directory: URL = LaunchAgent.directory()) {
        url = directory.appendingPathComponent("\(LaunchAgent.label).plist")
    }

    /// Where the agent's file goes. `BATON_LAUNCH_AGENTS` names another folder, and an instance
    /// run with `BATON_HOME` keeps its agent inside that folder, so neither a test nor a second
    /// instance can touch the agent of the installed Baton.
    public static func directory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let override = environment["BATON_LAUNCH_AGENTS"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if let testHome = environment["BATON_HOME"] {
            return URL(fileURLWithPath: testHome, isDirectory: true).appendingPathComponent("LaunchAgents", isDirectory: true)
        }
        return home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    /// Whether `directory()` is somewhere other than the real `~/Library/LaunchAgents`.
    public static func isRedirected(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["BATON_LAUNCH_AGENTS"] != nil || environment["BATON_HOME"] != nil
    }

    public static func propertyList(executable: String) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [executable],
            // Lists the agent under Baton's name in System Settings › General › Login Items.
            "AssociatedBundleIdentifiers": label,
            "RunAtLoad": true,
            // Started again after a crash, left alone after Quit.
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 5,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "StandardErrorPath": "/dev/null",
        ]
    }

    public var isInstalled: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// The program the installed agent starts.
    public var executable: String? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return (plist["ProgramArguments"] as? [String])?.first
    }

    public func install(executable: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let plist = LaunchAgent.propertyList(executable: executable)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url, options: .atomic)
    }

    public func remove() throws {
        guard isInstalled else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Points an installed agent at `executable` if it starts another copy, as it does after
    /// Baton has moved, say from `~/Applications` to `/Applications`. An agent that is already
    /// right is not rewritten. Returns the path that was replaced.
    @discardableResult
    public func correct(executable: String) throws -> String? {
        guard isInstalled else { return nil }
        let current = self.executable
        if let current, LaunchAgent.samePath(current, executable) { return nil }
        try install(executable: executable)
        return current ?? "an unreadable file"
    }

    static func samePath(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).standardizedFileURL.path == URL(fileURLWithPath: b).standardizedFileURL.path
    }

    /// macOS runs an app that is opened straight out of a download from a random, read-only
    /// copy of it, which is gone after a restart.
    public static func isTranslocated(_ executable: String) -> Bool {
        executable.contains("/AppTranslocation/")
    }

    /// Whether a copy of Baton has any business with the agent in `directory()`. A build run
    /// from the source tree has none with the installed app's agent, to write it or to remove it.
    public static func belongs(toExecutable executable: String, redirected: Bool = LaunchAgent.isRedirected()) -> Bool {
        redirected || executable.contains(".app/Contents/MacOS/")
    }

    /// Why an agent must not point at `executable`, or nil if it may.
    public static func problem(withExecutable executable: String, redirected: Bool = LaunchAgent.isRedirected()) -> String? {
        if isTranslocated(executable) {
            return "Move Baton to the Applications folder and open it from there. Opened from where it was downloaded, it has no lasting place to start from."
        }
        // A build run from the source tree must not take the installed app's place at login.
        if !belongs(toExecutable: executable, redirected: redirected) {
            return "Open at Login needs Baton.app; this copy is a bare program."
        }
        return nil
    }
}
