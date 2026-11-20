import AppKit
import PSCore

/// NSTextView configured as a code editor: auto-indent, bracket pairing, line commands.
/// Every mutation goes through `replace`, so each command is a single undo step.
final class CodeTextView: NSTextView {
    weak var document: Document?
    var currentLineColor = NSColor.clear
    var bracketColor = NSColor.controlAccentColor
    private var bracketRanges: [NSRange] = []

    /// Carets/selections besides the primary one (multiple cursors).
    private(set) var extraCursors: [NSRange] = []
    private var applyingCursors = false
    var cursorCount: Int { extraCursors.count + 1 }

    /// Word under the caret, whose other occurrences get a soft highlight.
    private var highlightedWord: String?
    private var swatches: [(rect: NSRect, range: NSRange)] = []
    private var editingColor: NSRange?

    private var language: Language { document?.language ?? LanguageRegistry.plainText }

    private var indentUnit: String {
        guard let document else { return "    " }
        return document.useTabs ? "\t" : String(repeating: " ", count: document.indentWidth)
    }

    /// The live storage string. `string` (a Swift String) would copy the whole text.
    private var nsString: NSString { textStorage?.mutableString ?? NSString() }

    // MARK: Drawing

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager, let textContainer else { return }

        let selection = selectedRange()
        if selection.length == 0, Prefs.highlightCurrentLine {
            let line = lineRect(containing: selection.location)
            currentLineColor.setFill()
            NSRect(x: 0, y: line.minY, width: bounds.width, height: line.height).fill()
        }

        let visible = visibleCharacters()
        if Prefs.highlightOccurrences { drawOccurrences(in: visible) }
        for range in extraCursors where range.length > 0 && NSMaxRange(range) <= nsString.length {
            (selectedTextAttributes[.backgroundColor] as? NSColor ?? .selectedTextBackgroundColor).setFill()
            rects(for: range).forEach { $0.fill() }
        }
        if Prefs.colorSwatches { drawSwatches(in: visible) } else { swatches = [] }

        for range in bracketRanges where NSMaxRange(range) <= nsString.length {
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let box = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
                .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
                .insetBy(dx: -1, dy: 0)
            let path = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
            bracketColor.withAlphaComponent(0.18).setFill()
            path.fill()
            bracketColor.withAlphaComponent(0.7).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    private func visibleCharacters() -> NSRange {
        guard let layoutManager, let textContainer else { return NSRange(location: 0, length: 0) }
        let glyphs = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        return layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    }

    private func rects(for range: NSRange) -> [NSRect] {
        guard let layoutManager, let textContainer else { return [] }
        var result: [NSRect] = []
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: textContainer) { rect, _ in
            result.append(rect.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y))
        }
        return result
    }

    private func drawOccurrences(in visible: NSRange) {
        guard let word = highlightedWord,
              let regex = try? NSRegularExpression(pattern: #"\b"# + NSRegularExpression.escapedPattern(for: word) + #"\b"#) else { return }
        let selection = selectedRange()
        var count = 0
        // Only the visible text is searched, on a small copy.
        let visibleText = nsString.substring(with: visible)
        regex.enumerateMatches(in: visibleText, range: NSRange(location: 0, length: (visibleText as NSString).length)) { match, _, stop in
            guard let local = match?.range else { return }
            let range = NSRange(location: local.location + visible.location, length: local.length)
            guard range != selection else { return }
            for rect in rects(for: range) {
                let path = NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: 0.5), xRadius: 3, yRadius: 3)
                bracketColor.withAlphaComponent(0.13).setFill()
                path.fill()
                bracketColor.withAlphaComponent(0.35).setStroke()
                path.lineWidth = 0.5
                path.stroke()
            }
            count += 1
            if count > 500 { stop.pointee = true }
        }
    }

    /// Colour literals get a swatch in the space before them (or a bar underneath).
    private func drawSwatches(in visible: NSRange) {
        swatches = []
        guard let language = document?.language.id, ColorLiteral.languages.contains(language), visible.length < 200_000 else { return }
        let visibleText = nsString.substring(with: visible) as NSString
        for (local, color) in ColorLiteral.find(in: visibleText, range: NSRange(location: 0, length: visibleText.length)) {
            let range = NSRange(location: local.location + visible.location, length: local.length)
            guard let first = rects(for: NSRange(location: range.location, length: 1)).first,
                  let whole = rects(for: range).first else { continue }
            let previous = range.location > 0 ? nsString.character(at: range.location - 1) : 0
            let gap = range.location > 0 ? rects(for: NSRange(location: range.location - 1, length: 1)).first : nil
            let swatch: NSRect
            if previous == 32 || previous == 9, let gap {
                // Sized to sit inside the space before the literal.
                let size = min(first.height - 5, gap.width - 1.5)
                swatch = NSRect(x: gap.midX - size / 2 + 0.5, y: first.midY - size / 2, width: size, height: size)
            } else {
                swatch = NSRect(x: whole.minX, y: whole.maxY - 2.5, width: whole.width, height: 2.5)
            }
            NSGraphicsContext.saveGraphicsState()
            let path = NSBezierPath(roundedRect: swatch, xRadius: 2.5, yRadius: 2.5)
            color.setFill()
            path.fill()
            NSColor.labelColor.withAlphaComponent(0.35).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            NSGraphicsContext.restoreGraphicsState()
            swatches.append((swatch.insetBy(dx: -3, dy: -3), range))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !extraCursors.isEmpty else { return }
        insertionPointColor.setFill()
        for range in extraCursors where range.length == 0 {
            caretRect(at: range.location).fill()
        }
    }

    private func caretRect(at location: Int) -> NSRect {
        guard let layoutManager, let textContainer else { return .zero }
        let length = nsString.length
        if location >= length, length == 0 || nsString.character(at: length - 1) == 10 {
            let line = layoutManager.extraLineFragmentRect
            return NSRect(x: line.minX + textContainerOrigin.x + textContainer.lineFragmentPadding, y: line.minY + textContainerOrigin.y, width: 2, height: line.height)
        }
        let index = min(location, length)
        let glyph = layoutManager.glyphIndexForCharacter(at: min(index, max(0, length - 1)))
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        var x = layoutManager.location(forGlyphAt: glyph).x + line.minX
        if index >= length {
            x += layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer).width
        }
        return NSRect(x: x + textContainerOrigin.x, y: line.minY + textContainerOrigin.y, width: 2, height: line.height)
    }

    private func lineRect(containing location: Int) -> NSRect {
        guard let layoutManager else { return .zero }
        let length = nsString.length
        if location >= length, length == 0 || nsString.character(at: length - 1) == 10 {
            return layoutManager.extraLineFragmentRect.offsetBy(dx: 0, dy: textContainerOrigin.y)
        }
        let glyph = layoutManager.glyphIndexForCharacter(at: min(location, max(0, length - 1)))
        return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            .offsetBy(dx: 0, dy: textContainerOrigin.y)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        // Any selection change we didn't make ourselves (click, arrows, find) ends multi-cursor mode.
        if !applyingCursors, !extraCursors.isEmpty { extraCursors = [] }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        updateHighlightedWord()
        setNeedsDisplay(visibleRect, avoidAdditionalLayout: true)
    }

    private func updateHighlightedWord() {
        let selection = selectedRange()
        let text = nsString
        // While the view is being detached from its text (tab closing) the selection can
        // briefly point past the end of an empty string.
        guard text.length < 5_000_000, NSMaxRange(selection) <= text.length else {
            highlightedWord = nil
            return
        }
        var word: String?
        if selection.length > 0, selection.length < 100 {
            let selected = text.substring(with: selection)
            if selected.range(of: #"^\w+$"#, options: .regularExpression) != nil { word = selected }
        } else if selection.length == 0 {
            let line = text.lineRange(for: selection)
            if line.length < 2000, let regex = try? NSRegularExpression(pattern: #"\w+"#) {
                let lineText = text.substring(with: line)
                let caret = selection.location - line.location
                for match in regex.matches(in: lineText, range: NSRange(location: 0, length: (lineText as NSString).length))
                    where match.range.location <= caret && caret <= NSMaxRange(match.range) {
                    word = (lineText as NSString).substring(with: match.range)
                }
            }
        }
        highlightedWord = (word?.count ?? 0) >= 2 && !(word?.allSatisfy(\.isNumber) ?? true) ? word : nil
    }

    // MARK: Multiple cursors

    private var allCursors: [NSRange] {
        MultiCursor.normalize(extraCursors + [selectedRange()])
    }

    /// Sets every caret; the last one becomes the primary (real) selection.
    func setCursors(_ ranges: [NSRange], primary: NSRange? = nil) {
        let normalized = MultiCursor.normalize(ranges)
        guard let main = primary ?? normalized.last else { return }
        applyingCursors = true
        extraCursors = normalized.filter { $0 != main }
        setSelectedRange(main)
        applyingCursors = false
        setNeedsDisplay(visibleRect)
        (delegate as? CodeEditor)?.cursorsChanged()
    }

    private func replaceAtCursors(_ ranges: [NSRange], with text: String) {
        let ranges = MultiCursor.normalize(ranges)
        guard !ranges.isEmpty,
              shouldChangeText(inRanges: ranges.map { NSValue(range: $0) }, replacementStrings: Array(repeating: text, count: ranges.count)) else { return }
        textStorage?.beginEditing()
        for range in ranges.reversed() {
            textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: typingAttributes))
        }
        textStorage?.endEditing()
        applyingCursors = true
        didChangeText()
        applyingCursors = false
        setCursors(MultiCursor.carets(afterReplacing: ranges, insertedLength: (text as NSString).length))
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let swatch = swatches.first(where: { $0.rect.contains(point) }) {
            pickColor(for: swatch.range)
            return
        }
        // ⌘-click jumps to where the word is declared (in this file or another one).
        if event.modifierFlags.contains(.command), event.clickCount == 1, !event.modifierFlags.contains(.shift),
           let controller = window?.windowController as? MainWindowController {
            let index = characterIndexForInsertion(at: point)
            if let url = CodeLink.url(in: nsString, at: index) {
                NSWorkspace.shared.open(url)
                return
            }
            if let word = MainWindowController.word(in: nsString, at: index) {
                setSelectedRange(NSRange(location: index, length: 0))
                controller.goToDefinition(of: word, from: self, at: point)
                return
            }
        }
        // Option-click adds a caret (VS Code); a plain click goes back to one caret.
        if event.modifierFlags.contains(.option), event.clickCount == 1, !event.modifierFlags.contains(.shift) {
            let index = characterIndexForInsertion(at: point)
            setCursors(allCursors + [NSRange(location: index, length: 0)], primary: NSRange(location: index, length: 0))
            return
        }
        super.mouseDown(with: event)
    }

    /// ⌥⎋ / Edit ▸ Complete: declarations from the whole folder plus words of this file.
    override func completions(forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String]? {
        let text = nsString
        guard charRange.length > 0, NSMaxRange(charRange) <= text.length else { return nil }
        let prefix = text.substring(with: charRange)
        var result: [String] = []
        var seen = Set<String>()
        func add(_ word: String) {
            if word != prefix, seen.insert(word).inserted { result.append(word) }
        }
        if let controller = window?.windowController as? MainWindowController {
            controller.symbols.names(withPrefix: prefix, limit: 30).forEach(add)
        }
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: prefix) + "[\\w$]+"
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            for match in regex.matches(in: text as String, range: NSRange(location: 0, length: min(text.length, 2_000_000))).prefix(2000) {
                add(text.substring(with: match.range))
                if result.count >= 60 { break }
            }
        }
        index.pointee = result.isEmpty ? -1 : 0
        return result
    }

    /// Cmd+D: select the word, then add its next occurrence as another selection.
    @objc func addNextOccurrence(_ sender: Any?) {
        let selection = selectedRange()
        if selection.length == 0 {
            let word = selectionRange(forProposedRange: selection, granularity: .selectByWord)
            if word.length > 0 { setCursors(extraCursors + [word], primary: word) }
            return
        }
        let needle = nsString.substring(with: selection)
        let cursors = allCursors
        let after = cursors.map { NSMaxRange($0) }.max() ?? NSMaxRange(selection)
        guard let next = MultiCursor.nextOccurrence(of: needle, in: nsString, after: after, excluding: cursors) else { return }
        setCursors(cursors + [next], primary: next)
        scrollRangeToVisible(next)
    }

    /// Adds a caret on the line above/below each existing one (Option+Cmd+arrows).
    @objc func addCursorAbove(_ sender: Any?) { addCursorVertically(-1) }
    @objc func addCursorBelow(_ sender: Any?) { addCursorVertically(1) }

    private func addCursorVertically(_ direction: Int) {
        guard let document else { return }
        let index = document.lineIndex
        var cursors = allCursors
        let reference = direction < 0 ? cursors.first! : cursors.last!
        let line = index.line(at: reference.location)
        let target = line + direction
        guard target >= 0, target < index.lineCount else { return }
        let column = reference.location - index.start(ofLine: line)
        let start = index.start(ofLine: target)
        let end = target + 1 < index.lineCount ? index.start(ofLine: target + 1) - 1 : nsString.length
        let caret = NSRange(location: min(start + column, end), length: 0)
        cursors.append(caret)
        setCursors(cursors, primary: caret)
    }

    override func cancelOperation(_ sender: Any?) {
        if !extraCursors.isEmpty {
            setCursors([selectedRange()])
            return
        }
        super.cancelOperation(sender)
    }

    override func moveLeft(_ sender: Any?) { moveCursors(-1) ?? super.moveLeft(sender) }
    override func moveRight(_ sender: Any?) { moveCursors(1) ?? super.moveRight(sender) }

    /// Left/right move every caret; nil when there is only one (normal behaviour).
    private func moveCursors(_ delta: Int) -> Void? {
        guard !extraCursors.isEmpty else { return nil }
        let length = nsString.length
        setCursors(allCursors.map { range in
            let base = range.length > 0 ? (delta < 0 ? range.location : NSMaxRange(range)) : range.location + delta
            return NSRange(location: min(max(0, base), length), length: 0)
        })
        return ()
    }

    override func paste(_ sender: Any?) {
        guard !extraCursors.isEmpty, let text = NSPasteboard.general.string(forType: .string) else {
            super.paste(sender)
            return
        }
        let cursors = allCursors
        let lines = text.components(separatedBy: "\n")
        // One pasted line per cursor when the counts match, like VS Code.
        if lines.count == cursors.count, cursors.count > 1 {
            guard shouldChangeText(inRanges: cursors.map { NSValue(range: $0) }, replacementStrings: lines) else { return }
            textStorage?.beginEditing()
            for (range, line) in zip(cursors, lines).reversed() {
                textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: line, attributes: typingAttributes))
            }
            textStorage?.endEditing()
            applyingCursors = true
            didChangeText()
            applyingCursors = false
            var shift = 0
            setCursors(zip(cursors, lines).map { range, line in
                let length = (line as NSString).length
                defer { shift += length - range.length }
                return NSRange(location: range.location + shift + length, length: 0)
            })
            return
        }
        replaceAtCursors(cursors, with: text)
    }

    // MARK: Colour picker

    var swatchCount: Int { swatches.count }

    /// Same as clicking the swatch of the literal at `range`.
    func editColorLiteral(at range: NSRange) {
        pickColor(for: range)
    }

    private func pickColor(for range: NSRange) {
        guard let color = ColorLiteral.parse(nsString.substring(with: range)) else { return }
        editingColor = range
        let panel = NSColorPanel.shared
        panel.showsAlpha = true
        panel.color = color
        panel.orderFront(nil)
    }

    /// NSColorPanel talks to the first responder; in a code view that edits the literal.
    override func changeColor(_ sender: Any?) {
        guard let range = editingColor, NSMaxRange(range) <= nsString.length else { return }
        let original = nsString.substring(with: range)
        guard ColorLiteral.parse(original) != nil else {
            editingColor = nil
            return
        }
        let replacement = ColorLiteral.format(NSColorPanel.shared.color, like: original)
        guard replacement != original, shouldChangeText(in: range, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: replacement, attributes: typingAttributes))
        didChangeText()
        editingColor = NSRange(location: range.location, length: (replacement as NSString).length)
    }

    // MARK: Bracket matching

    func updateBracketMatch() {
        let previous = bracketRanges
        bracketRanges = []
        defer {
            if previous != bracketRanges { setNeedsDisplay(visibleRect, avoidAdditionalLayout: true) }
        }
        let selection = selectedRange()
        guard selection.length == 0 else { return }
        let text = nsString
        let pairs: [unichar: (unichar, Bool)] = [
            40: (41, true), 91: (93, true), 123: (125, true),
            41: (40, false), 93: (91, false), 125: (123, false),
        ]
        for location in [selection.location - 1, selection.location] where location >= 0 && location < text.length {
            let character = text.character(at: location)
            guard let (partner, forward) = pairs[character] else { continue }
            if let match = findPartner(of: character, partner: partner, from: location, forward: forward, in: text) {
                bracketRanges = [NSRange(location: location, length: 1), NSRange(location: match, length: 1)]
                return
            }
        }
    }

    private func findPartner(of character: unichar, partner: unichar, from start: Int, forward: Bool, in text: NSString) -> Int? {
        var depth = 0
        var location = start
        let limit = 50_000
        var steps = 0
        while location >= 0 && location < text.length && steps < limit {
            let current = text.character(at: location)
            if current == character { depth += 1 }
            if current == partner {
                depth -= 1
                if depth == 0 { return location }
            }
            location += forward ? 1 : -1
            steps += 1
        }
        return nil
    }

    // MARK: Typing

    private func character(at location: Int) -> Character? {
        guard location >= 0, location < nsString.length, let scalar = UnicodeScalar(nsString.character(at: location)) else {
            return nil
        }
        return Character(scalar)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        if !extraCursors.isEmpty, replacementRange.location == NSNotFound, !hasMarkedText() {
            let text = (insertString as? String) ?? (insertString as? NSAttributedString)?.string ?? ""
            replaceAtCursors(allCursors, with: text)
            return
        }
        if let typed = insertString as? String, replacementRange.location == NSNotFound,
           renameTag(replacing: selectedRange(), with: typed) {
            return
        }
        guard let typed = insertString as? String, typed.count == 1, let key = typed.first,
              replacementRange.location == NSNotFound, !hasMarkedText() else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        let selection = selectedRange()
        let next = character(at: NSMaxRange(selection))
        let pairs = Prefs.autoCloseBrackets ? language.pairs : []

        // Typing a closer that's already there just steps over it.
        if selection.length == 0, next == key, pairs.contains(where: { $0.close == key }) {
            setSelectedRange(NSRange(location: selection.location + 1, length: 0))
            return
        }

        if let pair = pairs.first(where: { $0.open == key }) {
            if selection.length > 0 {
                let inner = nsString.substring(with: selection)
                replace(selection, with: "\(pair.open)\(inner)\(pair.close)",
                        select: NSRange(location: selection.location + 1, length: (inner as NSString).length))
                return
            }
            let isQuote = pair.open == pair.close
            let nextAllows = next.map { $0.isWhitespace || ")]}>,;:".contains($0) } ?? true
            let previousIsWord = character(at: selection.location - 1).map { $0.isLetter || $0.isNumber || $0 == "_" } ?? false
            if nextAllows && !(isQuote && previousIsWord) {
                replace(selection, with: "\(pair.open)\(pair.close)", select: NSRange(location: selection.location + 1, length: 0))
                return
            }
        }
        super.insertText(insertString, replacementRange: replacementRange)
    }

    override func deleteBackward(_ sender: Any?) {
        if !extraCursors.isEmpty {
            replaceAtCursors(MultiCursor.backspaceRanges(allCursors), with: "")
            return
        }
        let selection = selectedRange()
        let deleted = selection.length > 0 ? selection : NSRange(location: selection.location - 1, length: 1)
        if selection.location > 0 || selection.length > 0, renameTag(replacing: deleted, with: "") { return }
        if selection.length == 0, selection.location > 0,
           let previous = character(at: selection.location - 1), let next = character(at: selection.location),
           language.pairs.contains(where: { $0.open == previous && $0.close == next }) {
            replace(NSRange(location: selection.location - 1, length: 2), with: "", select: NSRange(location: selection.location - 1, length: 0))
            return
        }
        super.deleteBackward(sender)
    }

    override func deleteForward(_ sender: Any?) {
        let selection = selectedRange()
        let deleted = selection.length > 0 ? selection : NSRange(location: selection.location, length: 1)
        if extraCursors.isEmpty, NSMaxRange(deleted) <= nsString.length, renameTag(replacing: deleted, with: "") { return }
        super.deleteForward(sender)
    }

    /// Typing or deleting inside `<div` renames its `</div>` too, and the other way round
    /// (VS Code's linked editing). One undo step covers both. False when it doesn't apply.
    private func renameTag(replacing range: NSRange, with text: String) -> Bool {
        guard extraCursors.isEmpty, !hasMarkedText(), TagPair.languages.contains(language.id),
              text.utf16.allSatisfy(TagPair.isNameCharacter),
              let pair = TagPair.partner(in: nsString, at: range.location),
              range.location >= pair.own.location, NSMaxRange(range) <= NSMaxRange(pair.own) else { return false }
        let name = (nsString.substring(with: pair.own) as NSString)
            .replacingCharacters(in: NSRange(location: range.location - pair.own.location, length: range.length), with: text)
        // An empty or invalid name is left to the normal edit; the partner keeps its name.
        guard let first = name.first, first.isLetter else { return false }
        let ranges = [pair.own, pair.partner].sorted { $0.location < $1.location }
        guard shouldChangeText(inRanges: ranges.map { NSValue(range: $0) }, replacementStrings: [name, name]) else { return true }
        textStorage?.beginEditing()
        for target in ranges.reversed() {
            textStorage?.replaceCharacters(in: target, with: NSAttributedString(string: name, attributes: typingAttributes))
        }
        textStorage?.endEditing()
        didChangeText()
        let growth = (name as NSString).length - pair.own.length
        let caret = range.location + (text as NSString).length + (pair.partner.location < pair.own.location ? growth : 0)
        setSelectedRange(NSRange(location: caret, length: 0))
        return true
    }

    override func insertNewline(_ sender: Any?) {
        if !extraCursors.isEmpty {
            replaceAtCursors(allCursors, with: "\n")
            return
        }
        let selection = selectedRange()
        let lineStart = nsString.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let before = nsString.substring(with: NSRange(location: lineStart, length: selection.location - lineStart))
        let indent = String(before.prefix { $0 == " " || $0 == "\t" })
        var extra = ""
        if let pattern = language.indentAfter, before.range(of: pattern, options: .regularExpression) != nil {
            extra = indentUnit
        }

        let previous = character(at: selection.location - 1)
        let next = character(at: NSMaxRange(selection))
        if !extra.isEmpty, let previous, let next, language.pairs.contains(where: { $0.open == previous && $0.close == next && $0.open != $0.close }) {
            let head = "\n" + indent + extra
            replace(selection, with: head + "\n" + indent, select: NSRange(location: selection.location + (head as NSString).length, length: 0))
            return
        }
        let inserted = "\n" + indent + extra
        replace(selection, with: inserted, select: NSRange(location: selection.location + (inserted as NSString).length, length: 0))
    }

    override func insertTab(_ sender: Any?) {
        if !extraCursors.isEmpty {
            replaceAtCursors(allCursors, with: indentUnit)
            return
        }
        let selection = selectedRange()
        if selection.length > 0, nsString.substring(with: selection).contains("\n") {
            shiftLines(by: 1)
            return
        }
        guard let document, !document.useTabs else {
            super.insertText("\t", replacementRange: selection)
            return
        }
        let lineStart = nsString.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let column = selection.location - lineStart
        let count = document.indentWidth - column % document.indentWidth
        super.insertText(String(repeating: " ", count: count), replacementRange: selection)
    }

    override func insertBacktab(_ sender: Any?) {
        shiftLines(by: -1)
    }

    // MARK: Line commands

    /// Whole lines touched by the selection (a selection ending at column 0 excludes that line).
    private func selectedLineBlock() -> NSRange {
        var selection = selectedRange()
        if selection.length > 0, nsString.character(at: NSMaxRange(selection) - 1) == 10 {
            selection.length -= 1
        }
        return nsString.lineRange(for: selection)
    }

    private func replace(_ range: NSRange, with replacement: String, select: NSRange?) {
        guard shouldChangeText(in: range, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: replacement, attributes: typingAttributes))
        didChangeText()
        if let select { setSelectedRange(select) }
        scrollRangeToVisible(selectedRange())
    }

    private func shiftLines(by direction: Int) {
        let block = selectedLineBlock()
        let lines = nsString.substring(with: block).components(separatedBy: "\n")
        let unit = indentUnit
        let width = document?.indentWidth ?? 4
        let shifted = lines.enumerated().map { index, line -> String in
            if index == lines.count - 1, line.isEmpty { return line }
            if direction > 0 { return line.isEmpty ? line : unit + line }
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            let spaces = line.prefix { $0 == " " }.count
            return String(line.dropFirst(min(spaces, width)))
        }
        let result = shifted.joined(separator: "\n")
        let length = (result as NSString).length - (result.hasSuffix("\n") ? 1 : 0)
        replace(block, with: result, select: NSRange(location: block.location, length: length))
    }

    @objc func psIndent(_ sender: Any?) { shiftLines(by: 1) }
    @objc func psOutdent(_ sender: Any?) { shiftLines(by: -1) }

    @objc func toggleComment(_ sender: Any?) {
        let block = selectedLineBlock()
        let blockText = nsString.substring(with: block)
        let trailingNewline = blockText.hasSuffix("\n")
        let body = trailingNewline ? String(blockText.dropLast()) : blockText

        if let marker = language.lineComment {
            var lines = body.components(separatedBy: "\n")
            let filled = lines.indices.filter { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }
            guard !filled.isEmpty else { return }
            let commented = filled.allSatisfy { lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix(marker) }
            if commented {
                for index in filled {
                    let line = lines[index]
                    guard let range = line.range(of: marker) else { continue }
                    var end = range.upperBound
                    if end < line.endIndex, line[end] == " " { end = line.index(after: end) }
                    lines[index].removeSubrange(range.lowerBound..<end)
                }
            } else {
                let indent = filled.map { lines[$0].prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
                for index in filled {
                    let position = lines[index].index(lines[index].startIndex, offsetBy: indent)
                    lines[index].insert(contentsOf: marker + " ", at: position)
                }
            }
            let result = lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
            replace(block, with: result, select: NSRange(location: block.location, length: (result as NSString).length - (trailingNewline ? 1 : 0)))
        } else if let (open, close) = language.blockComment {
            let trimmed = body.trimmingCharacters(in: .whitespaces)
            let result: String
            if trimmed.hasPrefix(open) && trimmed.hasSuffix(close) {
                var inner = trimmed.dropFirst(open.count).dropLast(close.count)
                if inner.hasPrefix(" ") { inner = inner.dropFirst() }
                if inner.hasSuffix(" ") { inner = inner.dropLast() }
                let indent = String(body.prefix { $0 == " " || $0 == "\t" })
                result = indent + String(inner)
            } else {
                let indent = String(body.prefix { $0 == " " || $0 == "\t" })
                result = indent + open + " " + String(body.dropFirst(indent.count)) + " " + close
            }
            let full = result + (trailingNewline ? "\n" : "")
            replace(block, with: full, select: NSRange(location: block.location, length: (result as NSString).length))
        }
    }

    @objc func duplicateLine(_ sender: Any?) {
        let block = selectedLineBlock()
        var text = nsString.substring(with: block)
        let offset = selectedRange().location - block.location
        if text.hasSuffix("\n") {
            replace(NSRange(location: NSMaxRange(block), length: 0), with: text,
                    select: NSRange(location: NSMaxRange(block) + offset, length: 0))
        } else {
            text = "\n" + text
            replace(NSRange(location: NSMaxRange(block), length: 0), with: text,
                    select: NSRange(location: NSMaxRange(block) + 1 + offset, length: 0))
        }
    }

    @objc func moveLineUp(_ sender: Any?) { moveLines(up: true) }
    @objc func moveLineDown(_ sender: Any?) { moveLines(up: false) }

    private func moveLines(up: Bool) {
        let block = selectedLineBlock()
        let selection = selectedRange()
        if up {
            guard block.location > 0 else { return }
            let other = nsString.lineRange(for: NSRange(location: block.location - 1, length: 0))
            let swapped = swap(first: other, second: block)
            replace(NSRange(location: other.location, length: other.length + block.length), with: swapped.text,
                    select: NSRange(location: other.location + selection.location - block.location, length: selection.length))
        } else {
            guard NSMaxRange(block) < nsString.length else { return }
            let other = nsString.lineRange(for: NSRange(location: NSMaxRange(block), length: 0))
            let swapped = swap(first: block, second: other)
            replace(NSRange(location: block.location, length: block.length + other.length), with: swapped.text,
                    select: NSRange(location: block.location + swapped.firstLength + selection.location - block.location, length: selection.length))
        }
    }

    /// Returns "second + first", fixing the newline when `second` is the last line of the file.
    private func swap(first: NSRange, second: NSRange) -> (text: String, firstLength: Int) {
        var a = nsString.substring(with: first)
        var b = nsString.substring(with: second)
        if !b.hasSuffix("\n") {
            b += "\n"
            a = String(a.dropLast())
        }
        return (b + a, (b as NSString).length)
    }

    @objc func deleteLine(_ sender: Any?) {
        var block = selectedLineBlock()
        if NSMaxRange(block) == nsString.length, block.location > 0, !nsString.substring(with: block).hasSuffix("\n") {
            block = NSRange(location: block.location - 1, length: block.length + 1)
        }
        replace(block, with: "", select: NSRange(location: min(block.location, nsString.length - block.length), length: 0))
    }

    func goTo(line: Int, column: Int = 1) {
        guard let document else { return }
        let index = document.lineIndex
        let start = index.start(ofLine: line - 1)
        let end = line < index.lineCount ? index.start(ofLine: line) - 1 : nsString.length
        let location = min(start + max(0, column - 1), max(start, end))
        setSelectedRange(NSRange(location: location, length: 0))
        scrollRangeToVisible(selectedRange())
        showFindIndicator(for: nsString.lineRange(for: NSRange(location: location, length: 0)))
    }
}
