import AppKit
import PSCore

/// Scaled-down view of the code beside the editor: each character is a tiny block in its
/// syntax colour, the visible part is shaded. Click or drag to jump. Only the lines on
/// screen are drawn, read straight from the storage, so big files stay cheap.
final class MinimapView: NSView {
    static let width: CGFloat = 96
    private let lineHeight: CGFloat = 2.6
    private let charWidth: CGFloat = 1.05
    private let maxColumns = 140

    private weak var textView: NSTextView?
    private unowned let document: Document
    var foreground = NSColor.textColor
    var background = NSColor.textBackgroundColor

    init(textView: NSTextView, document: Document) {
        self.textView = textView
        self.document = document
        super.init(frame: NSRect(x: 0, y: 0, width: MinimapView.width, height: 400))
        if #available(macOS 14, *) { clipsToBounds = true }
        setAccessibilityElement(true)
        setAccessibilityRole(.scrollBar)
        setAccessibilityLabel(L("Minimap"))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isFlipped: Bool { true }

    private var clip: NSClipView? { textView?.enclosingScrollView?.contentView }

    /// The editor's scroll position, 0…1.
    private var fraction: CGFloat {
        guard let clip, let textView else { return 0 }
        let range = textView.frame.height - clip.bounds.height
        return range > 0 ? min(1, max(0, clip.bounds.minY / range)) : 0
    }

    private var totalHeight: CGFloat {
        CGFloat(document.lineIndex.lineCount) * lineHeight
    }

    /// How far the minimap itself is scrolled: it moves along with the editor.
    private var minimapOffset: CGFloat {
        max(0, totalHeight - bounds.height) * fraction
    }

    override func draw(_ dirtyRect: NSRect) {
        background.setFill()
        bounds.fill()
        NSColor.separatorColor.withAlphaComponent(0.4).setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
        guard let textView, let layoutManager = textView.layoutManager, let storage = textView.textStorage else { return }

        let text = storage.mutableString
        let index = document.lineIndex
        let offset = minimapOffset
        let first = max(0, Int(offset / lineHeight))
        let last = min(index.lineCount, first + Int(bounds.height / lineHeight) + 2)
        var buffer = [unichar](repeating: 0, count: maxColumns * 2)
        var effective = NSRange()

        if first < last {
            for line in first..<last {
                let start = index.start(ofLine: line)
                let end = line + 1 < index.lineCount ? index.start(ofLine: line + 1) : text.length
                let length = min(end - start, buffer.count)
                guard length > 0, start + length <= text.length else { continue }
                text.getCharacters(&buffer, range: NSRange(location: start, length: length))
                let y = CGFloat(line) * lineHeight - offset
                var column = 0
                var position = 0
                while position < length, column < maxColumns {
                    let character = buffer[position]
                    if character == 10 || character == 13 { break }
                    if character == 32 {
                        column += 1
                        position += 1
                        continue
                    }
                    if character == 9 {
                        column += 4
                        position += 1
                        continue
                    }
                    let color = layoutManager.temporaryAttribute(.foregroundColor, atCharacterIndex: start + position, effectiveRange: &effective) as? NSColor ?? foreground
                    let runLimit = min(length, NSMaxRange(effective) - start)
                    var runEnd = position
                    while runEnd < runLimit, buffer[runEnd] != 32, buffer[runEnd] != 9, buffer[runEnd] != 10, buffer[runEnd] != 13 { runEnd += 1 }
                    runEnd = max(runEnd, position + 1)
                    color.withAlphaComponent(0.55).setFill()
                    NSRect(x: 8 + CGFloat(column) * charWidth, y: y, width: CGFloat(runEnd - position) * charWidth, height: lineHeight - 0.9).fill()
                    column += runEnd - position
                    position = runEnd
                }
            }
        }

        // The part of the file that's on screen.
        guard let clip, textView.frame.height > 0 else { return }
        let viewport = NSRect(
            x: 1,
            y: clip.bounds.minY / textView.frame.height * totalHeight - offset,
            width: bounds.width - 1,
            height: max(12, clip.bounds.height / textView.frame.height * totalHeight)
        )
        foreground.withAlphaComponent(0.09).setFill()
        viewport.fill()
        foreground.withAlphaComponent(0.14).setStroke()
        NSBezierPath(rect: viewport.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }

    override func mouseDown(with event: NSEvent) {
        jump(to: convert(event.locationInWindow, from: nil).y)
    }

    override func mouseDragged(with event: NSEvent) {
        jump(to: convert(event.locationInWindow, from: nil).y)
    }

    /// Centres the editor on the clicked spot of the map.
    func jump(to y: CGFloat) {
        guard let clip, let textView, totalHeight > 0 else { return }
        let target = (y + minimapOffset) / totalHeight
        let top = target * textView.frame.height - clip.bounds.height / 2
        let maxTop = max(0, textView.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(max(0, top), maxTop)))
        textView.enclosingScrollView?.reflectScrolledClipView(clip)
        needsDisplay = true
    }
}
