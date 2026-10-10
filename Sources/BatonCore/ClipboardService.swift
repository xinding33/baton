import Foundation
import Network

/// A connection that carries clipboard frames. Everything runs on the service's queue.
final class ClipboardLink {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var parser = ClipboardFrameParser()
    private var closed = false

    var onReady: (() -> Void)?
    /// Frames other than those of a transfer.
    var onFrame: ((ClipboardFrame) -> Void)?
    var onContent: ((ClipboardContent) -> Void)?
    var onRefused: ((ClipboardHeader) -> Void)?
    var onClose: ((String) -> Void)?
    var maxBytes: () -> Int = { 0 }
    /// Set once the other side has introduced itself.
    var peer: ClipboardHello?

    private var outgoing: ClipboardOutgoing?
    private var queued: ClipboardContent?
    private var sending = false
    private var abandon = false
    private var nextTransfer: UInt32 = 0
    private var incoming: ClipboardIncoming?

    init(_ connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onReady?()
                self.receive()
            case let .failed(error): self.close("failed: \(error)")
            case let .waiting(error): self.close("unreachable: \(error)")
            case .cancelled: self.close("cancelled")
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func close(_ reason: String) {
        guard !closed else { return }
        closed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClose?(reason)
    }

    func send(_ frame: ClipboardFrame) {
        guard !closed else { return }
        connection.send(content: frame.encoded(), completion: .contentProcessed { [weak self] error in
            if let error { self?.close("send failed: \(error)") }
        })
    }

    /// Sends a copy, in place of any older one still on its way out.
    func send(_ content: ClipboardContent) {
        queued = content
        if outgoing != nil { abandon = true }
        pump()
    }

    /// Stops sending a copy that a newer one from elsewhere has overtaken.
    func cancelOutgoing(olderThan stamp: ClipboardStamp) {
        if let queued, queued.stamp < stamp { self.queued = nil }
        if let outgoing, outgoing.content.stamp < stamp { abandon = true }
        pump()
    }

    /// Hands the connection one chunk and waits until it has taken it before handing it the
    /// next, so a newer copy never waits behind more than one chunk.
    private func pump() {
        guard !closed, !sending else { return }
        if abandon {
            abandon = false
            if let outgoing { send(.cancel(transfer: outgoing.transfer)) }
            outgoing = nil
        }
        if outgoing == nil, let content = queued {
            queued = nil
            nextTransfer &+= 1
            outgoing = ClipboardOutgoing(content, transfer: nextTransfer)
        }
        guard var transfer = outgoing else { return }
        var batch = Data()
        while batch.count < ClipboardWire.chunkSize, let frame = transfer.next() {
            batch.append(frame.encoded())
        }
        outgoing = transfer.isFinished ? nil : transfer
        sending = true
        connection.send(content: batch, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.sending = false
            if let error { return self.close("send failed: \(error)") }
            self.pump()
        })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 2 * ClipboardWire.chunkSize) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.parser.append(data)
                do {
                    while !self.closed, let frame = try self.parser.next() { try self.handle(frame) }
                } catch {
                    return self.close("bad data: \(error)")
                }
            }
            if isComplete || error != nil {
                return self.close(error.map { "read failed: \($0)" } ?? "closed by peer")
            }
            self.receive()
        }
    }

    private func handle(_ frame: ClipboardFrame) throws {
        switch frame {
        case let .begin(header):
            do {
                incoming = try ClipboardIncoming(header, maxBytes: maxBytes())
            } catch ClipboardWireError.tooLarge {
                // Its chunks match no transfer and are dropped as they come.
                incoming = nil
                onRefused?(header)
            }
        case let .chunk(transfer, data):
            if incoming?.header.transfer == transfer { try incoming?.append(data) }
        case let .end(transfer):
            guard let finished = incoming, finished.header.transfer == transfer else { return }
            incoming = nil
            onContent?(try finished.finish())
        case let .cancel(transfer):
            if incoming?.header.transfer == transfer { incoming = nil }
        default:
            onFrame?(frame)
        }
    }
}

/// Keeps one Mac's pasteboard in step with the others'.
///
/// The Macs form a star, like the input link: the anchor listens and each client connects to it,
/// so a copy made on one client reaches the other through the anchor. A copy is sent to the
/// other Macs as soon as it is made, not when the cursor crosses: it is then already there when
/// the cursor arrives, and it also reaches a Mac that is used with its own keyboard.
///
/// The pasteboard, the timer and the connections all live on one private queue. Nothing here
/// runs on the main thread, which carries the mouse and the heartbeat.
public final class ClipboardService {
    public struct Status: Sendable {
        public var enabled = false
        public var access = ClipboardAccess.allowed
        /// Anchor: the port being listened on.
        public var port: UInt16?
        /// Client: whether the anchor is connected.
        public var connected = false
        /// Anchor: the clients connected.
        public var peers: [String] = []
        public var maxBytes = 0
        /// The shared copy: where it was made, its types and sizes.
        public var shared = "nothing yet"
        public var lastEvent = "none yet"
        /// Whether Universal Clipboard is on on this Mac.
        public var universalClipboard = false
        /// The Macs on which Handoff should be turned off, as the anchor sees it.
        public var turnOffHandoffOn: [String] = []
        /// When a clipboard last arrived here through Handoff.
        public var handoffClipboardSeen: Date?
    }

    private let name: String
    private let isHub: Bool
    private let board: ClipboardBoard
    private let pollInterval: TimeInterval
    private let log: (String) -> Void
    private let queue = DispatchQueue(label: "baton.clipboard", qos: .userInitiated)

    private var register: ClipboardRegister
    private var enabled = false
    private let initiallyEnabled: Bool
    private var maxBytes: Int
    private var timer: DispatchSourceTimer?
    private var lastCount: Int?
    private var lastListing: ClipboardListing?
    private var lastReadIncomplete = false
    /// Ticks left in which a copy that an app is still writing gets looked at again.
    private var settling = 0
    private var settleTicks: Int { Int((0.3 / pollInterval).rounded(.up)) }

    // Universal Clipboard, which competes with this.
    private let universalClipboardSetting: () -> Bool
    private let settingCheckInterval: TimeInterval
    private var ticksToSettingCheck = 0
    private var universalClipboardHere = false
    /// Since when the setting has said off, and when a Handoff clipboard last turned up anyway.
    private var settingOffSince: UInt64?
    private var handoffClipboardSeenAt: UInt64?
    /// Anchor: what each client reports.
    private var universalClipboardOn: [String: Bool] = [:]
    private var turnOffHandoffOn: [String] = []

    // Anchor
    private var listener: NWListener?
    private var listening: (port: NWEndpoint.Port, parameters: NWParameters)?
    private var peers: [String: ClipboardLink] = [:]
    private var greeting: [ObjectIdentifier: ClipboardLink] = [:]
    // Client
    private var target: (host: NWEndpoint.Host, port: NWEndpoint.Port, parameters: NWParameters)?
    private var link: ClipboardLink?
    private var lastFailure = ""

    private let statusLock = NSLock()
    private var currentStatus = Status()

    /// Called on a private queue when sharing was switched, a Mac joined or left, or the
    /// permission to read the pasteboard changed.
    public var onStatusChanged: (() -> Void)?
    /// Anchor only, called on a private queue: sharing was switched on or off, from any Mac.
    public var onEnabledChanged: ((Bool) -> Void)?
    /// Called on a private queue: someone asked to see this Mac's Handoff setting.
    public var onShowHandoffSetting: (() -> Void)?

    /// - Parameters:
    ///   - hub: true on the anchor, which listens; false on a client, which connects to it.
    ///   - enabled: the anchor's setting. A client waits to be told by the anchor.
    ///   - universalClipboard: whether this Mac's settings leave Universal Clipboard on.
    public init(
        name: String, hub: Bool, board: ClipboardBoard, enabled: Bool, maxBytes: Int, pollInterval: TimeInterval = 0.05,
        universalClipboard: @escaping () -> Bool = { false }, settingCheckInterval: TimeInterval = 5, log: @escaping (String) -> Void
    ) {
        universalClipboardSetting = universalClipboard
        self.settingCheckInterval = settingCheckInterval
        self.name = name
        isHub = hub
        self.board = board
        initiallyEnabled = hub && enabled
        self.maxBytes = maxBytes
        self.pollInterval = pollInterval
        self.log = log
        register = ClipboardRegister(name: name, now: ClipboardService.now())
        currentStatus.maxBytes = maxBytes
        currentStatus.enabled = initiallyEnabled
    }

    public var status: Status {
        statusLock.lock()
        defer { statusLock.unlock() }
        return currentStatus
    }

    private func update(notify: Bool = false, _ change: (inout Status) -> Void) {
        statusLock.lock()
        change(&currentStatus)
        statusLock.unlock()
        if notify { onStatusChanged?() }
    }

    private func note(_ event: String) {
        log(event)
        update { $0.lastEvent = event }
    }

    private static func now() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000)
    }

    private static func uptime() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1_000_000
    }

    // MARK: Switching on and off

    /// Switches sharing for every Mac. On a client this asks the anchor, which tells everyone.
    public func setEnabled(_ value: Bool) {
        queue.async {
            if self.isHub {
                self.changeEnabled(value)
            } else {
                self.link?.send(.setEnabled(value))
            }
        }
    }

    private func changeEnabled(_ value: Bool) {
        guard value != enabled else { return }
        apply(enabled: value)
        for peer in peers.values { peer.send(.settings(settings)) }
        advise()
        onEnabledChanged?(value)
    }

    private var settings: ClipboardSettings { ClipboardSettings(enabled: enabled, maxBytes: maxBytes) }

    private func apply(enabled value: Bool) {
        guard value != enabled else { return }
        enabled = value
        timer?.cancel()
        timer = nil
        if value {
            // What was copied while nobody was watching is of unknown age: it is not sent, but
            // an older copy from elsewhere must not replace it either.
            let count = board.changeCount
            if let lastCount, lastCount != count { register.changedWithoutSharing(now: ClipboardService.now()) }
            lastCount = count
            settling = 0
            ticksToSettingCheck = 0
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval, leeway: .milliseconds(10))
            timer.setEventHandler { [weak self] in self?.poll() }
            timer.resume()
            self.timer = timer
        }
        log(value ? "sharing on" : "sharing off")
        update(notify: true) {
            $0.enabled = value
            $0.access = self.board.access
        }
    }

    // MARK: Copies made on this Mac

    /// There is no notification for a copy; the change count is all there is to watch. Reading
    /// it costs well under a microsecond.
    private func poll() {
        ticksToSettingCheck -= 1
        if ticksToSettingCheck <= 0 {
            ticksToSettingCheck = Int((settingCheckInterval / pollInterval).rounded(.up))
            checkUniversalClipboard()
        }
        let count = board.changeCount
        if count != lastCount {
            lastCount = count
            settling = settleTicks
            inspect()
        } else if settling > 0 {
            // The count moves when an app clears the pasteboard, not when it then adds its data,
            // so a copy caught half-written is looked at again.
            settling -= 1
            if lastReadIncomplete || board.listing() != lastListing { inspect() }
        }
    }

    private func inspect() {
        let access = board.access
        if access != status.access { update(notify: true) { $0.access = access } }
        guard access == .allowed || access == .notAskedYet else {
            settling = 0
            register.changedWithoutSharing(now: ClipboardService.now())
            return note("copy not shared: macOS does not let Baton read the clipboard here (\(access.rawValue))")
        }
        let listing = board.listing()
        lastListing = listing
        lastReadIncomplete = false
        switch ClipboardFilter.verdict(markers: listing.markers, item: listing.item) {
        case .skip(.empty):
            break
        case let .skip(reason):
            if reason != .fromBaton { register.changedWithoutSharing(now: ClipboardService.now()) }
            note("copy not shared (\(reason.rawValue))")
            if reason == .fromHandoff {
                handoffClipboardSeenAt = ClipboardService.uptime()
                update { $0.handoffClipboardSeen = Date() }
                checkUniversalClipboard()
            }
        case let .share(types):
            switch board.read(types, limit: maxBytes) {
            case .changed:
                lastReadIncomplete = true
            case .tooLarge:
                register.changedWithoutSharing(now: ClipboardService.now())
                note("copy not shared: larger than \(ClipboardContent.format(bytes: maxBytes))")
            case let .parts(parts):
                lastReadIncomplete = parts.count < types.count
                guard !parts.isEmpty, let content = register.copied(parts, now: ClipboardService.now()) else { return }
                publish(content)
            }
        }
    }

    private func publish(_ content: ClipboardContent) {
        var destinations: [String] = []
        if isHub {
            for (name, peer) in peers where peer.peer != nil {
                peer.send(content)
                destinations.append(name)
            }
        } else if let link, let hub = link.peer {
            link.send(content)
            destinations.append(hub.name)
        }
        update { $0.shared = "from \(self.name): \(content.summary)" }
        note("copied here: \(content.summary); sent to \(destinations.isEmpty ? "nobody" : destinations.sorted().joined(separator: ", "))")
    }

    // MARK: Copies made elsewhere

    private func received(_ content: ClipboardContent, from sender: String, on link: ClipboardLink) {
        guard enabled else { return }
        // A copy made here since the last look is dealt with first: it is the newer of the two,
        // and writing over it unseen would lose it.
        poll()
        let reception = register.receive(content, now: ClipboardService.now())
        guard reception != .ignore else { return }
        link.cancelOutgoing(olderThan: content.stamp)
        if reception == .apply {
            // Recording the count this write leaves is what keeps it from being sent back.
            lastCount = board.write(content)
            settling = 0
            let delay = Int64(ClipboardService.now()) - Int64(content.stamp.time)
            note("from \(content.stamp.origin): \(content.summary); on the pasteboard \(delay) ms after the copy")
        }
        update { $0.shared = "from \(content.stamp.origin): \(content.summary)" }
        if isHub {
            for (name, peer) in peers where name != sender && peer.peer != nil { peer.send(content) }
        }
    }

    /// Once both sides have said what they hold, the one that is ahead sends its copy.
    private func catchUp(_ link: ClipboardLink, with hello: ClipboardHello) {
        guard enabled, let current = register.current else { return }
        if let have = hello.have, have >= current.stamp { return }
        link.send(current)
    }

    private func refused(_ header: ClipboardHeader, from sender: String) {
        note("from \(sender): refused, \(ClipboardContent.format(bytes: header.total)) is over the limit")
    }

    // MARK: Universal Clipboard

    /// It counts as on here if the settings say so, or if one of its clipboards has turned up
    /// in the last ten minutes although they say it is off.
    private func checkUniversalClipboard() {
        let now = ClipboardService.uptime()
        var on = universalClipboardSetting()
        if on {
            settingOffSince = nil
        } else {
            let since = settingOffSince ?? now
            settingOffSince = since
            if let seen = handoffClipboardSeenAt, seen >= since, now - seen < 600_000 { on = true }
        }
        guard on != universalClipboardHere else { return }
        universalClipboardHere = on
        log("Universal Clipboard is \(on ? "on" : "off") on this Mac")
        update(notify: true) { $0.universalClipboard = on }
        if isHub {
            advise()
        } else if let link, link.peer != nil {
            link.send(.universalClipboard(on))
        }
    }

    /// Anchor: works out where Handoff should be turned off and tells every Mac.
    private func advise() {
        guard isHub else { return }
        let clients = enabled ? peers.keys.filter { universalClipboardOn[$0] == true } : []
        let machines = UniversalClipboard.turnOff(anchorOn: universalClipboardHere, clientsOn: clients)
        guard machines != turnOffHandoffOn else { return }
        turnOffHandoffOn = machines
        log(machines.isEmpty ? "Universal Clipboard no longer competes" : "Universal Clipboard competes: Handoff should be turned off on \(machines.joined(separator: ", "))")
        update(notify: true) { $0.turnOffHandoffOn = machines }
        for peer in peers.values { peer.send(.turnOffHandoff(machines)) }
    }

    /// Shows the Handoff setting on the named Mac: this one, or a client, which is asked to.
    public func showHandoffSetting(on machine: String) {
        queue.async {
            if machine == self.name {
                self.onShowHandoffSetting?()
            } else {
                self.peers[machine]?.send(.showHandoffSetting)
            }
        }
    }

    // MARK: Anchor

    /// Starts accepting the clients' clipboard connections.
    public func listen(on port: NWEndpoint.Port, using parameters: NWParameters) {
        queue.async {
            self.listening = (port, parameters)
            self.apply(enabled: self.initiallyEnabled)
            self.startListener()
        }
    }

    private func startListener() {
        guard let listening, listener == nil else { return }
        guard let listener = try? NWListener(using: listening.parameters, on: listening.port) else {
            log("cannot listen on port \(listening.port)")
            return queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.startListener() }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, self.listener === listener else { return }
            switch state {
            case .ready:
                self.update(notify: true) { $0.port = listener.port?.rawValue }
            case let .failed(error):
                self.log("listener failed: \(error)")
                listener.cancel()
                self.listener = nil
                self.update { $0.port = nil }
                self.queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.startListener() }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func accept(_ connection: NWConnection) {
        let link = ClipboardLink(connection, queue: queue)
        let id = ObjectIdentifier(link)
        greeting[id] = link
        link.maxBytes = { [weak self] in self?.maxBytes ?? 0 }
        link.onFrame = { [weak self, weak link] frame in
            guard let self, let link, self.greeting.removeValue(forKey: id) != nil else { return }
            guard case let .hello(hello) = frame, hello.version == clipboardProtocolVersion, hello.name != self.name else {
                return link.close("bad hello")
            }
            self.join(hello, link)
        }
        link.onClose = { [weak self] _ in self?.greeting[id] = nil }
        link.start()
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.greeting.removeValue(forKey: id)?.close("no hello")
        }
    }

    private func join(_ hello: ClipboardHello, _ link: ClipboardLink) {
        if let old = peers.removeValue(forKey: hello.name) {
            old.onClose = nil
            old.close("replaced by a new connection")
        }
        peers[hello.name] = link
        link.peer = hello
        link.onFrame = { [weak self] frame in
            guard let self else { return }
            switch frame {
            case let .setEnabled(value):
                self.changeEnabled(value)
            case let .universalClipboard(on):
                self.universalClipboardOn[hello.name] = on
                self.advise()
            default:
                break
            }
        }
        link.onContent = { [weak self, weak link] content in
            guard let self, let link else { return }
            self.received(content, from: hello.name, on: link)
        }
        link.onRefused = { [weak self] header in self?.refused(header, from: hello.name) }
        link.onClose = { [weak self, weak link] reason in
            guard let self, let link, self.peers[hello.name] === link else { return }
            self.peers[hello.name] = nil
            self.universalClipboardOn[hello.name] = nil
            self.log("\(hello.name): disconnected (\(reason))")
            self.update(notify: true) { $0.peers = self.peers.keys.sorted() }
            self.advise()
        }
        // The settings go first, so the client knows whether sharing is on when the hello arrives.
        link.send(.settings(settings))
        link.send(.hello(ClipboardHello(name: name, have: register.current?.stamp)))
        link.send(.turnOffHandoff(turnOffHandoffOn))
        universalClipboardOn[hello.name] = nil
        log("\(hello.name): connected")
        update(notify: true) { $0.peers = self.peers.keys.sorted() }
        catchUp(link, with: hello)
    }

    // MARK: Client

    /// Connects to the anchor, and keeps reconnecting until `disconnect()`.
    public func connect(to host: NWEndpoint.Host, port: NWEndpoint.Port, using parameters: NWParameters) {
        queue.async {
            self.target = (host, port, parameters)
            self.link?.close("reconnecting")
            self.open()
        }
    }

    public func disconnect() {
        queue.async {
            guard self.target != nil else { return }
            self.target = nil
            self.link?.close("the anchor is gone")
        }
    }

    private func open() {
        guard let target, link == nil else { return }
        let link = ClipboardLink(NWConnection(host: target.host, port: target.port, using: target.parameters), queue: queue)
        self.link = link
        link.maxBytes = { [weak self] in self?.maxBytes ?? 0 }
        link.onReady = { [weak self, weak link] in
            guard let self, let link, self.link === link else { return }
            link.send(.hello(ClipboardHello(name: self.name, have: self.register.current?.stamp)))
        }
        link.onFrame = { [weak self, weak link] frame in
            guard let self, let link, self.link === link else { return }
            switch frame {
            case let .settings(settings):
                self.maxBytes = settings.maxBytes
                self.update { $0.maxBytes = settings.maxBytes }
                self.apply(enabled: settings.enabled)
            case let .hello(hello):
                guard hello.version == clipboardProtocolVersion, link.peer == nil else { return link.close("bad hello") }
                link.peer = hello
                self.lastFailure = ""
                self.log("connected to \(hello.name)")
                self.update(notify: true) { $0.connected = true }
                link.send(.universalClipboard(self.universalClipboardHere))
                self.catchUp(link, with: hello)
            case let .turnOffHandoff(machines):
                self.turnOffHandoffOn = machines
                self.update(notify: true) { $0.turnOffHandoffOn = machines }
            case .showHandoffSetting:
                self.onShowHandoffSetting?()
            default:
                break
            }
        }
        link.onContent = { [weak self, weak link] content in
            guard let self, let link, self.link === link else { return }
            self.received(content, from: link.peer?.name ?? "the anchor", on: link)
        }
        link.onRefused = { [weak self, weak link] header in self?.refused(header, from: link?.peer?.name ?? "the anchor") }
        link.onClose = { [weak self, weak link] reason in
            guard let self, let link, self.link === link else { return }
            let wasConnected = link.peer != nil
            // While retrying, report a failure only when its cause changes.
            if wasConnected || reason != self.lastFailure {
                self.log(wasConnected ? "connection closed (\(reason))" : "cannot reach the anchor (\(reason))")
            }
            self.lastFailure = wasConnected ? "" : reason
            self.link = nil
            self.turnOffHandoffOn = []
            if wasConnected {
                self.update(notify: true) {
                    $0.connected = false
                    $0.turnOffHandoffOn = []
                }
            }
            self.queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.open() }
        }
        link.start()
        queue.asyncAfter(deadline: .now() + 4) { [weak link] in
            guard let link, link.peer == nil else { return }
            link.close("connect timed out")
        }
    }
}
