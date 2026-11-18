import AppKit

/// The app icon is drawn in code: no binary assets in the repo, and the build script
/// renders the .icns from this same function.
enum AppIcon {
    static func image(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(in: rect)
            return true
        }
    }

    static func draw(in rect: NSRect) {
        let size = rect.width
        let inset = size * 0.1
        let tile = rect.insetBy(dx: inset, dy: inset)
        let radius = tile.width * 0.225
        let path = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = size * 0.03
        shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
        shadow.set()
        NSColor.black.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSGradient(colors: [
            NSColor(srgbRed: 0.24, green: 0.19, blue: 0.85, alpha: 1),
            NSColor(srgbRed: 0.75, green: 0.22, blue: 0.78, alpha: 1),
            NSColor(srgbRed: 1.0, green: 0.52, blue: 0.36, alpha: 1),
        ])?.draw(in: tile, angle: -50)

        // Soft highlight across the top.
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0)])?
            .draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)

        // A sheet of paper with text lines (prose) beside code brackets (source).
        let sheet = NSRect(x: tile.minX + tile.width * 0.44, y: tile.minY + tile.height * 0.2, width: tile.width * 0.38, height: tile.height * 0.6)
        NSColor.white.withAlphaComponent(0.95).setFill()
        NSBezierPath(roundedRect: sheet, xRadius: tile.width * 0.04, yRadius: tile.width * 0.04).fill()
        let lineColor = NSColor(srgbRed: 0.55, green: 0.3, blue: 0.85, alpha: 0.55)
        lineColor.setFill()
        for (index, fraction) in [0.75, 0.9, 0.6, 0.85, 0.5].enumerated() {
            let y = sheet.maxY - sheet.height * (0.2 + CGFloat(index) * 0.14)
            let width = (sheet.width - sheet.width * 0.3) * fraction
            let height = index == 0 ? sheet.height * 0.07 : sheet.height * 0.045
            NSBezierPath(roundedRect: NSRect(x: sheet.minX + sheet.width * 0.15, y: y, width: width, height: height), xRadius: height / 2, yRadius: height / 2).fill()
        }

        let font = NSFont.systemFont(ofSize: tile.width * 0.42, weight: .heavy)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let brackets = "{" as NSString
        let bracketSize = brackets.size(withAttributes: attributes)
        brackets.draw(at: NSPoint(x: tile.minX + tile.width * 0.12, y: tile.midY - bracketSize.height / 2 + tile.height * 0.02), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }

    static func exportIconset(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = base * scale
                guard let bitmap = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                    bytesPerRow: 0, bitsPerPixel: 0
                ) else { continue }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
                NSGraphicsContext.restoreGraphicsState()
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name))
            }
        }
    }
}
