import AppKit
import PSCore

struct PaletteItem {
    let title: String
    let detail: String
    let image: NSImage?
    let shortcut: String
    let run: () -> Void
}

/// Frosted panel over the window with fuzzy search. Two uses: Quick Open (⌘P, files of the
/// open folder) and the Command Palette (⇧⌘P, every menu command).
final class QuickOpenPanel: NSPanel, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private enum Mode {
        case files
        case commands
    }

    private let field = NSSearchField()
    private let table = NSTableView()
    private var mode = Mode.files
    private var files: [URL] = []
    private var root: URL?
    private var items: [PaletteItem] = []
    private var results: [PaletteItem] = []
    var onOpen: ((URL) -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 580, height: 400), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovable = false
        isFloatingPanel = true
        hidesOnDeactivate = true
        becomesKeyOnlyIfNeeded = false
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true

        field.font = .systemFont(ofSize: 15)
        field.controlSize = .large
        field.delegate = self
        field.focusRingType = .none

        table.addTableColumn(NSTableColumn(identifier: .init("item")))
        table.headerView = nil
        table.rowHeight = 34
        table.style = .inset
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(runSelected)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true

        for view in [field, scroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(view)
        }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: effect.topAnchor, constant: 14),
            field.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
            field.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -6),
        ])
        contentView = effect
    }

    override var canBecomeKey: Bool { true }

    func invalidateIndex() {
        files = []
        root = nil
    }

    private func present(over window: NSWindow, placeholder: String) {
        let frame = window.frame
        setFrameOrigin(NSPoint(x: frame.midX - self.frame.width / 2, y: frame.maxY - self.frame.height - 90))
        window.addChildWindow(self, ordered: .above)
        makeKeyAndOrderFront(nil)
        field.stringValue = ""
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        makeFirstResponder(field)
    }

    // MARK: Files

    func show(over window: NSWindow, root folder: URL?, recent: [URL]) {
        mode = .files
        present(over: window, placeholder: L("Search files by name"))
        if folder != root || files.isEmpty {
            root = folder
            files = recent
            filter()
            guard let folder else { return }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let found = FolderSearch.files(in: folder, includeHidden: Prefs.showHidden)
                DispatchQueue.main.async {
                    guard let self, self.root == folder else { return }
                    self.files = found
                    if self.mode == .files { self.filter() }
                }
            }
        } else {
            filter()
        }
    }

    private func relativePath(_ url: URL) -> String {
        let path = url.resolvingSymlinksInPath().path
        guard let rootPath = root?.resolvingSymlinksInPath().path, path.hasPrefix(rootPath + "/") else { return path }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private func fileItem(_ url: URL, relative: String) -> PaletteItem {
        PaletteItem(title: url.lastPathComponent, detail: (relative as NSString).deletingLastPathComponent, image: FileIcon.image(for: url, size: 14), shortcut: "") { [weak self] in
            self?.onOpen?(url)
        }
    }

    // MARK: Commands

    func showCommands(over window: NSWindow, items: [PaletteItem]) {
        mode = .commands
        self.items = items
        present(over: window, placeholder: L("Type a command"))
        filter()
    }

    // MARK: Filtering

    private func filter() {
        let query = field.stringValue
        switch mode {
        case .files:
            if query.isEmpty {
                results = files.prefix(200).map { fileItem($0, relative: relativePath($0)) }
            } else {
                results = files
                    .compactMap { url -> (URL, String, Int)? in
                        let relative = relativePath(url)
                        return Fuzzy.score(query, in: relative).map { (url, relative, $0) }
                    }
                    .sorted { $0.2 > $1.2 }
                    .prefix(200)
                    .map { fileItem($0.0, relative: $0.1) }
            }
        case .commands:
            if query.isEmpty {
                results = items
            } else {
                results = items
                    .compactMap { item in Fuzzy.score(query, in: item.title + " " + item.detail).map { (item, $0) } }
                    .sorted { $0.1 > $1.1 }
                    .map(\.0)
            }
        }
        table.reloadData()
        if !results.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = results[row]
        let cell = NSTableCellView()
        let name = NSTextField(labelWithString: item.title)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        let detail = NSTextField(labelWithString: item.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingHead
        let texts = NSStackView(views: [name, detail])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 0
        var views: [NSView] = [texts]
        if let image = item.image { views.insert(NSImageView(image: image), at: 0) }
        let rowStack = NSStackView(views: views)
        rowStack.spacing = 10
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(rowStack)
        let keys = NSTextField(labelWithString: item.shortcut)
        keys.font = .systemFont(ofSize: 12)
        keys.textColor = .tertiaryLabelColor
        keys.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(keys)
        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            rowStack.trailingAnchor.constraint(lessThanOrEqualTo: keys.leadingAnchor, constant: -8),
            rowStack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            keys.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
            keys.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.setAccessibilityLabel(item.shortcut.isEmpty ? item.title : "\(item.title), \(item.shortcut)")
        return cell
    }

    func controlTextDidChange(_ obj: Notification) {
        filter()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            guard !results.isEmpty else { return true }
            let delta = selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let row = min(max(0, table.selectedRow + delta), results.count - 1)
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            runSelected()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
            return true
        default:
            return false
        }
    }

    @objc private func runSelected() {
        guard results.indices.contains(table.selectedRow) else { return }
        let item = results[table.selectedRow]
        dismiss()
        item.run()
    }

    /// Runs the first match for a query, without showing anything (used by the self-test).
    func runFirst(matching query: String) -> String? {
        field.stringValue = query
        filter()
        guard let item = results.first else { return nil }
        dismiss()
        item.run()
        return item.title
    }

    override func resignKey() {
        super.resignKey()
        dismiss()
    }

    func dismiss() {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}
