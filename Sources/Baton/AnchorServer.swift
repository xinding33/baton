import BatonCore
import Foundation
import Network

final class PeerSession {
    let name: String
    let link: Link
    var displays: [DisplayInfo]
    var codec: DatagramCodec
    var datagrams: NWConnection?
    var datagramsSeenAt: UInt64 = 0
    var lastPongAt: UInt64
    var rttMs: Double = 0
    /// Whether the shared keyboard is attached to this client.
    var keyboardPresent = false

    init(name: String, link: Link, displays: [DisplayInfo], codec: DatagramCodec) {
        self.name = name
        self.link = link
        self.displays = displays
        self.codec = codec
        lastPongAt = Net.monotonicMillis()
    }

    /// The datagram path counts as up while the client's keepalives keep arriving.
    var datagramsUp: Bool {
        datagrams != nil && Net.monotonicMillis() - datagramsSeenAt < 3000
    }
}

/// Accepts the clients' connections and keeps one session per client.
final class AnchorServer {
    private let config: Config
    private let secret: Data
    private var listener: NWListener?
    private var datagramListener: NWListener?
    private var nextSessionId = UInt32.random(in: 1...UInt32.max / 2)
    private(set) var peers: [String: PeerSession] = [:]
    /// Connections that have not introduced themselves yet.
    private var greeting: [ObjectIdentifier: Link] = [:]

    /// A client joined, left, or changed its displays.
    var onPeersChanged: (() -> Void)?
    var onPeerLost: ((String) -> Void)?
    /// A client passed on a key typed on the shared keyboard.
    var onForwardedKey: ((String, Key) -> Void)?
    var onKeyboardMoved: (() -> Void)?
    /// A client's own trackpad, mouse or keyboard was used, with its cursor at this point.
    var onLocalInput: ((String, CGPoint) -> Void)?
    /// A client said it is going to sleep. It is dropped right after.
    var onPeerSleeping: ((String) -> Void)?
    private var nextCommandId: UInt32 = 0
    private var commands: [UInt32: (peer: String, completion: (Bool, String) -> Void)] = [:]

    init(config: Config, secret: Data) {
        self.config = config
        self.secret = secret
    }

    func start() throws {
        let port = NWEndpoint.Port(rawValue: config.port)!
        let listener = try NWListener(using: Net.tlsParameters(secret: secret), on: port)
        listener.service = NWListener.Service(name: config.name, type: batonServiceType)
        listener.stateUpdateHandler = { state in log("listener: \(state)") }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: .main)
        self.listener = listener

        let datagramListener = try NWListener(using: Net.udpParameters, on: port)
        datagramListener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            self?.receiveDatagram(on: connection)
        }
        datagramListener.start(queue: .main)
        self.datagramListener = datagramListener
    }

    private func accept(_ connection: NWConnection) {
        let link = Link(connection)
        let id = ObjectIdentifier(link)
        greeting[id] = link
        link.onMessage = { [weak self, weak link] message in
            guard let self, let link, self.greeting.removeValue(forKey: id) != nil else { return }
            guard case let .hello(hello) = message, hello.version == batonProtocolVersion, hello.name != self.config.name else {
                return link.close("bad hello")
            }
            self.register(hello, link: link)
        }
        link.onClose = { [weak self] _ in self?.greeting[id] = nil }
        link.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.greeting.removeValue(forKey: id)?.close("no hello")
        }
    }

    private func register(_ hello: Hello, link: Link) {
        if let old = peers.removeValue(forKey: hello.name) {
            old.link.onClose = nil
            old.link.close("replaced by a new connection")
            old.datagrams?.cancel()
            onPeerLost?(hello.name)
        }
        nextSessionId += 1
        let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let codec = DatagramCodec(key: key, sessionId: nextSessionId, sending: .anchorToClient)
        let peer = PeerSession(name: hello.name, link: link, displays: hello.displays, codec: codec)
        peers[hello.name] = peer
        link.onMessage = { [weak self, weak peer] message in
            guard let self, let peer else { return }
            switch message {
            case let .displays(displays):
                peer.displays = displays
                log("\(peer.name): displays changed")
                self.onPeersChanged?()
            case let .pong(sentAt):
                let now = Net.monotonicMillis()
                peer.lastPongAt = now
                let sample = Double(now &- sentAt)
                peer.rttMs = peer.rttMs == 0 ? sample : peer.rttMs * 0.8 + sample * 0.2
            case let .key(key):
                self.onForwardedKey?(peer.name, key)
            case let .keyboardPresent(present):
                peer.keyboardPresent = present
                self.onKeyboardMoved?()
            case let .keyboardResult(result):
                self.commands.removeValue(forKey: result.id)?.completion(result.ok, result.detail)
            case let .localInput(motion):
                self.onLocalInput?(peer.name, CGPoint(x: motion.x, y: motion.y))
            case .sleeping:
                log("\(peer.name): going to sleep")
                self.onPeerSleeping?(peer.name)
                self.drop(peer.name)
            default:
                break
            }
        }
        link.onClose = { [weak self, weak peer] reason in
            guard let self, let peer, self.peers[peer.name] === peer else { return }
            log("\(peer.name): disconnected (\(reason))")
            self.drop(peer.name)
        }
        link.send(.welcome(Welcome(anchorName: config.name, sessionId: codec.sessionId, udpKey: key, udpPort: config.port, keyboardAddress: config.keyboardAddress)))
        log("\(hello.name): connected, \(hello.displays.count) display(s)")
        onPeersChanged?()
    }

    func drop(_ name: String) {
        guard let peer = peers.removeValue(forKey: name) else { return }
        peer.link.onClose = nil
        peer.link.close("dropped")
        peer.datagrams?.cancel()
        for (id, command) in commands where command.peer == name {
            commands[id] = nil
            command.completion(false, "\(name) disconnected")
        }
        onPeerLost?(name)
        onPeersChanged?()
        onKeyboardMoved?()
    }

    /// Asks a client to release or take the shared keyboard and reports how it went.
    func sendKeyboardCommand(_ name: String, action: KeyboardCommand.Action, address: String, strategy: HandoffStrategy, completion: @escaping (Bool, String) -> Void) {
        guard let peer = peers[name] else { return completion(false, "\(name) is not connected") }
        nextCommandId += 1
        let id = nextCommandId
        commands[id] = (name, completion)
        peer.link.send(.keyboardCommand(KeyboardCommand(id: id, action: action, address: address, strategy: strategy)))
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
            self?.commands.removeValue(forKey: id)?.completion(false, "\(name) did not answer")
        }
    }

    private func receiveDatagram(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil else { return connection.cancel() }
            if let data, let sessionId = DatagramCodec.sessionId(of: data),
               let peer = self.peers.values.first(where: { $0.codec.sessionId == sessionId }),
               let payload = peer.codec.open(data), DatagramPayload(payload) == .hello {
                if peer.datagrams !== connection {
                    peer.datagrams?.cancel()
                    peer.datagrams = connection
                    log("\(peer.name): datagram path up")
                }
                peer.datagramsSeenAt = Net.monotonicMillis()
            }
            self.receiveDatagram(on: connection)
        }
    }

    func send(_ name: String, _ message: Message) {
        peers[name]?.link.send(message)
    }

    /// Sends a cursor position by datagram when that path is up, otherwise over the reliable link.
    func sendMotion(_ name: String, _ motion: Motion) {
        guard let peer = peers[name] else { return }
        if peer.datagramsUp, let datagrams = peer.datagrams {
            let sealed = peer.codec.seal(DatagramPayload.motion(seq: motion.seq, x: motion.x, y: motion.y).encoded())
            datagrams.send(content: sealed, completion: .idempotent)
        } else {
            peer.link.send(.move(motion))
        }
    }

    func pingAll() {
        let now = Net.monotonicMillis()
        for peer in peers.values { peer.link.send(.ping(now)) }
    }
}
