import AppKit
import BatonCore

/// The Settings window: one pane at a time, chosen from its toolbar. Before Baton is set up it
/// holds the setup form alone, with no toolbar, and the other panes join once Baton runs.
final class SettingsWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    private(set) var panes: [SettingsPane] = []
    private var selected: String?
    private var window: NSWindow?
    private var timer: DispatchSourceTimer?

    /// Puts the window in front of its user. A test replaces it.
    var present: (NSWindow) -> Void = { window in
        // Baton has no menu bar of its own, and without an Edit menu ⌘V does nothing in a
        // text field, which is how most pairing codes arrive.
        if NSApp.mainMenu == nil { NSApp.mainMenu = SettingsWindowController.makeMainMenu() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    static func makeMainMenu() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let main = NSMenu()
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit
        return main
    }

    var isVisible: Bool { window?.isVisible == true }
    private var current: SettingsPane? { panes.first { $0.id == selected } ?? panes.first }

    /// The panes on offer, in the toolbar's order. The pane that was showing stays if it is
    /// still among them.
    func setPanes(_ panes: [SettingsPane]) {
        self.panes = panes
        guard let window else { return }
        installToolbar(in: window)
        select(current?.id)
    }

    // MARK: The window

    /// Opens the window on the pane called `id`, or on the one it showed last.
    func show(_ id: String? = nil) {
        guard !panes.isEmpty else { return }
        if !isVisible { panes.forEach { $0.windowWillOpen() } }
        let isNew = window == nil
        if isNew {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SetupView.width, height: 400), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.toolbarStyle = .preference
            window.delegate = self
            self.window = window
            installToolbar(in: window)
        }
        select(panes.contains { $0.id == id } ? id : current?.id)
        if isNew { window?.center() }
        window.map(present)
        if timer == nil { timer = repeatingTimer(every: 1) { [weak self] in self?.refresh() } }
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        timer?.cancel()
        timer = nil
        panes.forEach { $0.windowDidClose() }
    }

    /// Brings the pane on show up to date. Called every second while the window is open, and
    /// whenever something Baton shows has changed.
    func refresh() {
        guard isVisible, let pane = current else { return }
        pane.refresh()
        fit()
    }

    private func select(_ id: String?) {
        guard let window, let pane = panes.first(where: { $0.id == id }) ?? panes.first else { return }
        selected = pane.id
        let corner = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        pane.refresh()
        if window.contentView !== pane.view { window.contentView = pane.view }
        window.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(pane.id)
        window.title = panes.count == 1 ? "Set Up Baton" : "Baton Settings"
        fit(keeping: corner)
    }

    /// Gives the window the size of its pane. It grows and shrinks downwards, as notes come and
    /// go or another pane is chosen, so that its title bar stays where it was put.
    func fit(keeping corner: NSPoint? = nil) {
        guard let window, let view = window.contentView else { return }
        let size = view.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        let corner = corner ?? NSPoint(x: window.frame.minX, y: window.frame.maxY)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: corner.x, y: corner.y - frame.height)
        guard abs(frame.width - window.frame.width) > 0.5 || abs(frame.height - window.frame.height) > 0.5 || frame.origin != window.frame.origin else { return }
        // Not animated: that would hold the main thread, which carries the mouse, until it is over.
        window.setFrame(frame, display: true)
    }

    // MARK: The toolbar

    private func installToolbar(in window: NSWindow) {
        // One pane needs no choosing, which is the case until Baton is set up.
        guard panes.count > 1 else { return window.toolbar = nil }
        let toolbar = NSToolbar(identifier: "BatonSettings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
    }

    private var identifiers: [NSToolbarItem.Identifier] { panes.map { NSToolbarItem.Identifier($0.id) } }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let pane = panes.first(where: { $0.id == itemIdentifier.rawValue }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = pane.title
        item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(chose(_:))
        return item
    }

    @objc private func chose(_ sender: NSToolbarItem) {
        select(sender.itemIdentifier.rawValue)
    }

    // MARK: Control commands

    /// `ctl settings`: the part that is about the window and its panes. `press` and `choose` work
    /// a pane without the mouse. The rest is about setting this Mac up, and goes to `setup`.
    func command(_ words: [String], setup: ([String]) -> String) -> String {
        func pane(_ id: String) -> SettingsPane? { panes.first { $0.id == id } }
        let known = "the panes are: \(panes.map(\.id).joined(separator: ", "))"
        switch (words.first, words.count) {
        case ("show", 1), ("show", 2):
            if words.count == 2, pane(words[1]) == nil { return known }
            show(words.count == 2 ? words[1] : nil)
            return setup([])
        case ("snapshot", 2), ("snapshot", 3):
            guard let pane = words.count == 3 ? pane(words[2]) : panes.first else { return known }
            pane.refresh()
            return pane.view.writeSnapshot(to: URL(fileURLWithPath: words[1])) ? "wrote \(words[1])" : "could not write \(words[1])"
        case ("pane", 2):
            guard let pane = pane(words[1]) else { return known }
            return pane.rows.map(\.line).joined(separator: "\n")
        case ("press", 3...):
            guard let pane = pane(words[1]) else { return known }
            let title = words.dropFirst(2).joined(separator: " ")
            return pane.rows.press(title) ?? "no “\(title)” to press; see `settings pane \(pane.id)`"
        case ("choose", 5...):
            guard let pane = pane(words[1]) else { return known }
            guard let equals = words.firstIndex(of: "="), equals > 2, equals < words.count - 1 else { return "usage: settings choose <pane> <title> = <option>" }
            let title = words[2..<equals].joined(separator: " ")
            return pane.rows.choose(words[(equals + 1)...].joined(separator: " "), for: title) ?? "no choice called “\(title)”; see `settings pane \(pane.id)`"
        default:
            return setup(words)
        }
    }
}
