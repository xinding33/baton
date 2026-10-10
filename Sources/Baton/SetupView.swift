import AppKit
import BatonCore

/// Everything the setup form shows, which is the General pane of Settings once Baton is set
/// up. `SetupWindowController` fills it in from
/// this Mac; a test or a snapshot can fill it in by hand.
struct SetupState: Equatable {
    enum Mode: Equatable {
        /// Baton is not set up on this Mac, and does nothing until it is.
        case firstRun
        /// Baton is running, and this is its Settings window.
        case settings
    }

    var mode: Mode = .firstRun
    /// Something that has to be known before anything else, such as a config that cannot be read.
    var banner: String?
    /// Settings only: how sharing is going.
    var status: String?
    var statusNeedsAttention = false

    var name = ""
    var nameProblem: String?
    var nameNote: String?
    var role: Role = .anchor

    var code = ""
    var codeProblem: String?
    var codeNote: String?

    var permissions: [PermissionRow] = []

    /// On the first run this is part of what Start writes; afterwards it is the switch itself.
    var openAtLogin = true
    var loginEnabled = true
    var loginNote: String?
    /// Settings only: whether Baton has its item in the menu bar.
    var showsMenuIcon = true

    var actionTitle = "Start Baton"
    var actionEnabled = true
    var actionNote: String?
    var actionFailed = false
    var cancelTitle = "Quit"
}

/// The setup form: what this Mac is called, whether it has the mouse, the pairing code, the
/// permissions Baton still needs, and how Baton starts and shows itself here.
final class SetupView: NSView, NSTextFieldDelegate {
    enum Edit: Equatable {
        case name(String)
        case role(Role)
        case code(String)
        case generateCode
        case copyCode
        case openAtLogin(Bool)
        case showMenuIcon(Bool)
        case permission(PermissionKind)
        case apply
        case cancel
    }

    /// Every pane of Settings is this wide, so the window keeps its width from one to the next.
    static let width: CGFloat = 720
    private static let inset: CGFloat = 24
    private static let contentWidth = width - 2 * inset
    private static let buttonWidth: CGFloat = 130

    /// Called with what the person at the window did. The controller answers with `apply(_:)`.
    var onEdit: ((Edit) -> Void)?
    private(set) var state = SetupState()
    private var built = false

    private let stack = NSStackView()
    private let banner = NoteView()
    private let status = NoteView()
    private let nameField = NSTextField()
    private let nameProblem = SetupView.paragraph(color: .systemRed)
    private let nameNote = SetupView.paragraph(color: .secondaryLabelColor)
    private lazy var anchorChoice = NSButton(radioButtonWithTitle: "This Mac has the mouse and keyboard", target: self, action: #selector(roleChosen(_:)))
    private lazy var clientChoice = NSButton(radioButtonWithTitle: "This Mac is controlled from another Mac", target: self, action: #selector(roleChosen(_:)))
    private let roleNote = SetupView.paragraph(color: .secondaryLabelColor)
    private let codeField = NSTextField()
    private lazy var generateButton = NSButton(title: "Generate", target: self, action: #selector(generate))
    private lazy var copyButton = NSButton(title: "Copy", target: self, action: #selector(copyCode))
    private let codeProblem = SetupView.paragraph(color: .systemRed)
    private let codeNote = SetupView.paragraph(color: .secondaryLabelColor)
    private let permissionRows = NSStackView()
    private lazy var loginCheckbox = NSButton(checkboxWithTitle: "Open at Login", target: self, action: #selector(loginToggled))
    private let loginNote = SetupView.paragraph(color: .secondaryLabelColor)
    private lazy var iconCheckbox = NSButton(checkboxWithTitle: "Show in the menu bar", target: self, action: #selector(iconToggled))
    private let iconNote = SetupView.paragraph("Without its menu bar item, open Baton again to get back to these settings.", color: .secondaryLabelColor)
    private let actionNote = SetupView.paragraph(color: .secondaryLabelColor)
    private lazy var cancelButton = NSButton(title: "Quit", target: self, action: #selector(cancel))
    private lazy var actionButton = NSButton(title: "Start Baton", target: self, action: #selector(act))

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: SetupView.width, height: 400))
        build()
        apply(SetupState())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }

    // MARK: Building

    private static func header(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    /// Small print that wraps at the width of the window's content.
    private static func paragraph(_ text: String = "", color: NSColor, width: CGFloat = contentWidth) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = color
        label.isSelectable = false
        label.preferredMaxLayoutWidth = width
        label.widthAnchor.constraint(equalToConstant: width).isActive = true
        return label
    }

    private static func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = spacing
        return row
    }

    private func build() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: SetupView.width),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SetupView.inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SetupView.inset),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
        ])

        let nameLabel = NSTextField(labelWithString: "Name")
        nameField.delegate = self
        nameField.placeholderString = "studio"
        nameField.widthAnchor.constraint(equalToConstant: 240).isActive = true

        codeField.delegate = self
        codeField.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        codeField.placeholderString = "five groups of five letters and digits"
        codeField.widthAnchor.constraint(equalToConstant: 330).isActive = true

        permissionRows.orientation = .vertical
        permissionRows.alignment = .leading
        permissionRows.spacing = 12

        let separator = NSBox()
        separator.boxType = .separator
        separator.widthAnchor.constraint(equalToConstant: SetupView.contentWidth).isActive = true

        let filler = NSView()
        filler.setContentHuggingPriority(.defaultLow, for: .horizontal)
        actionButton.keyEquivalent = "\r"
        let buttons = SetupView.row([filler, cancelButton, actionButton])
        buttons.widthAnchor.constraint(equalToConstant: SetupView.contentWidth).isActive = true

        let codeHint = SetupView.paragraph(
            "Every Mac needs the same code. Generate it on one Mac, then type it into the others. It never leaves these Macs, and anyone who has it can control them, so keep it to yourself.",
            color: .secondaryLabelColor
        )
        let sections: [[NSView]] = [
            [banner],
            [status],
            [SetupView.header("This Mac"), SetupView.row([nameLabel, nameField]), nameProblem, nameNote, anchorChoice, clientChoice, roleNote],
            [SetupView.header("Pairing code"), SetupView.row([codeField, generateButton, copyButton]), codeProblem, codeNote, codeHint],
            [SetupView.header("Permissions"), permissionRows],
            [SetupView.header("Baton"), loginCheckbox, loginNote, iconCheckbox, iconNote],
            [separator, actionNote, buttons],
        ]
        for section in sections {
            for view in section { stack.addArrangedSubview(view) }
            if let last = section.last { stack.setCustomSpacing(20, after: last) }
        }
        // Each of these sits alone in its section, and takes its spacing with it when hidden.
        stack.setCustomSpacing(14, after: banner)
        stack.setCustomSpacing(14, after: status)
    }

    private func permissionView(_ row: PermissionRow) -> NSView {
        let symbol: String, tint: NSColor
        switch row.level {
        case .granted: (symbol, tint) = ("checkmark.circle.fill", .systemGreen)
        case .missing: (symbol, tint) = ("exclamationmark.triangle.fill", .systemOrange)
        case .undecided: (symbol, tint) = ("questionmark.circle.fill", .tertiaryLabelColor)
        }
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: row.state)
        icon.contentTintColor = tint
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true

        let title = NSMutableAttributedString(string: row.title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)])
        title.append(NSAttributedString(string: "   \(row.state)", attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: row.level == .granted ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]))
        let textWidth = SetupView.contentWidth - 20 - SetupView.buttonWidth - 2 * 10
        let heading = NSTextField(labelWithAttributedString: title)
        heading.lineBreakMode = .byTruncatingTail
        heading.widthAnchor.constraint(lessThanOrEqualToConstant: textWidth).isActive = true
        let text = NSStackView(views: [heading, SetupView.paragraph(row.detail, color: .secondaryLabelColor, width: textWidth)])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let trailing: NSView
        if let buttonTitle = row.button {
            let button = NSButton(title: buttonTitle, target: self, action: #selector(permissionAction(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(row.kind.rawValue)
            trailing = button
        } else {
            trailing = NSView()
        }
        trailing.widthAnchor.constraint(equalToConstant: SetupView.buttonWidth).isActive = true
        let line = SetupView.row([icon, text, trailing], spacing: 10)
        line.alignment = .top
        return line
    }

    // MARK: Showing a state

    func apply(_ new: SetupState) {
        let old = state
        state = new

        banner.show(new.banner, tone: .warning)
        status.show(new.mode == .settings ? new.status : nil, tone: new.statusNeedsAttention ? .warning : .plain)

        // What was typed is echoed back unchanged, so this only writes when the text came from
        // somewhere else, as a generated code does, and never moves the insertion point.
        if nameField.stringValue != new.name { nameField.stringValue = new.name }
        if codeField.stringValue != new.code { codeField.stringValue = new.code }
        set(nameProblem, new.nameProblem)
        set(nameNote, new.nameProblem == nil ? new.nameNote : nil)
        anchorChoice.state = new.role == .anchor ? .on : .off
        clientChoice.state = new.role == .client ? .on : .off
        roleNote.stringValue = new.role == .anchor
            ? "The other Macs connect to this one. Baton calls it the anchor."
            : "It finds the Mac with the mouse on your network by itself. Baton calls this Mac a client."
        set(codeProblem, new.codeProblem)
        set(codeNote, new.codeProblem == nil ? new.codeNote : nil)
        copyButton.isEnabled = PairingCode.problem(with: new.code) == nil

        if new.permissions != old.permissions || !built {
            permissionRows.arrangedSubviews.forEach { $0.removeFromSuperview() }
            new.permissions.map(permissionView).forEach(permissionRows.addArrangedSubview)
        }

        loginCheckbox.state = new.openAtLogin ? .on : .off
        loginCheckbox.isEnabled = new.loginEnabled
        set(loginNote, new.loginNote)
        // Until Baton is set up it has no menu bar item to show or hide.
        iconCheckbox.isHidden = new.mode == .firstRun
        iconCheckbox.state = new.showsMenuIcon ? .on : .off
        iconNote.isHidden = new.mode == .firstRun || new.showsMenuIcon
        set(actionNote, new.actionNote)
        actionNote.textColor = new.actionFailed ? .systemRed : .secondaryLabelColor
        actionButton.title = new.actionTitle
        actionButton.isEnabled = new.actionEnabled
        cancelButton.title = new.cancelTitle

        built = true
        needsLayout = true
    }

    private func set(_ label: NSTextField, _ text: String?) {
        label.stringValue = text ?? ""
        label.isHidden = text == nil
    }

    // MARK: What the person at the window does

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        onEdit?(field === nameField ? .name(field.stringValue) : .code(field.stringValue))
    }

    @objc private func roleChosen(_ sender: NSButton) { onEdit?(.role(sender === anchorChoice ? .anchor : .client)) }
    @objc private func generate() { onEdit?(.generateCode) }
    @objc private func copyCode() { onEdit?(.copyCode) }
    @objc private func loginToggled() { onEdit?(.openAtLogin(loginCheckbox.state == .on)) }
    @objc private func iconToggled() { onEdit?(.showMenuIcon(iconCheckbox.state == .on)) }
    @objc private func act() { onEdit?(.apply) }
    @objc private func cancel() { onEdit?(.cancel) }
    @objc private func permissionAction(_ sender: NSButton) {
        guard let kind = sender.identifier.flatMap({ PermissionKind(rawValue: $0.rawValue) }) else { return }
        onEdit?(.permission(kind))
    }

    // MARK: Pictures

    /// Renders `state` as the window would show it, in a window that is never put on screen.
    static func writeSnapshot(of state: SetupState, to url: URL) -> Bool {
        let view = SetupView()
        view.apply(state)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: view.fittingSize), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.setContentSize(view.fittingSize)
        return view.writeSnapshot(to: url)
    }
}

/// A tinted box for the one thing in a pane that must not be overlooked.
final class NoteView: NSView {
    enum Tone { case plain, warning }

    private let label = NSTextField(wrappingLabelWithString: "")
    private var tone = Tone.plain

    init(width: CGFloat = SetupView.width - 2 * 24) {
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 12)
        label.isSelectable = true
        label.preferredMaxLayoutWidth = width - 24
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ text: String?, tone: Tone) {
        isHidden = text == nil
        label.stringValue = text ?? ""
        self.tone = tone
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let fill: NSColor = tone == .warning ? .systemOrange.withAlphaComponent(0.18) : .labelColor.withAlphaComponent(0.06)
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
}
