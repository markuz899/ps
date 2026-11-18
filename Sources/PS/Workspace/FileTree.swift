import AppKit
import CoreServices
import PSCore

/// FSEvents wrapper: one stream for a set of roots, callbacks on the main queue.
final class FSWatcher {
    private var stream: FSEventStreamRef?
    private(set) var paths: Set<String> = []
    private let handler: ([String]) -> Void

    init(handler: @escaping ([String]) -> Void) {
        self.handler = handler
    }

    deinit { stop() }

    func watch(_ newPaths: Set<String>) {
        guard newPaths != paths else { return }
        stop()
        paths = newPaths
        guard !newPaths.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(rawPaths, to: NSArray.self) as? [String] ?? []
            watcher.handler(Array(array.prefix(count)))
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(nil, callback, &context, Array(newPaths) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}

final class FileNode: NSObject {
    let url: URL
    let isDirectory: Bool
    weak var parent: FileNode?
    /// nil until the folder is expanded for the first time (lazy loading).
    var children: [FileNode]?
    var isLoading = false

    init(url: URL, isDirectory: Bool, parent: FileNode?) {
        self.url = url
        self.isDirectory = isDirectory
        self.parent = parent
    }

    var name: String { url.lastPathComponent }

    /// Lists one level; runs off the main thread.
    static func list(_ url: URL, showHidden: Bool) -> [(URL, Bool)] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        let entries = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: options)) ?? []
        return entries
            .map { entry -> (URL, Bool) in
                let values = try? entry.resourceValues(forKeys: Set(keys))
                // .rtfd packages are documents, not folders.
                let isDirectory = values?.isDirectory == true && entry.pathExtension.lowercased() != "rtfd"
                return (entry, isDirectory)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 }
                return lhs.0.lastPathComponent.localizedStandardCompare(rhs.0.lastPathComponent) == .orderedAscending
            }
    }
}

protocol FileTreeDelegate: AnyObject {
    func fileTree(open url: URL)
    func fileTree(didMove from: URL, to: URL)
    func fileTreeOpenDropped(_ urls: [URL])
}

/// Explorer: NSOutlineView with lazy folders, live refresh, context menu, inline rename
/// and drag-and-drop moves.
final class FileTreeController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
    weak var delegate: FileTreeDelegate?
    private let outline = NSOutlineView()
    private(set) var root: FileNode?
    private var nodesByPath: [String: FileNode] = [:]
    private let header = NSTextField(labelWithString: "")
    private let placeholder = NSTextField(wrappingLabelWithString: L("No folder open"))
    private let dragType = NSPasteboard.PasteboardType("app.ps.filenode")

    override func loadView() {
        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .default
        outline.indentationPerLevel = 12
        outline.autoresizesOutlineColumn = true
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked)
        outline.doubleAction = #selector(clicked)
        outline.setAccessibilityLabel(L("Files"))
        outline.registerForDraggedTypes([dragType, .fileURL])
        outline.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor
        header.lineBreakMode = .byTruncatingTail
        header.translatesAutoresizingMaskIntoConstraints = false
        placeholder.textColor = .tertiaryLabelColor
        placeholder.alignment = .center
        placeholder.translatesAutoresizingMaskIntoConstraints = false

        let view = NSView()
        for subview in [header, scroll, placeholder] { view.addSubview(subview) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            placeholder.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            placeholder.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            placeholder.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
        self.view = view
    }

    // MARK: Root & loading

    func setRoot(_ url: URL?) {
        nodesByPath = [:]
        if let url {
            let node = FileNode(url: url, isDirectory: true, parent: nil)
            root = node
            nodesByPath[url.standardizedFileURL.path] = node
            header.stringValue = url.lastPathComponent.uppercased()
            load(node)
        } else {
            root = nil
            header.stringValue = ""
        }
        placeholder.isHidden = url != nil
        outline.reloadData()
    }

    func reloadAll() {
        for node in nodesByPath.values where node.children != nil { load(node) }
    }

    private func load(_ node: FileNode) {
        guard !node.isLoading else { return }
        node.isLoading = true
        let showHidden = Prefs.showHidden
        DispatchQueue.global(qos: .userInitiated).async {
            let entries = FileNode.list(node.url, showHidden: showHidden)
            DispatchQueue.main.async { [weak self] in
                node.isLoading = false
                self?.apply(entries, to: node)
            }
        }
    }

    /// Reuses existing child nodes so expansion state survives refreshes.
    private func apply(_ entries: [(URL, Bool)], to node: FileNode) {
        let existing = Dictionary((node.children ?? []).map { ($0.url.standardizedFileURL.path, $0) }, uniquingKeysWith: { a, _ in a })
        let children = entries.map { url, isDirectory -> FileNode in
            let path = url.standardizedFileURL.path
            if let old = existing[path], old.isDirectory == isDirectory { return old }
            return FileNode(url: url, isDirectory: isDirectory, parent: node)
        }
        let keep = Set(children.map { $0.url.standardizedFileURL.path })
        for (path, old) in existing where !keep.contains(path) { forget(old) }
        for child in children where child.isDirectory { nodesByPath[child.url.standardizedFileURL.path] = child }
        node.children = children
        let selected = outline.selectedRow >= 0 ? (outline.item(atRow: outline.selectedRow) as? FileNode) : nil
        outline.reloadItem(node === root ? nil : node, reloadChildren: true)
        if let selected { select(selected.url) }
    }

    private func forget(_ node: FileNode) {
        nodesByPath.removeValue(forKey: node.url.standardizedFileURL.path)
        node.children?.forEach(forget)
    }

    /// FSEvents paths: refresh the loaded folders that contain them.
    func filesChanged(_ paths: [String]) {
        var folders = Set<String>()
        for path in paths {
            let standardized = URL(fileURLWithPath: path).standardizedFileURL
            folders.insert(standardized.deletingLastPathComponent().path)
            folders.insert(standardized.path)
        }
        for folder in folders {
            if let node = nodesByPath[folder], node.children != nil { load(node) }
        }
    }

    func select(_ url: URL) {
        let path = url.standardizedFileURL.path
        for row in 0..<outline.numberOfRows {
            if let node = outline.item(atRow: row) as? FileNode, node.url.standardizedFileURL.path == path {
                outline.selectRowIndexes([row], byExtendingSelection: false)
                outline.scrollRowToVisible(row)
                return
            }
        }
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = (item as? FileNode) ?? root else { return 0 }
        if node.children == nil { load(node) }
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? FileNode) ?? root)!.children![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isDirectory ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let image = NSImageView()
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingMiddle
            text.delegate = self
            for view in [image, text] as [NSView] {
                view.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(view)
            }
            cell.imageView = image
            cell.textField = text
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        cell.textField?.stringValue = node.name
        cell.imageView?.image = FileIcon.image(for: node.url, isDirectory: node.isDirectory, size: 12)
        cell.setAccessibilityLabel(node.isDirectory ? L("Folder %@", node.name) : node.name)
        return cell
    }

    @objc private func clicked() {
        guard let node = outline.item(atRow: outline.clickedRow) as? FileNode else { return }
        if node.isDirectory {
            if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
        } else {
            delegate?.fileTree(open: node.url)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, let node = outline.item(atRow: outline.selectedRow) as? FileNode, !node.isDirectory {
            delegate?.fileTree(open: node.url)
            return
        }
        super.keyDown(with: event)
    }

    // MARK: Context menu

    private var contextNode: FileNode? {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        return row >= 0 ? outline.item(atRow: row) as? FileNode : nil
    }

    private var targetFolder: FileNode? {
        guard let node = contextNode else { return root }
        return node.isDirectory ? node : node.parent ?? root
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard root != nil else { return }
        menu.addItem(withTitle: L("New File"), action: #selector(newFile), keyEquivalent: "").target = self
        menu.addItem(withTitle: L("New Folder"), action: #selector(newFolder), keyEquivalent: "").target = self
        if contextNode != nil {
            menu.addItem(.separator())
            menu.addItem(withTitle: L("Rename"), action: #selector(rename), keyEquivalent: "").target = self
            menu.addItem(withTitle: L("Move to Trash"), action: #selector(trash), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: L("Reveal in Finder"), action: #selector(reveal), keyEquivalent: "").target = self
            menu.addItem(withTitle: L("Copy Path"), action: #selector(copyPath), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        let hidden = menu.addItem(withTitle: L("Show Hidden Files"), action: #selector(toggleHidden), keyEquivalent: "")
        hidden.target = self
        hidden.state = Prefs.showHidden ? .on : .off
    }

    private func uniqueURL(in folder: URL, base: String) -> URL {
        var candidate = folder.appendingPathComponent(base)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(index)")
            index += 1
        }
        return candidate
    }

    @objc private func newFile() { create(directory: false) }
    @objc private func newFolder() { create(directory: true) }

    private func create(directory: Bool) {
        guard let folder = targetFolder else { return }
        let url = uniqueURL(in: folder.url, base: directory ? L("untitled folder") : L("untitled"))
        do {
            if directory {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            } else {
                try Data().write(to: url, options: .withoutOverwriting)
            }
        } catch {
            presentError(error)
            return
        }
        if folder !== root { outline.expandItem(folder) }
        let entries = FileNode.list(folder.url, showHidden: Prefs.showHidden)
        apply(entries, to: folder)
        select(url)
        beginRename()
    }

    @objc private func rename() {
        if let node = contextNode { select(node.url) }
        beginRename()
    }

    private func beginRename() {
        let row = outline.selectedRow
        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView,
              let field = cell.textField else { return }
        field.isEditable = true
        field.isSelectable = true
        view.window?.makeFirstResponder(field)
        if let editor = field.currentEditor() {
            let name = field.stringValue as NSString
            let ext = name.pathExtension
            editor.selectedRange = NSRange(location: 0, length: ext.isEmpty ? name.length : name.length - ext.count - 1)
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        field.isEditable = false
        let row = outline.row(for: field)
        guard row >= 0, let node = outline.item(atRow: row) as? FileNode else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != node.name, !name.contains("/") else {
            field.stringValue = node.name
            return
        }
        move(node.url, to: node.url.deletingLastPathComponent().appendingPathComponent(name))
    }

    private func move(_ source: URL, to destination: URL) {
        do {
            try FileManager.default.moveItem(at: source, to: destination)
            delegate?.fileTree(didMove: source, to: destination)
        } catch {
            presentError(error)
        }
    }

    @objc private func trash() {
        guard let node = contextNode else { return }
        do {
            try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
        } catch {
            presentError(error)
        }
    }

    @objc private func reveal() {
        if let node = contextNode { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
    }

    @objc private func copyPath() {
        guard let node = contextNode else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.url.path, forType: .string)
    }

    @objc private func toggleHidden() {
        Prefs.defaults.set(!Prefs.showHidden, forKey: Prefs.Key.showHidden)
    }

    // MARK: Drag & drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? FileNode else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(node.url.path, forType: dragType)
        pasteboardItem.setString(node.url.absoluteString, forType: .fileURL)
        return pasteboardItem
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard root != nil else { return [] }
        if info.draggingPasteboard.types?.contains(dragType) == true {
            var target = (item as? FileNode) ?? root
            if let node = target, !node.isDirectory { target = node.parent ?? root }
            outlineView.setDropItem(target === root ? nil : target, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .move
        }
        return .copy
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let pasteboard = info.draggingPasteboard
        if let paths = pasteboard.pasteboardItems?.compactMap({ $0.string(forType: dragType) }), !paths.isEmpty {
            guard let folder = (item as? FileNode) ?? root else { return false }
            for path in paths {
                let source = URL(fileURLWithPath: path)
                let destination = folder.url.appendingPathComponent(source.lastPathComponent)
                // Never move a folder into itself or onto its current place.
                if folder.url.standardizedFileURL.path.hasPrefix(source.standardizedFileURL.path) { continue }
                if destination.standardizedFileURL == source.standardizedFileURL { continue }
                move(source, to: destination)
            }
            return true
        }
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        delegate?.fileTreeOpenDropped(urls)
        return !urls.isEmpty
    }
}
