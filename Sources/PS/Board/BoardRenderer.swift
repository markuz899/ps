import AppKit
import PSCore

/// Draws a whiteboard scene with a hand-drawn look: every stroke is drawn twice with a
/// small, seeded wobble, fills are hatched like Excalidraw's. Coordinates are scene units;
/// callers set the transform.
struct BoardRenderer {
    var dark: Bool

    // MARK: Colours

    /// Excalidraw shows dark mode by inverting lightness and keeping the hue.
    func color(_ hex: String, alpha: CGFloat = 1) -> NSColor? {
        guard hex != "transparent", let base = NSColor(hex: hex)?.usingColorSpace(.sRGB) else { return nil }
        guard dark else { return base.withAlphaComponent(base.alphaComponent * alpha) }
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var lightness: CGFloat = 0
        let r = base.redComponent, g = base.greenComponent, b = base.blueComponent
        let maxC = max(r, g, b), minC = min(r, g, b)
        lightness = (maxC + minC) / 2
        if maxC != minC {
            let d = maxC - minC
            saturation = lightness > 0.5 ? d / (2 - maxC - minC) : d / (maxC + minC)
            switch maxC {
            case r: hue = (g - b) / d + (g < b ? 6 : 0)
            case g: hue = (b - r) / d + 2
            default: hue = (r - g) / d + 4
            }
            hue /= 6
        }
        let mapped = 0.93 - 0.86 * lightness
        return hsl(hue, saturation * 0.9, mapped).withAlphaComponent(base.alphaComponent * alpha)
    }

    private func hsl(_ h: CGFloat, _ s: CGFloat, _ l: CGFloat) -> NSColor {
        func channel(_ t: CGFloat) -> CGFloat {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            let q = l < 0.5 ? l * (1 + s) : l + s - l * s
            let p = 2 * l - q
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        guard s > 0 else { return NSColor(srgbRed: l, green: l, blue: l, alpha: 1) }
        return NSColor(srgbRed: channel(h + 1 / 3), green: channel(h), blue: channel(h - 1 / 3), alpha: 1)
    }

    func background(of scene: BoardScene) -> NSColor {
        color(scene.appState.viewBackgroundColor) ?? (dark ? NSColor(white: 0.07, alpha: 1) : .white)
    }

    static func font(family: Int?, size: CGFloat) -> NSFont {
        switch family {
        case 2: return NSFont(name: "Helvetica Neue", size: size) ?? .systemFont(ofSize: size)
        case 3: return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        default: return NSFont(name: "Chalkboard SE", size: size) ?? NSFont(name: "Marker Felt", size: size) ?? .systemFont(ofSize: size)
        }
    }

    // MARK: Scene

    func draw(_ scene: BoardScene) {
        let byID = Dictionary(scene.elements.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for element in scene.elements where !element.isDeleted {
            if element.type == .image {
                drawImage(element, files: scene.files)
                continue
            }
            draw(element, container: element.containerId.flatMap { byID[$0] })
        }
    }

    /// Decoded pictures, by file id: decoding a data URL on every frame would be slow.
    private static var imageCache: [String: NSImage] = [:]

    static func image(for fileID: String, in files: [String: BoardFile]) -> NSImage? {
        if let cached = imageCache[fileID] { return cached }
        guard let data = files[fileID]?.data, let image = NSImage(data: data) else { return nil }
        imageCache[fileID] = image
        return image
    }

    private func drawImage(_ element: BoardElement, files: [String: BoardFile]) {
        let frame = BoardGeometry.bounds(of: element)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        if element.angle != 0 {
            context.translateBy(x: frame.midX, y: frame.midY)
            context.rotate(by: element.angle)
            context.translateBy(x: -frame.midX, y: -frame.midY)
        }
        context.setAlpha(CGFloat(element.opacity / 100))
        guard let fileID = element.fileId, let image = BoardRenderer.image(for: fileID, in: files) else {
            draw(element)
            return
        }
        image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }

    func draw(_ element: BoardElement, container: BoardElement? = nil) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        let frame = BoardGeometry.bounds(of: element)
        if element.angle != 0, !element.type.isLinear {
            context.translateBy(x: frame.midX, y: frame.midY)
            context.rotate(by: element.angle)
            context.translateBy(x: -frame.midX, y: -frame.midY)
        }
        context.setAlpha(CGFloat(element.opacity / 100))
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { context.endTransparencyLayer() }

        var random = SeededRandom(seed: element.seed)
        switch element.type {
        case .rectangle:
            let path = shapePath(element, frame)
            fill(path, element, &random)
            if element.roundness != nil {
                strokeTwice(element, &random) { r in
                    let jitter = CGFloat(element.roughness) * 0.8
                    return NSBezierPath(roundedRect: frame.offsetBy(dx: r.next() * jitter, dy: r.next() * jitter), xRadius: cornerRadius(frame), yRadius: cornerRadius(frame))
                }
            } else {
                let corners = [CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.maxY), CGPoint(x: frame.minX, y: frame.maxY)]
                strokeTwice(element, &random) { r in roughPolygon(corners, closed: true, element.roughness, &r) }
            }
        case .diamond:
            let corners = diamond(frame)
            fill(shapePath(element, frame), element, &random)
            strokeTwice(element, &random) { r in roughPolygon(corners, closed: true, element.roughness, &r) }
        case .ellipse:
            fill(NSBezierPath(ovalIn: frame), element, &random)
            strokeTwice(element, &random) { r in roughEllipse(frame, element.roughness, &r) }
        case .line, .arrow:
            let points = element.absolutePoints
            guard points.count >= 2 else { return }
            strokeTwice(element, &random) { r in
                points.count == 2 ? roughLine(points[0], points[1], element.roughness, &r) : roughCurve(points, element.roughness, &r)
            }
            if element.type == .arrow {
                drawArrowhead(element.endArrowhead, at: points[points.count - 1], from: points[points.count - 2], element)
                drawArrowhead(element.startArrowhead, at: points[0], from: points[1], element)
            }
        case .freedraw:
            let points = element.absolutePoints
            guard let stroke = color(element.strokeColor) else { return }
            stroke.setStroke()
            stroke.setFill()
            if points.count == 1 {
                let size = CGFloat(element.strokeWidth) * 1.6
                NSBezierPath(ovalIn: NSRect(x: points[0].x - size / 2, y: points[0].y - size / 2, width: size, height: size)).fill()
                return
            }
            let path = smoothPath(points)
            path.lineWidth = CGFloat(element.strokeWidth) * 1.4
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        case .text:
            drawText(element, container: container)
        case .other, .image:
            // Unsupported Excalidraw element (frame…) or a missing picture: a dashed placeholder.
            let path = NSBezierPath(rect: frame)
            path.setLineDash([4, 4], count: 2, phase: 0)
            (color("#868e96") ?? .gray).setStroke()
            path.stroke()
        }
    }

    // MARK: Shapes

    private func cornerRadius(_ frame: CGRect) -> CGFloat {
        min(32, min(frame.width, frame.height) * 0.25)
    }

    private func diamond(_ frame: CGRect) -> [CGPoint] {
        [CGPoint(x: frame.midX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.midY),
         CGPoint(x: frame.midX, y: frame.maxY), CGPoint(x: frame.minX, y: frame.midY)]
    }

    /// Clean outline, used for fills and clipping.
    func shapePath(_ element: BoardElement, _ frame: CGRect) -> NSBezierPath {
        switch element.type {
        case .ellipse:
            return NSBezierPath(ovalIn: frame)
        case .diamond:
            let path = NSBezierPath()
            let corners = diamond(frame)
            path.move(to: corners[0])
            corners.dropFirst().forEach { path.line(to: $0) }
            path.close()
            return path
        default:
            return element.roundness != nil
                ? NSBezierPath(roundedRect: frame, xRadius: cornerRadius(frame), yRadius: cornerRadius(frame))
                : NSBezierPath(rect: frame)
        }
    }

    private func fill(_ path: NSBezierPath, _ element: BoardElement, _ random: inout SeededRandom) {
        guard let fill = color(element.backgroundColor) else { return }
        if element.fillStyle == "solid" {
            fill.setFill()
            path.fill()
            return
        }
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        fill.setStroke()
        let bounds = path.bounds
        let gap = max(5, CGFloat(element.strokeWidth) * 4 + 2)
        let directions: [CGFloat] = element.fillStyle == "cross-hatch" ? [-1, 1] : [-1]
        for direction in directions {
            var offset = -bounds.height
            while offset < bounds.width + bounds.height {
                let a = CGPoint(x: bounds.minX + offset, y: direction < 0 ? bounds.maxY : bounds.minY)
                let b = CGPoint(x: bounds.minX + offset + bounds.height, y: direction < 0 ? bounds.minY : bounds.maxY)
                let line = roughLine(a, b, element.roughness * 0.6, &random)
                line.lineWidth = max(1, CGFloat(element.strokeWidth) * 0.6)
                line.stroke()
                offset += gap
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Strokes a sketchy path twice (once when roughness is 0, "architect").
    private func strokeTwice(_ element: BoardElement, _ random: inout SeededRandom, _ make: (inout SeededRandom) -> NSBezierPath) {
        guard let stroke = color(element.strokeColor) else { return }
        stroke.setStroke()
        let passes = element.roughness > 0 ? 2 : 1
        for _ in 0..<passes {
            let path = make(&random)
            path.lineWidth = CGFloat(element.strokeWidth)
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            switch element.strokeStyle {
            case "dashed": path.setLineDash([8, 8 + CGFloat(element.strokeWidth)], count: 2, phase: 0)
            case "dotted": path.setLineDash([1.5, 6 + CGFloat(element.strokeWidth)], count: 2, phase: 0)
            default: break
            }
            path.stroke()
        }
    }

    // MARK: Hand-drawn primitives

    func roughLine(_ a: CGPoint, _ b: CGPoint, _ roughness: Double, _ random: inout SeededRandom) -> NSBezierPath {
        let path = NSBezierPath()
        let length = hypot(b.x - a.x, b.y - a.y)
        guard roughness > 0, length > 0.5 else {
            path.move(to: a)
            path.line(to: b)
            return path
        }
        let wobble = CGFloat(min(roughness * 1.4, Double(length) * 0.04 + 0.4))
        let bow = CGFloat(min(roughness * Double(length) * 0.012, 5))
        let normal = CGPoint(x: -(b.y - a.y) / length, y: (b.x - a.x) / length)
        let start = CGPoint(x: a.x + random.next() * wobble, y: a.y + random.next() * wobble)
        let end = CGPoint(x: b.x + random.next() * wobble, y: b.y + random.next() * wobble)
        let bend1 = random.next() * bow
        let bend2 = random.next() * bow
        path.move(to: start)
        path.curve(
            to: end,
            controlPoint1: CGPoint(x: start.x + (end.x - start.x) * 0.33 + normal.x * bend1, y: start.y + (end.y - start.y) * 0.33 + normal.y * bend1),
            controlPoint2: CGPoint(x: start.x + (end.x - start.x) * 0.66 + normal.x * bend2, y: start.y + (end.y - start.y) * 0.66 + normal.y * bend2)
        )
        return path
    }

    private func roughPolygon(_ corners: [CGPoint], closed: Bool, _ roughness: Double, _ random: inout SeededRandom) -> NSBezierPath {
        let path = NSBezierPath()
        let pairs = zip(corners, corners.dropFirst() + (closed ? [corners[0]] : []))
        for (a, b) in pairs { path.append(roughLine(a, b, roughness, &random)) }
        return path
    }

    private func roughEllipse(_ frame: CGRect, _ roughness: Double, _ random: inout SeededRandom) -> NSBezierPath {
        let steps = 28
        let start = random.next() * .pi
        let overshoot: CGFloat = roughness > 0 ? 0.18 + abs(random.next()) * 0.2 : 0
        let rx: CGFloat = frame.width / 2
        let ry: CGFloat = frame.height / 2
        var points: [CGPoint] = []
        for index in 0...steps {
            let fraction = CGFloat(index) / CGFloat(steps)
            let angle: CGFloat = start + (2 * .pi + overshoot) * fraction
            let jitter: CGFloat = roughness > 0 ? 1 + random.next() * 0.012 * CGFloat(roughness) : 1
            points.append(CGPoint(x: frame.midX + cos(angle) * rx * jitter, y: frame.midY + sin(angle) * ry * jitter))
        }
        return smoothPath(points)
    }

    private func roughCurve(_ points: [CGPoint], _ roughness: Double, _ random: inout SeededRandom) -> NSBezierPath {
        let wobble = CGFloat(roughness) * 1.2
        return smoothPath(points.map { CGPoint(x: $0.x + random.next() * wobble, y: $0.y + random.next() * wobble) })
    }

    /// Catmull-Rom spline through the points.
    func smoothPath(_ points: [CGPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            points.dropFirst().forEach { path.line(to: $0) }
            return path
        }
        for index in 0..<(points.count - 1) {
            let p0 = points[max(0, index - 1)]
            let p1 = points[index]
            let p2 = points[index + 1]
            let p3 = points[min(points.count - 1, index + 2)]
            path.curve(
                to: p2,
                controlPoint1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                controlPoint2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            )
        }
        return path
    }

    private func drawArrowhead(_ style: String?, at tip: CGPoint, from previous: CGPoint, _ element: BoardElement) {
        guard let style, let stroke = color(element.strokeColor) else { return }
        let length = hypot(tip.x - previous.x, tip.y - previous.y)
        guard length > 0.5 else { return }
        let size = min(max(10, CGFloat(element.strokeWidth) * 4 + 10), length * 0.6, 30)
        let angle = atan2(tip.y - previous.y, tip.x - previous.x)
        let left = CGPoint(x: tip.x - size * cos(angle - 0.45), y: tip.y - size * sin(angle - 0.45))
        let right = CGPoint(x: tip.x - size * cos(angle + 0.45), y: tip.y - size * sin(angle + 0.45))
        stroke.setStroke()
        stroke.setFill()
        let path = NSBezierPath()
        path.lineWidth = CGFloat(element.strokeWidth)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        switch style {
        case "triangle":
            path.move(to: tip)
            path.line(to: left)
            path.line(to: right)
            path.close()
            path.fill()
            path.stroke()
        case "dot", "circle":
            let radius = size * 0.35
            let dot = NSBezierPath(ovalIn: NSRect(x: tip.x - radius, y: tip.y - radius, width: radius * 2, height: radius * 2))
            dot.fill()
        case "bar":
            let half = size * 0.5
            path.move(to: CGPoint(x: tip.x + half * sin(angle), y: tip.y - half * cos(angle)))
            path.line(to: CGPoint(x: tip.x - half * sin(angle), y: tip.y + half * cos(angle)))
            path.stroke()
        default:
            path.move(to: left)
            path.line(to: tip)
            path.line(to: right)
            path.stroke()
        }
    }

    // MARK: Text

    static func textAttributes(_ element: BoardElement, color: NSColor) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        switch element.textAlign {
        case "center": style.alignment = .center
        case "right": style.alignment = .right
        default: style.alignment = .left
        }
        let size = CGFloat(element.fontSize ?? 20)
        style.minimumLineHeight = size * CGFloat(element.lineHeight ?? 1.25)
        style.maximumLineHeight = style.minimumLineHeight
        return [.font: font(family: element.fontFamily, size: size), .foregroundColor: color, .paragraphStyle: style]
    }

    /// Size of a text element's content, in scene units.
    static func measure(_ element: BoardElement) -> CGSize {
        let text = (element.text ?? "").isEmpty ? " " : element.text ?? " "
        let size = (text as NSString).boundingRect(with: CGSize(width: 10_000, height: 10_000), options: [.usesLineFragmentOrigin], attributes: textAttributes(element, color: .black)).size
        return CGSize(width: ceil(size.width) + 2, height: ceil(size.height))
    }

    private func drawText(_ element: BoardElement, container: BoardElement?) {
        guard let text = element.text, !text.isEmpty, let ink = color(element.strokeColor) else { return }
        var bound = element
        if container != nil { bound.textAlign = "center" }
        let size = BoardRenderer.measure(bound)
        var origin = CGPoint(x: element.x, y: element.y)
        if let container {
            let frame = BoardGeometry.bounds(of: container)
            origin = CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2)
        }
        (text as NSString).draw(with: CGRect(origin: origin, size: size), options: [.usesLineFragmentOrigin], attributes: BoardRenderer.textAttributes(bound, color: ink))
    }

    // MARK: Export

    /// Vector PDF of the whole board, one page sized to its content.
    static func pdf(_ scene: BoardScene, dark: Bool = false, padding: CGFloat = 32) -> Data? {
        guard let content = BoardGeometry.bounds(of: scene.visible) else { return nil }
        let frame = content.insetBy(dx: -padding, dy: -padding)
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: frame.size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let cg = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        cg.beginPDFPage(nil)
        cg.translateBy(x: 0, y: frame.height)
        cg.scaleBy(x: 1, y: -1)
        cg.translateBy(x: -frame.minX, y: -frame.minY)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        let renderer = BoardRenderer(dark: dark)
        renderer.background(of: scene).setFill()
        frame.fill()
        renderer.draw(scene)
        NSGraphicsContext.restoreGraphicsState()
        cg.endPDFPage()
        cg.closePDF()
        return data as Data
    }

    /// PNG of the given elements (or the whole scene), 2×, with padding and background.
    static func png(_ scene: BoardScene, only ids: Set<String>? = nil, dark: Bool = false, padding: CGFloat = 32) -> Data? {
        var subset = scene
        if let ids, !ids.isEmpty {
            subset.elements = scene.elements.filter { ids.contains($0.id) || ($0.containerId.map(ids.contains) ?? false) }
        }
        guard let content = BoardGeometry.bounds(of: subset.visible) else { return nil }
        let frame = content.insetBy(dx: -padding, dy: -padding)
        let scale: CGFloat = 2
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(frame.width * scale), pixelsHigh: Int(frame.height * scale),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        let cg = context.cgContext
        cg.translateBy(x: 0, y: frame.height * scale)
        cg.scaleBy(x: scale, y: -scale)
        cg.translateBy(x: -frame.minX, y: -frame.minY)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        let renderer = BoardRenderer(dark: dark)
        renderer.background(of: scene).setFill()
        frame.fill()
        renderer.draw(subset)
        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = frame.size
        return bitmap.representation(using: .png, properties: [:])
    }
}
