import BatonCore
import Foundation

private let logQueue = DispatchQueue(label: "baton.log")
private let logHandle: FileHandle? = {
    let url = Paths.log
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    let handle = try? FileHandle(forWritingTo: url)
    _ = try? handle?.seekToEnd()
    return handle
}()
private let logFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return f
}()

func log(_ message: String) {
    let now = Date()
    logQueue.async {
        let line = "\(logFormatter.string(from: now)) \(message)\n"
        logHandle?.write(Data(line.utf8))
        FileHandle.standardError.write(Data(line.utf8))
    }
}
