import BatonCore
import Foundation

/// A local socket for inspecting and driving the running agent: `Baton ctl status`.
final class ControlServer {
    private var source: DispatchSourceRead?
    private let handler: ([String]) -> String

    init(handler: @escaping ([String]) -> String) {
        self.handler = handler
    }

    func start() {
        let path = Paths.controlSocket.path
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, withSocketAddress(path, { bind(fd, $0, $1) }) == 0, listen(fd, 4) == 0 else {
            return log("control socket unavailable: \(String(cString: strerror(errno)))")
        }
        chmod(path, 0o600)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            let client = accept(fd, nil, nil)
            guard client >= 0, let self else { return }
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let request = readLine(from: client)
            let reply = self.handler(request.split(separator: " ").map(String.init)) + "\n"
            _ = reply.withCString { write(client, $0, strlen($0)) }
            close(client)
        }
        source.resume()
        self.source = source
    }
}

private func withSocketAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strlcpy($0, path, capacity) }
    }
    return withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}

private func readLine(from fd: Int32) -> String {
    var bytes: [UInt8] = []
    var byte: UInt8 = 0
    while bytes.count < 4096, read(fd, &byte, 1) == 1, byte != 10 { bytes.append(byte) }
    return String(decoding: bytes, as: UTF8.self)
}

/// The `ctl` subcommand: sends one command to the running agent and prints its reply.
func controlClient(_ words: [String]) -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0, withSocketAddress(Paths.controlSocket.path, { connect(fd, $0, $1) }) == 0 else {
        FileHandle.standardError.write(Data("Baton is not running (no control socket)\n".utf8))
        return 1
    }
    let request = words.joined(separator: " ") + "\n"
    _ = request.withCString { write(fd, $0, strlen($0)) }
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(fd, &buffer, buffer.count)
        guard n > 0 else { break }
        FileHandle.standardOutput.write(Data(buffer[0..<n]))
    }
    close(fd)
    return 0
}
