import AppKit
import PSCore

extension NSAttributedString.Key {
    /// Temporary attribute marking tokens that span lines (block comments, multi-line
    /// strings). Used to widen the repainted range after an edit.
    static let psMultiline = NSAttributedString.Key("PSMultiline")
}

/// Paints syntax colours as layout-manager temporary attributes: they are never saved,
/// never enter undo, and repainting them doesn't touch the text storage.
///
/// - After an edit only the touched paragraphs are re-tokenized (widened to the enclosing
///   multi-line token, if any).
/// - The initial pass for a big file runs in the background and is applied in chunks.
final class Highlighter {
    private weak var layoutManager: NSLayoutManager?
    private unowned let document: Document
    private var tokenizer: Tokenizer?
    private var colors: [NSColor?] = []
    private var generation = 0
    private var fullPassInFlight = false
    private var scheduledFullPass: DispatchWorkItem?
    private let generationLock = NSLock()

    init(document: Document, layoutManager: NSLayoutManager) {
        self.document = document
        self.layoutManager = layoutManager
    }

    var isActive: Bool { tokenizer != nil }

    func configure(theme: Theme?, visibleRange: NSRange?) {
        tokenizer = document.highlightingDisabled ? nil : Tokenizer.forLanguage(document.language)
        colors = tokenizer?.scopes.map { theme?.scopeColor($0) } ?? []
        rehighlightAll(visibleRange: visibleRange)
    }

    private func currentGeneration() -> Int {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generation
    }

    private func bumpGeneration() -> Int {
        generationLock.lock()
        defer { generationLock.unlock() }
        generation += 1
        return generation
    }

    func rehighlightAll(visibleRange: NSRange? = nil) {
        let token = bumpGeneration()
        guard layoutManager != nil else { return }
        let length = document.textStorage.length
        let full = NSRange(location: 0, length: length)
        let live = document.textStorage.string as NSString
        guard let tokenizer else {
            clear(full)
            return
        }
        if length < 60_000 {
            clear(full)
            apply(tokenizer.tokens(in: live, from: 0, until: length), text: live)
            return
        }

        // Paint what's on screen right away; the full pass below fixes multi-line context.
        if let visible = visibleRange, visible.length > 0 {
            let start = live.paragraphRange(for: NSRange(location: visible.location, length: 0)).location
            apply(tokenizer.tokens(in: live, from: start, until: NSMaxRange(visible)), text: live)
        }

        let snapshot = NSString(string: document.textStorage.string)
        fullPassInFlight = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let tokens = tokenizer.tokens(in: snapshot, from: 0, until: snapshot.length) {
                self?.currentGeneration() != token
            }
            DispatchQueue.main.async {
                self?.applyInChunks(tokens[...], from: 0, text: snapshot, generation: token)
            }
        }
    }

    /// Applies a background result a slice at a time so the UI keeps responding.
    /// Each chunk clears the old colours of the span it covers, so a re-run never flickers.
    private func applyInChunks(_ tokens: ArraySlice<Token>, from start: Int, text: NSString, generation token: Int) {
        guard currentGeneration() == token else { return }
        let chunk = tokens.prefix(4000)
        let rest = tokens.dropFirst(chunk.count)
        let end = rest.isEmpty ? text.length : (chunk.last.map { NSMaxRange($0.range) } ?? text.length)
        clear(NSRange(location: start, length: max(0, end - start)))
        apply(Array(chunk), text: text)
        if rest.isEmpty {
            fullPassInFlight = false
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.applyInChunks(rest, from: end, text: text, generation: token)
        }
    }

    private func clear(_ range: NSRange) {
        layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
        layoutManager?.removeTemporaryAttribute(.psMultiline, forCharacterRange: range)
    }

    /// Called after colours were painted (the minimap redraws from them).
    var onPainted: (() -> Void)?

    private func apply(_ tokens: [Token], text: NSString) {
        guard let layoutManager else { return }
        defer { onPainted?() }
        for token in tokens {
            if let color = colors[token.scope] {
                layoutManager.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: token.range)
            }
            if token.range.length > 1,
               text.rangeOfCharacter(from: .newlines, options: [], range: token.range).location != NSNotFound {
                layoutManager.addTemporaryAttribute(.psMultiline, value: true, forCharacterRange: token.range)
            }
        }
    }

    /// Incremental update after an edit.
    func edited(_ editedRange: NSRange) {
        guard let tokenizer, let layoutManager else { return }
        if fullPassInFlight {
            // The background result is now stale: drop it and redo it once typing pauses.
            _ = bumpGeneration()
            fullPassInFlight = false
            scheduleFullPass()
        }

        let text = document.textStorage.string as NSString
        let length = text.length
        let location = min(editedRange.location, length)
        let editEnd = min(NSMaxRange(editedRange), length)
        var start = text.paragraphRange(for: NSRange(location: location, length: 0)).location
        var end = NSMaxRange(text.paragraphRange(for: NSRange(location: editEnd, length: 0)))
        var effective = NSRange()

        if start > 0, layoutManager.temporaryAttribute(
            .psMultiline, atCharacterIndex: start - 1,
            longestEffectiveRange: &effective, in: NSRange(location: 0, length: start)
        ) != nil {
            start = effective.location
        }
        if end < length, layoutManager.temporaryAttribute(
            .psMultiline, atCharacterIndex: end,
            longestEffectiveRange: &effective, in: NSRange(location: end, length: length - end)
        ) != nil {
            end = NSMaxRange(effective)
        }

        let tokens = tokenizer.tokens(in: text, from: start, until: end)
        let realEnd = max(end, tokens.last.map { NSMaxRange($0.range) } ?? end)
        clear(NSRange(location: start, length: realEnd - start))
        apply(tokens, text: text)
    }

    private func scheduleFullPass() {
        scheduledFullPass?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rehighlightAll() }
        scheduledFullPass = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }
}
