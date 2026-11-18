import AppKit
import PSCore
import UniformTypeIdentifiers

final class Tab {
    let document: Document
    var editor: DocumentEditor?
    var prompting = false
    weak var pane: Pane?

    init(document: Document) {
        self.document = document
    }
}

/// One editor group: its own tabs, tab bar, breadcrumb, formatting bar and find bar.
/// The window shows one or more panes side by side.
final class Pane: NSObject, TabBarDelegate {
    unowned let owner: MainWindowController
    var tabs: [Tab] = []
    var activeIndex = -1
    let view = NSView()
    let tabBar = TabBar()
    let breadcrumb = BreadcrumbBar()
    let formatBar = FormatBar()
    let findBar = FindBar()
    let container = PaneDropView()

    var activeTab: Tab? { tabs.indices.contains(activeIndex) ? tabs[activeIndex] : nil }

    var isActive = false {
        didSet { tabBar.isActivePane = isActive }
    }

    init(owner: MainWindowController) {
        self.owner = owner
        super.init()
        tabBar.delegate = self
        breadcrumb.onJump = { [weak self] location in
            guard let view = self?.activeTab?.editor?.textView else { return }
            view.setSelectedRange(NSRange(location: location, length: 0))
            view.scrollRangeToVisible(view.selectedRange())
            view.showFindIndicator(for: (view.string as NSString).lineRange(for: view.selectedRange()))
            view.window?.makeFirstResponder(view)
        }
        breadcrumb.onReveal = { [weak owner] url in owner?.revealInSidebar(url) }
        container.onDrop = { [weak self] in
            guard let self else { return false }
            return self.owner.acceptDraggedTab(into: self, at: nil)
        }
        findBar.isHidden = true
        findBar.onClose = { [weak self] in self?.findBar.hide() }
        formatBar.isHidden = true
        breadcrumb.isHidden = true
        container.wantsLayer = true
        container.setContentHuggingPriority(.defaultLow, for: .vertical)
        container.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let stack = NSStackView(views: [tabBar, breadcrumb, formatBar, findBar, container])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .width
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    func tabBar(_ bar: TabBar, select index: Int) { owner.activate(tabs[index]) }
    func tabBar(_ bar: TabBar, close index: Int) { owner.closeTab(tabs[index]) }
    func tabBar(_ bar: TabBar, menuFor index: Int) -> NSMenu { owner.tabMenu(for: tabs[index]) }

    func tabBar(_ bar: TabBar, beginDraggingTabAt index: Int) {
        TabDrag.tab = tabs[index]
    }

    func tabBar(_ bar: TabBar, acceptDropAt index: Int) -> Bool {
        owner.acceptDraggedTab(into: self, at: index)
    }

    func tabBar(_ bar: TabBar, draggedOutsideTo screenPoint: NSPoint) {
        if let tab = TabDrag.tab { owner.tearOff(tab, at: screenPoint) }
        TabDrag.tab = nil
    }

    func tabBar(_ bar: TabBar, move from: Int, to: Int) {
        let active = activeTab
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: to)
        activeIndex = tabs.firstIndex { $0 === active } ?? to
        owner.paneTabsChanged(self)
    }
}

/// The tab being dragged (between panes or windows of this app).
enum TabDrag {
    static var tab: Tab?
}

/// A pane's editor area: accepts a dragged tab, with a soft highlight while hovering.
final class PaneDropView: NSView {
    var onDrop: (() -> Bool)?
    private let highlight = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.psTab])
        highlight.wantsLayer = true
        highlight.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        highlight.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor
        highlight.layer?.borderWidth = 2
        highlight.layer?.cornerRadius = 6
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private func setHighlighted(_ on: Bool) {
        if on {
            highlight.frame = bounds.insetBy(dx: 6, dy: 6)
            highlight.autoresizingMask = [.width, .height]
            addSubview(highlight, positioned: .above, relativeTo: nil)
        } else {
            highlight.removeFromSuperview()
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.types?.contains(.psTab) == true else { return [] }
        setHighlighted(true)
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { setHighlighted(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { setHighlighted(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setHighlighted(false)
        return onDrop?() ?? false
    }
}

/// The main window: sidebar + one or more editor panes + status bar. Owns the tab model
/// and every document-level command (menu items reach it through the responder chain or
/// the app delegate).
/// The title bar: sidebar toggle at the left, title right after the sidebar.
final class ToolbarProvider: NSObject, NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    /// Required by AppKit even when only system items are used: without it the delegate
    /// is rejected ("does not implement all required methods") and the bar stays empty.
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        nil
    }
}

final class MainWindowController: NSWindowController, NSWindowDelegate, FileTreeDelegate {
    static let maxPanes = 4

    private(set) var panes: [Pane] = []
    private(set) var activePane: Pane!
    private(set) var folder: URL?
    fileprivate(set) var focusMode = false
    fileprivate var sidebarWasCollapsed = false
    fileprivate weak var focusedPane: Pane?

    fileprivate let split = NSSplitViewController()
    let sidebar = SidebarController()
    private let editorArea = NSViewController()
    fileprivate let paneSplit = PaneContainer()
    fileprivate let mainContainer = NSView()
    fileprivate let statusBar = StatusBar()
    private let welcome = WelcomeView()
    lazy var quickOpen = QuickOpenPanel()
    private var languagePopover: NSPopover?
    private var watcher: FSWatcher?
    private var loading = Set<String>()
    private var autosaveTimer: Timer?
    private var countWork: DispatchWorkItem?
    private var preferenceSignature = Prefs.signature
    private var responderObservation: NSKeyValueObservation?
    private let isPrimary: Bool
    private let toolbarProvider = ToolbarProvider()

    /// Every open tab, pane by pane.
    var tabs: [Tab] { panes.flatMap(\.tabs) }
    var activeTab: Tab? { activePane?.activeTab }
    var formatBar: FormatBar { activePane.formatBar }
    var findBar: FindBar { activePane.findBar }

    /// Every open window's controller (registered by the app delegate).
    static var all: [MainWindowController] {
        (NSApp.delegate as? AppDelegate)?.controllers ?? []
    }

    /// `primary`: the first window, whose frame is remembered between launches.
    init(primary: Bool = true) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 640, height: 400)
        window.titlebarSeparatorStyle = .line
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        if primary {
            window.setFrameAutosaveName("PSMainWindow")
            if !window.setFrameUsingName("PSMainWindow") { window.center() }
        }
        isPrimary = primary
        super.init(window: window)
        window.delegate = self
        buildLayout()
        buildToolbar()
        watcher = FSWatcher { [weak self] paths in self?.filesChanged(paths) }
        updateChrome()

        // Clicking into a pane makes it the active one.
        responderObservation = window.observe(\.firstResponder, options: [.new]) { [weak self] window, _ in
            guard let self, let view = window.firstResponder as? NSView else { return }
            if let pane = self.panes.first(where: { view.isDescendant(of: $0.view) }), pane !== self.activePane {
                self.setActivePane(pane)
            }
        }

        NotificationCenter.default.addObserver(self, selector: #selector(documentStateChanged(_:)), name: .documentStateChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(defaultsChanged), name: UserDefaults.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appBecameActive), name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(focusLost), name: NSApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(focusLost), name: NSWindow.didResignKeyNotification, object: window)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(appearanceChanged), name: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil)
        configureAutosave()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // MARK: Layout

    private func buildLayout() {
        sidebar.tree.delegate = self
        sidebar.onClose = { [weak self] in self?.setSidebarCollapsed(true) }
        sidebar.search.onOpen = { [weak self] match in
            self?.open(match.url) { tab in
                if let tab { self?.select(match.range, in: tab) }
            }
        }
        sidebar.search.openTextViews = { [weak self] in
            Dictionary((self?.tabs ?? []).compactMap { tab -> (String, NSTextView)? in
                guard let url = tab.document.url, let view = tab.editor?.textView else { return nil }
                return (url.resolvingSymlinksInPath().path, view)
            }, uniquingKeysWith: { a, _ in a })
        }

        welcome.onOpenRecent = { [weak self] url in self?.open(url) }
        statusBar.position.target = self
        statusBar.position.action = #selector(goToLine(_:))
        statusBar.language.target = self
        statusBar.language.action = #selector(showLanguagePicker(_:))
        statusBar.encoding.target = self
        statusBar.encoding.action = #selector(showEncodingMenu(_:))
        statusBar.lineEnding.target = self
        statusBar.lineEnding.action = #selector(showLineEndingMenu(_:))
        statusBar.indent.target = self
        statusBar.indent.action = #selector(showIndentMenu(_:))

        mainContainer.setContentHuggingPriority(.defaultLow, for: .vertical)
        mainContainer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let stack = NSStackView(views: [mainContainer, statusBar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .width
        stack.detachesHiddenViews = true

        let area = DropView()
        area.onDrop = { [weak self] urls in urls.forEach { self?.open($0) } }
        stack.translatesAutoresizingMaskIntoConstraints = false
        area.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: area.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: area.trailingAnchor),
            stack.topAnchor.constraint(equalTo: area.safeAreaLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: area.bottomAnchor),
            area.widthAnchor.constraint(greaterThanOrEqualToConstant: 420),
        ])
        editorArea.view = area

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 480
        sidebarItem.canCollapse = true
        // Showing/hiding the sidebar resizes the editor, never the window.
        sidebarItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        let editorItem = NSSplitViewItem(viewController: editorArea)
        editorItem.titlebarSeparatorStyle = .line
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(editorItem)
        split.splitView.autosaveName = "PSSplit"
        contentViewController = split
        window?.setContentSize(NSSize(width: 1180, height: 760))
        if isPrimary, !(window?.setFrameUsingName("PSMainWindow") ?? false) { window?.center() }

        let first = Pane(owner: self)
        panes = [first]
        syncPaneViews()
        setActivePane(first)
        showWelcome()
    }

    private func buildToolbar() {
        let toolbar = NSToolbar(identifier: "PSToolbar")
        toolbar.delegate = toolbarProvider
        toolbar.displayMode = .iconOnly
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
    }

    var isSidebarCollapsed: Bool {
        split.splitViewItems.first?.isCollapsed ?? false
    }

    func setSidebarCollapsed(_ collapsed: Bool, animated: Bool = true) {
        guard let item = split.splitViewItems.first, item.isCollapsed != collapsed else { return }
        if animated {
            item.animator().isCollapsed = collapsed
        } else {
            item.isCollapsed = collapsed
        }
        Session.save(self)
    }

    @objc func hideSidebar(_ sender: Any?) {
        setSidebarCollapsed(true)
    }

    /// Handled here too (not only by the split view controller): with the focus in the
    /// closed sidebar, the split view controller is no longer in the responder chain.
    @objc func toggleSidebar(_ sender: Any?) {
        setSidebarCollapsed(!isSidebarCollapsed)
    }

    fileprivate func fill(_ container: NSView, with view: NSView) {
        guard view.superview !== container || container.subviews.count != 1 else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    private func showWelcome() {
        // Back to a single pane.
        panes = Array(panes.prefix(1))
        syncPaneViews()
        setActivePane(panes[0])
        welcome.setRecents(Recents.items)
        fill(mainContainer, with: welcome)
        statusBar.isHidden = true
    }

    private func showPanes() {
        fill(mainContainer, with: focusMode && focusedPane != nil ? focusedPane!.view : paneSplit)
        statusBar.isHidden = focusMode
    }

    // MARK: Panes

    func setActivePane(_ pane: Pane) {
        guard pane !== activePane else { return }
        activePane?.isActive = false
        activePane = pane
        pane.isActive = true
        updateChrome()
        updateStatus()
    }

    private func makePane(after reference: Pane) -> Pane {
        let pane = Pane(owner: self)
        let index = (panes.firstIndex { $0 === reference } ?? panes.count - 1) + 1
        panes.insert(pane, at: index)
        syncPaneViews()
        return pane
    }

    private func removePane(_ pane: Pane) {
        guard panes.count > 1, let index = panes.firstIndex(where: { $0 === pane }) else { return }
        panes.remove(at: index)
        syncPaneViews()
        if pane === activePane {
            activePane = nil
            setActivePane(panes[min(index, panes.count - 1)])
            if let tab = activePane.activeTab { activate(tab) }
        }
        equalizePanes()
    }

    /// Puts the pane views in the container in model order, with equal widths.
    fileprivate func syncPaneViews() {
        paneSplit.setPanes(panes.filter { !(focusMode && $0 === focusedPane) }.map(\.view))
    }

    private func equalizePanes() {
        paneSplit.equalize()
    }

    func paneTabsChanged(_ pane: Pane) {
        reloadTabBar(pane)
        Session.save(self)
    }

    /// Opens the tab's document again in a new pane to the right (same text, own view).
    func splitRight(_ tab: Tab) {
        guard let source = tab.pane, panes.count < MainWindowController.maxPanes, !focusMode else { return }
        let pane = makePane(after: source)
        _ = addTab(tab.document, in: pane)
    }

    /// Moves a tab to another pane (or to a new one on the right when `target` is nil).
    func move(_ tab: Tab, to target: Pane?) {
        guard let source = tab.pane, let index = source.tabs.firstIndex(where: { $0 === tab }) else { return }
        if target == nil, panes.count >= MainWindowController.maxPanes || focusMode { return }
        let destination = target ?? makePane(after: source)
        source.tabs.remove(at: index)
        source.activeIndex = min(source.activeIndex, source.tabs.count - 1)
        destination.tabs.insert(tab, at: destination.activeIndex + 1)
        tab.pane = destination
        if source.tabs.isEmpty {
            removePane(source)
        } else if let next = source.activeTab {
            show(next)
        }
        activate(tab)
    }

    /// Session restore of an untitled document from its backup: back in a tab, still unsaved.
    @discardableResult
    func restoreUntitled(_ content: LoadedContent, mode: EditorMode, backupID: String, language: Language?, in pane: Pane) -> Tab {
        let document = Document(mode: mode, backupID: backupID)
        document.apply(content)
        if let language { document.setLanguage(language, manual: true) }
        document.markModified()
        return addTab(document, in: pane)
    }

    /// Used by session restore.
    func appendPane() -> Pane {
        makePane(after: panes[panes.count - 1])
    }

    @objc func splitEditor(_ sender: Any?) {
        if let tab = activeTab { splitRight(tab) }
    }

    @objc func focusNextPane(_ sender: Any?) { cyclePane(1) }
    @objc func focusPreviousPane(_ sender: Any?) { cyclePane(-1) }

    private func cyclePane(_ delta: Int) {
        guard panes.count > 1, let index = panes.firstIndex(where: { $0 === activePane }) else { return }
        let pane = panes[(index + delta + panes.count) % panes.count]
        if let tab = pane.activeTab { activate(tab) } else { setActivePane(pane) }
    }

    @objc func closePane(_ sender: Any?) {
        guard let pane = activePane else { return }
        let victims = pane.tabs
        func next(_ remaining: ArraySlice<Tab>) {
            guard let tab = remaining.first else { return }
            closeTab(tab) { proceed in if proceed { next(remaining.dropFirst()) } }
        }
        next(victims[...])
    }

    // MARK: Chrome

    private func updateChrome() {
        window?.title = folder?.lastPathComponent ?? "PS"
        if let url = activeTab?.document.url {
            window?.subtitle = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        } else {
            window?.subtitle = activeTab?.document.displayName ?? ""
        }
        window?.isDocumentEdited = tabs.contains { $0.document.isDirty }
        panes.forEach(reloadTabBar)
    }

    private func reloadTabBar(_ pane: Pane) {
        let names = pane.tabs.map { $0.document.displayName }
        let infos = pane.tabs.map { tab -> TabInfo in
            let document = tab.document
            let duplicate = names.filter { $0 == document.displayName }.count > 1
            let detail = duplicate ? document.url?.deletingLastPathComponent().lastPathComponent : nil
            return TabInfo(title: document.displayName, detail: detail, url: document.url, mode: document.mode, isDirty: document.isDirty)
        }
        pane.tabBar.reload(infos, selected: pane.activeIndex)
    }

    @objc private func documentStateChanged(_ notification: Notification) {
        guard let document = notification.object as? Document, tabs.contains(where: { $0.document === document }) else { return }
        updateChrome()
        if document === activeTab?.document { updateStatus() }
        for pane in panes where pane.activeTab?.document === document { updateBreadcrumb(pane) }
    }

    private func updateStatus() {
        guard let tab = activeTab, let editor = tab.editor else {
            statusBar.clear()
            return
        }
        let document = tab.document
        let view = editor.textView
        statusBar.showCode(document.mode == .code)
        statusBar.notice.isHidden = true
        if document.mode == .board {
            let count = document.board.visible.filter { $0.containerId == nil }.count
            statusBar.counts.stringValue = L("%d elements", count)
            statusBar.kind.stringValue = L("Whiteboard") + " · Excalidraw"
            return
        }
        if document.mode == .code {
            let location = view.selectedRange().location
            let line = document.lineIndex.line(at: location)
            let column = location - document.lineIndex.start(ofLine: line) + 1
            statusBar.position.title = L("Ln %d, Col %d", line + 1, column)
            let carets = (editor as? CodeEditor)?.codeView.cursorCount ?? 1
            let selected = view.selectedRanges.reduce(0) { $0 + $1.rangeValue.length }
            if carets > 1 {
                statusBar.selection.stringValue = L("%d cursors", carets)
            } else {
                statusBar.selection.stringValue = selected > 0 ? L("(%d selected)", selected) : ""
            }
            statusBar.selection.isHidden = carets <= 1 && selected == 0
            statusBar.language.title = document.language.name
            statusBar.encoding.title = TextFileIO.displayName(of: document.format.encoding) + (document.format.hasBOM ? " BOM" : "")
            statusBar.lineEnding.title = document.format.lineEnding.rawValue
            statusBar.indent.title = document.useTabs ? L("Tab Size: %d", Prefs.tabWidth) : L("Spaces: %d", document.indentWidth)
            if document.highlightingDisabled {
                statusBar.notice.stringValue = L("⚠︎ Large file: syntax highlighting off")
                statusBar.notice.isHidden = false
            }
        } else {
            let kind: String
            switch document.richKind {
            case .txt: kind = L("Plain Text") + " · " + TextFileIO.displayName(of: document.format.encoding)
            case .rtfd: kind = "RTFD"
            default: kind = "RTF"
            }
            statusBar.kind.stringValue = kind
            scheduleWordCount(document)
        }
    }

    private func scheduleWordCount(_ document: Document) {
        countWork?.cancel()
        let snapshot = document.textStorage.string
        let work = DispatchWorkItem { [weak self] in
            var words = 0
            snapshot.enumerateSubstrings(in: snapshot.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in words += 1 }
            let characters = snapshot.count
            DispatchQueue.main.async {
                guard self?.activeTab?.document === document else { return }
                self?.statusBar.counts.stringValue = L("%d words, %d characters", words, characters)
            }
        }
        countWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func updateBreadcrumb(_ pane: Pane) {
        guard let tab = pane.activeTab, let editor = tab.editor else { return }
        pane.breadcrumb.update(document: tab.document, root: folder, caret: editor.textView.selectedRange().location)
    }

    // MARK: Tabs

    private func editor(for tab: Tab) -> DocumentEditor {
        if let editor = tab.editor { return editor }
        let editor: DocumentEditor
        switch tab.document.mode {
        case .code: editor = CodeEditor(document: tab.document)
        case .rich: editor = RichEditor(document: tab.document)
        case .board: editor = BoardEditor(document: tab.document)
        }
        editor.onSelectionChange = { [weak self, weak tab] in
            guard let self, let tab, let pane = tab.pane, pane.activeTab === tab else { return }
            self.updateBreadcrumb(pane)
            guard pane === self.activePane else { return }
            self.updateStatus()
            if let rich = tab.editor as? RichEditor, !pane.formatBar.isHidden, pane.formatBar.target === rich.richView { pane.formatBar.refresh() }
        }
        editor.onTextChange = { [weak self, weak tab] in
            guard let self, let tab, let pane = tab.pane, pane.activeTab === tab else { return }
            pane.findBar.textDidChange()
            if tab.document.mode == .rich, pane === self.activePane { self.scheduleWordCount(tab.document) }
        }
        if let rich = editor as? RichEditor { rich.richView.focusMode = focusMode }
        tab.editor = editor
        return editor
    }

    /// Global index (pane by pane), kept for callers that iterate `tabs`.
    func activate(_ index: Int) {
        let all = tabs
        if all.indices.contains(index) { activate(all[index]) }
    }

    func activate(_ tab: Tab) {
        guard let pane = tab.pane, let index = pane.tabs.firstIndex(where: { $0 === tab }) else { return }
        // A tab in a pane hidden by focus mode: leave focus mode so it can be seen.
        if focusMode, let focused = focusedPane, pane !== focused { toggleFocusMode(nil) }
        if pane.activeTab !== tab, Prefs.autoSave == .focus, let previous = pane.activeTab { autosave(previous) }
        pane.activeIndex = index
        setActivePane(pane)
        show(tab)
        window?.makeFirstResponder(tab.editor?.focusView)
        if let url = tab.document.url { sidebar.tree.select(url) }
        updateChrome()
        updateStatus()
        Session.save(self)
    }

    /// Puts the tab's editor in its pane, with the bars that go with its mode.
    private func show(_ tab: Tab) {
        guard let pane = tab.pane else { return }
        let editor = editor(for: tab)
        showPanes()
        if editor.rootView.superview !== pane.container {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = 0.12
            pane.container.layer?.add(transition, forKey: "swap")
            fill(pane.container, with: editor.rootView)
        }
        applyChrome(to: pane)
        pane.findBar.highlightColor = Prefs.theme(for: NSApp.effectiveAppearance)?.color("findMatch") ?? NSColor.systemYellow.withAlphaComponent(0.4)
        pane.findBar.textView = editor.textView
        updateBreadcrumb(pane)
    }

    /// Which bars a pane shows: depends on the tab's mode and on focus mode.
    fileprivate func applyChrome(to pane: Pane) {
        let rich = pane.activeTab?.editor as? RichEditor
        pane.tabBar.isHidden = focusMode
        pane.breadcrumb.isHidden = focusMode || pane.activeTab == nil
        pane.formatBar.isHidden = focusMode || rich == nil
        pane.formatBar.target = rich?.richView
        if focusMode { pane.findBar.hide() }
    }

    private func addTab(_ document: Document, in target: Pane? = nil) -> Tab {
        let pane = target ?? activePane!
        let tab = Tab(document: document)
        tab.pane = pane
        let position = pane.activeIndex >= 0 ? pane.activeIndex + 1 : pane.tabs.count
        pane.tabs.insert(tab, at: position)
        activate(tab)
        updateWatchedPaths()
        return tab
    }

    func closeTab(_ tab: Tab, completion: ((Bool) -> Void)? = nil) {
        // Another tab still shows this document: nothing can be lost, so no prompt.
        let shared = tabs.contains { $0 !== tab && $0.document === tab.document }
        let ask: (@escaping (Bool) -> Void) -> Void = shared ? { $0(true) } : { [weak self] done in self?.confirmClose(tab, completion: done) }
        ask { [weak self] proceed in
            guard let self, proceed, let pane = tab.pane, let current = pane.tabs.firstIndex(where: { $0 === tab }) else {
                completion?(proceed)
                return
            }
            tab.editor?.detach()
            tab.editor?.rootView.removeFromSuperview()
            pane.tabs.remove(at: current)
            tab.pane = nil
            if self.tabs.isEmpty {
                pane.activeIndex = -1
                pane.findBar.hide()
                self.showWelcome()
                self.updateChrome()
            } else if pane.tabs.isEmpty {
                self.removePane(pane)
                if let next = self.activeTab { self.activate(next) }
            } else {
                pane.activeIndex = min(current, pane.tabs.count - 1)
                self.activate(pane.tabs[pane.activeIndex])
            }
            self.updateWatchedPaths()
            Session.save(self)
            completion?(true)
        }
    }

    /// Save / Don't Save / Cancel for a dirty tab.
    private func confirmClose(_ tab: Tab, completion: @escaping (Bool) -> Void) {
        guard tab.document.isDirty, let window else {
            completion(true)
            return
        }
        if tab !== activeTab { activate(tab) }
        let alert = NSAlert()
        alert.messageText = L("Do you want to save the changes to “%@”?", tab.document.displayName)
        alert.informativeText = L("Your changes will be lost if you don't save them.")
        alert.addButton(withTitle: L("Save"))
        alert.addButton(withTitle: L("Cancel"))
        alert.addButton(withTitle: L("Don't Save"))
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn: self?.save(tab, completion: completion)
            case .alertThirdButtonReturn: completion(true)
            default: completion(false)
            }
        }
    }

    /// One tab per document, for the documents that exist in several panes.
    private var uniqueDocumentTabs: [Tab] {
        var seen = Set<ObjectIdentifier>()
        return tabs.filter { seen.insert(ObjectIdentifier($0.document)).inserted }
    }

    /// Asks about every dirty document in turn. Used by quit and window close. On quit
    /// untitled documents are skipped: they are kept as backups and come back next launch.
    func confirmCloseAll(includeUntitled: Bool = true, _ completion: @escaping (Bool) -> Void) {
        let dirty = uniqueDocumentTabs.filter { $0.document.isDirty && (includeUntitled || $0.document.url != nil) }
        func next(_ remaining: ArraySlice<Tab>) {
            guard let tab = remaining.first else {
                completion(true)
                return
            }
            confirmClose(tab) { proceed in
                proceed ? next(remaining.dropFirst()) : completion(false)
            }
        }
        next(dirty[...])
    }

    func tabMenu(for tab: Tab) -> NSMenu {
        let menu = NSMenu()
        func item(_ title: String, enabled: Bool = true, _ handler: @escaping () -> Void) {
            let item = ClosureMenuItem(title: title, handler: handler)
            if !enabled {
                item.action = nil
                item.isEnabled = false
            }
            menu.addItem(item)
        }
        item(L("Close")) { [weak self] in self?.closeTab(tab) }
        item(L("Close Others")) { [weak self] in self?.closeTabs(in: tab.pane, except: tab) }
        item(L("Close All")) { [weak self] in self?.closeTabs(in: tab.pane, except: nil) }
        menu.addItem(.separator())
        let roomForPane = panes.count < MainWindowController.maxPanes
        item(L("Split Right"), enabled: roomForPane) { [weak self] in self?.splitRight(tab) }
        item(L("Move to New Pane"), enabled: roomForPane && (tab.pane?.tabs.count ?? 0) > 1) { [weak self] in self?.move(tab, to: nil) }
        for (index, pane) in panes.enumerated() where pane !== tab.pane {
            item(L("Move to Pane %d", index + 1)) { [weak self] in self?.move(tab, to: pane) }
        }
        item(L("Move to New Window"), enabled: tabs.count > 1) { [weak self] in self?.tearOff(tab, at: nil) }
        if let url = tab.document.url {
            menu.addItem(.separator())
            item(L("Reveal in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            item(L("Copy Path")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.path, forType: .string)
            }
        }
        return menu
    }

    private func closeTabs(in pane: Pane?, except keep: Tab?) {
        let victims = (pane?.tabs ?? []).filter { $0 !== keep }
        func next(_ remaining: ArraySlice<Tab>) {
            guard let tab = remaining.first else { return }
            closeTab(tab) { proceed in if proceed { next(remaining.dropFirst()) } }
        }
        next(victims[...])
    }

    // MARK: Opening

    /// Opens a file. With `pane`, the file goes in that pane (a document already open
    /// elsewhere gets a second view there); otherwise an existing tab is brought forward.
    func open(_ url: URL, mode forcedMode: EditorMode? = nil, in pane: Pane? = nil, completion: ((Tab?) -> Void)? = nil) {
        let url = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            presentMessage(L("The file “%@” doesn't exist.", url.lastPathComponent), detail: url.path)
            Recents.remove(url)
            completion?(nil)
            return
        }
        if isDirectory.boolValue && url.pathExtension.lowercased() != "rtfd" {
            openWorkspace(url)
            completion?(nil)
            return
        }
        let key = url.resolvingSymlinksInPath().path
        // Already open in another window: bring that one forward instead of a second copy.
        for other in MainWindowController.all where other !== self {
            if let tab = other.tabs.first(where: { $0.document.url?.resolvingSymlinksInPath().path == key }) {
                other.window?.makeKeyAndOrderFront(nil)
                other.activate(tab)
                completion?(tab)
                return
            }
        }
        let matches = tabs.filter { $0.document.url?.resolvingSymlinksInPath().path == key }
        if let pane, let other = matches.first, !matches.contains(where: { $0.pane === pane }) {
            completion?(addTab(other.document, in: pane))
            return
        }
        if let existing = matches.first(where: { $0.pane === (pane ?? activePane) }) ?? matches.first {
            activate(existing)
            completion?(existing)
            return
        }
        guard !loading.contains(key) else {
            completion?(nil)
            return
        }
        loading.insert(key)
        let mode = forcedMode ?? Session.modeOverride(for: url) ?? EditorMode.forFile(url)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try Document.read(url, mode: mode) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading.remove(key)
                switch result {
                case let .success(content):
                    let document = Document(mode: mode, url: url)
                    if let language = Session.languageOverride(for: url) { document.setLanguage(language, manual: true) }
                    document.apply(content)
                    let tab = self.addTab(document, in: pane.flatMap { target in self.panes.contains { $0 === target } ? target : nil })
                    Recents.add(url)
                    NSDocumentController.shared.noteNewRecentDocumentURL(url)
                    completion?(tab)
                case let .failure(error):
                    self.presentOpenError(error, url: url)
                    completion?(nil)
                }
            }
        }
    }

    private func presentOpenError(_ error: Error, url: URL) {
        switch error as? TextFileError {
        case .binary:
            presentMessage(L("“%@” can't be opened as text.", url.lastPathComponent), detail: L("The file looks like binary data (an image, an archive or a program)."))
        case .undecodable:
            presentMessage(L("“%@” can't be opened as text.", url.lastPathComponent), detail: L("Its encoding couldn't be recognised. Try File ▸ Reopen with Encoding."))
        default:
            presentMessage(L("“%@” couldn't be opened.", url.lastPathComponent), detail: error.localizedDescription)
        }
    }

    func openWorkspace(_ url: URL) {
        folder = url.standardizedFileURL
        sidebar.tree.setRoot(folder)
        sidebar.search.root = folder
        quickOpen.invalidateIndex()
        split.splitViewItems.first?.animator().isCollapsed = false
        Recents.add(url)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        updateWatchedPaths()
        updateChrome()
        Session.save(self)
    }

    func fileTreeCloseFolder() {
        closeFolder(nil)
    }

    /// Stops working on the folder: its files' tabs close (asking about unsaved changes;
    /// Cancel stops everything), tabs from elsewhere stay, the sidebar empties.
    @objc func closeFolder(_ sender: Any?) {
        guard let folder else { return }
        let root = folder.resolvingSymlinksInPath().path + "/"
        let inside = tabs.filter { $0.document.url.map { $0.resolvingSymlinksInPath().path.hasPrefix(root) } ?? false }
        func next(_ remaining: ArraySlice<Tab>) {
            guard let tab = remaining.first else {
                finishClosingFolder()
                return
            }
            guard tab.pane != nil else {
                next(remaining.dropFirst())
                return
            }
            closeTab(tab) { proceed in
                if proceed { next(remaining.dropFirst()) }
            }
        }
        next(inside[...])
    }

    private func finishClosingFolder() {
        folder = nil
        sidebar.tree.setRoot(nil)
        sidebar.search.root = nil
        sidebar.search.reset()
        quickOpen.invalidateIndex()
        updateWatchedPaths()
        updateChrome()
        if tabs.isEmpty { showWelcome() }
        Session.save(self)
    }

    private func select(_ range: NSRange, in tab: Tab) {
        guard let view = tab.editor?.textView, NSMaxRange(range) <= (view.string as NSString).length else { return }
        view.setSelectedRange(range)
        view.scrollRangeToVisible(range)
        view.showFindIndicator(for: range)
        window?.makeFirstResponder(view)
    }

    func revealInSidebar(_ url: URL) {
        split.splitViewItems.first?.animator().isCollapsed = false
        sidebar.showExplorer()
        sidebar.tree.select(url)
    }

    func fileTree(open url: URL) { open(url) }
    func fileTreeOpenDropped(_ urls: [URL]) { urls.forEach { open($0) } }

    func fileTree(didMove from: URL, to: URL) {
        let prefix = from.standardizedFileURL.path
        for tab in tabs {
            guard let url = tab.document.url?.standardizedFileURL, url.path == prefix || url.path.hasPrefix(prefix + "/") else { continue }
            let suffix = String(url.path.dropFirst(prefix.count))
            tab.document.url = URL(fileURLWithPath: to.standardizedFileURL.path + suffix)
            tab.document.acknowledgeDiskVersion()
        }
        updateChrome()
    }

    // MARK: Saving

    func save(_ tab: Tab, as saveAs: Bool = false, completion: ((Bool) -> Void)? = nil) {
        let document = tab.document
        if let url = document.url, !saveAs {
            write(tab, to: url, completion: completion)
            return
        }
        guard let window else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if document.mode == .board {
            panel.allowedContentTypes = [UTType(filenameExtension: "excalidraw") ?? .json]
            panel.nameFieldStringValue = (document.url?.deletingPathExtension().lastPathComponent ?? document.displayName) + ".excalidraw"
        } else if document.mode == .rich {
            let needsRTFD = RichTextIO.hasAttachments(document.textStorage)
            panel.allowedContentTypes = needsRTFD ? [.rtfd] : [.rtf, .rtfd, .plainText]
            panel.nameFieldStringValue = (document.url?.deletingPathExtension().lastPathComponent ?? document.displayName) + (needsRTFD ? ".rtfd" : ".rtf")
        } else {
            panel.allowsOtherFileTypes = true
            panel.nameFieldStringValue = document.url?.lastPathComponent ?? L("untitled")
        }
        if let directory = document.url?.deletingLastPathComponent() ?? folder { panel.directoryURL = directory }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else {
                completion?(false)
                return
            }
            self?.write(tab, to: url, completion: completion)
        }
    }

    /// Applies the rich-text format rules, then writes atomically.
    func write(_ tab: Tab, to url: URL, completion: ((Bool) -> Void)?) {
        let document = tab.document
        guard document.mode == .rich else {
            commit(tab, to: url, kind: nil, completion: completion)
            return
        }
        let hasImages = RichTextIO.hasAttachments(document.textStorage)
        switch RichFileKind(url: url) ?? .rtf {
        case .txt:
            guard TxtSavePolicy.decision(for: document.textStorage, defaults: Prefs.richDefaults) == .askUser else {
                commit(tab, to: url, kind: .txt, completion: completion)
                return
            }
            let target = TxtSavePolicy.convertedURL(for: url, needsRTFD: hasImages)
            ask(
                L("“%@” is a plain text file and can't keep formatting.", url.lastPathComponent),
                detail: L("Convert to %@ creates “%@” next to the original, which stays untouched. Save as Plain Text discards bold, colours, lists and images.", hasImages ? "RTFD" : "RTF", target.lastPathComponent),
                buttons: [L("Convert to %@", hasImages ? "RTFD" : "RTF"), L("Cancel"), L("Save as Plain Text")]
            ) { [weak self] choice in
                switch choice {
                case 0: self?.commit(tab, to: target, kind: hasImages ? .rtfd : .rtf, completion: completion)
                case 2:
                    self?.commit(tab, to: url, kind: .txt) { saved in
                        if saved { self?.stripFormatting(tab) }
                        completion?(saved)
                    }
                default: completion?(false)
                }
            }
        case .rtf where hasImages:
            let target = TxtSavePolicy.convertedURL(for: url, needsRTFD: true)
            ask(
                L("RTF files can't contain images."),
                detail: L("Convert to RTFD creates “%@” next to the original. Saving as RTF drops the images.", target.lastPathComponent),
                buttons: [L("Convert to %@", "RTFD"), L("Cancel"), L("Save without Images")]
            ) { [weak self] choice in
                switch choice {
                case 0: self?.commit(tab, to: target, kind: .rtfd, completion: completion)
                case 2: self?.commit(tab, to: url, kind: .rtf, completion: completion)
                default: completion?(false)
                }
            }
        case let kind:
            commit(tab, to: url, kind: kind, completion: completion)
        }
    }

    private func commit(_ tab: Tab, to url: URL, kind: RichFileKind?, completion: ((Bool) -> Void)?) {
        let document = tab.document
        do {
            try document.write(to: url, kind: kind)
            document.didSave(to: url)
            Recents.add(url)
            if let editor = tab.editor as? CodeEditor { editor.applyPreferences() }
            updateWatchedPaths()
            updateStatus()
            Session.save(self)
            completion?(true)
        } catch TextFileError.unencodable {
            let encoding = TextFileIO.displayName(of: document.format.encoding)
            ask(
                L("The text can't be saved as %@.", encoding),
                detail: L("Some characters don't exist in this encoding. Save it as UTF-8 instead?"),
                buttons: [L("Save as UTF-8"), L("Cancel")]
            ) { [weak self] choice in
                guard choice == 0 else {
                    completion?(false)
                    return
                }
                document.format = TextFormat(encoding: .utf8, lineEnding: document.format.lineEnding, hasBOM: false)
                self?.commit(tab, to: url, kind: kind, completion: completion)
            }
        } catch {
            presentMessage(L("“%@” couldn't be saved.", url.lastPathComponent), detail: error.localizedDescription + "\n" + L("Your document is still open and unchanged."))
            completion?(false)
        }
    }

    private func stripFormatting(_ tab: Tab) {
        let storage = tab.document.textStorage
        storage.setAttributes(Prefs.richDefaults.attributes, range: NSRange(location: 0, length: storage.length))
        (tab.editor as? RichEditor)?.richView.typingAttributes = Prefs.richDefaults.attributes
        tab.document.markSaved()
        tab.pane?.formatBar.refresh()
    }

    private func autosave(_ tab: Tab) {
        let document = tab.document
        guard document.isDirty, let url = document.url else { return }
        if document.mode == .rich {
            let kind = RichFileKind(url: url)
            if kind == .txt, TxtSavePolicy.decision(for: document.textStorage, defaults: Prefs.richDefaults) == .askUser { return }
            if kind == .rtf, RichTextIO.hasAttachments(document.textStorage) { return }
        }
        if (try? document.write(to: url)) != nil { document.didSave(to: url) }
    }

    private func configureAutosave() {
        autosaveTimer?.invalidate()
        autosaveTimer = nil
        guard Prefs.autoSave == .interval else { return }
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(Prefs.autoSaveInterval), repeats: true) { [weak self] _ in
            self?.tabs.forEach { self?.autosave($0) }
        }
    }

    @objc private func focusLost() {
        guard Prefs.autoSave == .focus else { return }
        tabs.forEach(autosave)
    }

    // MARK: External changes

    private func updateWatchedPaths() {
        var paths = Set<String>()
        if let folder { paths.insert(folder.path) }
        for tab in tabs {
            guard let url = tab.document.url else { continue }
            let parent = url.deletingLastPathComponent().path
            if let folder, parent.hasPrefix(folder.path) { continue }
            paths.insert(parent)
        }
        watcher?.watch(paths)
    }

    private func filesChanged(_ paths: [String]) {
        sidebar.tree.filesChanged(paths)
        quickOpen.invalidateIndex()
        checkExternalChanges()
    }

    @objc private func appBecameActive() {
        checkExternalChanges()
    }

    private func checkExternalChanges() {
        for tab in tabs where !tab.prompting {
            let document = tab.document
            guard let url = document.url, document.changedOnDisk else { continue }
            guard FileManager.default.fileExists(atPath: url.path) else {
                // Deleted or moved away: keep the text; saving recreates the file.
                document.acknowledgeDiskVersion()
                continue
            }
            if !document.isDirty {
                reload(tab)
                continue
            }
            tab.prompting = true
            activate(tab)
            ask(
                L("“%@” was changed by another application.", url.lastPathComponent),
                detail: L("You have unsaved changes. Reload the version on disk or keep yours?"),
                buttons: [L("Keep My Changes"), L("Reload")]
            ) { [weak self] choice in
                tab.prompting = false
                if choice == 1 {
                    self?.reload(tab)
                } else {
                    document.acknowledgeDiskVersion()
                }
            }
        }
    }

    func reload(_ tab: Tab, encoding: String.Encoding? = nil) {
        let document = tab.document
        guard let url = document.url else { return }
        let mode = document.mode
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try Document.read(url, mode: mode, encoding: encoding) }
            DispatchQueue.main.async {
                switch result {
                case let .success(content):
                    // Every view of this document (it may be open in several panes).
                    let views = (self?.tabs ?? [tab]).filter { $0.document === document }
                    let selections = views.map { $0.editor?.textView.selectedRange() ?? NSRange(location: 0, length: 0) }
                    document.apply(content)
                    let length = document.textStorage.length
                    for (view, selection) in zip(views, selections) {
                        view.editor?.applyPreferences()
                        view.editor?.textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
                    }
                    if document === self?.activeTab?.document { self?.updateStatus() }
                case let .failure(error):
                    document.acknowledgeDiskVersion()
                    self?.presentOpenError(error, url: url)
                }
            }
        }
    }

    // MARK: Preferences

    @objc private func defaultsChanged() {
        let signature = Prefs.signature
        configureAutosave()
        guard signature != preferenceSignature else { return }
        let hiddenChanged = signature.split(separator: "|").last != preferenceSignature.split(separator: "|").last
        preferenceSignature = signature
        for tab in tabs where tab.document.mode == .code {
            if !tab.document.languageIsManual, IndentDetector.detect(tab.document.textStorage.string) == nil {
                tab.document.useTabs = !Prefs.insertSpaces
                tab.document.indentWidth = Prefs.tabWidth
            }
        }
        tabs.forEach { $0.editor?.applyPreferences() }
        if hiddenChanged {
            sidebar.tree.reloadAll()
            quickOpen.invalidateIndex()
        }
        updateStatus()
    }

    @objc private func appearanceChanged() {
        // The distributed notification arrives before NSApp's appearance updates.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.tabs.forEach { $0.editor?.applyPreferences() }
            if let self { self.findBar.highlightColor = Prefs.theme(for: NSApp.effectiveAppearance)?.color("findMatch") ?? self.findBar.highlightColor }
        }
    }

    // MARK: Window

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Closing the last window quits, which runs the save prompts exactly once.
        if MainWindowController.all.count <= 1 {
            NSApp.terminate(nil)
            return false
        }
        confirmCloseAll { [weak self] proceed in
            if proceed { self?.closeWindow() }
        }
        return false
    }

    /// Closes this window without asking (prompts already done, or nothing to lose).
    func closeWindow() {
        for tab in tabs { tab.editor?.detach() }
        watcher?.stop()
        autosaveTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        responderObservation = nil
        (NSApp.delegate as? AppDelegate)?.remove(self)
        window?.close()
        Session.save(self)
    }

    // MARK: Moving tabs between panes and windows

    /// Takes a tab out of this window, keeping its editor alive so it can move elsewhere.
    func takeOut(_ tab: Tab) {
        guard let pane = tab.pane, let index = pane.tabs.firstIndex(where: { $0 === tab }) else { return }
        tab.editor?.rootView.removeFromSuperview()
        pane.tabs.remove(at: index)
        tab.pane = nil
        if tabs.isEmpty {
            pane.activeIndex = -1
            if MainWindowController.all.count > 1 {
                // An emptied window goes away, like a browser window whose last tab left.
                DispatchQueue.main.async { [weak self] in self?.closeWindow() }
            } else {
                showWelcome()
            }
            updateChrome()
        } else if pane.tabs.isEmpty {
            removePane(pane)
            if let next = activeTab { activate(next) }
        } else {
            pane.activeIndex = min(index, pane.tabs.count - 1)
            if pane === activePane { activate(pane.tabs[pane.activeIndex]) } else { show(pane.tabs[pane.activeIndex]) }
        }
        updateWatchedPaths()
        Session.save(self)
    }

    /// Puts a tab (from this window or another one) into a pane of this window.
    func adopt(_ tab: Tab, into pane: Pane, at index: Int?) {
        if focusMode { toggleFocusMode(nil) }
        tab.pane = pane
        let position = min(max(0, index ?? pane.activeIndex + 1), pane.tabs.count)
        pane.tabs.insert(tab, at: position)
        activate(tab)
        updateWatchedPaths()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Drop of the dragged tab on a pane's tab bar (`index`) or editor area (nil).
    @discardableResult
    func acceptDraggedTab(into pane: Pane, at index: Int?) -> Bool {
        guard let tab = TabDrag.tab, let from = tab.pane else { return false }
        TabDrag.tab = nil
        if from === pane {
            guard let index, let current = pane.tabs.firstIndex(where: { $0 === tab }) else { return true }
            let target = min(index > current ? index - 1 : index, pane.tabs.count - 1)
            pane.tabs.remove(at: current)
            pane.tabs.insert(tab, at: target)
            pane.activeIndex = target
            activate(tab)
            return true
        }
        from.owner.takeOut(tab)
        adopt(tab, into: pane, at: index)
        return true
    }

    /// A tab dragged outside the app (or "Move to New Window"): it gets its own window.
    func tearOff(_ tab: Tab, at screenPoint: NSPoint?) {
        guard let window else { return }
        let topLeft = screenPoint.map { NSPoint(x: $0.x - 80, y: $0.y + 18) }
        if tabs.count == 1 {
            // Nothing would be left behind: just move this window there.
            if let topLeft { window.setFrameTopLeftPoint(topLeft) }
            return
        }
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        let controller = delegate.newWindow(cascadingFrom: self)
        if let topLeft { controller.window?.setFrameTopLeftPoint(topLeft) }
        if let folder { controller.openWorkspace(folder) }
        takeOut(tab)
        controller.adopt(tab, into: controller.panes[0], at: 0)
    }

    // MARK: Helpers

    func presentMessage(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    /// Sheet with buttons; the handler receives the index of the clicked button.
    func ask(_ message: String, detail: String, buttons: [String], handler: @escaping (Int) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        buttons.forEach { alert.addButton(withTitle: $0) }
        guard let window else {
            handler(alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue)
            return
        }
        // If another sheet is up, AppKit queues this one until it closes.
        alert.beginSheetModal(for: window) { response in
            handler(response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue)
        }
    }
}

// MARK: - Commands

extension MainWindowController: NSMenuItemValidation {
    @objc func newCodeFile(_ sender: Any?) {
        _ = addTab(Document(mode: .code))
        activeTab?.editor?.applyPreferences()
    }

    @objc func newRichDocument(_ sender: Any?) {
        _ = addTab(Document(mode: .rich))
    }

    @objc func newWhiteboard(_ sender: Any?) {
        _ = addTab(Document(mode: .board))
    }

    @objc func openDocument(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        if let folder { panel.directoryURL = folder }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            panel.urls.forEach { self?.open($0) }
        }
    }

    @objc func openFolder(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = L("Open")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.openWorkspace(url)
        }
    }

    @objc func saveDocument(_ sender: Any?) {
        if let tab = activeTab { save(tab) }
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        if let tab = activeTab { save(tab, as: true) }
    }

    @objc func saveAllDocuments(_ sender: Any?) {
        let dirty = uniqueDocumentTabs.filter { $0.document.isDirty }
        func next(_ remaining: ArraySlice<Tab>) {
            guard let tab = remaining.first else { return }
            save(tab) { saved in if saved { next(remaining.dropFirst()) } }
        }
        next(dirty[...])
    }

    @objc func revertDocumentToSaved(_ sender: Any?) {
        guard let tab = activeTab, tab.document.url != nil else { return }
        ask(L("Revert to the saved version of “%@”?", tab.document.displayName), detail: L("Your current changes will be lost."), buttons: [L("Revert"), L("Cancel")]) { [weak self] choice in
            if choice == 0 { self?.reload(tab) }
        }
    }

    @objc func closeActiveTab(_ sender: Any?) {
        if let tab = activeTab { closeTab(tab) }
    }

    @objc func reopenWithEncoding(_ sender: NSMenuItem) {
        guard let tab = activeTab, tab.document.url != nil else { return }
        let encoding = String.Encoding(rawValue: UInt(sender.tag))
        let go = { [weak self] in self?.reload(tab, encoding: encoding) }
        if tab.document.isDirty {
            ask(L("Discard unsaved changes and reopen?"), detail: "", buttons: [L("Reopen"), L("Cancel")]) { if $0 == 0 { go() } }
        } else {
            go()
        }
    }

    @objc func saveWithEncoding(_ sender: NSMenuItem) {
        guard let tab = activeTab else { return }
        let document = tab.document
        let previous = document.format
        document.format = TextFormat(encoding: String.Encoding(rawValue: UInt(sender.tag)), lineEnding: previous.lineEnding, hasBOM: false)
        save(tab) { saved in if !saved { document.format = previous } }
    }

    @objc func setLineEnding(_ sender: NSMenuItem) {
        guard let tab = activeTab, let ending = LineEnding(rawValue: sender.representedObject as? String ?? "") else { return }
        tab.document.format.lineEnding = ending
        tab.document.markModified()
        updateStatus()
    }

    @objc func setIndentation(_ sender: NSMenuItem) {
        guard let tab = activeTab else { return }
        tab.document.useTabs = sender.tag == 0
        if sender.tag > 0 { tab.document.indentWidth = sender.tag }
        tab.editor?.applyPreferences()
        updateStatus()
    }

    @objc func openAsPlainText(_ sender: Any?) { switchMode(.code) }
    @objc func openAsFormattedDocument(_ sender: Any?) { switchMode(.rich) }

    private func switchMode(_ mode: EditorMode) {
        guard let tab = activeTab, tab.document.mode != mode else { return }
        let apply = { [weak self] in
            guard let self else { return }
            let views = self.tabs.filter { $0.document === tab.document }
            for view in views {
                view.editor?.detach()
                view.editor?.rootView.removeFromSuperview()
                view.editor = nil
            }
            tab.document.convert(to: mode)
            if let url = tab.document.url { Session.setModeOverride(mode, for: url) }
            for view in views where view.pane?.activeTab === view { self.show(view) }
            self.activate(tab)
        }
        if mode == .code, RichTextIO.hasFormatting(tab.document.textStorage, defaults: Prefs.richDefaults) {
            ask(L("Open as plain text?"), detail: L("The formatting of this document will be discarded."), buttons: [L("Open as Plain Text"), L("Cancel")]) { if $0 == 0 { apply() } }
        } else {
            apply()
        }
    }

    @objc func exportPDF(_ sender: Any?) {
        guard let tab = activeTab, let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (tab.document.url?.deletingPathExtension().lastPathComponent ?? tab.document.displayName) + ".pdf"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let info = NSPrintInfo.shared.copy() as! NSPrintInfo
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
            let operation = NSPrintOperation(view: self.printableView(for: tab, info: info), printInfo: info)
            operation.showsPrintPanel = false
            operation.showsProgressPanel = false
            if !operation.run() {
                self.presentMessage(L("“%@” couldn't be saved.", url.lastPathComponent), detail: "")
            }
        }
    }

    @objc func exportWord(_ sender: Any?) { export(as: .officeOpenXML, type: UTType(filenameExtension: "docx") ?? .data, ext: "docx") }
    @objc func exportHTML(_ sender: Any?) { export(as: .html, type: .html, ext: "html") }

    private func export(as type: NSAttributedString.DocumentType, type uti: UTType, ext: String) {
        guard let tab = activeTab, let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [uti]
        panel.nameFieldStringValue = (tab.document.url?.deletingPathExtension().lastPathComponent ?? tab.document.displayName) + "." + ext
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try RichTextIO.export(NSAttributedString(attributedString: tab.document.textStorage), as: type)
                try SafeWriter.write(data, to: url)
            } catch {
                self?.presentMessage(L("“%@” couldn't be saved.", url.lastPathComponent), detail: error.localizedDescription)
            }
        }
    }

    @objc func printDocument(_ sender: Any?) {
        guard let tab = activeTab, let window else { return }
        let info = NSPrintInfo.shared
        NSPrintOperation(view: printableView(for: tab, info: info), printInfo: info)
            .runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    /// A standalone text view sized to the paper, so printing doesn't depend on the
    /// window's layout (centred column, line numbers, dark mode).
    private func printableView(for tab: Tab, info: NSPrintInfo) -> NSView {
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        view.appearance = NSAppearance(named: .aqua)
        view.textStorage?.setAttributedString(tab.document.textStorage)
        if tab.document.mode == .code {
            let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
            view.textStorage?.addAttributes([.font: font, .foregroundColor: NSColor.black], range: NSRange(location: 0, length: view.textStorage?.length ?? 0))
        }
        view.isVerticallyResizable = true
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        let height = view.layoutManager?.usedRect(for: view.textContainer!).height ?? 100
        view.setFrameSize(NSSize(width: width, height: max(height, 100)))
        return view
    }

    @objc func showFind(_ sender: Any?) { if activeTab != nil { findBar.show(replace: false) } }
    @objc func showFindReplace(_ sender: Any?) { if activeTab != nil { findBar.show(replace: true) } }
    @objc func findNextMatch(_ sender: Any?) { findBar.findNext(forward: true) }
    @objc func findPreviousMatch(_ sender: Any?) { findBar.findNext(forward: false) }
    @objc func useSelectionForFind(_ sender: Any?) { findBar.useSelectionForFind() }

    @objc func showFolderSearch(_ sender: Any?) {
        split.splitViewItems.first?.animator().isCollapsed = false
        sidebar.showSearch()
        if let view = activeTab?.editor?.textView, view.selectedRange().length > 0, view.selectedRange().length < 200 {
            sidebar.search.prefill((view.string as NSString).substring(with: view.selectedRange()))
        }
    }

    @objc func showExplorer(_ sender: Any?) {
        split.splitViewItems.first?.animator().isCollapsed = false
        sidebar.showExplorer()
    }

    @objc func quickOpenFile(_ sender: Any?) {
        guard let window else { return }
        quickOpen.onOpen = { [weak self] url in self?.open(url) }
        let recent = tabs.compactMap { $0.document.url } + Recents.items.filter { !$0.hasDirectoryPath }
        quickOpen.show(over: window, root: folder, recent: recent)
    }

    @objc func goToLine(_ sender: Any?) {
        guard let tab = activeTab, let editor = tab.editor, let window else { return }
        let alert = NSAlert()
        alert.messageText = L("Go to Line")
        alert.informativeText = L("Line number, optionally followed by :column (1–%d).", tab.document.lineIndex.lineCount)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.placeholderString = "42:7"
        alert.accessoryView = field
        alert.addButton(withTitle: L("Go"))
        alert.addButton(withTitle: L("Cancel"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let parts = field.stringValue.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard let line = parts.first else { return }
            let index = tab.document.lineIndex
            let target = min(max(1, line), index.lineCount)
            let start = index.start(ofLine: target - 1)
            let end = target < index.lineCount ? index.start(ofLine: target) - 1 : tab.document.textStorage.length
            let location = min(start + max(0, (parts.count > 1 ? parts[1] : 1) - 1), max(start, end))
            let view = editor.textView
            view.setSelectedRange(NSRange(location: location, length: 0))
            view.scrollRangeToVisible(view.selectedRange())
            view.showFindIndicator(for: (view.string as NSString).lineRange(for: view.selectedRange()))
            window.makeFirstResponder(view)
        }
    }

    @objc func showLanguagePicker(_ sender: Any?) {
        guard let tab = activeTab, tab.document.mode == .code else { return }
        let picker = LanguagePicker(current: tab.document.language.id)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = picker
        popover.contentSize = NSSize(width: 260, height: 320)
        picker.onPick = { [weak self, weak popover] language in
            popover?.close()
            self?.setLanguage(language, for: tab)
        }
        languagePopover = popover
        let anchor: NSView = statusBar.language.isHidden ? activePane.container : statusBar.language
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    func setLanguage(_ language: Language, for tab: Tab) {
        tab.document.setLanguage(language, manual: true)
        if let url = tab.document.url { Session.setLanguageOverride(language, for: url) }
        tab.editor?.applyPreferences()
        updateStatus()
        Session.save(self)
    }

    @objc private func showEncodingMenu(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: L("Reopen with Encoding"), action: nil, keyEquivalent: "").isEnabled = false
        for encoding in TextFileIO.supportedEncodings {
            let item = menu.addItem(withTitle: "   " + TextFileIO.displayName(of: encoding), action: #selector(reopenWithEncoding(_:)), keyEquivalent: "")
            item.tag = Int(encoding.rawValue)
            item.target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Save with Encoding"), action: nil, keyEquivalent: "").isEnabled = false
        for encoding in TextFileIO.supportedEncodings {
            let item = menu.addItem(withTitle: "   " + TextFileIO.displayName(of: encoding), action: #selector(saveWithEncoding(_:)), keyEquivalent: "")
            item.tag = Int(encoding.rawValue)
            item.target = self
            item.state = activeTab?.document.format.encoding == encoding ? .on : .off
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func showLineEndingMenu(_ sender: NSButton) {
        let menu = NSMenu()
        for ending in LineEnding.allCases {
            let item = menu.addItem(withTitle: ending.rawValue, action: #selector(setLineEnding(_:)), keyEquivalent: "")
            item.representedObject = ending.rawValue
            item.target = self
            item.state = activeTab?.document.format.lineEnding == ending ? .on : .off
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func showIndentMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let tabsItem = menu.addItem(withTitle: L("Indent Using Tabs"), action: #selector(setIndentation(_:)), keyEquivalent: "")
        tabsItem.tag = 0
        tabsItem.target = self
        tabsItem.state = activeTab?.document.useTabs == true ? .on : .off
        menu.addItem(.separator())
        for width in [2, 4, 8] {
            let item = menu.addItem(withTitle: L("Indent Using %d Spaces", width), action: #selector(setIndentation(_:)), keyEquivalent: "")
            item.tag = width
            item.target = self
            item.state = activeTab?.document.useTabs == false && activeTab?.document.indentWidth == width ? .on : .off
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc func selectNextTab(_ sender: Any?) { cycleTab(1) }
    @objc func selectPreviousTab(_ sender: Any?) { cycleTab(-1) }

    /// Ctrl+Tab cycles within the active pane.
    private func cycleTab(_ delta: Int) {
        guard let pane = activePane, !pane.tabs.isEmpty else { return }
        activate(pane.tabs[(pane.activeIndex + delta + pane.tabs.count) % pane.tabs.count])
    }

    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        // Cmd+9 is always the last tab of the pane, as in browsers and VS Code.
        guard let pane = activePane, !pane.tabs.isEmpty else { return }
        let index = sender.tag == 9 ? pane.tabs.count - 1 : sender.tag - 1
        if pane.tabs.indices.contains(index) { activate(pane.tabs[index]) }
    }

    @objc func toggleWordWrap(_ sender: Any?) {
        Prefs.defaults.set(!Prefs.wordWrap, forKey: Prefs.Key.wordWrap)
    }

    @objc func toggleLineNumbers(_ sender: Any?) {
        Prefs.defaults.set(!Prefs.lineNumbers, forKey: Prefs.Key.lineNumbers)
    }

    @objc func toggleHiddenFiles(_ sender: Any?) {
        Prefs.defaults.set(!Prefs.showHidden, forKey: Prefs.Key.showHidden)
    }

    private var activeBoard: BoardEditor? { activeTab?.editor as? BoardEditor }

    @objc func zoomIn(_ sender: Any?) { if let board = activeBoard { board.zoomIn() } else { adjustFontSize(1) } }
    @objc func zoomOut(_ sender: Any?) { if let board = activeBoard { board.zoomOut() } else { adjustFontSize(-1) } }
    @objc func zoomReset(_ sender: Any?) {
        if let board = activeBoard {
            board.canvas.setZoom(1)
        } else {
            Prefs.defaults.removeObject(forKey: Prefs.Key.codeFontSize)
        }
    }

    private func adjustFontSize(_ delta: Double) {
        let size = min(40, max(8, Prefs.defaults.double(forKey: Prefs.Key.codeFontSize) + delta))
        Prefs.defaults.set(size, forKey: Prefs.Key.codeFontSize)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let tab = activeTab
        let document = tab?.document
        switch menuItem.action {
        case #selector(saveDocument(_:)), #selector(saveDocumentAs(_:)), #selector(closeActiveTab(_:)):
            return tab != nil
        case #selector(printDocument(_:)), #selector(exportPDF(_:)), #selector(showFind(_:)),
             #selector(showFindReplace(_:)), #selector(findNextMatch(_:)), #selector(findPreviousMatch(_:)),
             #selector(useSelectionForFind(_:)), #selector(goToLine(_:)):
            return tab != nil && document?.mode != .board
        case #selector(saveAllDocuments(_:)):
            return tabs.contains { $0.document.isDirty }
        case #selector(revertDocumentToSaved(_:)):
            return document?.url != nil && document?.isDirty == true
        case #selector(reopenWithEncoding(_:)):
            return document?.url != nil && document?.richKind != .rtf && document?.richKind != .rtfd
        case #selector(saveWithEncoding(_:)), #selector(setLineEnding(_:)), #selector(setIndentation(_:)):
            return document?.mode == .code || document?.richKind == .txt
        case #selector(showLanguagePicker(_:)):
            return document?.mode == .code
        case #selector(openAsPlainText(_:)):
            menuItem.state = document?.mode == .code && document?.richKind == .txt ? .on : .off
            return document?.mode == .rich && (document?.richKind == .txt || document?.url == nil)
        case #selector(openAsFormattedDocument(_:)):
            menuItem.state = document?.mode == .rich && document?.richKind == .txt ? .on : .off
            return document?.mode == .code && (document?.richKind == .txt || document?.url == nil)
        case #selector(exportWord(_:)), #selector(exportHTML(_:)):
            return document?.mode == .rich
        case #selector(selectNextTab(_:)), #selector(selectPreviousTab(_:)):
            return (activePane?.tabs.count ?? 0) > 1
        case #selector(splitEditor(_:)):
            return tab != nil && panes.count < MainWindowController.maxPanes && !focusMode
        case #selector(focusNextPane(_:)), #selector(focusPreviousPane(_:)):
            return panes.count > 1
        case #selector(closeFolder(_:)):
            return folder != nil
        case #selector(closePane(_:)):
            return !(activePane?.tabs.isEmpty ?? true)
        case #selector(toggleFocusMode(_:)):
            menuItem.state = focusMode ? .on : .off
            return true
        case #selector(toggleMarkdownPreview(_:)):
            menuItem.state = (tab?.editor as? CodeEditor)?.isPreviewVisible == true ? .on : .off
            return document?.language.id == "markdown" && document?.mode == .code
        case #selector(copyCodeImage(_:)), #selector(exportCodeImage(_:)):
            return document?.mode == .board ? document?.hasContent == true : document?.mode == .code && (document?.textStorage.length ?? 0) > 0
        case #selector(selectTabByNumber(_:)):
            return !tabs.isEmpty
        case #selector(toggleWordWrap(_:)):
            menuItem.state = Prefs.wordWrap ? .on : .off
            return true
        case #selector(toggleLineNumbers(_:)):
            menuItem.state = Prefs.lineNumbers ? .on : .off
            return true
        case #selector(toggleHiddenFiles(_:)):
            menuItem.state = Prefs.showHidden ? .on : .off
            return true
        default:
            return true
        }
    }
}

/// Accepts files and folders dropped anywhere on the editor area.
final class DropView: NSView {
    var onDrop: (([URL]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        onDrop?(urls)
        return !urls.isEmpty
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func fire() { handler() }
}

// MARK: - Palette, focus mode, preview, code images

extension MainWindowController {
    @objc func showCommandPalette(_ sender: Any?) {
        guard let window, let menu = NSApp.mainMenu else { return }
        quickOpen.showCommands(over: window, items: paletteCommands(in: menu))
    }

    /// Every enabled command of the menu bar, validated against the current focus.
    func paletteCommands(in menu: NSMenu) -> [PaletteItem] {
        var result: [PaletteItem] = []
        func walk(_ menu: NSMenu, path: [String]) {
            menu.update()
            for item in menu.items where !item.isSeparatorItem && !item.isHidden && !item.title.isEmpty {
                if let submenu = item.submenu {
                    if submenu !== NSApp.servicesMenu { walk(submenu, path: path + [item.title]) }
                    continue
                }
                guard let action = item.action, item.isEnabled, action != #selector(showCommandPalette(_:)) else { continue }
                let target = item.target
                result.append(PaletteItem(title: item.title, detail: path.joined(separator: " › "), image: nil, shortcut: Self.shortcut(of: item)) { [weak self] in
                    self?.window?.makeKeyAndOrderFront(nil)
                    NSApp.sendAction(action, to: target, from: item)
                })
            }
        }
        walk(menu, path: [])
        return result
    }

    static func shortcut(of item: NSMenuItem) -> String {
        let key = item.keyEquivalent
        guard !key.isEmpty else { return "" }
        let modifiers = item.keyEquivalentModifierMask
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        let special: [String: String] = [
            "\t": "⇥", "\r": "↩", " ": "Space",
            String(UnicodeScalar(NSUpArrowFunctionKey)!): "↑",
            String(UnicodeScalar(NSDownArrowFunctionKey)!): "↓",
            String(UnicodeScalar(NSLeftArrowFunctionKey)!): "←",
            String(UnicodeScalar(NSRightArrowFunctionKey)!): "→",
        ]
        return text + (special[key] ?? key.uppercased())
    }

    @objc func toggleFocusMode(_ sender: Any?) {
        focusMode.toggle()
        let sidebarItem = split.splitViewItems.first
        if focusMode {
            sidebarWasCollapsed = sidebarItem?.isCollapsed ?? false
            sidebarItem?.isCollapsed = true
        } else {
            sidebarItem?.isCollapsed = sidebarWasCollapsed
        }
        window?.toolbar?.isVisible = !focusMode
        statusBar.isHidden = focusMode || tabs.isEmpty
        // Only the pane being written in stays on screen: it leaves the split view and
        // fills the editor area; on the way back it returns to its place among the others.
        if focusMode, let pane = activePane, !tabs.isEmpty {
            focusedPane = pane
            fill(mainContainer, with: pane.view)
        } else if !focusMode {
            focusedPane = nil
            if !tabs.isEmpty { fill(mainContainer, with: paneSplit) }
            syncPaneViews()
        }
        panes.forEach(applyChrome)
        for tab in tabs { (tab.editor as? RichEditor)?.richView.focusMode = focusMode }
        if let view = activeTab?.editor?.textView { window?.makeFirstResponder(view) }
    }

    @objc func toggleMarkdownPreview(_ sender: Any?) {
        (activeTab?.editor as? CodeEditor)?.togglePreview()
    }

    private func codeImage() -> (data: Data, name: String)? {
        if let tab = activeTab, let board = tab.editor as? BoardEditor {
            return board.canvas.pngData().map { ($0, (tab.document.displayName as NSString).deletingPathExtension) }
        }
        guard let tab = activeTab, let editor = tab.editor as? CodeEditor else { return nil }
        let title = tab.document.displayName
        guard let data = CodeSnapshot.png(view: editor.textView, title: title, theme: Prefs.theme(for: NSApp.effectiveAppearance)) else { return nil }
        return (data, (title as NSString).deletingPathExtension)
    }

    @objc func copyCodeImage(_ sender: Any?) {
        guard let image = codeImage() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(image.data, forType: .png)
        statusBar.notice.stringValue = L("Image copied to the clipboard")
        statusBar.notice.isHidden = false
    }

    @objc func exportCodeImage(_ sender: Any?) {
        guard let image = codeImage(), let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = image.name + ".png"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try SafeWriter.write(image.data, to: url)
            } catch {
                self?.presentMessage(L("“%@” couldn't be saved.", url.lastPathComponent), detail: error.localizedDescription)
            }
        }
    }

    /// For the self-test: the PNG of the current code view.
    func codeImageData() -> Data? {
        codeImage()?.data
    }
}
