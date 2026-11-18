import AppKit
import QuartzCore

/// Empty state: an aurora gradient that drifts slowly (Core Animation, so it costs the
/// app's main thread nothing), the icon, four action cards and the recent items.
final class WelcomeView: NSView {
    struct Action {
        let symbol: String
        let title: String
        let shortcut: String
        let selector: Selector
    }

    private let aurora = CAGradientLayer()
    private let glow = CAGradientLayer()
    private let stack = NSStackView()
    private let recentStack = NSStackView()
    var onOpenRecent: ((URL) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(aurora)
        layer?.addSublayer(glow)
        aurora.type = .axial
        glow.type = .radial
        build()
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isFlipped: Bool { true }

    private func build() {
        let icon = NSImageView(image: AppIcon.image(size: 112))
        icon.wantsLayer = true
        icon.setAccessibilityElement(false)

        let title = NSTextField(labelWithString: "PS")
        let rounded = NSFont.systemFont(ofSize: 44, weight: .heavy).fontDescriptor.withDesign(.rounded)
        title.font = rounded.flatMap { NSFont(descriptor: $0, size: 44) } ?? .systemFont(ofSize: 44, weight: .heavy)
        let subtitle = NSTextField(labelWithString: L("Prose & Source — one fast editor for code and documents."))
        subtitle.font = .systemFont(ofSize: 14)
        subtitle.textColor = .secondaryLabelColor

        let actions = [
            Action(symbol: "chevron.left.forwardslash.chevron.right", title: L("New File"), shortcut: "⌘N", selector: #selector(MainWindowController.newCodeFile(_:))),
            Action(symbol: "doc.richtext", title: L("New Text Document"), shortcut: "⇧⌘N", selector: #selector(MainWindowController.newRichDocument(_:))),
            Action(symbol: "doc", title: L("Open File…"), shortcut: "⌘O", selector: #selector(MainWindowController.openDocument(_:))),
            Action(symbol: "folder", title: L("Open Folder…"), shortcut: "⇧⌘O", selector: #selector(MainWindowController.openFolder(_:))),
        ]
        let cards = NSStackView(views: actions.map(WelcomeCard.init))
        cards.spacing = 14
        cards.distribution = .fillEqually

        recentStack.orientation = .vertical
        recentStack.alignment = .leading
        recentStack.spacing = 2

        let hint = NSTextField(labelWithString: L("⌘P Quick Open   ·   ⇧⌘F Search in Folder   ·   ⌘, Settings"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor

        stack.setViews([icon, title, subtitle, cards, recentStack, hint], in: .top)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(4, after: icon)
        stack.setCustomSpacing(30, after: subtitle)
        stack.setCustomSpacing(28, after: cards)
        stack.setCustomSpacing(24, after: recentStack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -10),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            cards.widthAnchor.constraint(lessThanOrEqualToConstant: 640),
        ])

        // A gentle float on the icon.
        let float = CABasicAnimation(keyPath: "transform.translation.y")
        float.fromValue = -3
        float.toValue = 3
        float.duration = 3.2
        float.autoreverses = true
        float.repeatCount = .infinity
        float.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        icon.layer?.add(float, forKey: "float")
    }

    func setRecents(_ urls: [URL]) {
        recentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !urls.isEmpty else { return }
        let header = NSTextField(labelWithString: L("Recent").uppercased())
        header.font = .systemFont(ofSize: 10.5, weight: .semibold)
        header.textColor = .tertiaryLabelColor
        recentStack.addArrangedSubview(header)
        for url in urls.prefix(6) {
            let button = RecentButton(url: url) { [weak self] in self?.onOpenRecent?(url) }
            recentStack.addArrangedSubview(button)
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        aurora.frame = bounds.insetBy(dx: -bounds.width * 0.25, dy: -bounds.height * 0.25)
        glow.frame = bounds
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateColors()
        if window == nil {
            aurora.removeAllAnimations()
        } else {
            animate()
        }
    }

    private func updateColors() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let alpha: CGFloat = dark ? 0.32 : 0.18
        aurora.colors = [
            NSColor(srgbRed: 0.33, green: 0.27, blue: 0.95, alpha: alpha).cgColor,
            NSColor(srgbRed: 0.78, green: 0.25, blue: 0.8, alpha: alpha * 0.8).cgColor,
            NSColor(srgbRed: 1.0, green: 0.55, blue: 0.35, alpha: alpha * 0.6).cgColor,
            NSColor(srgbRed: 0.2, green: 0.75, blue: 0.85, alpha: alpha * 0.7).cgColor,
        ]
        let base = dark ? NSColor(white: 0.08, alpha: 1) : NSColor(white: 0.98, alpha: 1)
        layer?.backgroundColor = base.cgColor
        glow.colors = [base.withAlphaComponent(0).cgColor, base.withAlphaComponent(dark ? 0.75 : 0.6).cgColor]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1.1, y: 1.1)
    }

    private func animate() {
        guard aurora.animation(forKey: "drift") == nil else { return }
        aurora.startPoint = CGPoint(x: 0, y: 0)
        aurora.endPoint = CGPoint(x: 1, y: 1)
        let start = CABasicAnimation(keyPath: "startPoint")
        start.fromValue = CGPoint(x: 0, y: 0)
        start.toValue = CGPoint(x: 1, y: 0.2)
        let end = CABasicAnimation(keyPath: "endPoint")
        end.fromValue = CGPoint(x: 1, y: 1)
        end.toValue = CGPoint(x: 0.1, y: 0.9)
        let group = CAAnimationGroup()
        group.animations = [start, end]
        group.duration = 14
        group.autoreverses = true
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        aurora.add(group, forKey: "drift")
    }

    // Dropping files or folders on the empty state opens them.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        urls.forEach { onOpenRecent?($0) }
        return !urls.isEmpty
    }
}

/// A card that lifts and glows on hover; sends its action down the responder chain.
private final class WelcomeCard: NSView {
    private let action: WelcomeView.Action
    private var hovering = false { didSet { updateHover() } }

    init(_ action: WelcomeView.Action) {
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        let icon = NSImageView(image: NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 20, weight: .regular)) ?? NSImage())
        icon.contentTintColor = .controlAccentColor
        let title = NSTextField(wrappingLabelWithString: action.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.alignment = .center
        title.maximumNumberOfLines = 2
        title.preferredMaxLayoutWidth = 128
        let shortcut = NSTextField(labelWithString: action.shortcut)
        shortcut.font = .systemFont(ofSize: 11)
        shortcut.textColor = .tertiaryLabelColor
        let stack = NSStackView(views: [icon, title, shortcut])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 148),
            heightAnchor.constraint(equalToConstant: 104),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(action.title)
        updateHover()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidChangeEffectiveAppearance() {
        updateHover()
    }

    private func updateHover() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.allowsImplicitAnimation = true
            layer?.backgroundColor = (dark ? NSColor.white.withAlphaComponent(hovering ? 0.1 : 0.05) : NSColor.white.withAlphaComponent(hovering ? 0.95 : 0.7)).cgColor
            layer?.borderColor = (hovering ? NSColor.controlAccentColor.withAlphaComponent(0.6) : NSColor.separatorColor).cgColor
            layer?.shadowColor = NSColor.controlAccentColor.cgColor
            layer?.shadowOpacity = hovering ? 0.35 : 0
            layer?.shadowRadius = 14
            layer?.shadowOffset = .zero
        }
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { fire() }
    }

    override func accessibilityPerformPress() -> Bool {
        fire()
        return true
    }

    private func fire() {
        NSApp.sendAction(action.selector, to: nil, from: self)
    }
}

private final class RecentButton: NSButton {
    private let handler: () -> Void

    init(url: URL, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        isBordered = false
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        image = FileIcon.image(for: url, isDirectory: isDirectory.boolValue && url.pathExtension != "rtfd", size: 11)
        imagePosition = .imageLeading
        let path = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        let title = NSMutableAttributedString(string: " " + url.lastPathComponent, attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .medium), .foregroundColor: NSColor.controlAccentColor])
        title.append(NSAttributedString(string: "   " + path, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor]))
        attributedTitle = title
        target = self
        action = #selector(pressed)
        toolTip = url.path
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    @objc private func pressed() { handler() }
}
