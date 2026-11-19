import AppKit
import PSCore

/// Cmd+Shift+F: search the open folder in the background, results grouped by file.
final class FolderSearchController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate {
    /// NSOutlineView tracks items by identity, so results are wrapped in classes.
    private final class FileResult {
        let url: URL
        let matches: [MatchItem]
        init(url: URL, matches: [FolderMatch]) {
            self.url = url
            self.matches = matches.map(MatchItem.init)
        }
    }

    private final class MatchItem {
        let match: FolderMatch
        init(_ match: FolderMatch) { self.match = match }
    }

    var root: URL?
    var onOpen: ((FolderMatch) -> Void)?
    /// Text views of the files open in tabs, by resolved path: replacements there go
    /// through the editor so they can be undone.
    var openTextViews: (() -> [String: NSTextView])?

    private let field = NSSearchField()
    private let replaceField = NSTextField()
    private let replaceButton = NSButton(title: L("Replace All…"), target: nil, action: nil)
    private let options = NSSegmentedControl()
    private let status = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let stop = NSButton()
    private let outline = NSOutlineView()
    private var results: [FileResult] = []
    /// Cancellation flag shared with the background search.
    private final class Token {
        private let lock = NSLock()
        private var flag = false
        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return flag
        }
        func cancel() {
            lock.lock()
            flag = true
            lock.unlock()
        }
    }

    private var task: Token?
    private var searchID = 0

    override func loadView() {
        field.placeholderString = L("Search in folder")
        field.delegate = self
        field.sendsSearchStringImmediately = false
        field.sendsWholeSearchString = true
        field.target = self
        field.action = #selector(start)
        field.setAccessibilityLabel(L("Search in folder"))

        options.segmentCount = 3
        options.trackingMode = .selectAny
        options.controlSize = .small
        options.segmentStyle = .texturedRounded
        for (index, (label, tip)) in [("Aa", L("Match Case")), ("ab", L("Whole Word")), (".*", L("Regular Expression"))].enumerated() {
            options.setLabel(label, forSegment: index)
            options.setToolTip(tip, forSegment: index)
        }
        options.target = self
        options.action = #selector(start)

        replaceField.placeholderString = L("Replace")
        replaceField.setAccessibilityLabel(L("Replace in folder"))
        replaceField.controlSize = .regular
        replaceButton.controlSize = .small
        replaceButton.bezelStyle = .rounded
        replaceButton.target = self
        replaceButton.action = #selector(previewReplace)
        replaceButton.toolTip = L("Shows the changes before applying them")

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        stop.image = NSImage(systemSymbolName: "stop.circle", accessibilityDescription: L("Stop"))
        stop.isBordered = false
        stop.target = self
        stop.action = #selector(cancel)
        stop.isHidden = true
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail

        let column = NSTableColumn(identifier: .init("result"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.usesAutomaticRowHeights = true
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked)
        outline.setAccessibilityLabel(L("Search results"))

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let statusRow = NSStackView(views: [spinner, status, stop])
        statusRow.spacing = 6
        let replaceRow = NSStackView(views: [replaceField, replaceButton])
        replaceRow.spacing = 6
        let stack = NSStackView(views: [field, replaceRow, options, statusRow, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 0, right: 10)
        for view in [field, scroll] { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true }
        statusRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
        replaceRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        view = stack
    }

    func focus() {
        view.window?.makeFirstResponder(field)
    }

    /// Back to empty, e.g. when the folder is closed.
    func reset() {
        task?.cancel()
        searchID += 1
        results = []
        outline.reloadData()
        spinner.stopAnimation(nil)
        stop.isHidden = true
        status.stringValue = ""
    }

    func prefill(_ text: String) {
        field.stringValue = text
        start()
    }

    @objc private func start() {
        task?.cancel()
        searchID += 1
        let id = searchID
        results = []
        outline.reloadData()
        let query = field.stringValue
        guard let root, !query.isEmpty else {
            status.stringValue = root == nil ? L("Open a folder to search it.") : ""
            return
        }
        let findOptions = FindOptions(caseSensitive: options.isSelected(forSegment: 0), wholeWord: options.isSelected(forSegment: 1), regex: options.isSelected(forSegment: 2))
        let showHidden = Prefs.showHidden
        spinner.startAnimation(nil)
        stop.isHidden = false
        status.stringValue = L("Searching…")

        let token = Token()
        task = token
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var batch: [[FolderMatch]] = []
            var lastFlush = Date()
            let flush = {
                let ready = batch
                batch = []
                DispatchQueue.main.async { self?.append(ready, id: id) }
            }
            do {
                try FolderSearch.search(root: root, query: query, options: findOptions, includeHidden: showHidden, isCancelled: { token.isCancelled }) { matches in
                    batch.append(matches)
                    if Date().timeIntervalSince(lastFlush) > 0.15 {
                        lastFlush = Date()
                        flush()
                    }
                }
                flush()
                let cancelled = token.isCancelled
                DispatchQueue.main.async { self?.finish(id: id, cancelled: cancelled, error: nil) }
            } catch {
                DispatchQueue.main.async { self?.finish(id: id, cancelled: false, error: error) }
            }
        }
    }

    private var findOptions: FindOptions {
        FindOptions(caseSensitive: options.isSelected(forSegment: 0), wholeWord: options.isSelected(forSegment: 1), regex: options.isSelected(forSegment: 2))
    }

    /// Shows every change (old line → new line) and applies them only on confirmation.
    @objc func previewReplace() {
        let query = field.stringValue
        let template = replaceField.stringValue
        guard !query.isEmpty, !results.isEmpty, let window = view.window else { return }
        let options = findOptions
        let total = results.reduce(0) { $0 + $1.matches.count }

        let preview = NSMutableAttributedString()
        let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        for file in results.prefix(100) {
            preview.append(NSAttributedString(string: file.url.lastPathComponent + "\n", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor]))
            for item in file.matches.prefix(30) {
                let old = item.match.preview
                let new = (try? FindEngine.replaceAll(of: query, in: old, with: template, options: options).text) ?? old
                preview.append(NSAttributedString(string: "  \(item.match.line)  − " + old + "\n", attributes: [.font: mono, .foregroundColor: NSColor.systemRed, .strikethroughStyle: NSUnderlineStyle.single.rawValue]))
                preview.append(NSAttributedString(string: "  \(item.match.line)  + " + new + "\n", attributes: [.font: mono, .foregroundColor: NSColor.systemGreen]))
            }
            preview.append(NSAttributedString(string: "\n"))
        }

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 280))
        textView.isEditable = false
        textView.textStorage?.setAttributedString(preview)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 280))
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let alert = NSAlert()
        alert.messageText = L("Replace %d occurrences in %d files?", total, results.count)
        alert.informativeText = L("Open files are changed in their tabs (you can undo there); the others are saved to disk.")
        alert.accessoryView = scroll
        alert.addButton(withTitle: L("Replace"))
        alert.addButton(withTitle: L("Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.applyReplace(query: query, template: template, options: options) }
        }
    }

    func applyReplace(query: String, template: String, options: FindOptions) {
        let open = openTextViews?() ?? [:]
        var onDisk: [URL] = []
        var skipped = 0
        for file in results {
            let path = file.url.resolvingSymlinksInPath().path
            if let textView = open[path] {
                guard let items = try? FindEngine.replacements(of: query, in: textView.string, template: template, options: options), !items.isEmpty,
                      textView.shouldChangeText(inRanges: items.map { NSValue(range: $0.range) }, replacementStrings: items.map(\.replacement)) else { continue }
                textView.textStorage?.beginEditing()
                for item in items.reversed() { textView.textStorage?.replaceCharacters(in: item.range, with: item.replacement) }
                textView.textStorage?.endEditing()
                textView.didChangeText()
            } else if ["rtf", "rtfd"].contains(file.url.pathExtension.lowercased()) {
                skipped += 1
            } else {
                onDisk.append(file.url)
            }
        }
        status.stringValue = L("Replacing…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failed = 0
            for url in onDisk where (try? FolderSearch.replace(in: url, query: query, template: template, options: options)) == nil {
                failed += 1
            }
            DispatchQueue.main.async {
                self?.start()
                if failed + skipped > 0 {
                    self?.status.stringValue = L("%d files could not be changed", failed + skipped)
                }
            }
        }
    }

    @objc private func cancel() {
        task?.cancel()
    }

    private func append(_ batches: [[FolderMatch]], id: Int) {
        guard id == searchID, !batches.isEmpty else { return }
        for matches in batches {
            guard let url = matches.first?.url else { continue }
            let result = FileResult(url: url, matches: matches)
            results.append(result)
            outline.reloadData()
            if results.count <= 30 { outline.expandItem(result) }
        }
        updateStatus(prefix: L("Searching…") + " ")
    }

    private func finish(id: Int, cancelled: Bool, error: Error?) {
        guard id == searchID else { return }
        spinner.stopAnimation(nil)
        stop.isHidden = true
        if error != nil {
            status.stringValue = L("Invalid regex")
            return
        }
        updateStatus(prefix: cancelled ? L("Stopped.") + " " : "")
    }

    private func updateStatus(prefix: String) {
        let total = results.reduce(0) { $0 + $1.matches.count }
        status.stringValue = results.isEmpty ? prefix + L("No results") : prefix + L("%d results in %d files", total, results.count)
    }

    // MARK: Outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let file = item as? FileResult { return file.matches.count }
        return item == nil ? results.count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let file = item as? FileResult { return file.matches[index] }
        return results[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is FileResult
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            label.topAnchor.constraint(equalTo: cell.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -2),
        ])
        if let file = item as? FileResult {
            let filePath = file.url.resolvingSymlinksInPath().path
            let rootPath = (root?.resolvingSymlinksInPath().path ?? "") + "/"
            let relative = filePath.hasPrefix(rootPath) ? String(filePath.dropFirst(rootPath.count)) : filePath
            let text = NSMutableAttributedString(string: file.url.lastPathComponent, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)])
            let folder = (relative as NSString).deletingLastPathComponent
            if !folder.isEmpty {
                text.append(NSAttributedString(string: "  " + folder, attributes: [.font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: NSColor.tertiaryLabelColor]))
            }
            text.append(NSAttributedString(string: "  \(file.matches.count)", attributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .medium), .foregroundColor: NSColor.controlAccentColor]))
            label.attributedStringValue = text
        } else if let match = (item as? MatchItem)?.match {
            let text = NSMutableAttributedString(string: "\(match.line)  ", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor])
            let preview = NSMutableAttributedString(string: match.preview, attributes: [.font: NSFont.systemFont(ofSize: 11.5)])
            if NSMaxRange(match.previewRange) <= preview.length {
                preview.addAttributes([.backgroundColor: NSColor.systemYellow.withAlphaComponent(0.35), .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold)], range: match.previewRange)
            }
            text.append(preview)
            label.attributedStringValue = text
            cell.setAccessibilityLabel(L("Line %d: %@", match.line, match.preview))
        }
        return cell
    }

    @objc private func clicked() {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        guard row >= 0 else { return }
        if let item = outline.item(atRow: row) as? MatchItem {
            onOpen?(item.match)
        } else if let file = outline.item(atRow: row) {
            if outline.isItemExpanded(file) { outline.collapseItem(file) } else { outline.expandItem(file) }
        }
    }
}

/// Sidebar: Explorer, Search and Git Graph panes behind a segmented switch.
final class SidebarController: NSViewController {
    let tree = FileTreeController()
    let search = FolderSearchController()
    let graph = GitGraphController()
    var onClose: (() -> Void)?
    private let switcher = NSSegmentedControl()
    private let closeButton = NSButton()
    private let container = NSView()

    override func loadView() {
        switcher.segmentCount = 3
        switcher.setImage(NSImage(systemSymbolName: "folder", accessibilityDescription: L("Explorer")), forSegment: 0)
        switcher.setImage(NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: L("Search")), forSegment: 1)
        switcher.setImage(NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: L("Git Graph")), forSegment: 2)
        switcher.setToolTip(L("Explorer") + " (⇧⌘E)", forSegment: 0)
        switcher.setToolTip(L("Search") + " (⇧⌘F)", forSegment: 1)
        switcher.setToolTip(L("Git Graph"), forSegment: 2)
        switcher.selectedSegment = 0
        switcher.segmentStyle = .automatic
        switcher.target = self
        switcher.action = #selector(switched)
        switcher.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false

        // Closes the sidebar (it comes back from the title-bar button or ⌃⌘S).
        closeButton.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: L("Hide Sidebar"))
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = L("Hide Sidebar") + " (⌃⌘S)"
        closeButton.setAccessibilityLabel(L("Hide Sidebar"))
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(switcher)
        root.addSubview(closeButton)
        root.addSubview(container)
        NSLayoutConstraint.activate([
            switcher.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 6),
            switcher.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            closeButton.centerYAnchor.constraint(equalTo: switcher.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            closeButton.leadingAnchor.constraint(greaterThanOrEqualTo: switcher.trailingAnchor, constant: 6),
            container.topAnchor.constraint(equalTo: switcher.bottomAnchor, constant: 6),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])
        view = root
        addChild(tree)
        addChild(search)
        addChild(graph)
        show(tree)
    }

    private func show(_ controller: NSViewController) {
        container.subviews.forEach { $0.removeFromSuperview() }
        let child = controller.view
        child.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            child.topAnchor.constraint(equalTo: container.topAnchor),
            child.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    @objc private func closePressed() {
        onClose?()
    }

    @objc private func switched() {
        switch switcher.selectedSegment {
        case 1: showSearch()
        case 2: showGraph()
        default: showExplorer()
        }
    }

    func showExplorer() {
        switcher.selectedSegment = 0
        show(tree)
    }

    func showSearch() {
        switcher.selectedSegment = 1
        show(search)
        search.focus()
    }

    func showGraph() {
        switcher.selectedSegment = 2
        show(graph)
    }
}
