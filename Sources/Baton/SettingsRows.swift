import AppKit
import BatonCore

/// One pane of the Settings window. A feature supplies its own, the way it has its own `ctl`
/// command.
protocol SettingsPane: AnyObject {
    /// One of `StatusMenu.Pane`, which is also what `ctl settings show <pane>` takes.
    var id: String { get }
    var title: String { get }
    /// The SF Symbol in the toolbar.
    var symbol: String { get }
    /// As wide and as tall as its contents; the window takes its size from it.
    var view: NSView { get }
    /// Brings the view up to date. Called while the pane shows: once a second, and whenever
    /// something Baton shows has changed. It runs on the main thread and must not wait.
    func refresh()
    /// The window is about to come up after being closed.
    func windowWillOpen()
    func windowDidClose()
    /// What the pane shows, as text, for `ctl settings pane`.
    var rows: [SettingsRow] { get }
}

extension SettingsPane {
    func windowWillOpen() {}
    func windowDidClose() {}
    var rows: [SettingsRow] { [] }
}

/// One line of a pane that is made of switches, choices and notes.
struct SettingsRow {
    enum Kind: Equatable {
        case header
        case toggle(on: Bool)
        case choice(options: [String], selected: Int)
        case button
        /// Small print.
        case text
        /// A tinted box for what must not be overlooked.
        case note(warning: Bool)
    }

    var kind: Kind
    var title: String
    var enabled = true
    var indent = 0
    /// Small print under the row.
    var detail: String?
    /// A toggle is handed 1 or 0, a choice the index that was picked.
    var act: ((Int) -> Void)?

    static func header(_ title: String) -> SettingsRow {
        SettingsRow(kind: .header, title: title)
    }

    static func toggle(_ title: String, on: Bool, enabled: Bool = true, indent: Int = 0, detail: String? = nil, set: @escaping (Bool) -> Void) -> SettingsRow {
        SettingsRow(kind: .toggle(on: on), title: title, enabled: enabled, indent: indent, detail: detail, act: { set($0 != 0) })
    }

    static func choice(_ title: String, options: [String], selected: Int, enabled: Bool = true, detail: String? = nil, set: @escaping (Int) -> Void) -> SettingsRow {
        SettingsRow(kind: .choice(options: options, selected: selected), title: title, enabled: enabled, detail: detail, act: set)
    }

    static func button(_ title: String, enabled: Bool = true, detail: String? = nil, action: @escaping () -> Void) -> SettingsRow {
        SettingsRow(kind: .button, title: title, enabled: enabled, detail: detail, act: { _ in action() })
    }

    static func text(_ text: String) -> SettingsRow {
        SettingsRow(kind: .text, title: text)
    }

    static func note(_ text: String, warning: Bool = true) -> SettingsRow {
        SettingsRow(kind: .note(warning: warning), title: text)
    }

    /// Whether a toggle is on; nil for any other row.
    var isOn: Bool? {
        if case let .toggle(on) = kind { return on }
        return nil
    }

    /// Everything the row shows. Two rows that look the same are the same as far as the view goes.
    fileprivate var appearance: String { "\(kind)|\(title)|\(enabled)|\(indent)|\(detail ?? "")" }

    /// The row as `ctl settings pane` prints it.
    var line: String {
        let pad = String(repeating: "  ", count: indent)
        let off = enabled ? "" : "  [greyed out]"
        var line: String
        switch kind {
        case .header: line = "\(title):"
        case let .toggle(on): line = "  \(pad)[\(on ? "x" : " ")] \(title)\(off)"
        case let .choice(options, selected): line = "  \(pad)\(title): \(options.indices.contains(selected) ? options[selected] : "?") (of \(options.joined(separator: ", ")))\(off)"
        case .button: line = "  \(pad)<\(title)>\(off)"
        case .text: line = "  \(pad)\(title)"
        case let .note(warning): line = "  \(pad)\(warning ? "⚠︎ " : "")\(title)"
        }
        if let detail { line += "\n  \(pad)    \(detail)" }
        return line
    }
}

extension Array where Element == SettingsRow {
    /// Presses the button or flips the toggle called `title`, as a click would. Returns nil if
    /// there is no such row to press.
    func press(_ title: String) -> String? {
        guard let row = first(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame && $0.act != nil }) else { return nil }
        guard row.enabled else { return "“\(row.title)” is greyed out" }
        switch row.kind {
        case let .toggle(on): row.act?(on ? 0 : 1)
        case .button: row.act?(0)
        default: return nil
        }
        return "pressed “\(row.title)”"
    }

    /// Picks `option` for the choice called `title`.
    func choose(_ option: String, for title: String) -> String? {
        for row in self where row.title.caseInsensitiveCompare(title) == .orderedSame {
            guard case let .choice(options, _) = row.kind else { continue }
            guard let index = options.firstIndex(where: { $0.caseInsensitiveCompare(option) == .orderedSame }) else {
                return "“\(row.title)” is one of: \(options.joined(separator: ", "))"
            }
            guard row.enabled else { return "“\(row.title)” is greyed out" }
            row.act?(index)
            return "chose “\(options[index])”"
        }
        return nil
    }
}

/// A pane made of rows, which it asks for again at every refresh.
final class FormPane: SettingsPane {
    let id: String
    let title: String
    let symbol: String
    private let makeRows: () -> [SettingsRow]
    private lazy var form = FormView()
    /// Called as the window comes up, for a pane that starts afresh each time.
    var onOpen: (() -> Void)?
    /// Called as the window closes, for a pane that was in the middle of something.
    var onClose: (() -> Void)?

    init(id: String, title: String, symbol: String, rows: @escaping () -> [SettingsRow]) {
        self.id = id
        self.title = title
        self.symbol = symbol
        makeRows = rows
    }

    var view: NSView { form }
    var rows: [SettingsRow] { makeRows() }
    func refresh() { form.show(makeRows()) }
    func windowWillOpen() { onOpen?() }
    func windowDidClose() { onClose?() }
}

/// Draws a list of rows down the window, at the width of the setup form.
final class FormView: NSView {
    private static let inset: CGFloat = 24
    private static let contentWidth = SetupView.width - 2 * inset
    private static let indentWidth: CGFloat = 20

    private let stack = NSStackView()
    private var shown: [SettingsRow] = []
    /// Set by a click that Baton has not answered yet; see `acted`.
    private var settleBy: Date?
    /// The controls on show. Each has the index of its row as its tag.
    private var controls: [NSControl] = []

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: SetupView.width, height: 200))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: SetupView.width),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FormView.inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FormView.inset),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }

    func show(_ rows: [SettingsRow]) {
        let unchanged = rows.map(\.appearance) == shown.map(\.appearance)
        shown = rows
        // The controls call the newest closures either way; the views are only made again when
        // something looks different, so that a refresh never disturbs a click in progress.
        if unchanged, !stack.arrangedSubviews.isEmpty {
            guard let settleBy, settleBy < Date() else { return }
        }
        settleBy = nil

        // Whoever is working the pane from the keyboard stays on the control they were on.
        let focused = controls.firstIndex { $0 === window?.firstResponder }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        controls = []
        for (index, row) in rows.enumerated() {
            let view = makeView(row, index: index)
            if case .header = row.kind, let last = stack.arrangedSubviews.last { stack.setCustomSpacing(20, after: last) }
            stack.addArrangedSubview(view)
        }
        if let focused, controls.indices.contains(focused) { window?.makeFirstResponder(controls[focused]) }
        needsLayout = true
    }

    /// Stops waiting for the last click to be answered, as six seconds would.
    func settleNow() {
        if settleBy != nil { settleBy = .distantPast }
    }

    private func paragraph(_ text: String, width: CGFloat) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.isSelectable = false
        label.preferredMaxLayoutWidth = width
        label.widthAnchor.constraint(equalToConstant: width).isActive = true
        return label
    }

    private func makeView(_ row: SettingsRow, index: Int) -> NSView {
        let leading = CGFloat(row.indent) * FormView.indentWidth
        let width = FormView.contentWidth - leading
        var views: [NSView] = []
        // Small print lines up with a checkbox's title, not with its box.
        var detailInset: CGFloat = 0

        func track(_ control: NSControl) {
            control.tag = index
            control.target = self
            control.action = #selector(acted(_:))
            control.isEnabled = row.enabled
            controls.append(control)
        }

        switch row.kind {
        case .header:
            let label = NSTextField(labelWithString: row.title)
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            views.append(label)
        case let .toggle(on):
            let box = NSButton(checkboxWithTitle: row.title, target: nil, action: nil)
            box.state = on ? .on : .off
            track(box)
            views.append(box)
            detailInset = 20
        case let .choice(options, selected):
            let label = NSTextField(labelWithString: row.title)
            label.textColor = row.enabled ? .labelColor : .disabledControlTextColor
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            // `addItems(withTitles:)` drops a title it has already been given.
            for option in options { popup.menu?.addItem(NSMenuItem(title: option, action: nil, keyEquivalent: "")) }
            if options.indices.contains(selected) { popup.selectItem(at: selected) }
            track(popup)
            let line = NSStackView(views: [label, popup])
            line.orientation = .horizontal
            line.spacing = 8
            views.append(line)
        case .button:
            let button = NSButton(title: row.title, target: nil, action: nil)
            track(button)
            views.append(button)
        case .text:
            views.append(paragraph(row.title, width: width))
        case let .note(warning):
            let note = NoteView(width: width)
            note.show(row.title, tone: warning ? .warning : .plain)
            views.append(note)
        }
        if let detail = row.detail {
            let text = paragraph(detail, width: width - detailInset)
            views.append(detailInset == 0 ? text : padded(text, by: detailInset))
        }

        let column = NSStackView(views: views)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 3
        return leading == 0 ? column : padded(column, by: leading)
    }

    private func padded(_ view: NSView, by inset: CGFloat) -> NSView {
        let box = NSStackView(views: [view])
        box.orientation = .horizontal
        box.edgeInsets = NSEdgeInsets(top: 0, left: inset, bottom: 0, right: 0)
        return box
    }

    @objc private func acted(_ sender: NSControl) {
        guard shown.indices.contains(sender.tag) else { return }
        let row = shown[sender.tag]
        let value: Int
        switch sender {
        case let popup as NSPopUpButton: value = popup.indexOfSelectedItem
        case let button as NSButton: value = button.state == .on ? 1 : 0
        default: return
        }
        // The control already shows what was asked for. Some of it takes a while, such as a
        // display going off or a switch that the anchor has to make; if Baton has shown nothing
        // new by then, the rows are drawn again as they really are.
        settleBy = Date().addingTimeInterval(6)
        // After this click is over, because what it leads to may replace the control it came from.
        DispatchQueue.main.async { row.act?(value) }
    }
}

extension NSView {
    /// Renders the view to a PNG, for checking its appearance without looking at the window. A
    /// view that is in no window is laid out in one that is never put on screen.
    func writeSnapshot(to url: URL) -> Bool {
        var borrowed: NSWindow?
        if window == nil {
            // A view without constraints has no fitting size, and keeps the frame it was made with.
            let size = fittingSize.width > 0 && fittingSize.height > 0 ? fittingSize : frame.size
            let host = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: true)
            host.isReleasedWhenClosed = false
            host.contentView = self
            host.setContentSize(size)
            borrowed = host
        }
        defer { if borrowed != nil { borrowed?.contentView = NSView() } }
        layoutSubtreeIfNeeded()
        guard let bitmap = bitmapImageRepForCachingDisplay(in: bounds) else { return false }
        cacheDisplay(in: bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }
}
