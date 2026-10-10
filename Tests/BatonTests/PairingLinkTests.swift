import BatonCore
import Network
import XCTest
@testable import Baton

/// A pairing code, typed on two Macs, has to open the real link between them, and a different
/// code has to be refused in a way the client can name. Both ends are in this process, on the
/// loopback interface.
final class PairingLinkTests: XCTestCase {
    func wait(_ what: String, timeout: TimeInterval = 10, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out waiting for \(what)") }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// Connects a client holding `clientCode` to a listener holding `anchorCode`. Returns whether
    /// a message got through, and why the client's link closed if it did.
    func connect(anchorCode: String, clientCode: String) throws -> (delivered: Bool, failure: String?) {
        let port = NWEndpoint.Port(rawValue: UInt16.random(in: 40000..<60000))!
        let listener = try NWListener(using: Net.tlsParameters(secret: PairingCode.secret(from: anchorCode)), on: port)
        var accepted: [Link] = []
        var delivered = false
        listener.newConnectionHandler = { connection in
            let link = Link(connection)
            link.onMessage = { message in
                if case .ping(7) = message { delivered = true }
            }
            accepted.append(link)
            link.start()
        }
        var listening = false
        listener.stateUpdateHandler = { if case .ready = $0 { listening = true } }
        listener.start(queue: .main)
        defer { listener.cancel() }
        wait("the listener") { listening }

        let link = Link(NWConnection(host: "127.0.0.1", port: port, using: Net.tlsParameters(secret: try PairingCode.secret(from: clientCode))))
        var failure: String?
        link.onReady = { link.send(.ping(7)) }
        link.onClose = { failure = $0 }
        link.start()
        defer { link.close("test over") }
        wait("the link to open or fail") { delivered || failure != nil }
        return (delivered, failure)
    }

    func testTheSameCodeOnBothMacsOpensTheLink() throws {
        let code = PairingCode.generate()
        let outcome = try connect(anchorCode: code, clientCode: PairingCode.normalize(code).lowercased())
        XCTAssertTrue(outcome.delivered, "closed instead: \(outcome.failure ?? "")")
    }

    func testADifferentCodeIsRefusedAndRecognisedAsSuch() throws {
        let outcome = try connect(anchorCode: PairingCode.generate(), clientCode: PairingCode.generate())
        XCTAssertFalse(outcome.delivered)
        let failure = try XCTUnwrap(outcome.failure)
        print("a wrong code closes the link with: \(failure)")
    }
}
