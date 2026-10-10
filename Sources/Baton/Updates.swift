import AppKit
import BatonCore
import Network

/// One end of the update link, carrying `UpdateMessage` frames. Callbacks run on the main queue.
final class UpdateConnection {
    private let connection: NWConnection
    var onReady: (() -> Void)?
    var onMessage: ((UpdateMessage) -> Void)?
    var onClose: (() -> Void)?
    private(set) var isReady = false
    private var closed = false

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.isReady = true
                self.onReady?()
                self.readHeader()
            case .failed, .waiting, .cancelled:
                self.close()
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    func send(_ message: UpdateMessage) {
        guard !closed else { return }
        connection.send(content: message.frame(), completion: .contentProcessed { [weak self] error in
            if error != nil { self?.close() }
        })
    }

    func close() {
        guard !closed else { return }
        closed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClose?()
    }

    private func readHeader() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, _ in
            guard let self, !self.closed else { return }
            guard let data, let length = UpdateMessage.length(ofHeader: data) else { return self.close() }
            length == 0 ? self.readHeader() : self.readBody(length)
        }
    }

    private func readBody(_ length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, _ in
            guard let self, !self.closed else { return }
            guard let data, data.count == length else { return self.close() }
            // A message from a version that knows more than this one is skipped, not an error.
            if let message = UpdateMessage(body: data) { self.onMessage?(message) }
            self.readHeader()
        }
    }
}

/// Restarts Baton into the copy that has just been swapped in.
enum Relaunch {
    /// Whether launchd runs this process as a job of its own. The agent that
    /// `scripts/install-agent.sh` installs is one, and is started again when it exits with a failure.
    static var isLaunchdJob: Bool {
        let service = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] ?? ""
        return getppid() == 1 && !service.isEmpty && service != "0" && !service.hasPrefix("application.")
    }

    static func now() -> Never {
        if isLaunchdJob { exit(75) }
        // Opened by hand: something has to outlive this process to start the new copy. `Process`
        // puts it in a process group of its own.
        var start = [Bundle.main.executablePath ?? CommandLine.arguments[0]] + CommandLine.arguments.dropFirst()
        if start.count == 1, Bundle.main.bundlePath.hasSuffix(".app") {
            // Through LaunchServices, as when it was opened, so that the new process stands for
            // itself where permissions are concerned.
            start = ["/usr/bin/open", "-n", Bundle.main.bundlePath]
            if let home = ProcessInfo.processInfo.environment["BATON_HOME"] { start += ["--env", "BATON_HOME=\(home)"] }
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.1; done; exec \"$@\"", "sh"] + start
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try? child.run()
        exit(0)
    }
}

/// Keeps Baton up to date from its GitHub releases, on every Mac at once: the Updates pane, the
/// daily check, the update link between the Macs, and the restart. Who downloads what and when
/// everyone restarts is decided by `UpdateLeader` on the anchor (BatonCore); the clients follow.
///
/// Downloads, signature checks and the swap run off the main thread. Everything else here is
/// main-thread only.
final class Updates: NSObject {
    static let shared = Updates()

    private static var settingsFile: URL { Paths.support.appendingPathComponent("update.json") }
    private static var downloads: URL { Paths.support.appendingPathComponent("updates", isDirectory: true) }

    /// The anchor's: its choice counts for every Mac.
    struct Settings: Codable {
        var automatic = true
        var lastCheck = Date.distantPast

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            automatic = try c.decodeIfPresent(Bool.self, forKey: .automatic) ?? true
            lastCheck = try c.decodeIfPresent(Date.self, forKey: .lastCheck) ?? .distantPast
        }
    }

    /// `update-check run`: the updater by itself, with no input link to tell it who is sharing
    /// input or what the keyboard is doing.
    struct Harness {
        /// Count every Mac on the update link as sharing input.
        var together: Bool
        var conditions = RestartConditions.idle
    }

    /// Something the menu or Settings shows has changed.
    var onStateChanged: (() -> Void)?
    var harness: Harness?

    private var name = ""
    private var role = Role.client
    private var port: UInt16 = 0
    private var secret = Data()
    private weak var anchor: Anchor?
    private weak var client: ClientAgent?
    private let app = Bundle.main.bundleURL
    /// What this copy is as far as updating goes; see `ready`.
    private var build = Build.current
    /// Why this copy does not update itself, if it does not.
    private(set) var whyNot: String?
    private var settings = Settings()
    private var timer: DispatchSourceTimer?
    private var checking = false
    private var nextCheckAt = Date.distantFuture
    private var shown = ""
    private var recent: [String] = []

    // On the anchor.
    private var leader: UpdateLeader?
    private var listener: NWListener?
    private var links: [String: UpdateConnection] = [:]
    /// Connections that have not said hello yet.
    private var greeting: [ObjectIdentifier: UpdateConnection] = [:]

    // On a client.
    private var follower: UpdateFollower?
    private var link: UpdateConnection?
    private var anchorHost: NWEndpoint.Host?
    private var anchorBuild: (name: String, build: Build)?
    private var anchorState: (automatic: Bool, activity: String?)?
    /// Someone here asked the anchor for a release and has not heard how it went.
    private var asked = false
    /// The release this client is installing by itself, because no anchor is in reach.
    private var alone: Version?
    private var ownActivity: String?

    /// `build` stands in for the running copy in tests.
    func start(as config: Config, secret: Data, anchor: Anchor?, client: ClientAgent?, build: Build? = nil) {
        name = config.name
        role = config.role
        port = config.port &+ 2
        self.secret = secret
        self.anchor = anchor
        self.client = client
        if let data = try? Data(contentsOf: Self.settingsFile), let saved = try? JSONDecoder().decode(Settings.self, from: data) {
            settings = saved
        }
        // The input link gets there first, and says where the anchor is even if it is then refused.
        client?.onAnchorReached = { [weak self] in self?.reached($0) }
        if client == nil, let host = config.anchorHost { reached(NWEndpoint.Host(host)) }

        let stamped = build ?? Build.current
        let app = self.app
        // Checking a signature reads the whole bundle, which the main thread has no time for.
        DispatchQueue.global(qos: .utility).async {
            let signed = stamped.kind == .release && (build != nil || Updater.isDeveloperIDSigned(app))
            DispatchQueue.main.async { self.ready(stamped, signed: signed) }
        }
    }

    private func ready(_ stamped: Build, signed: Bool) {
        // Only a release signed like the published ones can be replaced by one.
        build = Build(version: stamped.version, kind: signed ? .release : .development)
        if stamped.kind == .development {
            whyNot = "This copy was built from source, so it doesn't update itself."
        } else if !signed {
            whyNot = "This copy isn't signed with a Developer ID, so it can't update itself."
        }
        note("Baton \(stamped) at \(app.path)" + (whyNot == nil ? "" : "; it does not update itself"))
        removeOldDownloads()
        switch role {
        case .anchor:
            leader = UpdateLeader(own: build)
            listen()
            nextCheckAt = Date().addingTimeInterval(30)
        case .client:
            follower = UpdateFollower(own: build)
            connect()
        }
        timer = repeatingTimer(every: 1) { [weak self] in self?.tick() }
        changed()
    }

    private func note(_ text: String) {
        log("updates: \(text)")
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        recent = Array((recent + ["\(time) \(text)"]).suffix(12))
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(settings).write(to: Self.settingsFile, options: .atomic)
        } catch {
            note("could not save \(Self.settingsFile.lastPathComponent): \(error)")
        }
    }

    /// Releases this copy has reached or passed are no use any more.
    private func removeOldDownloads() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.downloads, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            let version = Version(file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "Baton-", with: ""))
            if version.map({ $0 <= build.version }) ?? true { try? FileManager.default.removeItem(at: file) }
        }
    }

    // MARK: The update link

    /// The input link's TLS, as ordinary traffic. See `UpdateMessage` for what must never change.
    private var parameters: NWParameters {
        let parameters = Net.tlsParameters(secret: secret)
        parameters.serviceClass = .bestEffort
        return parameters
    }

    private var hello: UpdateMessage { .hello(name: name, version: build.version, kind: build.kind) }

    private func listen() {
        do {
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            listener.stateUpdateHandler = { [weak self] state in
                guard case let .failed(error) = state else { return }
                self?.note("the update link stopped listening: \(error)")
                self?.listener?.cancel()
                self?.listener = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self?.listen() }
            }
            listener.newConnectionHandler = { [weak self] in self?.accept($0) }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            note("the update link cannot listen on port \(port): \(error)")
        }
    }

    private func accept(_ connection: NWConnection) {
        let link = UpdateConnection(connection)
        let id = ObjectIdentifier(link)
        greeting[id] = link
        var peer: String?
        link.onMessage = { [weak self, weak link] message in
            guard let self, let link else { return }
            if case let .hello(name, version, kind) = message, name != self.name {
                self.greeting[id] = nil
                if let old = self.links[name], old !== link {
                    old.onClose = nil
                    old.close()
                }
                peer = name
                self.links[name] = link
                link.send(self.hello)
                link.send(self.state)
                self.note("\(name) has Baton \(Build(version: version, kind: kind))")
                self.perform(self.leader?.joined(name, version: version, kind: kind, now: Net.monotonicMillis()) ?? [])
            } else if let peer, self.links[peer] === link {
                self.received(message, from: peer)
            }
        }
        link.onClose = { [weak self, weak link] in
            guard let self else { return }
            self.greeting[id] = nil
            guard let peer, self.links[peer] === link else { return }
            self.links[peer] = nil
            self.leader?.left(peer)
            self.changed()
        }
        link.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.greeting.removeValue(forKey: id)?.close()
        }
    }

    private func reached(_ host: NWEndpoint.Host) {
        let known = anchorHost.map { "\($0)" } == "\(host)"
        anchorHost = host
        if follower != nil, link == nil || !known { connect() }
    }

    private func connect() {
        guard let host = anchorHost, let port = NWEndpoint.Port(rawValue: port) else { return }
        if let old = link {
            old.onClose = nil
            old.close()
            lostAnchor()
        }
        let link = UpdateConnection(NWConnection(host: host, port: port, using: parameters))
        self.link = link
        link.onReady = { [weak self, weak link] in
            guard let self, let link, self.link === link else { return }
            link.send(self.hello)
        }
        link.onMessage = { [weak self, weak link] message in
            guard let self, self.link === link else { return }
            self.received(message)
        }
        link.onClose = { [weak self, weak link] in
            guard let self, self.link === link else { return }
            self.lostAnchor()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                if self?.link == nil { self?.connect() }
            }
        }
        link.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak link] in
            if let link, !link.isReady { link.close() }
        }
    }

    private func lostAnchor() {
        link = nil
        anchorBuild = nil
        anchorState = nil
        asked = false
        changed()
    }

    // MARK: On the anchor

    private var state: UpdateMessage {
        .state(automatic: settings.automatic && build.kind == .release, activity: checking ? "Checking for Updates…" : leader?.activity)
    }

    private func received(_ message: UpdateMessage, from peer: String) {
        let now = Net.monotonicMillis()
        switch message {
        case let .prepared(version, ok, detail):
            note(ok ? "\(peer) has Baton \(version) ready" : "\(peer) cannot install Baton \(version): \(detail)")
            leader?.prepared(peer, version: version, ok: ok, detail: detail, now: now)
        case let .lead(version):
            note("\(peer) asks for Baton \(version)")
            perform(leader?.begin(version, origin: .peer(peer), urgency: .soon, now: now) ?? [])
        case let .setAutomatic(value):
            setAutomatic(value)
        default:
            break
        }
    }

    private func perform(_ actions: [UpdateLeader.Action]) {
        for action in actions {
            switch action {
            case let .send(peer, message):
                if case let .prepare(version) = message { note("asking \(peer) to download Baton \(version)") }
                if case let .install(version) = message { note("telling \(peer) to install Baton \(version)") }
                links[peer]?.send(message)
            case let .prepareSelf(version):
                note("downloading Baton \(version)")
                download(version) { [weak self] error in
                    guard let self else { return }
                    if error == nil { self.note("Baton \(version) is ready here") }
                    self.perform(self.leader?.selfPrepared(version, error: error) ?? [])
                }
            case let .installSelf(version):
                note("installing Baton \(version)")
                swap(version) { [weak self] error in
                    guard let self else { return }
                    if let error {
                        self.perform(self.leader?.selfInstallFailed(version, error: error) ?? [])
                    } else {
                        self.perform(self.leader?.selfInstalled(version) ?? [])
                    }
                }
            case .restart:
                restart()
            case let .failed(origin, version, detail):
                note("Baton \(version) was not installed: \(detail)")
                switch origin {
                case .automatic: break
                case .here: couldNotUpdate(detail)
                // Read at the client, "this Mac" would be the wrong one.
                case let .peer(peer): links[peer]?.send(.result(ok: false, detail: detail.replacingOccurrences(of: "This Mac", with: name)))
                }
            }
        }
        changed()
    }

    /// The clients sharing input with this anchor right now.
    private var sharingInput: Set<String> {
        harness.map { $0.together ? Set(links.keys) : [] } ?? Set(anchor?.peerNames ?? [])
    }

    private func tick() {
        guard leader != nil else { return }
        let inSession = sharingInput
        let conditions = harness?.conditions ?? anchor?.restartConditions ?? .idle
        perform(leader?.tick(now: Net.monotonicMillis(), inSession: inSession, conditions: conditions) ?? [])
        if Date() >= nextCheckAt {
            nextCheckAt = Date().addingTimeInterval(60 * 60)
            checkAutomatically()
        }
    }

    /// When automatic updates are on, looks once a day and moves every Mac to a newer release.
    /// Failures are logged and retried an hour later.
    private func checkAutomatically(evenIfNotDue: Bool = false) {
        guard build.kind == .release, leader?.target == nil, !checking else { return }
        guard evenIfNotDue || (settings.automatic && UpdatePolicy.isCheckDue(last: settings.lastCheck, now: Date())) else { return }
        check { [weak self] release, error in
            guard let self else { return }
            if let error { return self.note("could not check for updates: \(error)") }
            guard let release, release.version > self.build.version else {
                self.settings.lastCheck = Date()
                return self.save()
            }
            self.note("Baton \(release.version) is available")
            self.perform(self.leader?.begin(release.version, origin: .automatic, urgency: .whenIdle, now: Net.monotonicMillis()) ?? [])
        }
    }

    private func setAutomatic(_ value: Bool) {
        guard role == .anchor, value != settings.automatic else { return }
        settings.automatic = value
        save()
        note("install updates automatically: \(value)")
        if value { nextCheckAt = Date() }
        changed()
    }

    // MARK: On a client

    private func received(_ message: UpdateMessage) {
        switch message {
        case let .hello(name, version, kind):
            anchorBuild = (name, Build(version: version, kind: kind))
            note("\(name) has Baton \(Build(version: version, kind: kind))")
        case let .state(automatic, activity):
            anchorState = (automatic, activity)
        case let .result(ok, detail):
            if asked, !ok { couldNotUpdate(detail) }
            asked = false
        case .prepare, .install:
            run(follower?.received(message) ?? [])
        default:
            break
        }
        changed()
    }

    private func run(_ actions: [UpdateFollower.Action]) {
        for action in actions {
            switch action {
            case let .send(message):
                link?.send(message)
            case let .prepare(version):
                note("downloading Baton \(version)")
                download(version) { [weak self] error in
                    guard let self else { return }
                    self.note(error.map { "could not get Baton \(version): \($0)" } ?? "Baton \(version) is ready here")
                    self.run(self.follower?.finishedPreparing(version, error: error) ?? [])
                    if self.alone == version { self.installAlone(failure: error) }
                }
            case let .install(version):
                install(version)
            }
        }
        changed()
    }

    private func install(_ version: Version) {
        // Not in the middle of a Bluetooth step: that could leave the keyboard paired with no Mac.
        if client?.keyboardBusy == true {
            return DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.install(version) }
        }
        note("installing Baton \(version)")
        ownActivity = "Installing Baton \(version)…"
        swap(version) { [weak self] error in
            guard let self else { return }
            guard let error else { return self.restart() }
            self.note("could not install Baton \(version): \(error)")
            self.ownActivity = nil
            self.run(self.follower?.installFailed(version, error: error) ?? [])
            if self.alone == version {
                self.alone = nil
                self.couldNotUpdate(error)
            }
        }
    }

    /// With no anchor in reach, a client can only update itself. The anchor follows when it sees
    /// this Mac on the newer release.
    private func installAlone(failure: String? = nil) {
        guard let version = alone else { return }
        if let failure {
            alone = nil
            ownActivity = nil
            couldNotUpdate(failure)
        } else if follower?.prepared == version {
            run(follower?.received(.install(version)) ?? [])
        }
        changed()
    }

    // MARK: Downloading, swapping, restarting

    private func download(_ version: Version, completion: @escaping (String?) -> Void) {
        let app = self.app
        let folder = Self.downloads
        Task.detached {
            var failure: String?
            do {
                _ = try await Updater.download(version, into: folder, toReplace: app)
            } catch {
                failure = error.localizedDescription
            }
            let outcome = failure
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    /// Puts the downloaded release in place of this copy, wherever this copy is.
    private func swap(_ version: Version, completion: @escaping (String?) -> Void) {
        let app = self.app
        let zip = Self.downloads.appendingPathComponent("Baton-\(version).zip")
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            do {
                try Updater.install(zip: zip, version: version, replacing: app)
            } catch {
                failure = error.localizedDescription
            }
            DispatchQueue.main.async { completion(failure) }
        }
    }

    private func restart() {
        note("restarting into the new copy")
        // Hand the mouse back first, as before being stopped by a deploy.
        anchor?.goLocal(at: nil)
        // Leave time for the last messages and the log to go out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { Relaunch.now() }
    }

    // MARK: Checking

    private func check(_ completion: @escaping (Release?, String?) -> Void) {
        checking = true
        changed()
        let finish = { [weak self] (release: Release?, failure: String?) in
            self?.checking = false
            completion(release, failure)
            self?.changed()
        }
        Task.detached {
            var release: Release?
            var failure: String?
            do {
                release = try await Updater.latestRelease()
            } catch {
                failure = error.localizedDescription
            }
            let outcome = (release, failure)
            DispatchQueue.main.async { finish(outcome.0, outcome.1) }
        }
    }

    /// Moves this Mac, and with it the others, to release `version`. `byHand` says someone at
    /// this Mac is waiting to see how it goes.
    private func install(_ version: Version, byHand: Bool) {
        switch role {
        case .anchor:
            perform(leader?.begin(version, origin: byHand ? .here : .automatic, urgency: .soon, now: Net.monotonicMillis()) ?? [])
        case .client:
            if let link, anchorBuild != nil {
                asked = byHand
                link.send(.lead(version))
            } else if alone == nil {
                alone = version
                ownActivity = "Installing Baton \(version)…"
                run(follower?.received(.prepare(version)) ?? [])
                installAlone()
            }
        }
    }

    private func couldNotUpdate(_ detail: String) {
        // The harness has no application to show an alert with.
        guard harness == nil else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Couldn't update Baton"
        alert.informativeText = detail
        alert.runModal()
    }

    // MARK: Settings and the menu

    /// What is being downloaded or installed, on this Mac or for all of them.
    private var progress: String? { leader?.activity ?? ownActivity ?? anchorState?.activity }
    private var activity: String? { checking ? "Checking for Updates…" : progress }

    private var isAutomatic: Bool {
        guard build.kind == .release else { return false }
        return role == .anchor ? settings.automatic : anchorState?.automatic ?? false
    }

    /// Macs on another version than this one. They cannot share input until that is put right.
    private var strays: String? {
        if let anchorBuild, anchorBuild.build.version != build.version {
            return "\(anchorBuild.name) has Baton \(anchorBuild.build.version), this Mac \(build.version)"
        }
        let others = (leader?.peers ?? [:]).filter { $0.value.version != build.version }
        guard !others.isEmpty else { return nil }
        return others.sorted { $0.key < $1.key }.map { "\($0.key) has Baton \($0.value.version)" }.joined(separator: ", ") + ", this Mac \(build.version)"
    }

    /// Redraws the menu and tells the clients, if what they show has changed.
    private func changed() {
        let now = "\(activity ?? "")|\(isAutomatic)|\(strays ?? "")|\(anchorBuild?.name ?? "")"
        guard now != shown else { return }
        shown = now
        if role == .anchor { links.values.forEach { $0.send(state) } }
        onStateChanged?()
    }

    /// The one line the menu has for updates, and only while there is something to say: an
    /// update on its way in, or Macs that are on different versions. The daily check is not it.
    var menuLine: String? { progress ?? strays }

    /// The Updates pane of Settings.
    private(set) lazy var settingsPane = FormPane(id: StatusMenu.Pane.updates, title: "Updates", symbol: "arrow.down.circle") { [unowned self] in self.settingsRows() }

    private func settingsRows() -> [SettingsRow] {
        var rows: [SettingsRow] = [.header("Baton \(build.version)")]
        if let whyNot { rows.append(.text(whyNot)) }
        if let strays { rows.append(.note("\(strays). Macs on different versions cannot share input.")) }
        let activity = self.activity
        rows.append(.button(activity ?? "Check for Updates…", enabled: activity == nil) { [unowned self] in self.checkForUpdates() })
        // The anchor's switch counts for every Mac; a client changes it there.
        let reachable = role == .anchor || (anchorState != nil && anchorBuild?.build.kind == .release)
        rows.append(.toggle("Install updates automatically", on: isAutomatic, enabled: build.kind == .release && reachable,
                            detail: "Once a day. Your Macs update together, when the mouse and keyboard have been left alone for a minute.") { [unowned self] on in
            if self.role == .anchor {
                self.setAutomatic(on)
            } else {
                self.link?.send(.setAutomatic(on))
            }
        })
        rows.append(.text("For all your Macs: they are always on the same version, and the switch is the same on every one."))
        return rows
    }

    private func checkForUpdates() {
        check { [self] release, error in
            if let error { return couldNotUpdate(error) }
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            guard let release, release.version > build.version else {
                alert.messageText = "Baton is up to date"
                alert.informativeText = "Version \(build.version) is the latest."
                alert.runModal()
                return
            }
            alert.messageText = "Baton \(release.version) is available"
            alert.informativeText = "You have version \(build.version). " + (whyNot ?? "All your connected Macs update together.")
            if whyNot == nil { alert.addButton(withTitle: "Install and Restart") }
            alert.addButton(withTitle: "Release Notes")
            alert.addButton(withTitle: "Later")
            switch (alert.runModal(), whyNot == nil) {
            case (.alertFirstButtonReturn, true): install(release.version, byHand: true)
            case (.alertFirstButtonReturn, false), (.alertSecondButtonReturn, true): NSWorkspace.shared.open(release.page)
            default: break
            }
        }
    }

    // MARK: Control commands

    /// `update` reports; `update check` looks for a release now, `update install <version>` moves
    /// every Mac to that release, and `update auto on|off` switches automatic updates.
    func command(_ words: [String]) -> String {
        switch (words.first, words.count) {
        case (nil, _):
            return status()
        case ("check", 1):
            guard role == .anchor else { return "the anchor checks for every Mac; run this there" }
            guard whyNot == nil else { return whyNot ?? "" }
            checkAutomatically(evenIfNotDue: true)
            return "checking; `update` shows the outcome"
        case ("install", 2):
            guard let version = Version(words[1]) else { return "\(words[1]) is not a version" }
            if let refusal = UpdatePolicy.refusal(of: version, for: build) { return "This Mac \(refusal)." }
            install(version, byHand: false)
            return "moving to Baton \(version); `update` shows the outcome"
        case ("auto", 2) where ["on", "off"].contains(words[1]):
            guard role == .anchor else { return "the anchor's switch counts for every Mac; run this there" }
            setAutomatic(words[1] == "on")
            return "install updates automatically: \(settings.automatic)"
        case ("pretend", 2) where harness != nil && ["typing", "idle"].contains(words[1]):
            harness?.conditions = words[1] == "idle" ? .idle : RestartConditions(handoffInProgress: false, keysDown: true, buttonsDown: false, msSinceKey: 0, msSincePointer: 0)
            return "pretending the keyboard is \(words[1] == "idle" ? "idle" : "in use")"
        default:
            return "usage: update [check | install <version> | auto on|off]"
        }
    }

    private func status() -> String {
        var report: [String: Any] = [
            "version": "\(build.version)",
            "build": build.kind.rawValue,
            "path": app.path,
            "updatesItself": whyNot ?? "yes",
            "automatic": isAutomatic,
            "activity": activity ?? "none",
            "recent": recent,
        ]
        if let leader {
            report["lastCheck"] = settings.lastCheck == .distantPast ? "never" : ISO8601DateFormatter().string(from: settings.lastCheck)
            report["movingTo"] = leader.target.map { "\($0.version)" } ?? "nothing"
            report["macs"] = leader.peers.mapValues { peer -> [String: Any] in
                ["version": "\(peer.version)", "build": peer.kind.rawValue, "ready": peer.prepared.map { "\($0)" } ?? "nothing", "problem": peer.failure ?? "none"]
            }
            report["sharingInput"] = sharingInput.sorted()
        } else {
            report["anchor"] = anchorBuild.map { "\($0.name), Baton \($0.build)" } ?? "not reached"
            report["ready"] = follower?.prepared.map { "\($0)" } ?? "nothing"
        }
        return jsonString(report)
    }
}

/// `Baton update-check`: what the updater makes of this copy, and the latest release, without the
/// agent and without changing anything. `update-check run <seconds> [together]` runs the updater
/// by itself for a while under `BATON_HOME`, with the config and secret there, and answers
/// `ctl update`. With `together`, it counts every Mac on the update link as sharing input.
func runUpdateCheck(_ words: [String]) -> Int32 {
    if words.first == "run" {
        guard ProcessInfo.processInfo.environment["BATON_HOME"] != nil else {
            print("update-check run needs BATON_HOME, to stay out of the installed agent's way")
            return 64
        }
        do {
            let config = try loadConfig()
            let secret = try loadSecret()
            Updates.shared.harness = Updates.Harness(together: words.contains("together"))
            let control = ControlServer { words in
                words.first == "update" ? Updates.shared.command(Array(words.dropFirst())) : "only `update` works here"
            }
            control.start()
            Updates.shared.start(as: config, secret: secret, anchor: nil, client: nil)
            RunLoop.main.run(until: Date().addingTimeInterval(words.count > 1 ? Double(words[1]) ?? 60 : 60))
            return 0
        } catch {
            print("cannot start: \(error)")
            return 78
        }
    }
    let app = Bundle.main.bundleURL
    let build = Build.current
    let signature = Updater.signature(of: app)
    print("this copy: Baton \(build)")
    print("path: \(app.path)")
    print("signed with a Developer ID: \(signature.developerID ? "yes" : "no")")
    print("hardened runtime: \(signature.hardenedRuntime ? "yes" : "no")")
    print("notarized: \(signature.notarized ? "yes" : "no")")
    var replaceable = "yes"
    do { try Updater.checkReplaceable(app) } catch { replaceable = "no" }
    print("can be replaced in place: \(replaceable)")
    print("updates itself: \(build.kind == .release && signature.developerID ? "yes" : "no")")
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            let release = try await Updater.latestRelease()
            print("latest release: \(release.map { "\($0.version)" } ?? "none yet")")
        } catch {
            print("latest release: \(error.localizedDescription)")
        }
        done.signal()
    }
    done.wait()
    return 0
}
