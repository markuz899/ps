import AppKit
import PSCore

protocol TabBarDelegate: AnyObject {
    func tabBar(_ bar: TabBar, select index: Int)
    func tabBar(_ bar: TabBar, close index: Int)
    func tabBar(_ bar: TabBar, move from: Int, to: Int)
    func tabBar(_ bar: TabBar, menuFor index: Int) -> NSMenu
    /// A tab dragged out of its bar: the delegate remembers which one.
    func tabBar(_ bar: TabBar, beginDraggingTabAt index: Int)
    /// A dragged tab dropped on this bar, before the tab at `index`.
    func tabBar(_ bar: TabBar, acceptDropAt index: Int) -> Bool
    /// The drag ended outside every window of the app.
    func tabBar(_ bar: TabBar, draggedOutsideTo screenPoint: NSPoint)
}

extension NSPasteboard.PasteboardType {
    static let psTab = NSPasteboard.PasteboardType("app.ps.tab")
}

/// Icon and tint per language / mode, shared by tabs, the file tree and Quick Open.
enum FileIcon {
    static func symbol(for url: URL?, mode: EditorMode? = nil, isDirectory: Bool = false) -> (String, NSColor) {
        if isDirectory { return ("folder.fill", NSColor.systemBlue.withAlphaComponent(0.85)) }
        let ext = url?.pathExtension.lowercased() ?? ""
        if mode == .board || ext == "excalidraw" { return ("scribble.variable", .systemPink) }
        if mode == .rich || ["rtf", "rtfd"].contains(ext) { return ("doc.richtext.fill", .systemIndigo) }
        if ext == "txt" { return ("doc.text.fill", .systemGray) }
        let language = LanguageRegistry.detect(fileName: url?.lastPathComponent ?? "", firstLine: nil).id
        switch language {
        case "swift": return ("swift", .systemOrange)
        case "python": return ("chevron.left.forwardslash.chevron.right", .systemBlue)
        case "javascript": return ("curlybraces", .systemYellow)
        case "typescript": return ("curlybraces", .systemBlue)
        case "html", "xml": return ("chevron.left.forwardslash.chevron.right", .systemOrange)
        case "css": return ("paintbrush.fill", .systemPurple)
        case "json": return ("curlybraces.square.fill", .systemGreen)
        case "markdown": return ("text.alignleft", .systemTeal)
        case "c", "cpp": return ("c.square.fill", .systemBlue)
        case "java": return ("cup.and.saucer.fill", .systemRed)
        case "go": return ("g.square.fill", .systemCyan)
        case "rust": return ("gearshape.fill", .systemBrown)
        case "php": return ("p.square.fill", .systemIndigo)
        case "ruby": return ("diamond.fill", .systemRed)
        case "shell": return ("terminal.fill", .systemGreen)
        case "sql": return ("cylinder.fill", .systemTeal)
        case "yaml": return ("list.bullet.indent", .systemPink)
        default: return ("doc", .secondaryLabelColor)
        }
    }

    static func image(for url: URL?, mode: EditorMode? = nil, isDirectory: Bool = false, size: CGFloat = 12) -> NSImage? {
        let (name, color) = symbol(for: url, mode: mode, isDirectory: isDirectory)
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    }
}

struct TabInfo {
    let title: String
    let detail: String?
    let url: URL?
    let mode: EditorMode
    let isDirty: Bool
}

/// VS Code-style tab strip: dirty dot that turns into a close button on hover, middle-click
/// close, context menu, and drag-to-reorder where the other tabs slide out of the way.
final class TabBar: NSView, NSDraggingSource {
    weak var delegate: TabBarDelegate?
    private let scrollView = NSScrollView()
    private let content = FlippedView()
    private var items: [TabItemView] = []
    private(set) var selectedIndex = -1
    private var dragging: (item: TabItemView, offset: CGFloat, startIndex: Int)?
    private let dropIndicator = NSView()
    /// Kept alive until the session ends: the drop may remove this bar's pane.
    private static var activeSource: TabBar?
    /// With several panes, only the focused one shows the accent colour.
    var isActivePane = true {
        didSet { items.forEach { $0.refreshAppearance() } }
    }

    static let height: CGFloat = 36

    override init(frame: NSRect) {
        super.init(frame: frame)
        scrollView.documentView = content
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: TabBar.height),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        dropIndicator.wantsLayer = true
        dropIndicator.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        dropIndicator.layer?.cornerRadius = 1.5
        dropIndicator.isHidden = true
        content.addSubview(dropIndicator)
        registerForDraggedTypes([.psTab])
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel(L("Open files"))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.blended(withFraction: 0.04, of: .black)?.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    override var isFlipped: Bool { true }

    func reload(_ tabs: [TabInfo], selected: Int) {
        while items.count > tabs.count { items.removeLast().removeFromSuperview() }
        while items.count < tabs.count {
            let item = TabItemView(bar: self)
            content.addSubview(item)
            items.append(item)
        }
        for (item, info) in zip(items, tabs) { item.configure(info) }
        selectedIndex = selected
        for (index, item) in items.enumerated() { item.isSelected = index == selected }
        layoutItems(animated: false)
        if items.indices.contains(selected) { content.scrollToVisible(items[selected].frame) }
    }

    override func layout() {
        super.layout()
        layoutItems(animated: false)
    }

    private func layoutItems(animated: Bool) {
        var x: CGFloat = 0
        for item in items {
            let frame = NSRect(x: x, y: 0, width: item.preferredWidth, height: TabBar.height - 1)
            x += frame.width
            if item === dragging?.item { continue }
            if animated {
                item.animator().frame = frame
            } else {
                item.frame = frame
            }
        }
        content.frame = NSRect(x: 0, y: 0, width: max(x, scrollView.contentSize.width), height: TabBar.height - 1)
    }

    fileprivate func index(of item: TabItemView) -> Int? {
        items.firstIndex { $0 === item }
    }

    fileprivate func itemClicked(_ item: TabItemView) {
        if let index = index(of: item) { delegate?.tabBar(self, select: index) }
    }

    fileprivate func itemClosed(_ item: TabItemView) {
        if let index = index(of: item) { delegate?.tabBar(self, close: index) }
    }

    fileprivate func menu(for item: TabItemView) -> NSMenu? {
        index(of: item).map { delegate?.tabBar(self, menuFor: $0) ?? NSMenu() }
    }

    // MARK: Drag to reorder

    fileprivate func beginDrag(_ item: TabItemView, at point: NSPoint) {
        guard let index = index(of: item) else { return }
        dragging = (item, point.x - item.frame.minX, index)
        item.layer?.zPosition = 10
        item.isDragging = true
    }

    fileprivate func continueDrag(at point: NSPoint, event: NSEvent) {
        guard let drag = dragging, let current = index(of: drag.item) else { return }
        // Pulled well above or below the bar: becomes a real drag (other panes, other windows).
        let local = convert(event.locationInWindow, from: nil)
        if local.y < -24 || local.y > bounds.height + 24 {
            beginExternalDrag(drag.item, event: event)
            return
        }
        let x = min(max(0, point.x - drag.offset), content.frame.width - drag.item.frame.width)
        drag.item.setFrameOrigin(NSPoint(x: x, y: 0))
        let center = x + drag.item.frame.width / 2
        var target = 0
        var position: CGFloat = 0
        // Final index = how many of the other tabs have their midpoint left of the dragged one.
        for item in items where item !== drag.item {
            if center > position + item.preferredWidth / 2 { target += 1 }
            position += item.preferredWidth
        }
        if target != current {
            let moved = items.remove(at: current)
            items.insert(moved, at: target)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.allowsImplicitAnimation = true
                layoutItems(animated: true)
            }
        }
    }

    fileprivate func endDrag() {
        guard let drag = dragging else { return }
        dragging = nil
        drag.item.isDragging = false
        drag.item.layer?.zPosition = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            layoutItems(animated: true)
        }
        if let index = index(of: drag.item), index != drag.startIndex {
            delegate?.tabBar(self, move: drag.startIndex, to: index)
        }
    }

    // MARK: Drag between panes and windows

    private func beginExternalDrag(_ item: TabItemView, event: NSEvent) {
        guard let drag = dragging else { return }
        // Undo the live reordering: the tab goes back where it was while it travels.
        if let current = index(of: item), current != drag.startIndex {
            items.remove(at: current)
            items.insert(item, at: drag.startIndex)
        }
        dragging = nil
        item.isDragging = false
        item.layer?.zPosition = 0
        layoutItems(animated: false)
        guard let index = index(of: item) else { return }
        delegate?.tabBar(self, beginDraggingTabAt: index)

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString("\(index)", forType: .psTab)
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(item.bounds, contents: item.snapshot())
        TabBar.activeSource = self
        item.beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        defer { TabBar.activeSource = nil }
        guard operation.isEmpty else { return }
        // Dropped on nothing: only "outside the app" counts as tearing the tab off.
        let insideApp = NSApp.windows.contains { $0.isVisible && $0.frame.contains(screenPoint) }
        if !insideApp { delegate?.tabBar(self, draggedOutsideTo: screenPoint) }
    }

    private func dropIndex(for info: NSDraggingInfo) -> Int {
        let x = content.convert(info.draggingLocation, from: nil).x
        return items.filter { $0.frame.midX < x }.count
    }

    private func showIndicator(at index: Int) {
        let x = index < items.count ? items[index].frame.minX : (items.last?.frame.maxX ?? 0)
        dropIndicator.frame = NSRect(x: max(0, x - 1.5), y: 4, width: 3, height: TabBar.height - 9)
        dropIndicator.isHidden = false
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.types?.contains(.psTab) == true else { return [] }
        showIndicator(at: dropIndex(for: sender))
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropIndicator.isHidden = true
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dropIndicator.isHidden = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropIndicator.isHidden = true
        return delegate?.tabBar(self, acceptDropAt: dropIndex(for: sender)) ?? false
    }

    fileprivate func pointInContent(_ event: NSEvent) -> NSPoint {
        content.convert(event.locationInWindow, from: nil)
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class TabItemView: NSView {
    private unowned let bar: TabBar
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private var info: TabInfo?
    private var hovering = false { didSet { updateAppearance() } }
    private var mouseDownPoint: NSPoint?
    var isSelected = false { didSet { updateAppearance() } }
    var isDragging = false { didSet { needsDisplay = true } }

    init(bar: TabBar) {
        self.bar = bar
        super.init(frame: .zero)
        wantsLayer = true
        icon.imageScaling = .scaleProportionallyDown
        title.font = .systemFont(ofSize: 12)
        title.lineBreakMode = .byTruncatingMiddle
        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        closeButton.imagePosition = .imageOnly
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.setAccessibilityLabel(L("Close"))
        for view in [icon, title, closeButton] { addSubview(view) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    var preferredWidth: CGFloat {
        let text = title.attributedStringValue.size().width
        return min(280, max(110, ceil(text) + 74))
    }

    func configure(_ info: TabInfo) {
        self.info = info
        icon.image = FileIcon.image(for: info.url, mode: info.mode)
        let text = NSMutableAttributedString(string: info.title, attributes: [.font: NSFont.systemFont(ofSize: 12)])
        if let detail = info.detail {
            text.append(NSAttributedString(string: "  " + detail, attributes: [
                .font: NSFont.systemFont(ofSize: 10.5),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
        }
        title.attributedStringValue = text
        toolTip = info.url?.path ?? info.title
        setAccessibilityLabel(info.isDirty ? L("%@, modified", info.title) : info.title)
        updateAppearance()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        icon.frame = NSRect(x: 12, y: (height - 14) / 2, width: 14, height: 14)
        closeButton.frame = NSRect(x: bounds.width - 26, y: (height - 18) / 2, width: 18, height: 18)
        title.frame = NSRect(x: 31, y: (height - 16) / 2, width: bounds.width - 31 - 30, height: 16)
    }

    func refreshAppearance() {
        updateAppearance()
    }

    private func updateAppearance() {
        let dirty = info?.isDirty ?? false
        let showClose = hovering || (isSelected && !dirty)
        let name = dirty && !hovering ? "circle.fill" : "xmark"
        let size: CGFloat = dirty && !hovering ? 7 : 9
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .bold)
        closeButton.image = NSImage(systemSymbolName: name, accessibilityDescription: L("Close"))?.withSymbolConfiguration(configuration)
        closeButton.contentTintColor = dirty && !hovering ? .labelColor : .secondaryLabelColor
        closeButton.alphaValue = showClose || dirty ? 1 : 0
        title.textColor = isSelected && bar.isActivePane ? .labelColor : .secondaryLabelColor
        setAccessibilityValue(isSelected ? 1 : 0)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected || isDragging {
            NSColor.textBackgroundColor.setFill()
            bounds.fill()
            (bar.isActivePane ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: bounds.width, height: 2), xRadius: 1, yRadius: 1).fill()
        } else if hovering {
            NSColor.labelColor.withAlphaComponent(0.05).setFill()
            bounds.fill()
        }
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.width - 1, y: 6, width: 1, height: bounds.height - 12).fill()
        if isDragging {
            NSColor.black.withAlphaComponent(0.15).setFill()
            NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        }
    }

    override var isFlipped: Bool { true }

    /// Picture of the tab used while it's dragged.
    func snapshot() -> NSImage {
        let image = NSImage(size: bounds.size)
        if let bitmap = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: bitmap)
            image.addRepresentation(bitmap)
        }
        return image
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = bar.pointInContent(event)
        bar.itemClicked(self)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = bar.pointInContent(event)
        if let start = mouseDownPoint {
            if abs(point.x - start.x) < 4 { return }
            bar.beginDrag(self, at: start)
            mouseDownPoint = nil
        }
        bar.continueDrag(at: point, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownPoint = nil
        bar.endDrag()
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { bar.itemClosed(self) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        bar.menu(for: self)
    }

    @objc private func closePressed() {
        bar.itemClosed(self)
    }

    override func accessibilityPerformPress() -> Bool {
        bar.itemClicked(self)
        return true
    }
}
