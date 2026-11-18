import AppKit
import PSCore

final class RichEditor: NSObject, DocumentEditor, NSTextViewDelegate {
    let document: Document
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    let richView: RichTextView
    var onSelectionChange: (() -> Void)?
    var onTextChange: (() -> Void)?

    var rootView: NSView { scrollView }
    var textView: NSTextView { richView }

    init(document: Document) {
        self.document = document
        richView = makeTextView(RichTextView.self, storage: document.textStorage)
        super.init()

        scrollView.documentView = richView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let view = richView
        view.delegate = self
        view.isRichText = true
        view.importsGraphics = true
        view.allowsImageEditing = true
        view.usesFindBar = false
        view.usesFontPanel = true
        view.usesRuler = true
        view.isRulerVisible = false
        view.drawsBackground = true
        view.isContinuousSpellCheckingEnabled = true
        view.usesAdaptiveColorMappingForDarkAppearance = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainerInset = NSSize(width: 56, height: 56)
        view.typingAttributes = Prefs.richDefaults.attributes
        view.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        view.setAccessibilityLabel(L("Document editor"))
        view.onFormattingChange = { [weak self] in self?.onSelectionChange?() }
        if document.textStorage.length > 0 {
            var attributes = document.textStorage.attributes(at: 0, effectiveRange: nil)
            attributes.removeValue(forKey: .attachment)
            attributes.removeValue(forKey: .link)
            view.typingAttributes = attributes
        }
    }

    func detach() {
        if let layoutManager = richView.layoutManager {
            document.textStorage.removeLayoutManager(layoutManager)
        }
    }

    func applyPreferences() {
        richView.needsDisplay = true
    }

    // MARK: NSTextViewDelegate

    func undoManager(for view: NSTextView) -> UndoManager? {
        document.undoManager
    }

    func textDidChange(_ notification: Notification) {
        document.userDidEdit()
        onTextChange?()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        onSelectionChange?()
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        // Links open with Cmd+click; a plain click places the caret, like in Word.
        guard NSEvent.modifierFlags.contains(.command) else { return true }
        if let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) {
            NSWorkspace.shared.open(url)
        }
        return true
    }
}

/// The formatting bar. One instance, re-pointed at the active rich text view; every
/// control mirrors the attributes under the caret via `refresh()`.
final class FormatBar: NSView {
    weak var target: RichTextView? {
        didSet { refresh() }
    }

    private let styleMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fontMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sizeBox = NSComboBox()
    private let traits = NSSegmentedControl()
    private let textColor = NSColorWell()
    private let highlightColor = NSColorWell()
    private let alignment = NSSegmentedControl()
    private let lists = NSSegmentedControl()
    private let indents = NSSegmentedControl()
    private let spacing = NSPopUpButton(frame: .zero, pullsDown: false)
    private let link = NSButton()
    private let clear = NSButton()
    private var fontsLoaded = false
    private static let spacings: [CGFloat] = [1.0, 1.15, 1.5, 2.0]

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private func symbol(_ name: String, _ label: String) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: label) ?? NSImage()
        image.isTemplate = true
        return image
    }

    private func build() {
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel(L("Formatting"))

        for kind in ParagraphKind.allCases { styleMenu.addItem(withTitle: kind.title) }
        styleMenu.target = self
        styleMenu.action = #selector(styleChanged)
        styleMenu.setAccessibilityLabel(L("Paragraph style"))
        styleMenu.toolTip = L("Paragraph style")

        fontMenu.target = self
        fontMenu.action = #selector(fontChanged)
        fontMenu.setAccessibilityLabel(L("Font"))
        fontMenu.toolTip = L("Font")
        fontMenu.addItem(withTitle: Prefs.richDefaults.font.familyName ?? "Helvetica Neue")
        fontMenu.menu?.delegate = self

        sizeBox.addItems(withObjectValues: [9, 10, 11, 12, 13, 14, 16, 18, 20, 24, 28, 32, 36, 48, 64, 72].map(String.init))
        sizeBox.numberOfVisibleItems = 12
        sizeBox.target = self
        sizeBox.action = #selector(sizeChanged)
        sizeBox.setAccessibilityLabel(L("Font size"))
        sizeBox.toolTip = L("Font size")

        configure(traits, symbols: [("bold", L("Bold")), ("italic", L("Italic")), ("underline", L("Underline")), ("strikethrough", L("Strikethrough"))], mode: .selectAny, action: #selector(traitsChanged))
        configure(alignment, symbols: [("text.alignleft", L("Align Left")), ("text.aligncenter", L("Center")), ("text.alignright", L("Align Right")), ("text.justify", L("Justify"))], mode: .selectOne, action: #selector(alignmentChanged))
        configure(lists, symbols: [("list.bullet", L("Bulleted List")), ("list.number", L("Numbered List"))], mode: .selectAny, action: #selector(listChanged))
        configure(indents, symbols: [("decrease.indent", L("Decrease Indent")), ("increase.indent", L("Increase Indent"))], mode: .momentary, action: #selector(indentChanged))

        for (well, label, action) in [(textColor, L("Text Color"), #selector(textColorChanged)), (highlightColor, L("Highlight Color"), #selector(highlightChanged))] {
            well.colorWellStyle = .minimal
            well.target = self
            well.action = action
            well.toolTip = label
            well.setAccessibilityLabel(label)
        }
        highlightColor.color = .systemYellow

        for multiple in FormatBar.spacings { spacing.addItem(withTitle: String(format: "%.2g×", multiple)) }
        spacing.target = self
        spacing.action = #selector(spacingChanged)
        spacing.toolTip = L("Line Spacing")
        spacing.setAccessibilityLabel(L("Line Spacing"))

        for (button, name, label, action) in [(link, "link", L("Insert Link"), #selector(linkPressed)), (clear, "eraser", L("Clear Formatting"), #selector(clearPressed))] {
            button.bezelStyle = .texturedRounded
            button.image = symbol(name, label)
            button.toolTip = label
            button.setAccessibilityLabel(label)
            button.target = self
            button.action = action
        }

        let stack = NSStackView(views: [styleMenu, fontMenu, sizeBox, separator(), traits, textColor, highlightColor, separator(), alignment, lists, indents, spacing, separator(), link, clear])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        stack.setClippingResistancePriority(.defaultLow, for: .horizontal)
        for view in stack.arrangedSubviews { view.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal) }
        styleMenu.widthAnchor.constraint(equalToConstant: 108).isActive = true
        fontMenu.widthAnchor.constraint(equalToConstant: 150).isActive = true
        sizeBox.widthAnchor.constraint(equalToConstant: 58).isActive = true
        for control in [styleMenu, fontMenu, spacing] { control.controlSize = .small; control.font = .systemFont(ofSize: 11) }
        sizeBox.controlSize = .small
        sizeBox.font = .systemFont(ofSize: 11)

        let effect = NSVisualEffectView()
        effect.material = .titlebar
        effect.blendingMode = .withinWindow
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)

        // In a narrow pane the controls scroll sideways instead of widening the window.
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .allowed
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let content = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        scroll.documentView = content
        addSubview(scroll)
        let border = NSBox()
        border.boxType = .separator
        border.translatesAutoresizingMaskIntoConstraints = false
        addSubview(border)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 38),
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            content.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func configure(_ control: NSSegmentedControl, symbols: [(String, String)], mode: NSSegmentedControl.SwitchTracking, action: Selector) {
        control.segmentCount = symbols.count
        control.trackingMode = mode
        control.segmentStyle = .texturedRounded
        control.controlSize = .small
        control.target = self
        control.action = action
        for (index, (name, label)) in symbols.enumerated() {
            control.setImage(symbol(name, label), forSegment: index)
            control.setToolTip(label, forSegment: index)
            control.setWidth(26, forSegment: index)
        }
        control.setAccessibilityLabel(symbols.map(\.1).joined(separator: ", "))
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 1).isActive = true
        box.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return box
    }

    /// The font list is built the first time the menu opens: listing every family at
    /// launch would cost startup time for a menu most sessions never open.
    private func loadFonts() {
        guard !fontsLoaded else { return }
        fontsLoaded = true
        let selected = fontMenu.titleOfSelectedItem
        fontMenu.removeAllItems()
        fontMenu.addItems(withTitles: NSFontManager.shared.availableFontFamilies)
        if let selected { fontMenu.selectItem(withTitle: selected) }
    }

    func refresh() {
        guard let view = target else { return }
        let font = view.currentFont
        let attributes = view.currentAttributes
        let style = view.currentParagraphStyle
        let fontTraits = NSFontManager.shared.traits(of: font)

        styleMenu.selectItem(at: view.paragraphKind.rawValue)
        let family = font.familyName ?? ""
        if fontMenu.item(withTitle: family) == nil { fontMenu.addItem(withTitle: family) }
        fontMenu.selectItem(withTitle: family)
        sizeBox.stringValue = String(format: "%g", font.pointSize)

        traits.setSelected(fontTraits.contains(.boldFontMask), forSegment: 0)
        traits.setSelected(fontTraits.contains(.italicFontMask), forSegment: 1)
        traits.setSelected(((attributes[.underlineStyle] as? Int) ?? 0) != 0, forSegment: 2)
        traits.setSelected(((attributes[.strikethroughStyle] as? Int) ?? 0) != 0, forSegment: 3)
        textColor.color = (attributes[.foregroundColor] as? NSColor) ?? .black
        if let background = attributes[.backgroundColor] as? NSColor { highlightColor.color = background }

        let alignments: [NSTextAlignment] = [.left, .center, .right, .justified]
        alignment.selectedSegment = alignments.firstIndex(of: style.alignment == .natural ? .left : style.alignment) ?? 0
        let format = style.textLists.last?.markerFormat
        lists.setSelected(format == .disc || format == .circle || format == .square, forSegment: 0)
        lists.setSelected(format == .decimal || format == .lowercaseAlpha, forSegment: 1)
        let multiple = style.lineHeightMultiple == 0 ? 1 : style.lineHeightMultiple
        spacing.selectItem(at: FormatBar.spacings.enumerated().min { abs($0.element - multiple) < abs($1.element - multiple) }?.offset ?? 0)
    }

    // MARK: Actions

    private func run(_ body: (RichTextView) -> Void) {
        guard let view = target else { return }
        body(view)
        view.window?.makeFirstResponder(view)
        refresh()
    }

    @objc private func styleChanged() { run { $0.applyParagraphKind(ParagraphKind(rawValue: styleMenu.indexOfSelectedItem) ?? .normal) } }
    @objc private func fontChanged() { run { view in fontMenu.titleOfSelectedItem.map(view.setFontFamily) } }
    @objc private func sizeChanged() { run { $0.setFontSize(CGFloat(sizeBox.doubleValue)) } }
    @objc private func textColorChanged() { run { $0.setColor(textColor.color, for: .foregroundColor) } }
    @objc private func highlightChanged() { run { $0.setColor(highlightColor.color, for: .backgroundColor) } }
    @objc private func spacingChanged() { run { $0.setLineSpacing(FormatBar.spacings[spacing.indexOfSelectedItem]) } }
    @objc private func linkPressed() { run { $0.insertLink(nil) } }
    @objc private func clearPressed() { run { $0.clearFormatting(nil) } }

    @objc private func traitsChanged() {
        let segment = traits.selectedSegment
        run { view in
            switch segment {
            case 0: view.toggleBold(nil)
            case 1: view.toggleItalic(nil)
            case 2: view.toggleUnderline(nil)
            default: view.toggleStrikethrough(nil)
            }
        }
    }

    @objc private func alignmentChanged() {
        let segment = alignment.selectedSegment
        run { view in
            switch segment {
            case 0: view.alignLeft(nil)
            case 1: view.alignCenter(nil)
            case 2: view.alignRight(nil)
            default: view.alignJustified(nil)
            }
        }
    }

    @objc private func listChanged() {
        let segment = lists.selectedSegment
        run { segment == 0 ? $0.toggleBulletList(nil) : $0.toggleNumberedList(nil) }
    }

    @objc private func indentChanged() {
        let segment = indents.selectedSegment
        run { segment == 0 ? $0.psOutdent(nil) : $0.psIndent(nil) }
    }
}

extension FormatBar: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        loadFonts()
    }
}
