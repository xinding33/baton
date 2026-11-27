import CoreGraphics
import Foundation

/// Whether this Mac's screen is locked, kept from loginwindow's announcements so the main thread
/// can ask without calling into another process.
final class ScreenLock: NSObject {
    static let shared = ScreenLock()

    /// Read and written on the main thread only.
    private(set) var isLocked = false
    private var announced = false

    override private init() {
        super.init()
        let center = DistributedNotificationCenter.default()
        // Delivery otherwise waits until the app is the active one, which Baton never is.
        center.addObserver(self, selector: #selector(locked), name: Notification.Name("com.apple.screenIsLocked"), object: nil, suspensionBehavior: .deliverImmediately)
        center.addObserver(self, selector: #selector(unlocked), name: Notification.Name("com.apple.screenIsUnlocked"), object: nil, suspensionBehavior: .deliverImmediately)
        // Until the first announcement, ask once, off the main thread.
        DispatchQueue.global(qos: .utility).async {
            let session = CGSessionCopyCurrentDictionary() as? [String: Any]
            let locked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.announced else { return }
                self.isLocked = locked
            }
        }
    }

    @objc private func locked() { set(true) }
    @objc private func unlocked() { set(false) }

    private func set(_ value: Bool) {
        if Thread.isMainThread {
            announced = true
            isLocked = value
        } else {
            DispatchQueue.main.async { self.set(value) }
        }
    }
}
