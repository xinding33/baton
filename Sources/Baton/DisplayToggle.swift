import AppKit
import BatonCore
import Foundation

/// The standalone Wink does the same job with its own memory of which displays are off. Two apps
/// turning displays off behind each other's back would fight, so Baton stands down while it runs.
enum Wink {
    /// The current build and the one from before the move to a Developer ID bundle ID.
    private static let bundleIDs: Set = ["io.github.xinding33.wink", "local.DisplaySwitch"]

    static var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { bundleIDs.contains($0.bundleIdentifier ?? "") && !$0.isTerminated }
    }

    /// Where Wink has kept its files, under either of its names.
    static var folders: [URL] {
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return ["Wink", "Display Switch"].map { support.appendingPathComponent($0, isDirectory: true) }
    }
}

/// Turns this Mac's external displays off and on while their cables stay plugged in, with
/// Wink's memory of which ones to keep off, its safety rules and its recovery.
///
/// A display change blocks until the system has rearranged the screens, and the main thread
/// must never block. So the controller and its files are only touched on `queue`; the main
/// thread gets the outcome as `panel`.
final class DisplayToggle {
    static var folder: URL { Paths.support.appendingPathComponent("displays", isDirectory: true) }
    static var recoveryFile: URL { folder.appendingPathComponent("recovery.json") }
    static var rememberedFile: URL { folder.appendingPathComponent("remembered.json") }
    static var ownerFile: URL { folder.appendingPathComponent("owner.pid") }

    /// Why Baton leaves this Mac's displays alone at the moment, if it does. Main thread only.
    static var reasonToStandDown: String? {
        if Wink.isRunning {
            return "Wink is running and controls these displays.\nQuit Wink to switch them from Baton."
        }
        // A second instance must not act on displays the installed one is looking after.
        if ProcessInfo.processInfo.environment["BATON_HOME"] != nil {
            return "This is a test instance, which leaves displays alone."
        }
        return nil
    }

    /// What the system calls each display, which only AppKit knows. Main thread only.
    static func screenNames() -> [UInt32: String] {
        currentDisplays().reduce(into: [:]) { $0[$1.id] = $1.name }
    }

    static func makeController() -> DisplayController {
        DisplayController(backend: NativeDisplayBackend(), store: RecoveryStore(url: recoveryFile), preferences: PreferenceStore(url: rememberedFile))
    }

    private let queue = DispatchQueue(label: "baton.displays", qos: .userInitiated)

    // Touched on `queue` only.
    private let controller = DisplayToggle.makeController()
    private let helper = WatchdogProcess()
    private var standDown: String?
    private var decided = false
    private var lastError: String?
    private var helperFailure: String?
    /// Displays that failed to turn off on their own are left alone until they are turned off by hand.
    private var gaveUp: Set<String> = []

    // Main thread only.
    private(set) var panel = DisplayPanel()
    var onChange: (() -> Void)?
    private var pendingApply: DispatchWorkItem?
    private var timer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []

    func start() {
        enqueue { [self] in
            startHelper()
            let failures = controller.adopt()
            if !failures.isEmpty { lastError = failures.joined(separator: "\n") }
            let off = (try? controller.remembered().map(\.name)) ?? []
            log("displays: started" + (off.isEmpty ? "" : ", keeping off: \(off.joined(separator: ", "))"))
            failures.forEach { log("displays: \(oneLine($0))") }
        }
        // Displays that reappear after sleep or a cable change are turned off again once they settle.
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleApply(after: 1.5)
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleApply(after: 2)
        })
        timer = repeatingTimer(every: 2) { [weak self] in
            self?.enqueue(names: [:]) { self?.watch() }
        }
    }

    /// Carries out what Settings or the menu asked for. The outcome shows up in `panel`.
    func perform(_ action: DisplayAction) {
        // Let the menu close before the screens rearrange.
        enqueue(after: 0.1) { [self] in
            let startedAt = Net.monotonicMillis()
            do {
                if case let .turnOff(uuid) = action {
                    if let standDown { throw DisplayError(standDown) }
                    guard startHelper() else { throw DisplayError("The recovery helper is not running, so no display is turned off.") }
                    gaveUp.remove(uuid)
                }
                try controller.perform(action)
                lastError = nil
                log("displays: \(action) took \(Net.monotonicMillis() - startedAt) ms")
            } catch {
                lastError = error.localizedDescription
                log("displays: \(action) failed after \(Net.monotonicMillis() - startedAt) ms: \(oneLine(error.localizedDescription))")
            }
        }
    }

    /// For Quit, after which Baton is not there to turn anything back on: reconnects the displays,
    /// then exits. They stay remembered, and are turned off again when Baton next starts.
    func reconnectAllAndExit() {
        queue.async { [self] in
            let failures = controller.reconnectAll()
            failures.forEach { log("displays: \($0)") }
            // After a failure the watchdog is left to try again once Baton is gone.
            if failures.isEmpty { helper.stop() }
            exit(0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { exit(0) }
    }

    // MARK: On the main thread

    private func scheduleApply(after delay: TimeInterval) {
        pendingApply?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.enqueue { self?.apply() }
        }
        pendingApply = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Runs `body` on the display queue, knowing the displays' names and whether to stand down
    /// as of now, and passes the resulting panel back.
    private func enqueue(after delay: TimeInterval = 0, names: [UInt32: String] = DisplayToggle.screenNames(), _ body: @escaping () -> Void) {
        let reason = DisplayToggle.reasonToStandDown
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            (controller.backend as? NativeDisplayBackend)?.names.merge(names) { _, new in new }
            settle(standDown: reason)
            body()
            let panel = controller.panel(unavailable: standDown, lastError: lastError)
            DispatchQueue.main.async {
                guard panel != self.panel else { return }
                self.panel = panel
                self.onChange?()
            }
        }
    }

    // MARK: On the display queue

    /// Adopts the latest reason to stand down. Once there is none, Baton is in charge of the
    /// displays: the first time ever, it takes over the ones Wink remembered.
    private func settle(standDown reason: String?) {
        guard reason != standDown || !decided else { return }
        decided = true
        standDown = reason
        if let reason {
            return log("displays: standing down (\(oneLine(reason)))")
        }
        do {
            if let preferences = controller.preferences, let copied = try WinkImport.run(from: Wink.folders, into: preferences) {
                log("displays: took over \(copied.count) remembered display(s) from Wink" + (copied.isEmpty ? "" : ": \(copied.map(\.name).joined(separator: ", "))"))
            }
        } catch {
            log("displays: could not read Wink's remembered displays: \(error.localizedDescription)")
        }
        log("displays: in charge")
        // Give displays time to come online, after login in particular, before turning any off.
        DispatchQueue.main.async { self.scheduleApply(after: 2) }
    }

    /// Makes sure the watchdog is running. No display is turned off without it.
    @discardableResult
    private func startHelper() -> Bool {
        if helper.running { return true }
        do {
            try helper.start(folder: DisplayToggle.folder)
            // Claimed only now, so the previous agent's watchdog keeps watching until this one's does.
            try DisplayOwner(url: DisplayToggle.ownerFile).claim(getpid())
            helperFailure = nil
            return true
        } catch {
            // This is retried every two seconds; say so once.
            if helperFailure != error.localizedDescription { log("displays: cannot start the watchdog: \(error.localizedDescription)") }
            helperFailure = error.localizedDescription
            return false
        }
    }

    /// Turns off the connected displays that are remembered as off.
    private func apply() {
        guard standDown == nil, startHelper() else { return }
        let startedAt = Net.monotonicMillis()
        let before = (try? controller.remembered().count) ?? 0
        let failures = controller.applyPreferences(skipping: gaveUp)
        if !failures.isEmpty {
            gaveUp.formUnion(failures.keys)
            lastError = failures.values.sorted().joined(separator: "\n")
            failures.values.sorted().forEach { log("displays: could not turn off \($0)") }
        }
        let after = (try? controller.remembered().count) ?? 0
        if after > before { log("displays: turned off \(after - before) remembered display(s) in \(Net.monotonicMillis() - startedAt) ms") }
    }

    private func watch() {
        var failures: [String] = []
        if !startHelper() {
            // Never leave a display off with nothing to bring it back.
            failures += controller.reconnectAll()
        }
        if controller.isDark, (try? controller.remembered().isEmpty) == false {
            log("displays: no active screen left; reconnecting the ones turned off")
            failures += controller.reconnectAll()
        }
        if !failures.isEmpty { lastError = failures.joined(separator: "\n") }
    }
}

private func oneLine(_ text: String) -> String {
    text.replacingOccurrences(of: "\n", with: " ")
}

/// The child process that reconnects displays if the agent dies for good or every remaining
/// screen disappears. It runs this same executable; see `runDisplayWatchdog`.
///
/// `Process` starts its child in a process group of its own. That matters: when the agent stops,
/// launchd kills what is left of the agent's process group, and the watchdog has to outlive it.
private final class WatchdogProcess {
    private var process: Process?
    var running: Bool { process?.isRunning == true }

    func start(folder: URL) throws {
        let child = Process()
        child.executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        child.arguments = ["display-watchdog", String(getpid()), folder.path]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        process = child
    }

    func stop() {
        if running {
            process?.terminate()
            process?.waitUntilExit()
        }
        process = nil
    }
}

/// `Baton display-watchdog <agent pid> <folder>`: what the agent starts to watch over the
/// displays it turns off. It only ever reconnects displays the agent recorded.
func runDisplayWatchdog(_ words: [String]) -> Int32 {
    guard words.count == 2, let agent = Int32(words[0]) else { return 64 }
    let folder = URL(fileURLWithPath: words[1], isDirectory: true)
    let controller = DisplayController(backend: NativeDisplayBackend(), store: RecoveryStore(url: folder.appendingPathComponent("recovery.json")))
    let owner = DisplayOwner(url: folder.appendingPathComponent("owner.pid"))
    let note = watchdogLog(folder)
    var watchdog = Watchdog(agent: agent)
    while true {
        let current = owner.current()
        let step = watchdog.step(
            now: ProcessInfo.processInfo.systemUptime,
            agentAlive: getppid() == agent && kill(agent, 0) == 0,
            owner: current,
            ownerAlive: current.map { kill($0, 0) == 0 } ?? false,
            anyActiveDisplay: !controller.isDark
        )
        switch step {
        case .wait:
            break
        case .reconnect:
            if (try? controller.remembered().isEmpty) == false {
                note("no active screen left; reconnecting: \(controller.reconnectAll())")
            }
        case .finish(reconnect: false):
            note("agent \(agent) is gone and \(current ?? 0) has taken over; displays left as they are")
            return 0
        case .finish(reconnect: true):
            let off = (try? controller.remembered().map(\.name)) ?? []
            note("agent \(agent) is gone and none took over; reconnecting \(off)")
            for _ in 0..<3 {
                let failures = controller.reconnectAll()
                if failures.isEmpty { break }
                note("could not reconnect: \(failures)")
                Thread.sleep(forTimeInterval: 1)
            }
            return 0
        }
        Thread.sleep(forTimeInterval: 1)
    }
}

/// The watchdog's own log, next to the agent's. The agent's log handle does not append, so two
/// processes cannot share that file.
private func watchdogLog(_ folder: URL) -> (String) -> Void {
    let url = Paths.log.deletingLastPathComponent().appendingPathComponent("display-watchdog.log")
    let formatter = ISO8601DateFormatter()
    return { message in
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        let line = "\(formatter.string(from: Date())) [\(getpid())] \(message)\n"
        _ = line.withCString { write(fd, $0, strlen($0)) }
        close(fd)
    }
}

/// `Baton display-check`: what display control sees on this Mac, without touching anything
/// and without the agent. `display-check run <seconds> [displays command]` runs display control
/// by itself for a while under `BATON_HOME`, where it has its own files and leaves every display
/// alone, and gives it the command as `ctl displays` would.
func runDisplayCheck(_ words: [String]) -> Int32 {
    func show(_ rows: [SettingsRow]) {
        print(rows.map(\.line).joined(separator: "\n"))
    }
    if words.first == "run" {
        guard ProcessInfo.processInfo.environment["BATON_HOME"] != nil else {
            print("display-check run needs BATON_HOME, to stay out of the installed agent's way")
            return 64
        }
        var displayMenu: DisplayMenu?
        displayMenu = DisplayMenu(anchor: nil, client: nil) {
            print("settings:")
            show(displayMenu?.settingsPane.rows ?? [])
        }
        if words.count > 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { print(displayMenu?.command(Array(words.dropFirst(2))) ?? "") }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(words.count > 1 ? Double(words[1]) ?? 5 : 5))
        return 0
    }
    let controller = DisplayToggle.makeController()
    (controller.backend as? NativeDisplayBackend)?.names = DisplayToggle.screenNames()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    func json<T: Encodable>(_ value: T) -> String { String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self) }
    print("display disconnect API: \(controller.backend.available ? "available" : "unavailable")")
    print("online displays: \(json((try? controller.backend.displays()) ?? []))")
    print("layout displays: \(currentDisplays().map { "\($0.name) \(Int($0.frame.width))x\(Int($0.frame.height)) at (\(Int($0.frame.minX)),\(Int($0.frame.minY)))" })")
    print("stands down: \(DisplayToggle.reasonToStandDown.map(oneLine) ?? "no")")
    print("turned off by Baton: \(json((try? controller.remembered()) ?? []))")
    print("remembered by Baton: \(FileManager.default.fileExists(atPath: DisplayToggle.rememberedFile.path) ? json((try? controller.preferences?.load()) ?? []) : "nothing yet")")
    for folder in Wink.folders {
        let theirs = PreferenceStore(url: folder.appendingPathComponent("remembered.json"))
        guard FileManager.default.fileExists(atPath: theirs.url.path) else { continue }
        print("remembered by Wink in \(folder.lastPathComponent): \(json((try? theirs.load()) ?? []))")
    }
    print("settings:")
    show(DisplayMenu.rows(for: controller.panel(unavailable: DisplayToggle.reasonToStandDown)) { _ in })
    return controller.backend.available ? 0 : 1
}
