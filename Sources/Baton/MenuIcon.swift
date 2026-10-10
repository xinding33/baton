import AppKit
import BatonCore

/// Whether this Mac's menu bar item is hidden. Baton runs the same either way.
enum MenuIcon {
    private static var marker: URL { Paths.support.appendingPathComponent("icon-hidden") }
    private(set) static var isHidden = FileManager.default.fileExists(atPath: marker.path)

    static func setHidden(_ hidden: Bool) {
        guard hidden != isHidden else { return }
        if hidden {
            FileManager.default.createFile(atPath: marker.path, contents: nil)
        } else {
            try? FileManager.default.removeItem(at: marker)
        }
        isHidden = hidden
        log(hidden ? "menu bar icon hidden" : "menu bar icon shown")
    }

    /// Asks before hiding, because afterwards there is no menu left to undo it from.
    static func confirmHiding() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Hide the Baton menu bar icon?"
        alert.informativeText = """
            Baton keeps running. To show the icon again, open Baton again:

            open "\(Bundle.main.bundlePath)"
            """
        alert.addButton(withTitle: "Hide Icon")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
