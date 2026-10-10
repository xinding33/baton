import Foundation

/// What the anchor looks at before Baton restarts. The shared mouse and keyboard are attached to
/// it, so it sees their use whichever Mac the cursor is on. Times are in milliseconds.
public struct RestartConditions: Equatable, Sendable {
    /// The shared keyboard is being handed from one Mac to another, or a Bluetooth step is
    /// running. Restarting now would leave the keyboard paired with no Mac.
    public var handoffInProgress: Bool
    public var keysDown: Bool
    public var buttonsDown: Bool
    public var msSinceKey: UInt64
    public var msSincePointer: UInt64

    public init(handoffInProgress: Bool, keysDown: Bool, buttonsDown: Bool, msSinceKey: UInt64, msSincePointer: UInt64) {
        self.handoffInProgress = handoffInProgress
        self.keysDown = keysDown
        self.buttonsDown = buttonsDown
        self.msSinceKey = msSinceKey
        self.msSincePointer = msSincePointer
    }

    public static let idle = RestartConditions(handoffInProgress: false, keysDown: false, buttonsDown: false, msSinceKey: .max, msSincePointer: .max)
}

public enum RestartUrgency: Sendable {
    /// Nobody asked: wait until the mouse and keyboard have been left alone for a while.
    case whenIdle
    /// Someone asked, or a Mac is cut off until it restarts: the next pause in typing will do.
    case soon
}

/// Whether now is a good moment for the restart that finishes an update. It takes a second or
/// two, during which the cursor is back on the anchor and nothing is shared.
public enum RestartMoment {
    public static let idleMs: UInt64 = 60000
    public static let typingPauseMs: UInt64 = 2000
    /// An update nobody asked for stops waiting for idle Macs after this long.
    public static let patienceMs: UInt64 = 4 * 60 * 60 * 1000

    public static func isGood(_ conditions: RestartConditions, urgency: RestartUrgency, waitedMs: UInt64) -> Bool {
        guard !conditions.handoffInProgress, !conditions.keysDown, !conditions.buttonsDown else { return false }
        if urgency == .whenIdle, waitedMs < patienceMs {
            return min(conditions.msSinceKey, conditions.msSincePointer) >= idleMs
        }
        return conditions.msSinceKey >= typingPauseMs
    }
}

/// Runs on the anchor and keeps every Mac on one version. It hears each Mac's version on the
/// update link and decides who downloads what and when everyone restarts:
///
/// - A new release is downloaded here and on every connected client first. Only when all of them
///   have it, checked and ready, does the anchor swap its own copy in, tell the clients to do the
///   same, and restart. If one of them cannot get it, none is updated.
/// - A Mac that turns up on an older version is told to fetch the anchor's and restart.
/// - A Mac that turns up on a newer release pulls the anchor, and with it the others, up to it.
///   Versions only ever go up.
///
/// It does no work itself: it returns what to do, and is told how it went. Times are in
/// milliseconds on any steady clock.
public struct UpdateLeader {
    /// Who wanted an update, and so who hears if it fails.
    public enum Origin: Equatable, Sendable {
        case automatic
        /// Someone at the anchor.
        case here
        /// Someone at this client.
        case peer(String)
    }

    public enum Action: Equatable {
        case send(String, UpdateMessage)
        /// Download and check this release, then call `selfPrepared`.
        case prepareSelf(Version)
        /// Swap this release in for the running copy, then call `selfInstalled` or `selfInstallFailed`.
        case installSelf(Version)
        /// Everything has been said; restart into the copy now in place.
        case restart
        case failed(Origin, Version, String)
    }

    public struct Peer: Equatable {
        public var version: Version
        public var kind: BuildKind
        /// The release this Mac has downloaded and checked.
        public var prepared: Version?
        /// Why it could not prepare the release it was last asked for.
        public var failure: String?
        var failedAt: UInt64 = 0
        var toldToInstallAt: UInt64?
    }

    public struct Target: Equatable {
        public var version: Version
        public var origin: Origin
        public var urgency: RestartUrgency
        var since: UInt64
        var selfReady = false
        /// When every connected Mac had the release.
        var readyAt: UInt64?
        var installing = false
    }

    /// A Mac whose download failed is asked again after this long.
    public static let retryMs: UInt64 = 10 * 60 * 1000
    /// How long connected Macs get to download a release before the update is called off.
    public static let manualPatienceMs: UInt64 = 3 * 60 * 1000
    public static let automaticPatienceMs: UInt64 = 15 * 60 * 1000
    static let installRetryMs: UInt64 = 60000

    public let own: Build
    public private(set) var peers: [String: Peer] = [:]
    public private(set) var target: Target?

    public init(own: Build) {
        self.own = own
    }

    /// The version every Mac should end up on.
    private var goal: Version { target?.version ?? own.version }

    /// What the updater is doing, for the menu.
    public var activity: String? {
        guard let target else { return nil }
        if target.installing { return "Installing Baton \(target.version)…" }
        return target.readyAt == nil ? "Downloading Baton \(target.version)…" : "Waiting to Install Baton \(target.version)…"
    }

    // MARK: The other Macs

    /// A Mac said hello on the update link.
    public mutating func joined(_ name: String, version: Version, kind: BuildKind, now: UInt64) -> [Action] {
        peers[name] = Peer(version: version, kind: kind)
        // A Mac that is ahead cannot come back, so everything else moves up to it.
        if kind == .release, version > goal {
            return begin(version, origin: .automatic, urgency: .soon, now: now)
        }
        return ask(name, now: now)
    }

    public mutating func left(_ name: String) {
        peers[name] = nil
    }

    /// A Mac answered `prepare`.
    public mutating func prepared(_ name: String, version: Version, ok: Bool, detail: String, now: UInt64) {
        guard var peer = peers[name] else { return }
        if ok {
            peer.prepared = version
            peer.failure = nil
        } else {
            // Also what a Mac says when the swap itself failed: it has to start over.
            if peer.prepared == version { peer.prepared = nil }
            if version == goal {
                peer.failure = detail
                peer.failedAt = now
            }
        }
        peers[name] = peer
    }

    /// Has a Mac that is behind download the release everyone is moving to.
    private mutating func ask(_ name: String, now: UInt64) -> [Action] {
        guard own.kind == .release, var peer = peers[name], peer.version < goal, peer.prepared != goal else { return [] }
        peer.failure = nil
        peers[name] = peer
        // A development build would only say no.
        return peer.kind == .release ? [.send(name, .prepare(goal))] : []
    }

    // MARK: Moving to a release

    /// Starts moving every Mac to release `version`.
    public mutating func begin(_ version: Version, origin: Origin, urgency: RestartUrgency, now: UInt64) -> [Action] {
        if let refusal = UpdatePolicy.refusal(of: version, for: own) {
            return [.failed(origin, version, "This Mac \(refusal).")]
        }
        if var current = target, current.version >= version || current.installing {
            guard current.version == version else {
                return origin == .automatic ? [] : [.failed(origin, version, "Baton \(current.version) is already being installed.")]
            }
            // Someone asking by hand for what is under way gets it sooner, and hears how it goes.
            if origin != .automatic, !current.installing {
                current.origin = origin
                current.urgency = .soon
                target = current
            }
            return []
        }
        target = Target(version: version, origin: origin, urgency: urgency, since: now)
        return [.prepareSelf(version)] + peers.keys.sorted().flatMap { ask($0, now: now) }
    }

    /// The anchor's own download finished; `error` says why it failed, if it did.
    public mutating func selfPrepared(_ version: Version, error: String?) -> [Action] {
        guard var current = target, current.version == version, !current.selfReady else { return [] }
        if let error {
            target = nil
            return [.failed(current.origin, version, error)]
        }
        current.selfReady = true
        target = current
        return []
    }

    /// Call about once a second. `inSession` names the clients sharing input right now: they move
    /// together with the anchor, or not at all.
    public mutating func tick(now: UInt64, inSession: Set<String>, conditions: RestartConditions) -> [Action] {
        guard own.kind == .release, target?.installing != true else { return [] }
        var actions: [Action] = []
        for name in peers.keys.sorted() {
            if let peer = peers[name], peer.kind == .release, peer.failure != nil, now - peer.failedAt >= UpdateLeader.retryMs {
                actions += ask(name, now: now)
            }
        }
        guard var current = target else {
            return actions + catchUps(now: now, inSession: inSession, conditions: conditions)
        }
        guard current.selfReady else { return actions }

        let waiting = inSession.sorted().filter { name in
            guard let peer = peers[name] else { return true }
            return peer.version < current.version && peer.prepared != current.version
        }
        guard waiting.isEmpty else {
            let stuck = waiting.allSatisfy { peers[$0].map { $0.failure != nil || $0.kind == .development } ?? false }
            let patience = current.origin == .automatic ? UpdateLeader.automaticPatienceMs : UpdateLeader.manualPatienceMs
            guard stuck || now - current.since >= patience else { return actions }
            target = nil
            let reasons = waiting.map { name -> String in
                guard let peer = peers[name] else { return "\(name) is connected, but its updater isn't answering." }
                if peer.kind == .development { return "\(name) runs a development build, which doesn't update itself." }
                if let failure = peer.failure { return "\(name) couldn't get the update: \(failure)" }
                return "\(name) hasn't downloaded the update."
            }
            return actions + [.failed(current.origin, current.version, reasons.joined(separator: " ") + " No Mac was updated.")]
        }

        let readyAt = current.readyAt ?? now
        current.readyAt = readyAt
        if RestartMoment.isGood(conditions, urgency: current.urgency, waitedMs: now - readyAt) {
            current.installing = true
            actions.append(.installSelf(current.version))
        }
        target = current
        return actions
    }

    /// With no update under way, Macs that are behind the anchor and have its version ready are
    /// told to restart into it: at once if they are cut off anyway, otherwise at a pause.
    private mutating func catchUps(now: UInt64, inSession: Set<String>, conditions: RestartConditions) -> [Action] {
        var actions: [Action] = []
        for name in peers.keys.sorted() {
            guard var peer = peers[name], peer.version < own.version, peer.prepared == own.version else { continue }
            if let told = peer.toldToInstallAt, now - told < UpdateLeader.installRetryMs { continue }
            guard !inSession.contains(name) || RestartMoment.isGood(conditions, urgency: .soon, waitedMs: 0) else { continue }
            peer.toldToInstallAt = now
            peers[name] = peer
            actions.append(.send(name, .install(own.version)))
        }
        return actions
    }

    /// The anchor's copy has been replaced. The clients replace theirs now, and everyone restarts.
    public mutating func selfInstalled(_ version: Version) -> [Action] {
        guard let current = target, current.version == version, current.installing else { return [] }
        let installs = peers.keys.sorted().compactMap { name -> Action? in
            guard let peer = peers[name], peer.version < version, peer.prepared == version else { return nil }
            return .send(name, .install(version))
        }
        return installs + [.restart]
    }

    /// The anchor could not replace its copy. No client has been told to install, so nothing changed.
    public mutating func selfInstallFailed(_ version: Version, error: String) -> [Action] {
        guard let current = target, current.version == version else { return [] }
        target = nil
        return [.failed(current.origin, version, error)]
    }
}

/// Runs on a client: downloads what the anchor names, and installs it when told to.
public struct UpdateFollower {
    public enum Action: Equatable {
        case send(UpdateMessage)
        /// Download and check this release, then call `finishedPreparing`.
        case prepare(Version)
        /// Swap this release in and restart, or call `installFailed`.
        case install(Version)
    }

    public let own: Build
    public private(set) var prepared: Version?
    private var preparing: Version?
    public private(set) var installing = false

    public init(own: Build) {
        self.own = own
    }

    public mutating func received(_ message: UpdateMessage) -> [Action] {
        switch message {
        case let .prepare(version):
            if let refusal = UpdatePolicy.refusal(of: version, for: own) {
                return [.send(.prepared(version, ok: false, detail: "It \(refusal)."))]
            }
            if prepared == version { return [.send(.prepared(version, ok: true, detail: ""))] }
            if preparing == version || installing { return [] }
            preparing = version
            return [.prepare(version)]
        case let .install(version):
            guard UpdatePolicy.refusal(of: version, for: own) == nil, !installing else { return [] }
            guard prepared == version else {
                return [.send(.prepared(version, ok: false, detail: "The release hasn't been downloaded there."))]
            }
            installing = true
            return [.install(version)]
        default:
            return []
        }
    }

    public mutating func finishedPreparing(_ version: Version, error: String?) -> [Action] {
        if preparing == version { preparing = nil }
        if error == nil { prepared = version }
        return [.send(.prepared(version, ok: error == nil, detail: error ?? ""))]
    }

    public mutating func installFailed(_ version: Version, error: String) -> [Action] {
        installing = false
        prepared = nil
        return [.send(.prepared(version, ok: false, detail: error))]
    }
}
