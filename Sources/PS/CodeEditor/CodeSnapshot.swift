import AppKit
import PSCore

/// "Copy/Export Code as Image": the selection (or the whole file, up to 150 lines) with
/// its syntax colours, inside a window card on the app's gradient. PNG at 2×.
enum CodeSnapshot {
    static func png(view: NSTextView, title: String, theme: Theme?) -> Data? {
        guard let layoutManager = view.layoutManager else { return nil }
        let text = view.string as NSString
        var range = view.selectedRange()
        if range.length == 0 { range = NSRange(location: 0, length: text.length) }
        range = text.lineRange(for: range)
        var end = range.location
        var lines = 0
        while end < NSMaxRange(range), lines < 150 {
            end = NSMaxRange(text.lineRange(for: NSRange(location: end, length: 0)))
            lines += 1
        }
        range.length = min(end, NSMaxRange(range)) - range.location
        var snippet = text.substring(with: range)
        while snippet.hasSuffix("\n") { snippet.removeLast() }
        guard !snippet.isEmpty else { return nil }
        let length = (snippet as NSString).length

        let base = Prefs.codeFont
        let font = NSFont(descriptor: base.fontDescriptor, size: 15) ?? base
        let foreground = theme?.color("foreground") ?? .textColor
        let background = theme?.color("background") ?? .textBackgroundColor
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.2
        style.defaultTabInterval = (" " as NSString).size(withAttributes: [.font: font]).width * 4
        let code = NSMutableAttributedString(string: snippet, attributes: [.font: font, .foregroundColor: foreground, .paragraphStyle: style])

        // Syntax colours live in the layout manager, not in the text: copy them over.
        var index = range.location
        while index < range.location + length {
            var effective = NSRange()
            let color = layoutManager.temporaryAttribute(.foregroundColor, atCharacterIndex: index, effectiveRange: &effective) as? NSColor
            let overlap = NSIntersectionRange(effective, NSRange(location: range.location, length: length))
            if let color, overlap.length > 0 {
                code.addAttribute(.foregroundColor, value: color, range: NSRange(location: overlap.location - range.location, length: overlap.length))
            }
            index = max(NSMaxRange(effective), index + 1)
        }

        let codeSize = code.boundingRect(with: NSSize(width: 1600, height: 100_000), options: [.usesLineFragmentOrigin, .usesFontLeading]).size
        let padding: CGFloat = 64
        let titleBar: CGFloat = 40
        let inset: CGFloat = 24
        let card = NSSize(width: max(460, ceil(codeSize.width) + inset * 2), height: ceil(codeSize.height) + titleBar + inset)
        let size = NSSize(width: card.width + padding * 2, height: card.height + padding * 2)
        let scale: CGFloat = 2

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }

        let cg = context.cgContext
        cg.translateBy(x: 0, y: size.height * scale)
        cg.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)

        NSGradient(colors: [
            NSColor(srgbRed: 0.24, green: 0.19, blue: 0.85, alpha: 1),
            NSColor(srgbRed: 0.75, green: 0.22, blue: 0.78, alpha: 1),
            NSColor(srgbRed: 1.0, green: 0.52, blue: 0.36, alpha: 1),
        ])?.draw(in: NSRect(origin: .zero, size: size), angle: 35)

        let window = NSRect(x: padding, y: padding, width: card.width, height: card.height)
        let shape = NSBezierPath(roundedRect: window, xRadius: 14, yRadius: 14)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 30
        shadow.shadowOffset = NSSize(width: 0, height: -12)
        shadow.set()
        background.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.12).setStroke()
        shape.lineWidth = 1
        shape.stroke()

        for (offset, hex) in ["#FF5F57", "#FEBC2E", "#28C840"].enumerated() {
            (NSColor(hex: hex) ?? .gray).setFill()
            NSBezierPath(ovalIn: NSRect(x: window.minX + 18 + CGFloat(offset) * 20, y: window.minY + titleBar / 2 - 6, width: 12, height: 12)).fill()
        }
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
            .foregroundColor: foreground.withAlphaComponent(0.55),
        ]
        let titleSize = (title as NSString).size(withAttributes: titleAttributes)
        (title as NSString).draw(at: NSPoint(x: window.midX - titleSize.width / 2, y: window.minY + (titleBar - titleSize.height) / 2), withAttributes: titleAttributes)

        code.draw(with: NSRect(x: window.minX + inset, y: window.minY + titleBar, width: ceil(codeSize.width) + 2, height: ceil(codeSize.height) + 2), options: [.usesLineFragmentOrigin, .usesFontLeading])

        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = size
        return bitmap.representation(using: .png, properties: [:])
    }
}
