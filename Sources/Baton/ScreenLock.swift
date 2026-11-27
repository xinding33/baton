import CoreGraphics
import Foundation

/// Whether this Mac's screen is locked, so the main thread can ask without calling into another
/// process. loginwindow's announcements keep it current; `refresh` asks the system again, off the
/// main thread, in case one was missed.
final class ScreenLock: NSObject {
    static let shared = ScreenLock()

    /// Read and written on the main thread only. Nil until known.
    private(set) var isLocked: Bool?
    private var asking = false
    /// Bumped by each announcement, so an answer asked for before one does not overwrite it.
    private var generation = 0

    override private init() {
        super.init()
        let center = DistributedNotificationCenter.default()
        // Delivery otherwise waits until the app is the active one, which Baton never is.
        center.addObserver(self, selector: #selector(locked), name: Notification.Name("com.apple.screenIsLocked"), object: nil, suspensionBehavior: .deliverImmediately)
        center.addObserver(self, selector: #selector(unlocked), name: Notification.Name("com.apple.screenIsUnlocked"), object: nil, suspensionBehavior: .deliverImmediately)
        refresh()
    }

    /// Asks the system whether the screen is locked, off the main thread. Call on the main thread.
    func refresh() {
        guard !asking else { return }
        asking = true
        let asked = generation
        DispatchQueue.global(qos: .utility).async {
            let session = CGSessionCopyCurrentDictionary() as? [String: Any]
            let locked = session.map { $0["CGSSessionScreenIsLocked"] as? Bool ?? false }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.asking = false
                if asked == self.generation, let locked { self.isLocked = locked }
            }
        }
    }

    @objc private func locked() { announce(true) }
    @objc private func unlocked() { announce(false) }

    private func announce(_ value: Bool) {
        guard Thread.isMainThread else { return DispatchQueue.main.async { self.announce(value) } }
        generation += 1
        isLocked = value
    }
}
