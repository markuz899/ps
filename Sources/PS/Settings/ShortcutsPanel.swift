import AppKit

/// The "Shortcuts…" panel: lists the customizable menu shortcuts and lets the
/// user record a new key combination for each.
final class ShortcutsController: NSViewController {
    struct Entry {
        let id: String
        let title: String
        let defaultKey: String
        let defaultModifiers: NSEvent.ModifierFlags
    }

    static let entries: [Entry] = [
        Entry(id: "sidebar", title: L("Toggle Sidebar"), defaultKey: "s", defaultModifiers: [.command, .control]),
        Entry(id: "explorer", title: L("Explorer"), defaultKey: "e", defaultModifiers: [.command, .shift]),
        Entry(id: "search", title: L("Search"), defaultKey: "f", defaultModifiers: [.command, .shift, .control]),
        Entry(id: "gitGraph", title: L("Git Graph"), defaultKey: "g", defaultModifiers: [.command, .shift, .control]),
    ]

    weak var window: NSWindow?
    private var rows: [String: (label: NSTextField, button: NSButton)] = [:]
    private var capturing: String?
    private let captureView = ShortcutCaptureView()

    override func loadView() {
        var views: [NSView] = []
        for entry in Self.entries {
            let title = NSTextField(labelWithString: entry.title)
            title.font = .systemFont(ofSize: 12)
            let shortcut = Prefs.shortcut(id: entry.id, defaultKey: entry.defaultKey, defaultModifiers: entry.defaultModifiers)
            let label = NSTextField(labelWithString: Self.format(key: shortcut.key, modifiers: shortcut.modifiers))
            label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            let button = NSButton(title: L("Change…"), target: self, action: #selector(changePressed(_:)))
            button.bezelStyle = .rounded
            button.tag = Self.entries.firstIndex { $0.id == entry.id } ?? 0
            let row = NSStackView(views: [title, label, button])
            row.spacing = 10
            row.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
            title.setContentHuggingPriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            rows[entry.id] = (label, button)
            views.append(row)
        }
        let reset = NSButton(title: L("Reset to Defaults"), target: self, action: #selector(resetAll))
        reset.bezelStyle = .rounded
        views.append(reset)

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)

        captureView.handler = { [weak self] event in self?.capture(event) ?? false }
        captureView.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: captureView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: captureView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: captureView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: captureView.bottomAnchor),
        ])
        view = captureView
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        window?.makeFirstResponder(captureView)
    }

    @objc private func changePressed(_ sender: NSButton) {
        guard let entry = Self.entries[safe: sender.tag] else { return }
        capturing = entry.id
        if let row = rows[entry.id] {
            row.label.stringValue = L("Press shortcut…")
            row.label.textColor = .controlAccentColor
            row.button.title = L("Cancel")
        }
        window?.makeFirstResponder(captureView)
    }

    @objc private func resetAll() {
        for entry in Self.entries {
            Prefs.resetShortcut(id: entry.id)
            refresh(entry)
        }
        (NSApp.delegate as? AppDelegate)?.rebuildMenu()
        capturing = nil
    }

    private func refresh(_ entry: Entry) {
        guard let row = rows[entry.id] else { return }
        let shortcut = Prefs.shortcut(id: entry.id, defaultKey: entry.defaultKey, defaultModifiers: entry.defaultModifiers)
        row.label.stringValue = Self.format(key: shortcut.key, modifiers: shortcut.modifiers)
        row.label.textColor = .secondaryLabelColor
        row.button.title = L("Change…")
    }

    /// Returns true when the event was consumed.
    private func capture(_ event: NSEvent) -> Bool {
        guard let id = capturing, let entry = Self.entries.first(where: { $0.id == id }) else { return false }
        if event.keyCode == 53 { // escape cancels
            capturing = nil
            refresh(entry)
            return true
        }
        let characters = event.charactersIgnoringModifiers ?? ""
        guard !characters.isEmpty else { return true } // pure modifier press: keep waiting
        // Keep only the device-independent command keys; caps lock and function are noise.
        let relevant: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        var modifiers = event.modifierFlags.intersection(relevant)
        if modifiers.isEmpty, !characters.isEmpty, characters != characters.lowercased() {
            modifiers = [.shift] // a capital letter implies shift
        }
        modifiers.remove(.capsLock)
        Prefs.setShortcut(id: id, key: characters.lowercased(), modifiers: modifiers)
        (NSApp.delegate as? AppDelegate)?.rebuildMenu()
        capturing = nil
        refresh(entry)
        return true
    }

    static func format(key: String, modifiers: NSEvent.ModifierFlags) -> String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        let special: [String: String] = [
            "\t": "⇥", "\r": "↩", " ": "Space", "\u{1B}": "esc",
            String(UnicodeScalar(NSUpArrowFunctionKey)!): "↑",
            String(UnicodeScalar(NSDownArrowFunctionKey)!): "↓",
            String(UnicodeScalar(NSLeftArrowFunctionKey)!): "←",
            String(UnicodeScalar(NSRightArrowFunctionKey)!): "→",
        ]
        return text + (special[key] ?? key.uppercased())
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private final class ShortcutCaptureView: NSView {
    var handler: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if handler?(event) != true { super.keyDown(with: event) }
    }
}
