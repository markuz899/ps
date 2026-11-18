import AppKit
import PSCore

enum ParagraphKind: Int, CaseIterable {
    case normal, heading1, heading2, heading3, quote

    var title: String {
        switch self {
        case .normal: return L("Normal")
        case .heading1: return L("Title 1")
        case .heading2: return L("Title 2")
        case .heading3: return L("Title 3")
        case .quote: return L("Quote")
        }
    }

    var scale: CGFloat {
        switch self {
        case .heading1: return 2.0
        case .heading2: return 1.6
        case .heading3: return 1.3
        case .normal, .quote: return 1
        }
    }
}

/// The word-processor view: a centred, readable column drawn as a sheet of paper.
/// Formatting commands are plain responder actions (Cmd+B goes here via the menu) and
/// all go through `shouldChangeText`/`didChangeText`, so undo covers formatting too.
final class RichTextView: NSTextView {
    static let columnWidth: CGFloat = 700
    static let quoteColor = NSColor(srgbRed: 0.42, green: 0.45, blue: 0.5, alpha: 1)
    var onFormattingChange: (() -> Void)?

    private var defaults: RichDefaults { Prefs.richDefaults }

    /// Focus mode: only the paragraph being written is at full strength, and the caret
    /// line stays in the middle of the window (typewriter scrolling).
    var focusMode = false {
        didSet {
            guard focusMode != oldValue else { return }
            updateFocus()
            needsDisplay = true
        }
    }

    private func updateFocus() {
        guard let layoutManager, let storage = textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
        guard focusMode, storage.length > 0 else { return }
        let current = (string as NSString).paragraphRange(for: selectedRange())
        let dim = NSColor.gray.withAlphaComponent(0.55)
        if current.location > 0 {
            layoutManager.addTemporaryAttribute(.foregroundColor, value: dim, forCharacterRange: NSRange(location: 0, length: current.location))
        }
        if NSMaxRange(current) < storage.length {
            layoutManager.addTemporaryAttribute(.foregroundColor, value: dim, forCharacterRange: NSRange(location: NSMaxRange(current), length: storage.length - NSMaxRange(current)))
        }
        centerCaret()
    }

    private func centerCaret() {
        guard let layoutManager, let textContainer, let clip = enclosingScrollView?.contentView else { return }
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: min(selectedRange().location, max(0, (string as NSString).length - 1)), length: 0), actualCharacterRange: nil)
        let caret = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer).offsetBy(dx: 0, dy: textContainerOrigin.y)
        let target = max(0, min(caret.midY - clip.bounds.height / 2, frame.height - clip.bounds.height))
        guard abs(target - clip.bounds.minY) > 2 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            clip.animator().setBoundsOrigin(NSPoint(x: 0, y: target))
        }
        enclosingScrollView?.reflectScrolledClipView(clip)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if focusMode, !stillSelecting { updateFocus() }
    }

    override func didChangeText() {
        super.didChangeText()
        if focusMode { updateFocus() }
    }

    // MARK: Layout & paper

    override func setFrameSize(_ newSize: NSSize) {
        let horizontal = max(28, (newSize.width - RichTextView.columnWidth) / 2)
        if abs(textContainerInset.width - horizontal) > 0.5 {
            textContainerInset = NSSize(width: horizontal, height: 56)
        }
        super.setFrameSize(newSize)
    }

    override func drawBackground(in rect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let desk = dark ? NSColor(white: 0.11, alpha: 1) : NSColor(srgbRed: 0.93, green: 0.93, blue: 0.95, alpha: 1)
        let paper = dark ? NSColor(white: 0.16, alpha: 1) : NSColor.white
        desk.setFill()
        rect.fill()

        let margin: CGFloat = min(56, max(0, textContainerInset.width - 12))
        let sheet = NSRect(
            x: textContainerInset.width - margin,
            y: 24,
            width: bounds.width - 2 * (textContainerInset.width - margin),
            height: max(bounds.height - 48, 400)
        )
        guard sheet.intersects(rect) else { return }
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.5 : 0.12)
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.set()
        paper.setFill()
        NSBezierPath(roundedRect: sheet, xRadius: 6, yRadius: 6).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Attribute helpers

    /// Attributes at the selection start (or the typing attributes for an insertion point).
    var currentAttributes: [NSAttributedString.Key: Any] {
        let selection = selectedRange()
        guard let storage = textStorage, selection.length > 0, selection.location < storage.length else {
            return typingAttributes
        }
        return storage.attributes(at: selection.location, effectiveRange: nil)
    }

    var currentFont: NSFont { (currentAttributes[.font] as? NSFont) ?? defaults.font }

    var currentParagraphStyle: NSParagraphStyle {
        if let storage = textStorage, storage.length > 0 {
            let location = min(selectedRange().location, storage.length - 1)
            if let style = storage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle {
                return style
            }
        }
        return (typingAttributes[.paragraphStyle] as? NSParagraphStyle) ?? defaults.paragraphStyle
    }

    /// Rewrites the character attributes of every run in the selection, as one undo step.
    func changeCharacterAttributes(_ transform: ([NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any]) {
        let selection = selectedRange()
        if selection.length == 0 {
            typingAttributes = transform(typingAttributes)
            onFormattingChange?()
            return
        }
        guard let storage = textStorage,
              let ranges = rangesForUserCharacterAttributeChange?.map(\.rangeValue),
              shouldChangeText(inRanges: ranges as [NSValue], replacementStrings: nil) else { return }
        storage.beginEditing()
        for range in ranges {
            storage.enumerateAttributes(in: range) { attributes, run, _ in
                storage.setAttributes(transform(attributes), range: run)
            }
        }
        storage.endEditing()
        didChangeText()
        onFormattingChange?()
    }

    /// Rewrites the paragraph style of every selected paragraph.
    func changeParagraphStyle(_ transform: (NSMutableParagraphStyle) -> Void) {
        guard let storage = textStorage,
              let ranges = rangesForUserParagraphAttributeChange?.map(\.rangeValue),
              shouldChangeText(inRanges: ranges as [NSValue], replacementStrings: nil) else { return }
        storage.beginEditing()
        for range in ranges where range.length > 0 {
            storage.enumerateAttribute(.paragraphStyle, in: range) { value, run, _ in
                let style = ((value as? NSParagraphStyle) ?? defaults.paragraphStyle).mutableCopy() as! NSMutableParagraphStyle
                transform(style)
                storage.addAttribute(.paragraphStyle, value: style, range: run)
            }
        }
        storage.endEditing()
        let typing = ((typingAttributes[.paragraphStyle] as? NSParagraphStyle) ?? defaults.paragraphStyle).mutableCopy() as! NSMutableParagraphStyle
        transform(typing)
        typingAttributes[.paragraphStyle] = typing
        didChangeText()
        onFormattingChange?()
    }

    // MARK: Character formatting

    private func toggleTrait(_ trait: NSFontTraitMask) {
        let enable = !NSFontManager.shared.traits(of: currentFont).contains(trait)
        changeCharacterAttributes { attributes in
            var result = attributes
            let font = (attributes[.font] as? NSFont) ?? defaults.font
            result[.font] = enable
                ? NSFontManager.shared.convert(font, toHaveTrait: trait)
                : NSFontManager.shared.convert(font, toNotHaveTrait: trait)
            return result
        }
    }

    private func toggleLine(_ key: NSAttributedString.Key) {
        let enable = ((currentAttributes[key] as? Int) ?? 0) == 0
        changeCharacterAttributes { attributes in
            var result = attributes
            result[key] = enable ? NSUnderlineStyle.single.rawValue : nil
            return result
        }
    }

    @objc func toggleBold(_ sender: Any?) { toggleTrait(.boldFontMask) }
    @objc func toggleItalic(_ sender: Any?) { toggleTrait(.italicFontMask) }
    @objc func toggleUnderline(_ sender: Any?) { toggleLine(.underlineStyle) }
    @objc func toggleStrikethrough(_ sender: Any?) { toggleLine(.strikethroughStyle) }

    func setFontFamily(_ family: String) {
        changeCharacterAttributes { attributes in
            var result = attributes
            result[.font] = NSFontManager.shared.convert((attributes[.font] as? NSFont) ?? defaults.font, toFamily: family)
            return result
        }
    }

    func setFontSize(_ size: CGFloat) {
        guard size >= 4, size <= 400 else { return }
        changeCharacterAttributes { attributes in
            var result = attributes
            result[.font] = NSFontManager.shared.convert((attributes[.font] as? NSFont) ?? defaults.font, toSize: size)
            return result
        }
    }

    func setColor(_ color: NSColor?, for key: NSAttributedString.Key) {
        changeCharacterAttributes { attributes in
            var result = attributes
            result[key] = color
            return result
        }
    }

    @objc func clearFormatting(_ sender: Any?) {
        let base = defaults.attributes
        changeCharacterAttributes { attributes in
            var result = base
            result[.attachment] = attributes[.attachment]
            return result
        }
        changeParagraphStyle { style in style.setParagraphStyle(defaults.paragraphStyle) }
    }

    // MARK: Paragraph formatting

    var paragraphKind: ParagraphKind {
        let font = currentFont
        let base = defaults.font.pointSize
        let bold = NSFontManager.shared.traits(of: font).contains(.boldFontMask)
        for kind in [ParagraphKind.heading1, .heading2, .heading3] where bold && abs(font.pointSize - (base * kind.scale).rounded()) < 0.6 {
            return kind
        }
        let italic = NSFontManager.shared.traits(of: font).contains(.italicFontMask)
        if italic, currentParagraphStyle.headIndent >= 20, currentParagraphStyle.textLists.isEmpty { return .quote }
        return .normal
    }

    func applyParagraphKind(_ kind: ParagraphKind) {
        guard let storage = textStorage,
              let ranges = rangesForUserParagraphAttributeChange?.map(\.rangeValue),
              shouldChangeText(inRanges: ranges as [NSValue], replacementStrings: nil) else { return }
        let base = defaults.font
        let manager = NSFontManager.shared
        var font = manager.convert(base, toSize: (base.pointSize * kind.scale).rounded())
        switch kind {
        case .heading1, .heading2, .heading3: font = manager.convert(font, toHaveTrait: .boldFontMask)
        case .quote: font = manager.convert(font, toHaveTrait: .italicFontMask)
        case .normal: break
        }
        let style = defaults.paragraphStyle.mutableCopy() as! NSMutableParagraphStyle
        switch kind {
        case .heading1, .heading2, .heading3:
            style.paragraphSpacingBefore = base.pointSize * 0.8
            style.paragraphSpacing = base.pointSize * 0.4
            style.lineHeightMultiple = 1.05
        case .quote:
            style.headIndent = 24
            style.firstLineHeadIndent = 24
        case .normal:
            break
        }

        storage.beginEditing()
        for range in ranges {
            storage.addAttribute(.font, value: font, range: range)
            storage.addAttribute(.paragraphStyle, value: style, range: range)
            if kind == .quote {
                storage.addAttribute(.foregroundColor, value: RichTextView.quoteColor, range: range)
            } else {
                storage.enumerateAttribute(.foregroundColor, in: range) { value, run, _ in
                    if (value as? NSColor) == RichTextView.quoteColor { storage.removeAttribute(.foregroundColor, range: run) }
                }
            }
        }
        storage.endEditing()
        typingAttributes[.font] = font
        typingAttributes[.paragraphStyle] = style
        typingAttributes[.foregroundColor] = kind == .quote ? RichTextView.quoteColor : nil
        didChangeText()
        onFormattingChange?()
    }

    @objc func applyParagraphKindFromMenu(_ sender: NSMenuItem) {
        applyParagraphKind(ParagraphKind(rawValue: sender.tag) ?? .normal)
    }

    func setLineSpacing(_ multiple: CGFloat) {
        changeParagraphStyle { $0.lineHeightMultiple = multiple }
    }

    @objc func psIndent(_ sender: Any?) {
        if !currentParagraphStyle.textLists.isEmpty {
            changeListLevel(by: 1)
            return
        }
        changeParagraphStyle { style in
            style.headIndent += 36
            style.firstLineHeadIndent += 36
        }
    }

    @objc func psOutdent(_ sender: Any?) {
        if !currentParagraphStyle.textLists.isEmpty {
            changeListLevel(by: -1)
            return
        }
        changeParagraphStyle { style in
            style.headIndent = max(0, style.headIndent - 36)
            style.firstLineHeadIndent = max(0, style.firstLineHeadIndent - 36)
        }
    }

    // MARK: Lists

    @objc func toggleBulletList(_ sender: Any?) { toggleList(.disc) }
    @objc func toggleNumberedList(_ sender: Any?) { toggleList(.decimal) }

    private static func listStyle(_ lists: [NSTextList], base: NSParagraphStyle) -> NSMutableParagraphStyle {
        let style = base.mutableCopy() as! NSMutableParagraphStyle
        let level = CGFloat(lists.count)
        style.textLists = lists
        style.headIndent = 36 * level
        style.firstLineHeadIndent = 0
        style.tabStops = [
            NSTextTab(textAlignment: .natural, location: 36 * level - 22),
            NSTextTab(textAlignment: .natural, location: 36 * level),
        ]
        return style
    }

    /// Paragraph ranges covered by the selection.
    private func selectedParagraphs() -> [NSRange] {
        let text = string as NSString
        let block = text.paragraphRange(for: selectedRange())
        var result: [NSRange] = []
        text.enumerateSubstrings(in: block, options: [.byParagraphs, .substringNotRequired]) { _, _, enclosing, _ in
            result.append(enclosing)
        }
        if result.isEmpty { result = [block] }
        return result
    }

    /// Length of the "\t•\t" marker at the start of a list paragraph, 0 if none.
    private func markerLength(at location: Int) -> Int {
        let text = string as NSString
        guard location < text.length, text.character(at: location) == 9 else { return 0 }
        let search = NSRange(location: location + 1, length: min(16, text.length - location - 1))
        let tab = text.range(of: "\t", options: .literal, range: search)
        return tab.location == NSNotFound ? 0 : tab.location - location + 1
    }

    private func toggleList(_ format: NSTextList.MarkerFormat) {
        guard let storage = textStorage else { return }
        let paragraphs = selectedParagraphs()
        let alreadyInList = paragraphs.allSatisfy { range in
            let style = storage.length > range.location ? storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle : currentParagraphStyle
            return style?.textLists.last?.markerFormat == format
        }
        let list = NSTextList(markerFormat: format, options: 0)
        let whole = NSRange(location: paragraphs[0].location, length: NSMaxRange(paragraphs[paragraphs.count - 1]) - paragraphs[0].location)
        let rebuilt = NSMutableAttributedString()
        var number = 1
        for range in paragraphs {
            let paragraph = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
            let existing = markerLength(at: range.location)
            let hadList = range.location < storage.length
                && !((storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.textLists.isEmpty ?? true)
            if hadList, existing > 0 { paragraph.deleteCharacters(in: NSRange(location: 0, length: existing)) }
            let attributes = paragraph.length > 0 ? paragraph.attributes(at: 0, effectiveRange: nil) : typingAttributes
            let fullRange = NSRange(location: 0, length: paragraph.length)
            if alreadyInList {
                paragraph.addAttribute(.paragraphStyle, value: defaults.paragraphStyle, range: fullRange)
            } else {
                let style = RichTextView.listStyle([list], base: defaults.paragraphStyle)
                let marker = NSAttributedString(string: "\t\(list.marker(forItemNumber: number))\t", attributes: attributes)
                paragraph.insert(marker, at: 0)
                paragraph.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: paragraph.length))
                number += 1
            }
            rebuilt.append(paragraph)
        }
        guard shouldChangeText(in: whole, replacementString: rebuilt.string) else { return }
        storage.replaceCharacters(in: whole, with: rebuilt)
        if rebuilt.length > 0 {
            typingAttributes[.paragraphStyle] = rebuilt.attribute(.paragraphStyle, at: rebuilt.length - 1, effectiveRange: nil)
        }
        didChangeText()
        let end = whole.location + rebuilt.length - (rebuilt.string.hasSuffix("\n") ? 1 : 0)
        setSelectedRange(NSRange(location: end, length: 0))
        onFormattingChange?()
    }

    private func changeListLevel(by delta: Int) {
        guard let storage = textStorage else { return }
        let paragraphs = selectedParagraphs()
        let whole = NSRange(location: paragraphs[0].location, length: NSMaxRange(paragraphs[paragraphs.count - 1]) - paragraphs[0].location)
        let rebuilt = NSMutableAttributedString()
        for range in paragraphs {
            let paragraph = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
            guard paragraph.length > 0,
                  let style = paragraph.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle,
                  let last = style.textLists.last else {
                rebuilt.append(paragraph)
                continue
            }
            var lists = style.textLists
            if delta > 0 {
                lists.append(NSTextList(markerFormat: last.markerFormat == .disc ? .circle : last.markerFormat == .decimal ? .lowercaseAlpha : .disc, options: 0))
            } else if lists.count > 1 {
                lists.removeLast()
            } else {
                rebuilt.append(paragraph)
                continue
            }
            let existing = markerLength(at: range.location)
            let attributes = paragraph.attributes(at: min(existing, paragraph.length - 1), effectiveRange: nil)
            paragraph.replaceCharacters(in: NSRange(location: 0, length: existing),
                                        with: NSAttributedString(string: "\t\(lists.last!.marker(forItemNumber: 1))\t", attributes: attributes))
            paragraph.addAttribute(.paragraphStyle, value: RichTextView.listStyle(lists, base: style), range: NSRange(location: 0, length: paragraph.length))
            rebuilt.append(paragraph)
        }
        guard shouldChangeText(in: whole, replacementString: rebuilt.string) else { return }
        storage.replaceCharacters(in: whole, with: rebuilt)
        didChangeText()
        renumberLists(around: whole.location)
        let end = whole.location + rebuilt.length - (rebuilt.string.hasSuffix("\n") ? 1 : 0)
        setSelectedRange(NSRange(location: end, length: 0))
        onFormattingChange?()
    }

    /// Rewrites ordered markers ("1.", "2.", "a.") of the list block around `location`.
    func renumberLists(around location: Int) {
        guard let storage = textStorage, storage.length > 0 else { return }
        let text = storage.string as NSString
        var start = text.paragraphRange(for: NSRange(location: min(location, text.length - 1), length: 0)).location
        while start > 0 {
            let previous = text.paragraphRange(for: NSRange(location: start - 1, length: 0))
            let style = storage.attribute(.paragraphStyle, at: previous.location, effectiveRange: nil) as? NSParagraphStyle
            if style?.textLists.isEmpty ?? true { break }
            start = previous.location
        }
        var edits: [(NSRange, String)] = []
        var position = start
        while position < text.length {
            let paragraph = text.paragraphRange(for: NSRange(location: position, length: 0))
            guard let style = storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle,
                  let list = style.textLists.last else { break }
            let length = markerLength(at: paragraph.location)
            if length > 0 {
                let expected = "\t\(list.marker(forItemNumber: storage.itemNumber(in: list, at: paragraph.location)))\t"
                let range = NSRange(location: paragraph.location, length: length)
                if text.substring(with: range) != expected { edits.append((range, expected)) }
            }
            position = NSMaxRange(paragraph)
        }
        guard !edits.isEmpty,
              shouldChangeText(inRanges: edits.map { NSValue(range: $0.0) }, replacementStrings: edits.map(\.1)) else { return }
        storage.beginEditing()
        for (range, marker) in edits.reversed() {
            storage.replaceCharacters(in: range, with: marker)
        }
        storage.endEditing()
        didChangeText()
    }

    override func insertTab(_ sender: Any?) {
        let style = currentParagraphStyle
        let paragraphStart = (string as NSString).paragraphRange(for: selectedRange()).location
        let atItemStart = selectedRange().location <= paragraphStart + markerLength(at: paragraphStart)
        if !style.textLists.isEmpty, atItemStart {
            changeListLevel(by: 1)
            return
        }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if !currentParagraphStyle.textLists.isEmpty {
            changeListLevel(by: -1)
            return
        }
        super.insertBacktab(sender)
    }

    override func insertNewline(_ sender: Any?) {
        super.insertNewline(sender)
        if !currentParagraphStyle.textLists.isEmpty { renumberLists(around: selectedRange().location) }
    }

    // MARK: Links

    @objc func insertLink(_ sender: Any?) {
        let selection = selectedRange()
        let existing = selection.length > 0 ? textStorage?.attribute(.link, at: selection.location, effectiveRange: nil) : nil
        let alert = NSAlert()
        alert.messageText = L("Insert Link")
        alert.informativeText = L("Enter the address (URL) of the link.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "https://"
        field.stringValue = (existing as? URL)?.absoluteString ?? (existing as? String) ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: L("Insert"))
        alert.addButton(withTitle: L("Cancel"))
        if existing != nil { alert.addButton(withTitle: L("Remove Link")) }
        alert.window.initialFirstResponder = field
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertThirdButtonReturn {
                self.setColor(nil, for: .link)
                return
            }
            guard response == .alertFirstButtonReturn else { return }
            var address = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !address.isEmpty else { return }
            if !address.contains(":") { address = "https://" + address }
            guard let url = URL(string: address) else { return }
            if selection.length == 0 {
                var attributes = self.typingAttributes
                attributes[.link] = url
                let inserted = NSAttributedString(string: address, attributes: attributes)
                if self.shouldChangeText(in: selection, replacementString: inserted.string) {
                    self.textStorage?.replaceCharacters(in: selection, with: inserted)
                    self.didChangeText()
                }
            } else {
                self.setSelectedRange(selection)
                self.setColor(nil, for: .link)
                self.changeCharacterAttributes { attributes in
                    var result = attributes
                    result[.link] = url
                    return result
                }
            }
        }
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleBold(_:)):
            menuItem.state = NSFontManager.shared.traits(of: currentFont).contains(.boldFontMask) ? .on : .off
        case #selector(toggleItalic(_:)):
            menuItem.state = NSFontManager.shared.traits(of: currentFont).contains(.italicFontMask) ? .on : .off
        case #selector(toggleUnderline(_:)):
            menuItem.state = ((currentAttributes[.underlineStyle] as? Int) ?? 0) != 0 ? .on : .off
        case #selector(toggleStrikethrough(_:)):
            menuItem.state = ((currentAttributes[.strikethroughStyle] as? Int) ?? 0) != 0 ? .on : .off
        case #selector(applyParagraphKindFromMenu(_:)):
            menuItem.state = paragraphKind.rawValue == menuItem.tag ? .on : .off
        default:
            break
        }
        return super.validateMenuItem(menuItem)
    }
}
