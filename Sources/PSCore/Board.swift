import Foundation

/// Whiteboard model, stored in Excalidraw's own JSON format (`.excalidraw`), so boards
/// open on excalidraw.com and the other way round. Unknown fields fall back to defaults.
public struct BoardElement: Codable, Equatable {
    public enum Kind: String, Codable {
        case rectangle, ellipse, diamond, arrow, line, freedraw, text, image
        case other

        public init(from decoder: Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .other
        }

        public var isLinear: Bool { self == .arrow || self == .line || self == .freedraw }
        public var isShape: Bool { self == .rectangle || self == .ellipse || self == .diamond }
    }

    public struct Binding: Codable, Equatable {
        public var elementId: String
        public var focus: Double = 0
        public var gap: Double = 4

        public init(elementId: String) {
            self.elementId = elementId
        }
    }

    public struct BoundElement: Codable, Equatable {
        public var id: String
        public var type: String

        public init(id: String, type: String) {
            self.id = id
            self.type = type
        }
    }

    public struct Roundness: Codable, Equatable {
        public var type: Int

        public init(type: Int) {
            self.type = type
        }
    }

    public var id: String
    public var type: Kind
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var angle: Double = 0
    public var strokeColor = "#1e1e1e"
    public var backgroundColor = "transparent"
    public var fillStyle = "solid"
    public var strokeWidth: Double = 2
    public var strokeStyle = "solid"
    public var roughness: Double = 1
    public var opacity: Double = 100
    public var seed: Int
    public var roundness: Roundness?
    public var groupIds: [String] = []
    public var boundElements: [BoundElement]?
    public var isDeleted = false
    public var locked = false
    public var version = 1
    public var versionNonce: Int
    public var updated: Int
    /// Linear elements: points relative to (x, y).
    public var points: [[Double]]?
    public var startBinding: Binding?
    public var endBinding: Binding?
    public var startArrowhead: String?
    public var endArrowhead: String?
    public var text: String?
    public var originalText: String?
    public var fontSize: Double?
    public var fontFamily: Int?
    public var textAlign: String?
    public var verticalAlign: String?
    public var containerId: String?
    public var lineHeight: Double?
    /// Images: the key of the picture in the scene's `files`.
    public var fileId: String?

    public init(type: Kind, x: Double, y: Double, width: Double = 0, height: Double = 0) {
        id = BoardElement.newID()
        self.type = type
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        seed = Int.random(in: 1...2_000_000_000)
        versionNonce = Int.random(in: 1...2_000_000_000)
        updated = Int(Date().timeIntervalSince1970 * 1000)
        if type == .rectangle || type == .diamond { roundness = Roundness(type: 3) }
        if type.isLinear { points = [[0, 0]] }
        if type == .arrow { endArrowhead = "arrow" }
        if type == .text {
            text = ""
            originalText = ""
            fontSize = 20
            fontFamily = 1
            textAlign = "left"
            verticalAlign = "top"
            lineHeight = 1.25
        }
    }

    public static func newID() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        return String((0..<21).map { _ in alphabet.randomElement()! })
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, x, y, width, height, angle, strokeColor, backgroundColor, fillStyle, strokeWidth
        case strokeStyle, roughness, opacity, seed, roundness, groupIds, boundElements, isDeleted, locked
        case version, versionNonce, updated, points, startBinding, endBinding, startArrowhead, endArrowhead
        case text, originalText, fontSize, fontFamily, textAlign, verticalAlign, containerId, lineHeight
        case frameId, link, simulatePressure, pressures, baseline, fileId, status, scale
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? BoardElement.newID()
        type = try c.decodeIfPresent(Kind.self, forKey: .type) ?? .other
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 0
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? 0
        angle = try c.decodeIfPresent(Double.self, forKey: .angle) ?? 0
        strokeColor = try c.decodeIfPresent(String.self, forKey: .strokeColor) ?? "#1e1e1e"
        backgroundColor = try c.decodeIfPresent(String.self, forKey: .backgroundColor) ?? "transparent"
        fillStyle = try c.decodeIfPresent(String.self, forKey: .fillStyle) ?? "solid"
        strokeWidth = try c.decodeIfPresent(Double.self, forKey: .strokeWidth) ?? 2
        strokeStyle = try c.decodeIfPresent(String.self, forKey: .strokeStyle) ?? "solid"
        roughness = try c.decodeIfPresent(Double.self, forKey: .roughness) ?? 1
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 100
        seed = try c.decodeIfPresent(Int.self, forKey: .seed) ?? Int.random(in: 1...2_000_000_000)
        roundness = try c.decodeIfPresent(Roundness.self, forKey: .roundness)
        groupIds = try c.decodeIfPresent([String].self, forKey: .groupIds) ?? []
        boundElements = try c.decodeIfPresent([BoundElement].self, forKey: .boundElements)
        isDeleted = try c.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        versionNonce = try c.decodeIfPresent(Int.self, forKey: .versionNonce) ?? 0
        updated = try c.decodeIfPresent(Int.self, forKey: .updated) ?? 0
        points = try c.decodeIfPresent([[Double]].self, forKey: .points)
        startBinding = try? c.decodeIfPresent(Binding.self, forKey: .startBinding)
        endBinding = try? c.decodeIfPresent(Binding.self, forKey: .endBinding)
        startArrowhead = try c.decodeIfPresent(String.self, forKey: .startArrowhead)
        endArrowhead = try c.decodeIfPresent(String.self, forKey: .endArrowhead)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        originalText = try c.decodeIfPresent(String.self, forKey: .originalText)
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize)
        fontFamily = try c.decodeIfPresent(Int.self, forKey: .fontFamily)
        textAlign = try c.decodeIfPresent(String.self, forKey: .textAlign)
        verticalAlign = try c.decodeIfPresent(String.self, forKey: .verticalAlign)
        containerId = try c.decodeIfPresent(String.self, forKey: .containerId)
        lineHeight = try c.decodeIfPresent(Double.self, forKey: .lineHeight)
        fileId = try c.decodeIfPresent(String.self, forKey: .fileId)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(type == .other ? "rectangle" : type.rawValue, forKey: .type)
        try c.encode(x, forKey: .x)
        try c.encode(y, forKey: .y)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(angle, forKey: .angle)
        try c.encode(strokeColor, forKey: .strokeColor)
        try c.encode(backgroundColor, forKey: .backgroundColor)
        try c.encode(fillStyle, forKey: .fillStyle)
        try c.encode(strokeWidth, forKey: .strokeWidth)
        try c.encode(strokeStyle, forKey: .strokeStyle)
        try c.encode(roughness, forKey: .roughness)
        try c.encode(opacity, forKey: .opacity)
        try c.encode(seed, forKey: .seed)
        try c.encode(roundness, forKey: .roundness)
        try c.encode(groupIds, forKey: .groupIds)
        try c.encode(boundElements, forKey: .boundElements)
        try c.encode(isDeleted, forKey: .isDeleted)
        try c.encode(locked, forKey: .locked)
        try c.encode(version, forKey: .version)
        try c.encode(versionNonce, forKey: .versionNonce)
        try c.encode(updated, forKey: .updated)
        try c.encodeNil(forKey: .frameId)
        try c.encodeNil(forKey: .link)
        if type.isLinear {
            try c.encode(points ?? [[0, 0]], forKey: .points)
            if type == .freedraw {
                try c.encode(true, forKey: .simulatePressure)
                try c.encode([Double](), forKey: .pressures)
            } else {
                try c.encode(startBinding, forKey: .startBinding)
                try c.encode(endBinding, forKey: .endBinding)
                try c.encode(startArrowhead, forKey: .startArrowhead)
                try c.encode(endArrowhead, forKey: .endArrowhead)
            }
        }
        if type == .image {
            try c.encode(fileId, forKey: .fileId)
            try c.encode("saved", forKey: .status)
            try c.encode([1.0, 1.0], forKey: .scale)
        }
        if type == .text {
            try c.encode(text ?? "", forKey: .text)
            try c.encode(originalText ?? text ?? "", forKey: .originalText)
            try c.encode(fontSize ?? 20, forKey: .fontSize)
            try c.encode(fontFamily ?? 1, forKey: .fontFamily)
            try c.encode(textAlign ?? "left", forKey: .textAlign)
            try c.encode(verticalAlign ?? "top", forKey: .verticalAlign)
            try c.encode(containerId, forKey: .containerId)
            try c.encode(lineHeight ?? 1.25, forKey: .lineHeight)
            try c.encode(Double(fontSize ?? 20) * 0.9, forKey: .baseline)
        }
    }

    /// Absolute points of a linear element.
    public var absolutePoints: [CGPoint] {
        (points ?? [[0, 0]]).map { CGPoint(x: x + ($0.first ?? 0), y: y + ($0.count > 1 ? $0[1] : 0)) }
    }

    public mutating func setAbsolutePoints(_ list: [CGPoint]) {
        guard let first = list.first else { return }
        x = first.x
        y = first.y
        points = list.map { [$0.x - first.x, $0.y - first.y] }
        let xs = list.map(\.x)
        let ys = list.map(\.y)
        width = (xs.max() ?? 0) - (xs.min() ?? 0)
        height = (ys.max() ?? 0) - (ys.min() ?? 0)
    }

    public mutating func touch() {
        version += 1
        versionNonce = Int.random(in: 1...2_000_000_000)
        updated = Int(Date().timeIntervalSince1970 * 1000)
    }
}

public struct BoardScene: Codable, Equatable {
    public struct AppState: Codable, Equatable {
        public var viewBackgroundColor = "#ffffff"
        public var gridSize: Int?

        public init() {}
    }

    public var type = "excalidraw"
    public var version = 2
    public var source = "https://github.com/markuz899/ps"
    public var elements: [BoardElement] = []
    public var appState = AppState()
    /// Pictures used by image elements, embedded as data URLs (Excalidraw's `files`).
    public var files: [String: BoardFile] = [:]

    public init(elements: [BoardElement] = []) {
        self.elements = elements
    }

    private enum CodingKeys: String, CodingKey {
        case type, version, source, elements, appState, files
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "excalidraw"
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 2
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        elements = try c.decodeIfPresent([BoardElement].self, forKey: .elements) ?? []
        appState = (try? c.decodeIfPresent(AppState.self, forKey: .appState)) ?? AppState()
        files = (try? c.decodeIfPresent([String: BoardFile].self, forKey: .files)) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(version, forKey: .version)
        try c.encode(source, forKey: .source)
        try c.encode(elements, forKey: .elements)
        try c.encode(appState, forKey: .appState)
        // Only the pictures still used: deleting an image drops its data too.
        let used = Set(elements.compactMap { $0.isDeleted ? nil : $0.fileId })
        try c.encode(files.filter { used.contains($0.key) }, forKey: .files)
    }

    public static func decode(_ data: Data) throws -> BoardScene {
        try JSONDecoder().decode(BoardScene.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public var visible: [BoardElement] { elements.filter { !$0.isDeleted } }

    public func index(of id: String) -> Int? {
        elements.firstIndex { $0.id == id }
    }

    /// Excalidraw's clipboard payload, so copied elements paste into excalidraw.com.
    public static func clipboardJSON(_ elements: [BoardElement], files: [String: BoardFile] = [:]) -> String? {
        struct Clip: Encodable {
            let type = "excalidraw/clipboard"
            let elements: [BoardElement]
            let files: [String: BoardFile]
        }
        let used = Set(elements.compactMap(\.fileId))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(Clip(elements: elements, files: files.filter { used.contains($0.key) })) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func elements(fromClipboard text: String) -> [BoardElement]? {
        clipboardContent(text)?.elements
    }

    public static func clipboardContent(_ text: String) -> (elements: [BoardElement], files: [String: BoardFile])? {
        struct Clip: Decodable { let type: String?; let elements: [BoardElement]; let files: [String: BoardFile]? }
        guard let data = text.data(using: .utf8), let clip = try? JSONDecoder().decode(Clip.self, from: data),
              clip.type == nil || clip.type == "excalidraw/clipboard" || clip.type == "excalidraw" else { return nil }
        return (clip.elements, clip.files ?? [:])
    }

    /// Adds a picture and an image element showing it, fitted within `maxSide`.
    @discardableResult
    public mutating func addImage(data: Data, mimeType: String, size: CGSize, center: CGPoint, maxSide: Double = 480) -> BoardElement {
        let id = BoardElement.newID()
        files[id] = BoardFile(id: id, mimeType: mimeType, data: data)
        let scale = min(1, maxSide / max(size.width, size.height, 1))
        let width = max(8, size.width * scale)
        let height = max(8, size.height * scale)
        var element = BoardElement(type: .image, x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
        element.fileId = id
        element.roundness = nil
        element.strokeColor = "transparent"
        elements.append(element)
        return element
    }
}

/// A picture embedded in a board, as Excalidraw stores it.
public struct BoardFile: Codable, Equatable {
    public var id: String
    public var mimeType: String
    public var dataURL: String
    public var created: Int

    public init(id: String, mimeType: String, data: Data) {
        self.id = id
        self.mimeType = mimeType
        dataURL = "data:\(mimeType);base64," + data.base64EncodedString()
        created = Int(Date().timeIntervalSince1970 * 1000)
    }

    /// The decoded bytes of the data URL.
    public var data: Data? {
        guard let comma = dataURL.firstIndex(of: ",") else { return nil }
        return Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]))
    }
}

/// Geometry used for hit testing, selection and arrow binding.
public enum BoardGeometry {
    public static func bounds(of element: BoardElement) -> CGRect {
        if element.type.isLinear {
            let points = element.absolutePoints
            let xs = points.map(\.x)
            let ys = points.map(\.y)
            return CGRect(x: xs.min() ?? element.x, y: ys.min() ?? element.y,
                          width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
        }
        return CGRect(x: element.x, y: element.y, width: element.width, height: element.height).standardized
    }

    public static func bounds(of elements: [BoardElement]) -> CGRect? {
        var result: CGRect?
        for element in elements {
            let frame = bounds(of: element)
            result = result.map { $0.union(frame) } ?? frame
        }
        return result
    }

    static func distance(_ point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> Double {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }

    /// Outline (or inside, for filled shapes and text) within `tolerance` of the point.
    public static func hits(_ element: BoardElement, _ point: CGPoint, tolerance: Double) -> Bool {
        let frame = bounds(of: element)
        guard frame.insetBy(dx: -tolerance - element.strokeWidth, dy: -tolerance - element.strokeWidth).contains(point) else { return false }
        let filled = element.backgroundColor != "transparent"
        switch element.type {
        case .text, .other, .image:
            return true
        case .arrow, .line, .freedraw:
            let points = element.absolutePoints
            if points.count == 1 { return hypot(point.x - points[0].x, point.y - points[0].y) <= tolerance }
            return zip(points, points.dropFirst()).contains { distance(point, toSegment: $0, $1) <= tolerance + element.strokeWidth }
        case .rectangle:
            if filled, frame.contains(point) { return true }
            let inner = frame.insetBy(dx: tolerance, dy: tolerance)
            return !(inner.width > 0 && inner.height > 0 && inner.contains(point))
        case .ellipse:
            let rx = max(frame.width / 2, 0.5)
            let ry = max(frame.height / 2, 0.5)
            let nx: Double = (point.x - frame.midX) / rx
            let ny: Double = (point.y - frame.midY) / ry
            let r: Double = (nx * nx + ny * ny).squareRoot()
            if filled, r <= 1 { return true }
            let radius: Double = min(rx, ry)
            return abs(r - 1) * radius <= tolerance
        case .diamond:
            let nx = abs(point.x - frame.midX) / max(frame.width / 2, 0.5)
            let ny = abs(point.y - frame.midY) / max(frame.height / 2, 0.5)
            let r = nx + ny
            if filled, r <= 1 { return true }
            let halfSide: Double = min(frame.width, frame.height) / 2
            return abs(r - 1) * halfSide <= tolerance
        }
    }

    /// Topmost element under the point (later elements are drawn above earlier ones).
    public static func element(at point: CGPoint, in scene: BoardScene, tolerance: Double) -> BoardElement? {
        scene.elements.reversed().first { !$0.isDeleted && $0.containerId == nil && hits($0, point, tolerance: tolerance) }
    }

    public static func isBindable(_ element: BoardElement) -> Bool {
        element.type.isShape || element.type == .text || element.type == .image
    }

    /// Where an arrow should touch `element` when coming from `outside`: on its outline,
    /// along the line to its centre, `gap` away from it.
    public static func attachmentPoint(on element: BoardElement, from outside: CGPoint, gap: Double = 4) -> CGPoint {
        let frame = bounds(of: element)
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let dx = outside.x - center.x
        let dy = outside.y - center.y
        let length = hypot(dx, dy)
        guard length > 0.001 else { return center }
        let ux = dx / length
        let uy = dy / length
        let a = max(frame.width / 2, 0.5)
        let b = max(frame.height / 2, 0.5)
        let t: Double
        switch element.type {
        case .ellipse:
            let denominator: Double = (ux * ux) / (a * a) + (uy * uy) / (b * b)
            t = 1 / denominator.squareRoot()
        case .diamond:
            t = 1 / (abs(ux) / a + abs(uy) / b)
        default:
            t = min(abs(ux) > 0 ? a / abs(ux) : .infinity, abs(uy) > 0 ? b / abs(uy) : .infinity)
        }
        let distance = min(t + gap, length)
        return CGPoint(x: center.x + ux * distance, y: center.y + uy * distance)
    }

    /// Re-routes every arrow bound to one of `moved` so its ends stay on the shapes.
    public static func updateBindings(in scene: inout BoardScene, moved: Set<String>) {
        for index in scene.elements.indices where scene.elements[index].type == .arrow || scene.elements[index].type == .line {
            var arrow = scene.elements[index]
            let startID = arrow.startBinding?.elementId
            let endID = arrow.endBinding?.elementId
            guard startID.map(moved.contains) == true || endID.map(moved.contains) == true else { continue }
            var points = arrow.absolutePoints
            guard points.count >= 2 else { continue }
            let start = startID.flatMap { id in scene.elements.first { $0.id == id && !$0.isDeleted } }
            let end = endID.flatMap { id in scene.elements.first { $0.id == id && !$0.isDeleted } }
            let startFrame = start.map(bounds(of:))
            let endFrame = end.map(bounds(of:))
            let startTarget = endFrame.map { CGPoint(x: $0.midX, y: $0.midY) } ?? points[points.count - 2]
            let endTarget = startFrame.map { CGPoint(x: $0.midX, y: $0.midY) } ?? points[1]
            if let start { points[0] = attachmentPoint(on: start, from: points.count > 2 ? points[1] : startTarget, gap: arrow.startBinding?.gap ?? 4) }
            if let end { points[points.count - 1] = attachmentPoint(on: end, from: points.count > 2 ? points[points.count - 2] : endTarget, gap: arrow.endBinding?.gap ?? 4) }
            arrow.setAbsolutePoints(points)
            arrow.touch()
            scene.elements[index] = arrow
        }
    }
}

/// Deterministic randomness for the hand-drawn look: the same seed draws the same wobble.
public struct SeededRandom {
    private var state: UInt64

    public init(seed: Int) {
        state = UInt64(truncatingIfNeeded: seed) &* 6364136223846793005 &+ 1442695040888963407
        if state == 0 { state = 0x9E3779B97F4A7C15 }
    }

    /// Uniform in [-1, 1].
    public mutating func next() -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Double(state % 2_000_001) / 1_000_000 - 1
    }
}
