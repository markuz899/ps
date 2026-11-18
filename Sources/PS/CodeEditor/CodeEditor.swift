import AppKit
import PSCore

/// What a tab hosts. The rest of the app only uses this interface.
protocol DocumentEditor: AnyObject {
    var document: Document { get }
    var rootView: NSView { get }
    var textView: NSTextView { get }
    var focusView: NSView { get }
    var onSelectionChange: (() -> Void)? { get set }
    var onTextChange: (() -> Void)? { get set }
    func applyPreferences()
    func detach()
}

extension DocumentEditor {
    /// The view that gets the keyboard focus when the tab is shown.
    var focusView: NSView { textView }

    var visibleCharacterRange: NSRange? {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return nil }
        let glyphs = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: container)
        return layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    }
}

/// Builds a TextKit 1 stack. TextKit 1 is chosen on purpose: non-contiguous layout scales
/// to multi-megabyte files and temporary attributes make highlighting cheap.
func makeTextView<T: NSTextView>(_ type: T.Type, storage: NSTextStorage) -> T {
    let layoutManager = NSLayoutManager()
    layoutManager.allowsNonContiguousLayout = true
    storage.addLayoutManager(layoutManager)
    let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
    layoutManager.addTextContainer(container)
    let view = T(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
    view.isVerticallyResizable = true
    view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    view.allowsUndo = true
    return view
}

final class CodeEditor: NSObject, DocumentEditor, NSTextViewDelegate {
    let document: Document
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    let codeView: CodeTextView
    private let ruler: LineNumberRuler
    let highlighter: Highlighter
    var onSelectionChange: (() -> Void)?
    var onTextChange: (() -> Void)?

    /// Plain host view; the split with the Markdown preview is created only when needed
    /// (an always-present split view costs extra layout passes over the whole text).
    private let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    private var previewSplit: NSSplitView?
    private var preview: MarkdownPreview?
    var isPreviewVisible: Bool { preview != nil }
    var previewText: String { preview?.text ?? "" }

    var rootView: NSView { container }
    var textView: NSTextView { codeView }

    init(document: Document) {
        self.document = document
        codeView = makeTextView(CodeTextView.self, storage: document.textStorage)
        codeView.document = document
        highlighter = Highlighter(document: document, layoutManager: codeView.layoutManager!)

        scrollView.documentView = codeView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        ruler = LineNumberRuler(textView: codeView, document: document)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.autoresizingMask = [.width, .height]
        container.addSubview(scrollView)
        super.init()

        let view = codeView
        view.delegate = self
        view.isRichText = false
        view.importsGraphics = false
        view.usesFindBar = false
        view.usesFontPanel = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.isAutomaticTextCompletionEnabled = false
        view.smartInsertDeleteEnabled = false
        view.textContainerInset = NSSize(width: 4, height: 8)
        view.setAccessibilityLabel(L("Code editor"))

        document.editObservers.append { [weak self] range, _ in
            self?.highlighter.edited(range)
            self?.ruler.refresh()
            self?.preview?.scheduleRender()
        }
        applyPreferences()
    }

    func cursorsChanged() {
        onSelectionChange?()
    }

    func togglePreview() {
        if preview != nil {
            previewSplit?.removeFromSuperview()
            previewSplit = nil
            preview = nil
            scrollView.frame = container.bounds
            container.addSubview(scrollView)
            return
        }
        let preview = MarkdownPreview(document: document, source: scrollView)
        self.preview = preview
        let split = NSSplitView(frame: container.bounds)
        split.isVertical = true
        split.dividerStyle = .thin
        split.autoresizingMask = [.width, .height]
        scrollView.removeFromSuperview()
        split.addSubview(scrollView)
        split.addSubview(preview.scrollView)
        container.addSubview(split)
        previewSplit = split
        split.adjustSubviews()
        split.setPosition(container.bounds.width / 2, ofDividerAt: 0)
        preview.render()
    }

    func detach() {
        if let layoutManager = codeView.layoutManager {
            document.textStorage.removeLayoutManager(layoutManager)
        }
    }

    func applyPreferences() {
        let theme = Prefs.theme(for: NSApp.effectiveAppearance)
        let font = Prefs.codeFont
        let foreground = theme?.color("foreground") ?? .textColor
        let background = theme?.color("background") ?? .textBackgroundColor

        let style = NSMutableParagraphStyle()
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        style.tabStops = []
        style.defaultTabInterval = spaceWidth * CGFloat(document.useTabs ? Prefs.tabWidth : document.indentWidth)
        style.lineHeightMultiple = 1.12

        let storage = document.textStorage
        storage.beginEditing()
        storage.addAttributes(
            [.font: font, .foregroundColor: foreground, .paragraphStyle: style],
            range: NSRange(location: 0, length: storage.length)
        )
        storage.endEditing()

        codeView.font = font
        codeView.textColor = foreground
        codeView.defaultParagraphStyle = style
        codeView.typingAttributes = [.font: font, .foregroundColor: foreground, .paragraphStyle: style]
        codeView.backgroundColor = background
        codeView.insertionPointColor = theme?.color("cursor") ?? .textColor
        codeView.selectedTextAttributes = [.backgroundColor: theme?.color("selection") ?? .selectedTextBackgroundColor]
        codeView.currentLineColor = theme?.color("currentLine") ?? .clear
        codeView.bracketColor = theme?.color("bracket") ?? .controlAccentColor
        scrollView.backgroundColor = background

        ruler.apply(theme: theme, font: font)
        scrollView.rulersVisible = Prefs.lineNumbers
        setWrap(Prefs.wordWrap)
        highlighter.configure(theme: theme, visibleRange: visibleCharacterRange)
        if preview != nil, document.language.id != "markdown" { togglePreview() }
        preview?.render()
    }

    private func setWrap(_ wrap: Bool) {
        guard let container = codeView.textContainer else { return }
        let width = scrollView.contentSize.width
        codeView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        if wrap {
            codeView.isHorizontallyResizable = false
            codeView.autoresizingMask = [.width]
            container.widthTracksTextView = true
            codeView.setFrameSize(NSSize(width: width, height: codeView.frame.height))
            scrollView.hasHorizontalScroller = false
        } else {
            container.widthTracksTextView = false
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            codeView.isHorizontallyResizable = true
            codeView.autoresizingMask = [.width]
            scrollView.hasHorizontalScroller = true
        }
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
        codeView.updateBracketMatch()
        ruler.needsDisplay = true
        onSelectionChange?()
    }
}

/// Line numbers in the scroll view's vertical ruler. Only visible lines are drawn and line
/// numbers come from the document's incremental LineIndex, so cost doesn't grow with file size.
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    private unowned let document: Document
    private var font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private var textColor = NSColor.tertiaryLabelColor
    private var activeColor = NSColor.secondaryLabelColor
    private var background = NSColor.textBackgroundColor
    private var digits = 0

    init(textView: NSTextView, document: Document) {
        self.textView = textView
        self.document = document
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40
        setAccessibilityElement(false)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isFlipped: Bool { true }

    func apply(theme: Theme?, font editorFont: NSFont) {
        font = NSFont.monospacedDigitSystemFont(ofSize: max(9, editorFont.pointSize - 2), weight: .regular)
        textColor = theme?.color("gutterText") ?? .tertiaryLabelColor
        activeColor = theme?.color("gutterActive") ?? .labelColor
        background = theme?.color("gutter") ?? .textBackgroundColor
        digits = 0
        refresh()
    }

    func refresh() {
        let needed = max(3, String(document.lineIndex.lineCount).count)
        if needed != digits {
            digits = needed
            let width = ("8" as NSString).size(withAttributes: [.font: font]).width
            ruleThickness = ceil(width * CGFloat(needed) + 22)
        }
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        background.setFill()
        bounds.fill()
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }

        let index = document.lineIndex
        let length = document.textStorage.length
        let glyphs = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: container)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let currentLine = index.line(at: textView.selectedRange().location)
        var line = index.line(at: characters.location)
        let lineHeight = layoutManager.defaultLineHeight(for: font)

        while line < index.lineCount {
            let start = index.start(ofLine: line)
            if start > NSMaxRange(characters) { break }
            let fragment: NSRect
            if start >= length {
                fragment = layoutManager.extraLineFragmentRect
            } else {
                let glyph = layoutManager.glyphIndexForCharacter(at: start)
                fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true)
            }
            if fragment.height > 0 {
                let y = convert(NSPoint(x: 0, y: fragment.minY + textView.textContainerOrigin.y), from: textView).y
                let label = "\(line + 1)" as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: line == currentLine ? activeColor : textColor,
                ]
                let size = label.size(withAttributes: attributes)
                let baselineOffset = (min(fragment.height, lineHeight * 1.4) - size.height) / 2
                label.draw(at: NSPoint(x: ruleThickness - size.width - 10, y: y + max(0, baselineOffset)), withAttributes: attributes)
            }
            line += 1
        }
    }
}

/// Live, read-only rendering of a Markdown document, scrolled in step with the source.
final class MarkdownPreview: NSObject {
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
    private let textView: NSTextView
    private unowned let document: Document
    private weak var source: NSScrollView?
    private var pending: DispatchWorkItem?

    init(document: Document, source: NSScrollView) {
        self.document = document
        self.source = source
        textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        super.init()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.textContainerInset = NSSize(width: 28, height: 24)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.backgroundColor = .textBackgroundColor
        textView.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        textView.setAccessibilityLabel(L("Markdown Preview"))
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        source.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(sourceScrolled), name: NSView.boundsDidChangeNotification, object: source.contentView)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    var text: String { textView.string }

    func scheduleRender() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.render() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func render() {
        let style = MarkdownRenderer.Style(
            font: NSFont.systemFont(ofSize: 14),
            monoFont: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
            textColor: .labelColor,
            secondaryColor: .secondaryLabelColor,
            accentColor: .controlAccentColor,
            codeBackground: NSColor.labelColor.withAlphaComponent(0.07)
        )
        textView.textStorage?.setAttributedString(MarkdownRenderer.render(document.textStorage.string, style: style))
        sourceScrolled()
    }

    /// Keeps the same relative position as the source.
    @objc private func sourceScrolled() {
        guard let source, let sourceDocument = source.documentView, let target = scrollView.documentView else { return }
        let sourceRange = sourceDocument.frame.height - source.contentView.bounds.height
        let fraction = sourceRange > 0 ? source.contentView.bounds.minY / sourceRange : 0
        let targetRange = target.frame.height - scrollView.contentView.bounds.height
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, targetRange * fraction)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}
