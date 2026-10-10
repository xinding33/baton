import BatonCore
import CryptoKit
import Foundation
import Network

enum Net {
    /// TLS 1.2 with a pre-shared key over TCP, so only machines holding the secret can connect.
    static func tlsParameters(secret: Data) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let code = Data(HMAC<SHA256>.authenticationCode(for: Data("baton-psk-v1".utf8), using: SymmetricKey(data: secret)))
        let psk = code.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("baton".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        let options = tls.securityProtocolOptions
        sec_protocol_options_add_pre_shared_key(options, psk as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.keepaliveInterval = 1
        tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.serviceClass = .interactiveVideo
        useIPv4(parameters)
        return parameters
    }

    static var udpParameters: NWParameters {
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        parameters.serviceClass = .interactiveVideo
        useIPv4(parameters)
        return parameters
    }

    /// Discovery otherwise tends to pick an IPv6 link-local address, which is only meaningful
    /// together with an interface and so can't be reused for the datagram path or remembered.
    private static func useIPv4(_ parameters: NWParameters) {
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
    }

    static func monotonicMillis() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1_000_000
    }
}

/// A connection that carries length-prefixed `Message`s. All callbacks run on the main queue.
final class Link {
    let connection: NWConnection
    var onReady: (() -> Void)?
    var onMessage: ((Message) -> Void)?
    var onClose: ((String) -> Void)?
    private var closed = false

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onReady?()
                self.readHeader()
            case let .failed(error):
                self.close("failed: \(error)")
            case let .waiting(error):
                self.close("unreachable: \(error)")
            case .cancelled:
                self.close("cancelled")
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    func send(_ message: Message) {
        guard !closed, let frame = try? Wire.encode(message) else { return }
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            if let error { self?.close("send failed: \(error)") }
        })
    }

    func close(_ reason: String) {
        guard !closed else { return }
        closed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClose?(reason)
    }

    var remoteHost: NWEndpoint.Host? {
        if case let .hostPort(host, _) = connection.currentPath?.remoteEndpoint { return host }
        return nil
    }

    private func readHeader() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, error in
            guard let self, !self.closed else { return }
            guard let data, let length = Wire.length(ofHeader: data) else {
                return self.close(error.map { "read failed: \($0)" } ?? "closed by peer")
            }
            self.readBody(length)
        }
    }

    private func readBody(_ length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            guard let self, !self.closed else { return }
            guard let data, data.count == length else {
                return self.close(error.map { "read failed: \($0)" } ?? "closed by peer")
            }
            do {
                self.onMessage?(try Wire.decode(data))
            } catch {
                return self.close("bad message: \(error)")
            }
            self.readHeader()
        }
    }
}

/// A main-queue timer that keeps firing while a menu is open, which a run-loop `Timer` does not.
func repeatingTimer(every interval: TimeInterval, _ handler: @escaping () -> Void) -> DispatchSourceTimer {
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(10))
    timer.setEventHandler(handler: handler)
    timer.resume()
    return timer
}
