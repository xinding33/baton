import AppKit
import BatonCore
import CoreGraphics
import Foundation
import Network

/// Runs on a Mac without the mouse: connects to the anchor and replays the input it sends.
final class ClientAgent {
    private let config: Config
    private let secret: Data
    private let injector = Injector()
    private var browser: NWBrowser?
    private var discovered: NWEndpoint?
    private var link: Link?
    private var connected = false
    private var anchorName = ""
    private var datagrams: NWConnection?
    private var codec: DatagramCodec?
    private var lastMotionSeq: UInt64 = 0
    private var lastHeardAt = Net.monotonicMillis()
    private var datagramsReceived = 0
    private(set) var active = false
    private var displayWatcher: DisplayWatcher?
    private var timer: DispatchSourceTimer?
    private var useCachedNext = false
    private var lastFailure = ""
    private var idleCursorWatch: DispatchSourceTimer?
    private var tap: EventTap!
    private let keyCapture = KeyCapture()
    private let presence = KeyboardPresence()
    private let mover = KeyboardMover()

    var onStateChanged: (() -> Void)?

    init(config: Config, secret: Data) {
        self.config = config
        self.secret = secret
        tap = EventTap(types: EventTap.keys) { [unowned self] type, event in self.captured(type, event) }
    }

    /// While the shared keyboard is attached here but the cursor is on another machine, its
    /// keystrokes belong to that machine, so they go to the anchor instead of being typed here.
    private func captured(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let forwarding = connected && !active && presence.isPresent
        guard case let .forward(key) = keyCapture.process(type, event, forwarding: forwarding), let link else { return false }
        link.send(.key(key))
        return true
    }

    private func startTapWhenPermitted() {
        guard !tap.start() else { return log("keyboard tap active") }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self, self.tap.start() else { return }
            timer.invalidate()
            log("keyboard tap active")
        }
    }

    func start() {
        if !AXIsProcessTrusted() {
            log("Accessibility permission missing; input from the anchor cannot be replayed until it is granted")
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            CGRequestPostEventAccess()
        }
        startTapWhenPermitted()
        presence.onChange = { [weak self] present in
            self?.link?.send(.keyboardPresent(present))
            self?.onStateChanged?()
        }
        startBrowser()
        displayWatcher = DisplayWatcher { [weak self] in
            self?.link?.send(.displays(currentDisplays()))
        }
        timer = repeatingTimer(every: 1) { [weak self] in self?.tick() }
        connect()
    }

    // MARK: Finding and reaching the anchor

    private func startBrowser() {
        let browser = NWBrowser(for: .bonjour(type: batonServiceType, domain: nil), using: NWParameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            self.discovered = results.first?.endpoint
            if self.link == nil { self.connect() }
        }
        browser.stateUpdateHandler = { state in
            if case let .failed(error) = state { log("discovery failed: \(error)") }
            if case let .waiting(error) = state { log("discovery waiting: \(error)") }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private var cachedEndpoint: NWEndpoint? {
        guard let data = try? Data(contentsOf: Paths.state),
              let state = try? JSONDecoder().decode([String: String].self, from: data),
              let host = state["anchorHost"]
        else { return nil }
        return .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: config.port)!)
    }

    private func rememberAnchor(_ host: NWEndpoint.Host) {
        // Keep the address without any interface suffix so it stays valid across reboots.
        let text = "\(host)".split(separator: "%").first.map(String.init) ?? "\(host)"
        if let data = try? JSONEncoder().encode(["anchorHost": text]) {
            try? data.write(to: Paths.state, options: .atomic)
        }
    }

    private func connect() {
        guard link == nil else { return }
        let endpoint: NWEndpoint
        if let host = config.anchorHost {
            endpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: config.port)!)
        } else if let discovered, !useCachedNext || cachedEndpoint == nil {
            endpoint = discovered
        } else if let cachedEndpoint {
            endpoint = cachedEndpoint
        } else {
            return
        }
        // Alternate between the discovered and the remembered address while attempts fail.
        useCachedNext.toggle()

        let link = Link(NWConnection(to: endpoint, using: Net.tlsParameters(secret: secret)))
        self.link = link
        link.onReady = { [weak self, weak link] in
            guard let self, let link, self.link === link else { return }
            self.lastHeardAt = Net.monotonicMillis()
            link.send(.hello(Hello(name: self.config.name, version: batonProtocolVersion, displays: currentDisplays())))
        }
        link.onMessage = { [weak self, weak link] message in
            guard let self, let link, self.link === link else { return }
            self.receive(message, on: link)
        }
        link.onClose = { [weak self, weak link] reason in
            guard let self, let link, self.link === link else { return }
            // While retrying, report a failure only when its cause changes.
            if self.connected || reason != self.lastFailure {
                log(self.connected ? "anchor connection closed (\(reason))" : "cannot reach the anchor at \(endpoint) (\(reason))")
            }
            self.lastFailure = self.connected ? "" : reason
            self.disconnected()
        }
        link.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self, weak link] in
            guard let self, let link, self.link === link, !self.connected else { return }
            link.close("connect timed out")
        }
    }

    private func disconnected() {
        link = nil
        connected = false
        datagrams?.cancel()
        datagrams = nil
        codec = nil
        if active {
            active = false
            injector.releaseAll()
        }
        showCursor()
        onStateChanged?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.connect() }
    }

    private func tick() {
        if connected, Net.monotonicMillis() - lastHeardAt > 3000 {
            link?.close("anchor went silent")
        }
        if let datagrams, var codec {
            datagrams.send(content: codec.seal(DatagramPayload.hello.encoded()), completion: .idempotent)
            self.codec = codec
        }
    }

    // MARK: Cursor visibility

    /// Hides this Mac's cursor while the shared cursor is on another machine. It comes back as
    /// soon as it moves, which means someone used this Mac's own trackpad or mouse.
    private func hideIdleCursor() {
        CursorVisibility.hide()
        idleCursorWatch?.cancel()
        // The resting position is sampled on the first tick, once the last replayed move has landed.
        var resting: CGPoint?
        idleCursorWatch = repeatingTimer(every: 0.1) { [weak self] in
            let now = cursorLocation()
            guard let rest = resting else { return resting = now }
            if abs(now.x - rest.x) > 1 || abs(now.y - rest.y) > 1 { self?.showCursor() }
        }
    }

    private func showCursor() {
        idleCursorWatch?.cancel()
        idleCursorWatch = nil
        CursorVisibility.show()
    }

    // MARK: Messages from the anchor

    private func receive(_ message: Message, on link: Link) {
        lastHeardAt = Net.monotonicMillis()
        switch message {
        case let .welcome(welcome):
            connected = true
            lastFailure = ""
            useCachedNext = false
            anchorName = welcome.anchorName
            lastMotionSeq = 0
            log("connected to \(welcome.anchorName)")
            if let host = link.remoteHost {
                // An address set by hand is an override, not something to fall back on later.
                if config.anchorHost == nil { rememberAnchor(host) }
                openDatagrams(to: host, welcome)
            }
            hideIdleCursor()
            presence.watch(address: welcome.keyboardAddress)
            if welcome.keyboardAddress != nil { mover.requestPermission() }
            link.send(.keyboardPresent(presence.isPresent))
            onStateChanged?()
        case let .keyboardCommand(command):
            log("keyboard: asked to \(command.action.rawValue) (\(command.strategy.rawValue))")
            mover.perform(command) { [weak self] ok, detail in
                log("keyboard: \(command.action.rawValue) \(ok ? "succeeded" : "failed"): \(detail)")
                self?.link?.send(.keyboardResult(KeyboardResult(id: command.id, ok: ok, detail: detail)))
            }
        case let .ping(sentAt):
            link.send(.pong(sentAt))
        case let .enter(motion):
            active = true
            lastMotionSeq = motion.seq
            showCursor()
            injector.wake()
            injector.move(to: motion)
            onStateChanged?()
        case .leave:
            active = false
            injector.releaseAll()
            hideIdleCursor()
            onStateChanged?()
        case let .move(motion):
            apply(motion)
        case let .button(button):
            lastMotionSeq = max(lastMotionSeq, button.at.seq)
            if active { injector.button(button) }
        case let .scroll(scroll):
            lastMotionSeq = max(lastMotionSeq, scroll.at.seq)
            if active { injector.scroll(scroll) }
        case let .key(key):
            if active { injector.key(key) }
        default:
            break
        }
    }

    /// Positions can arrive late or out of order on the datagram path; only the newest one counts.
    private func apply(_ motion: Motion) {
        guard active, motion.seq > lastMotionSeq else { return }
        lastMotionSeq = motion.seq
        injector.move(to: motion)
    }

    private func openDatagrams(to host: NWEndpoint.Host, _ welcome: Welcome) {
        codec = DatagramCodec(key: welcome.udpKey, sessionId: welcome.sessionId, sending: .clientToAnchor)
        let connection = NWConnection(host: host, port: NWEndpoint.Port(rawValue: welcome.udpPort)!, using: Net.udpParameters)
        datagrams = connection
        connection.start(queue: .main)
        receiveDatagram(on: connection)
        tick()
    }

    private func receiveDatagram(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, self.datagrams === connection, error == nil else { return }
            if let data, var codec = self.codec, let payload = codec.open(data) {
                self.codec = codec
                self.datagramsReceived += 1
                if case let .motion(seq, x, y)? = DatagramPayload(payload) {
                    self.apply(Motion(x: x, y: y, seq: seq, flags: 0))
                }
            }
            self.receiveDatagram(on: connection)
        }
    }

    /// Runs single Bluetooth steps on this Mac; the outcome goes to the log.
    func bluetoothSteps(_ words: [String]) -> String {
        guard let address = presence.address else { return "the anchor has not named a keyboard" }
        return runBluetoothSteps(words, address: address, mover: mover)
    }

    func status() -> String {
        let position = cursorLocation()
        let report: [String: Any] = [
            "name": config.name,
            "role": "client",
            "connected": connected,
            "anchor": anchorName,
            "active": active,
            "cursor": [Int(position.x), Int(position.y)],
            "accessibility": AXIsProcessTrusted(),
            "postEvents": CGPreflightPostEventAccess(),
            "injected": injector.injected,
            "cursorHidden": CursorVisibility.isHidden,
            "keyboardTap": tap.isActive,
            "keyboard": presence.address.map { mover.describe(address: $0) } ?? ["configured": false],
            "datagramsReceived": datagramsReceived,
            "discovered": discovered.map { "\($0)" } ?? "none",
            "displays": currentDisplays().map { "\($0.name) \(Int($0.frame.width))x\(Int($0.frame.height)) at (\(Int($0.frame.minX)),\(Int($0.frame.minY)))" },
        ]
        return jsonString(report)
    }

    var isConnected: Bool { connected }
}
