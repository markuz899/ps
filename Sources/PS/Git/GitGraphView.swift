import AppKit
import PSCore

// MARK: - Row view

/// One commit row: graph lines + node drawn in `draw`, text as subviews.
/// Only visible rows exist (NSTableView virtualizes), so drawing stays cheap.
final class GitGraphRowView: NSView {
    static let height: CGFloat = 42
    private static let laneSpacing: CGFloat = 16
    private static let laneMargin: CGFloat = 10

    var commit: GitCommit?
    var node: GitGraphNode?
    var graphRow: GitGraphRow?
    var laneCount = 1
    var badges: [(text: String, color: NSColor)] = []
    var isHead = false

    private let subjectField = NSTextField(labelWithString: "")
    private let metaField = NSTextField(labelWithString: "")
    private var badgeRects: [(rect: NSRect, text: String, color: NSColor)] = []

    static func graphWidth(laneCount: Int) -> CGFloat {
        laneMargin * 2 + CGFloat(max(laneCount, 1)) * laneSpacing
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        subjectField.font = .systemFont(ofSize: 12, weight: .medium)
        subjectField.lineBreakMode = .byTruncatingTail
        subjectField.maximumNumberOfLines = 1
        metaField.font = .systemFont(ofSize: 10)
        metaField.textColor = .secondaryLabelColor
        metaField.lineBreakMode = .byTruncatingTail
        metaField.maximumNumberOfLines = 1
        addSubview(subjectField)
        addSubview(metaField)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func laneColor(_ index: Int) -> NSColor {
        NSColor(hex: GitBranchPalette.color(index: index)) ?? .controlAccentColor
    }

    func configure(commit: GitCommit, node: GitGraphNode, row: GitGraphRow, laneCount: Int,
                   badges: [(text: String, color: NSColor)], isHead: Bool, meta: String) {
        self.commit = commit
        self.node = node
        self.graphRow = row
        self.laneCount = laneCount
        self.badges = badges
        self.isHead = isHead
        subjectField.stringValue = commit.subject
        metaField.stringValue = meta
        arrangeSubviews()
        setNeedsDisplay(bounds)
    }

    override func layout() {
        super.layout()
        arrangeSubviews()
    }

    private func arrangeSubviews() {
        let graphWidth = min(Self.graphWidth(laneCount: laneCount), bounds.width * 0.45)
        var x = graphWidth + 4
        badgeRects = []
        let badgeFont = NSFont.systemFont(ofSize: 9.5, weight: .medium)
        for badge in badges {
            let size = (badge.text as NSString).size(withAttributes: [.font: badgeFont])
            let rect = NSRect(x: x, y: 4, width: size.width + 10, height: 14)
            badgeRects.append((rect, badge.text, badge.color))
            x = rect.maxX + 4
        }
        if !badgeRects.isEmpty { x += 2 }
        subjectField.frame = NSRect(x: x, y: 2, width: max(0, bounds.width - x - 4), height: 17)
        metaField.frame = NSRect(x: graphWidth + 4, y: 22, width: max(0, bounds.width - graphWidth - 8), height: 14)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let node, let row = graphRow else { return }
        let h = bounds.height
        let nodeY = h / 2
        func x(_ lane: Int) -> CGFloat {
            Self.laneMargin + CGFloat(lane) * Self.laneSpacing
        }

        // Vertical lines of edges passing through this row.
        for v in row.verticals {
            let path = NSBezierPath()
            path.lineWidth = 2
            path.move(to: NSPoint(x: x(v.lane), y: 0))
            path.line(to: NSPoint(x: x(v.lane), y: h))
            laneColor(v.colorIndex).setStroke()
            path.stroke()
        }
        // Curves leaving the node toward a parent in another lane.
        for o in row.outgoing {
            let path = NSBezierPath()
            path.lineWidth = 2
            path.move(to: NSPoint(x: x(o.fromLane), y: nodeY))
            path.curve(to: NSPoint(x: x(o.toLane), y: h),
                       controlPoint1: NSPoint(x: x(o.fromLane), y: h * 0.8),
                       controlPoint2: NSPoint(x: x(o.toLane), y: h * 0.8))
            laneColor(o.colorIndex).setStroke()
            path.stroke()
        }
        // Curves entering the node from an edge whose lane differs from the node's.
        for inc in row.incoming {
            let path = NSBezierPath()
            path.lineWidth = 2
            path.move(to: NSPoint(x: x(inc.lane), y: 0))
            path.curve(to: NSPoint(x: x(node.lane), y: nodeY),
                       controlPoint1: NSPoint(x: x(inc.lane), y: h * 0.25),
                       controlPoint2: NSPoint(x: x(node.lane), y: h * 0.25))
            laneColor(inc.colorIndex).setStroke()
            path.stroke()
        }

        // The commit node.
        let nodeRect = NSRect(x: x(node.lane) - 5, y: nodeY - 5, width: 10, height: 10)
        laneColor(node.colorIndex).setFill()
        NSBezierPath(ovalIn: nodeRect).fill()
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(ovalIn: nodeRect.insetBy(dx: 2, dy: 2)).fill()
        laneColor(node.colorIndex).setFill()
        NSBezierPath(ovalIn: nodeRect.insetBy(dx: 3.5, dy: 3.5)).fill()
        if isHead {
            let ring = NSBezierPath(ovalIn: nodeRect.insetBy(dx: -2.5, dy: -2.5))
            ring.lineWidth = 2
            NSColor.labelColor.setStroke()
            ring.stroke()
        }

        // Badges (HEAD, branches, remotes, tags).
        let badgeFont = NSFont.systemFont(ofSize: 9.5, weight: .medium)
        for badge in badgeRects {
            let path = NSBezierPath(roundedRect: badge.rect, xRadius: 4, yRadius: 4)
            badge.color.withAlphaComponent(0.18).setFill()
            path.fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: badgeFont, .foregroundColor: badge.color]
            let size = (badge.text as NSString).size(withAttributes: attributes)
            let point = NSPoint(x: badge.rect.midX - size.width / 2, y: badge.rect.midY - size.height / 2 + 0.5)
            badge.text.draw(at: point, withAttributes: attributes)
        }
    }
}

// MARK: - Controller

protocol GitGraphDelegate: AnyObject {
    func gitGraph(didSelectCommit hash: String)
    func gitGraph(didRequestDiff commit: GitCommit, path: String)
    func gitGraph(didRequestCheckout hash: String)
    func gitGraph(didRequestCreateBranch hash: String)
}

/// Sidebar pane with the commit graph: search field, branch filter, virtualized
/// table, context menu, keyboard navigation.
final class GitGraphController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    let store = GitGraphStore()
    weak var delegate: GitGraphDelegate?

    private let table = NSTableView()
    private let search = NSSearchField()
    private let filterButton = NSButton()
    private let status = NSTextField(labelWithString: "")
    private let empty = NSTextField(labelWithString: "")
    private var branchPopover: NSPopover?
    private var scrollObserver: NSObjectProtocol?

    var root: URL? {
        get { store.root }
        set { store.root = newValue }
    }

    override func loadView() {
        search.placeholderString = L("Filter commits…")
        search.delegate = self
        search.setAccessibilityLabel(L("Filter commits"))

        filterButton.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle", accessibilityDescription: L("Filter by branch"))
        filterButton.isBordered = false
        filterButton.bezelStyle = .texturedRounded
        filterButton.toolTip = L("Filter by branch")
        filterButton.setAccessibilityLabel(L("Filter by branch"))
        filterButton.target = self
        filterButton.action = #selector(showBranchFilter)

        let header = NSStackView(views: [search, filterButton])
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false

        status.font = .systemFont(ofSize: 10)
        status.textColor = .tertiaryLabelColor
        status.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("graph"))
        column.width = 200
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = GitGraphRowView.height
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(commitActivated)
        table.doubleAction = #selector(commitActivated)
        table.menu = NSMenu()
        table.menu?.delegate = self
        table.setAccessibilityLabel(L("Git graph"))
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.autoresizesSubviews = true

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        empty.alignment = .center
        empty.textColor = .secondaryLabelColor
        empty.maximumNumberOfLines = 3
        empty.lineBreakMode = .byWordWrapping
        empty.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(header)
        root.addSubview(status)
        root.addSubview(scroll)
        root.addSubview(empty)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 6),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            status.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 2),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            empty.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 16),
            empty.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -16),
        ])
        view = root

        store.onChange = { [weak self] in self?.reloadPreservingState() }
        scroll.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            self?.loadMoreIfNearBottom()
        }
        reloadPreservingState()
    }

    deinit {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
    }

    func notifyRepoChanged() {
        store.notifyRepoChanged()
    }

    // MARK: Data

    private func reloadPreservingState() {
        let selectedHash = selectedCommit?.hash
        let topHash = (table.visibleRect.minY >= 0 && !table.visibleRect.isEmpty)
            ? store.commit(atVisibleRow: table.row(at: table.visibleRect.origin))?.hash
            : nil
        table.reloadData()
        updateChrome()
        if let selectedHash, let row = store.visible.firstIndex(where: { store.commits[$0].hash == selectedHash }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        if let topHash, let row = store.visible.firstIndex(where: { store.commits[$0].hash == topHash }) {
            table.scrollRowToVisible(row)
        }
    }

    private func updateChrome() {
        let showEmpty: Bool
        switch store.state {
        case .idle:
            empty.stringValue = L("Open a folder to see its git graph.")
            showEmpty = true
        case .notARepository:
            empty.stringValue = L("This folder is not a git repository.")
            showEmpty = true
        case .empty:
            empty.stringValue = L("No commits yet.")
            showEmpty = true
        case .ready:
            showEmpty = store.visible.isEmpty
            empty.stringValue = L("No commits match the filter.")
        }
        empty.isHidden = !showEmpty
        if store.state == .ready {
            status.stringValue = store.visible.count < store.commits.count
                ? L("%d of %d commits", store.visible.count, store.commits.count)
                : L("%d commits", store.visible.count)
        } else {
            status.stringValue = ""
        }
    }

    private func loadMoreIfNearBottom() {
        guard let scroll = table.enclosingScrollView, let doc = scroll.documentView else { return }
        let visible = scroll.contentView.documentVisibleRect
        if visible.maxY > doc.bounds.height - 300 {
            store.loadMore()
        }
    }

    private var selectedCommit: GitCommit? {
        let row = table.selectedRow
        return row >= 0 ? store.commit(atVisibleRow: row) : nil
    }

    /// Selects and reveals a commit (used when clicking a parent in the detail pane).
    /// If the commit isn't loaded yet, more pages are loaded until it appears.
    func select(hash: String) {
        if let row = store.visible.firstIndex(where: { store.commits[$0].hash == hash }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
            if let commit = store.commit(atVisibleRow: row) {
                delegate?.gitGraph(didSelectCommit: commit.hash)
            }
        } else if store.hasMore {
            store.loadMore()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.select(hash: hash) }
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        store.visible.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let commit = store.commit(atVisibleRow: row),
              let node = store.node(atVisibleRow: row),
              let graphRow = store.graphRow(atVisibleRow: row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("row")
        let view = tableView.makeView(withIdentifier: identifier, owner: self) as? GitGraphRowView ?? {
            let view = GitGraphRowView(frame: .zero)
            view.identifier = identifier
            return view
        }()
        var badges: [(String, NSColor)] = []
        if store.isHead(commit.hash) {
            badges.append(("HEAD", .controlAccentColor))
        }
        for ref in store.refs(forCommit: commit.hash) {
            switch ref.kind {
            case .localBranch:
                let isCurrent = ref.name == store.currentBranch
                let color = isCurrent ? NSColor.controlAccentColor : NSColor(hex: GitBranchPalette.color(index: node.colorIndex)) ?? .controlAccentColor
                badges.append((ref.name, color))
            case .remoteBranch:
                badges.append((ref.name, .tertiaryLabelColor))
            case .tag:
                badges.append((ref.name, .systemOrange))
            }
        }
        let date = Date(timeIntervalSince1970: commit.timestamp)
        let relative = RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
        let meta = "\(commit.authorName) • \(relative) • \(commit.shortHash)"
        view.configure(commit: commit, node: node, row: graphRow, laneCount: store.graph.laneCount, badges: badges, isHead: store.isHead(commit.hash), meta: meta)
        view.setAccessibilityLabel("\(commit.subject), \(commit.authorName), \(relative), \(commit.shortHash)")
        return view
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        GitGraphRowView.height
    }

    /// Click (or Enter, via keyDown) opens the detail pane; arrows only move the selection.
    @objc private func commitActivated() {
        if table.clickedRow >= 0, table.clickedRow != table.selectedRow {
            table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false)
        }
        if let commit = selectedCommit {
            delegate?.gitGraph(didSelectCommit: commit.hash)
        }
    }

    override func keyDown(with event: NSEvent) {
        let row = table.selectedRow
        switch event.keyCode {
        case 126: // up
            table.selectRowIndexes(IndexSet(integer: max(0, row < 0 ? 0 : row - 1)), byExtendingSelection: false)
            table.scrollRowToVisible(table.selectedRow)
        case 125: // down
            let next = min(store.visible.count - 1, row < 0 ? 0 : row + 1)
            guard next >= 0 else { return }
            table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
            table.scrollRowToVisible(next)
        case 36, 76: // return
            if let commit = selectedCommit {
                delegate?.gitGraph(didSelectCommit: commit.hash)
                return
            }
        default:
            break
        }
        super.keyDown(with: event)
    }

    // MARK: Search

    func controlTextDidChange(_ notification: Notification) {
        store.query = search.stringValue
    }

    // MARK: Branch filter

    @objc private func showBranchFilter() {
        guard let refs = store.refs else { return }
        let content = BranchFilterController(refs: refs, selected: store.selectedBranches) { [weak self] selected in
            self?.store.selectedBranches = selected
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = content
        popover.contentSize = NSSize(width: 240, height: min(360, CGFloat(28 + refs.refs.count * 24)))
        branchPopover = popover
        popover.show(relativeTo: filterButton.bounds, of: filterButton, preferredEdge: .minY)
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let commit = selectedCommit ?? (table.clickedRow >= 0 ? store.commit(atVisibleRow: table.clickedRow) : nil) else { return }
        menu.addItem(ClosureMenuItem(title: L("Copy Hash")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(commit.hash, forType: .string)
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: L("Checkout")) { [weak self] in
            self?.delegate?.gitGraph(didRequestCheckout: commit.hash)
        })
        menu.addItem(ClosureMenuItem(title: L("Create Branch Here…")) { [weak self] in
            self?.delegate?.gitGraph(didRequestCreateBranch: commit.hash)
        })
    }
}

// MARK: - Branch filter popover

private final class BranchFilterController: NSViewController {
    private let refs: GitRefs
    private let onChange: (Set<String>?) -> Void
    private var selected: Set<String>
    private var buttons: [String: NSButton] = [:]

    init(refs: GitRefs, selected: Set<String>?, onChange: @escaping (Set<String>?) -> Void) {
        self.refs = refs
        self.selected = selected ?? []
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var allButton: NSButton!

    override func loadView() {
        allButton = NSButton(checkboxWithTitle: L("All branches"), target: self, action: #selector(toggleAll))
        allButton.state = selected.isEmpty ? .on : .off
        var views: [NSView] = [allButton]
        for ref in refs.refs.filter({ $0.kind != .tag }) {
            let button = NSButton(checkboxWithTitle: ref.name, target: self, action: #selector(toggled))
            button.state = selected.isEmpty || selected.contains(ref.name) ? .on : .off
            button.toolTip = ref.kind == .remoteBranch ? L("Remote branch") : L("Branch")
            buttons[ref.name] = button
            views.append(button)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        view = stack
    }

    @objc private func toggleAll() {
        for button in buttons.values { button.state = .on }
        allButton.state = .on
        onChange(nil) // nil = no filter
    }

    @objc private func toggled() {
        let set = Set(buttons.compactMap { $1.state == .on ? $0 : nil })
        allButton.state = set.count == buttons.count ? .on : .off
        // Unchecking everything falls back to showing all branches.
        onChange(set.isEmpty ? nil : set)
    }
}
