import Foundation

/// Ready-made pieces for architecture and flow diagrams. Each one is a group of plain
/// Excalidraw elements (shapes, lines, text), so it stays editable and opens anywhere.
public enum BoardLibrary {
    public struct Item {
        public let id: String
        public let name: String
        /// Builds the item with its top-left corner at the origin; callers move it.
        public let build: () -> [BoardElement]
    }

    public static let items: [Item] = [
        Item(id: "database", name: "Database", build: database),
        Item(id: "server", name: "Server", build: server),
        Item(id: "user", name: "User", build: user),
        Item(id: "queue", name: "Queue", build: queue),
        Item(id: "cloud", name: "Cloud", build: cloud),
        Item(id: "browser", name: "Browser", build: browser),
        Item(id: "phone", name: "Phone", build: phone),
        Item(id: "document", name: "Document", build: document),
        Item(id: "note", name: "Sticky note", build: note),
    ]

    /// The item centred on `center`, grouped, with fresh ids.
    public static func make(_ item: Item, at center: CGPoint, stroke: String = "#1e1e1e", roughness: Double = 1) -> [BoardElement] {
        var elements = item.build()
        guard let frame = BoardGeometry.bounds(of: elements) else { return [] }
        let dx = center.x - frame.midX
        let dy = center.y - frame.midY
        let group = BoardElement.newID()
        for index in elements.indices {
            if elements[index].type.isLinear {
                elements[index].setAbsolutePoints(elements[index].absolutePoints.map { CGPoint(x: $0.x + dx, y: $0.y + dy) })
            } else {
                elements[index].x += dx
                elements[index].y += dy
            }
            if elements[index].strokeColor == "#1e1e1e" { elements[index].strokeColor = stroke }
            elements[index].roughness = roughness
            elements[index].groupIds = [group]
        }
        return elements
    }

    // MARK: Builders

    private static func shape(_ kind: BoardElement.Kind, _ x: Double, _ y: Double, _ w: Double, _ h: Double, fill: String = "transparent", rounded: Bool = true) -> BoardElement {
        var element = BoardElement(type: kind, x: x, y: y, width: w, height: h)
        element.backgroundColor = fill
        element.fillStyle = "solid"
        if kind == .rectangle || kind == .diamond { element.roundness = rounded ? .init(type: 3) : nil }
        return element
    }

    private static func line(_ points: [CGPoint], width: Double = 2) -> BoardElement {
        var element = BoardElement(type: .line, x: 0, y: 0)
        element.setAbsolutePoints(points)
        element.strokeWidth = width
        return element
    }

    private static func text(_ string: String, _ x: Double, _ y: Double, size: Double = 16) -> BoardElement {
        var element = BoardElement(type: .text, x: x, y: y)
        element.text = string
        element.originalText = string
        element.fontSize = size
        element.width = Double(string.count) * size * 0.55
        element.height = size * 1.25
        return element
    }

    /// Points along an ellipse arc from `start` to `end` (radians), for curved lines.
    private static func arc(cx: Double, cy: Double, rx: Double, ry: Double, from start: Double, to end: Double, steps: Int = 12) -> [CGPoint] {
        (0...steps).map { step in
            let angle = start + (end - start) * Double(step) / Double(steps)
            return CGPoint(x: cx + cos(angle) * rx, y: cy + sin(angle) * ry)
        }
    }

    private static func database() -> [BoardElement] {
        let w = 120.0, h = 130.0, cap = 30.0
        return [
            shape(.ellipse, 0, 0, w, cap, fill: "#a5d8ff"),
            line([CGPoint(x: 0, y: cap / 2), CGPoint(x: 0, y: h - cap / 2)]),
            line([CGPoint(x: w, y: cap / 2), CGPoint(x: w, y: h - cap / 2)]),
            line(arc(cx: w / 2, cy: h - cap / 2, rx: w / 2, ry: cap / 2, from: 0, to: .pi)),
            line(arc(cx: w / 2, cy: h / 2, rx: w / 2, ry: cap / 2, from: 0, to: .pi), width: 1),
        ]
    }

    private static func server() -> [BoardElement] {
        var elements = [shape(.rectangle, 0, 0, 110, 140, fill: "#e9ecef")]
        for row in 0..<3 {
            let y = 30.0 + Double(row) * 38
            elements.append(line([CGPoint(x: 16, y: y), CGPoint(x: 70, y: y)]))
            elements.append(shape(.ellipse, 82, y - 6, 12, 12, fill: row == 0 ? "#2f9e44" : "#adb5bd"))
        }
        return elements
    }

    private static func user() -> [BoardElement] {
        [
            shape(.ellipse, 30, 0, 50, 50, fill: "#ffec99"),
            line(arc(cx: 55, cy: 110, rx: 50, ry: 50, from: .pi, to: 2 * .pi)),
            line([CGPoint(x: 5, y: 110), CGPoint(x: 105, y: 110)]),
        ]
    }

    private static func queue() -> [BoardElement] {
        var elements = [shape(.rectangle, 0, 0, 180, 60, fill: "#d0bfff", rounded: false)]
        for column in 1..<4 {
            let x = Double(column) * 45
            elements.append(line([CGPoint(x: x, y: 0), CGPoint(x: x, y: 60)]))
        }
        return elements
    }

    private static func cloud() -> [BoardElement] {
        [
            shape(.ellipse, 0, 30, 80, 60, fill: "#ffffff"),
            shape(.ellipse, 40, 0, 90, 80, fill: "#ffffff"),
            shape(.ellipse, 100, 25, 80, 65, fill: "#ffffff"),
            shape(.rectangle, 30, 55, 120, 35, fill: "#ffffff", rounded: true),
        ]
    }

    private static func browser() -> [BoardElement] {
        [
            shape(.rectangle, 0, 0, 220, 150, fill: "#ffffff"),
            line([CGPoint(x: 0, y: 28), CGPoint(x: 220, y: 28)]),
            shape(.ellipse, 10, 9, 10, 10, fill: "#ff8787"),
            shape(.ellipse, 26, 9, 10, 10, fill: "#ffd43b"),
            shape(.ellipse, 42, 9, 10, 10, fill: "#69db7c"),
            shape(.rectangle, 64, 7, 140, 14, fill: "#f1f3f5"),
        ]
    }

    private static func phone() -> [BoardElement] {
        [
            shape(.rectangle, 0, 0, 80, 150, fill: "#ffffff"),
            line([CGPoint(x: 28, y: 12), CGPoint(x: 52, y: 12)]),
            shape(.ellipse, 34, 128, 12, 12),
        ]
    }

    private static func document() -> [BoardElement] {
        [
            line([CGPoint(x: 0, y: 0), CGPoint(x: 80, y: 0), CGPoint(x: 110, y: 30), CGPoint(x: 110, y: 140), CGPoint(x: 0, y: 140), CGPoint(x: 0, y: 0)]),
            line([CGPoint(x: 80, y: 0), CGPoint(x: 80, y: 30), CGPoint(x: 110, y: 30)]),
            line([CGPoint(x: 18, y: 60), CGPoint(x: 92, y: 60)], width: 1),
            line([CGPoint(x: 18, y: 82), CGPoint(x: 92, y: 82)], width: 1),
            line([CGPoint(x: 18, y: 104), CGPoint(x: 70, y: 104)], width: 1),
        ]
    }

    private static func note() -> [BoardElement] {
        var sticky = shape(.rectangle, 0, 0, 150, 120, fill: "#ffec99", rounded: false)
        sticky.strokeColor = "#f08c00"
        return [sticky, text("Note", 16, 14, size: 20)]
    }
}
