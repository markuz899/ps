import AppKit
import PSCore

/// Current drawing properties: applied to new elements and to the selection.
struct BoardStyle {
    var strokeColor = "#1e1e1e"
    var backgroundColor = "transparent"
    var fillStyle = "hachure"
    var strokeWidth: Double = 2
    var strokeStyle = "solid"
    var roughness: Double = 1
    var opacity: Double = 100
    var rounded = true
    var fontSize: Double = 20
    var fontFamily = 1
    var endArrowhead: String? = "arrow"
}

/// The infinite canvas: tools, selection, moving, resizing, arrows that stick to shapes,
/// text editing, zoom and pan. The scene lives in the Document; every change goes
/// through `change(_:)`, which records undo and marks the document modified.
final class BoardCanvas: NSView, NSTextViewDelegate {
    enum Tool: Int, CaseIterable {
        case hand, select, rectangle, diamond, ellipse, arrow, line, draw, text, eraser
    }

    private enum Handle {
        case corner(Int)
        case point(Int)
    }

    private enum Interaction {
        case none
        case creating(id: String, origin: CGPoint)
        case drawing(id: String)
        case moving(start: CGPoint, originals: [String: BoardElement], moved: Bool)
        case resizing(id: String, corner: Int, original: BoardElement)
        case movingPoint(id: String, index: Int)
        case marquee(start: CGPoint, current: CGPoint)
        case panning(start: CGPoint, origin: CGPoint)
        case erasing
    }

    unowned let document: Document
    var tool = Tool.select {
        didSet {
            if tool != .select && tool != .hand && tool != .eraser { selection = [] }
            window?.invalidateCursorRects(for: self)
            onToolChange?()
        }
    }
    var style = BoardStyle()
    private(set) var selection: Set<String> = [] {
        didSet { if selection != oldValue { onSelectionChange?() } }
    }
    private(set) var offset = CGPoint(x: 0, y: 0)
    private(set) var zoom: CGFloat = 1
    var onChange: (() -> Void)?
    var onSelectionChange: (() -> Void)?
    var onToolChange: (() -> Void)?
    var onZoomChange: (() -> Void)?

    private var interaction = Interaction.none
    private var spacePanning = false
    private var textEditor: NSTextView?
    private var editingID: String?
    private var editingIsNew = false
    private var undoRecorded = false

    var scene: BoardScene {
        get { document.board }
        set { document.board = newValue }
    }

    init(document: Document) {
        self.document = document
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        setAccessibilityElement(true)
        setAccessibilityRole(.layoutArea)
        setAccessibilityLabel(L("Whiteboard"))
        centerContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var undoManager: UndoManager? { document.undoManager }

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    // MARK: Coordinates

    func scenePoint(_ view: CGPoint) -> CGPoint {
        CGPoint(x: (view.x - offset.x) / zoom, y: (view.y - offset.y) / zoom)
    }

    func viewPoint(_ scene: CGPoint) -> CGPoint {
        CGPoint(x: scene.x * zoom + offset.x, y: scene.y * zoom + offset.y)
    }

    func viewRect(_ rect: CGRect) -> CGRect {
        CGRect(origin: viewPoint(rect.origin), size: CGSize(width: rect.width * zoom, height: rect.height * zoom))
    }

    private func scenePoint(_ event: NSEvent) -> CGPoint {
        scenePoint(convert(event.locationInWindow, from: nil))
    }

    /// Opens on the content, or with the origin near the top left for a new board.
    func centerContent() {
        if let bounds = BoardGeometry.bounds(of: scene.visible), bounds.width > 0 || bounds.height > 0 {
            offset = CGPoint(x: self.bounds.midX - bounds.midX * zoom, y: self.bounds.midY - bounds.midY * zoom)
        } else {
            offset = CGPoint(x: 40, y: 40)
        }
        needsDisplay = true
    }

    func setZoom(_ value: CGFloat, around viewAnchor: CGPoint? = nil) {
        let anchor = viewAnchor ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let before = scenePoint(anchor)
        zoom = min(max(value, 0.1), 8)
        offset = CGPoint(x: anchor.x - before.x * zoom, y: anchor.y - before.y * zoom)
        repositionTextEditor()
        needsDisplay = true
        onZoomChange?()
    }

    func zoomToFit() {
        guard let content = BoardGeometry.bounds(of: scene.visible), content.width > 0 || content.height > 0 else {
            setZoom(1)
            return
        }
        let fit = min(bounds.width / (content.width + 160), bounds.height / (content.height + 160))
        zoom = min(max(fit, 0.1), 2)
        offset = CGPoint(x: bounds.midX - content.midX * zoom, y: bounds.midY - content.midY * zoom)
        needsDisplay = true
        onZoomChange?()
    }

    // MARK: Changes & undo

    /// Applies a change to the scene as one undo step.
    func change(_ body: (inout BoardScene) -> Void) {
        if !undoRecorded { recordUndo() }
        var copy = scene
        body(&copy)
        scene = copy
        needsDisplay = true
        onChange?()
    }

    private func recordUndo() {
        let snapshot = scene
        let selected = selection
        document.undoManager.registerUndo(withTarget: self) { canvas in canvas.restore(snapshot, selection: selected) }
        document.undoManager.setActionName(L("Whiteboard Change"))
    }

    private func restore(_ snapshot: BoardScene, selection selected: Set<String>) {
        let current = scene
        let currentSelection = selection
        document.undoManager.registerUndo(withTarget: self) { canvas in canvas.restore(current, selection: currentSelection) }
        scene = snapshot
        selection = selected.filter { id in snapshot.elements.contains { $0.id == id && !$0.isDeleted } }
        needsDisplay = true
        onChange?()
    }

    /// Several changes during one drag count as one undo step.
    private func beginGesture() {
        recordUndo()
        undoRecorded = true
    }

    private func endGesture() {
        undoRecorded = false
    }

    private func element(_ id: String) -> BoardElement? {
        scene.elements.first { $0.id == id }
    }

    private func update(_ id: String, in scene: inout BoardScene, _ body: (inout BoardElement) -> Void) {
        guard let index = scene.index(of: id) else { return }
        body(&scene.elements[index])
        scene.elements[index].touch()
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let renderer = BoardRenderer(dark: isDark)
        renderer.background(of: scene).setFill()
        dirtyRect.fill()
        drawGrid(dirtyRect)

        if scene.visible.isEmpty, textEditor == nil {
            let hint = L("Pick a tool above and start drawing — double-click anywhere to write.") as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: BoardRenderer.font(family: 1, size: 17),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
            let size = hint.size(withAttributes: attributes)
            hint.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
        }

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: offset.x, y: offset.y)
        context.scaleBy(x: zoom, y: zoom)
        var visible = scene
        if let editingID { visible.elements.removeAll { $0.id == editingID } }
        renderer.draw(visible)
        context.restoreGState()
        drawSelection()
    }

    private func drawGrid(_ rect: NSRect) {
        guard zoom >= 0.4 else { return }
        let step = 20 * zoom
        (isDark ? NSColor.white.withAlphaComponent(0.07) : NSColor.black.withAlphaComponent(0.07)).setFill()
        var x = offset.x.truncatingRemainder(dividingBy: step)
        if x < 0 { x += step }
        while x < rect.maxX {
            var y = offset.y.truncatingRemainder(dividingBy: step)
            if y < 0 { y += step }
            while y < rect.maxY {
                if x >= rect.minX - 2, y >= rect.minY - 2 { NSRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5).fill() }
                y += step
            }
            x += step
        }
    }

    private var selectedElements: [BoardElement] {
        scene.elements.filter { selection.contains($0.id) && !$0.isDeleted }
    }

    private func handleRects(for element: BoardElement) -> [(Handle, CGRect)] {
        let size: CGFloat = 9
        if element.type == .arrow || element.type == .line {
            return element.absolutePoints.enumerated().map { index, point in
                let p = viewPoint(point)
                return (.point(index), CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size))
            }
        }
        guard element.type.isShape else { return [] }
        let frame = viewRect(BoardGeometry.bounds(of: element)).insetBy(dx: -6, dy: -6)
        let corners = [CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.minY),
                       CGPoint(x: frame.maxX, y: frame.maxY), CGPoint(x: frame.minX, y: frame.maxY)]
        return corners.enumerated().map { index, p in (.corner(index), CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)) }
    }

    private func drawSelection() {
        let accent = NSColor.controlAccentColor
        let selected = selectedElements
        if let bounds = BoardGeometry.bounds(of: selected) {
            let frame = viewRect(bounds).insetBy(dx: -6, dy: -6)
            let path = NSBezierPath(rect: frame)
            path.lineWidth = 1
            if selected.count > 1 { path.setLineDash([4, 3], count: 2, phase: 0) }
            accent.setStroke()
            path.stroke()
            if selected.count == 1, let element = selected.first {
                for (_, rect) in handleRects(for: element) {
                    let handle = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
                    NSColor.textBackgroundColor.setFill()
                    handle.fill()
                    accent.setStroke()
                    handle.stroke()
                }
            }
        }
        if case let .marquee(start, current) = interaction {
            let rect = viewRect(CGRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(current.x - start.x), height: abs(current.y - start.y)))
            accent.withAlphaComponent(0.08).setFill()
            rect.fill()
            accent.withAlphaComponent(0.6).setStroke()
            NSBezierPath(rect: rect).stroke()
        }
    }

    override func resetCursorRects() {
        let cursor: NSCursor
        switch tool {
        case .hand: cursor = .openHand
        case .select: cursor = .arrow
        case .text: cursor = .iBeam
        default: cursor = .crosshair
        }
        addCursorRect(bounds, cursor: cursor)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: Mouse

    /// Elements selected together: the whole outermost group.
    private func groupMembers(of element: BoardElement) -> Set<String> {
        guard let group = element.groupIds.last else { return [element.id] }
        return Set(scene.visible.filter { $0.groupIds.contains(group) }.map(\.id))
    }

    private func boundTexts(of ids: Set<String>) -> [BoardElement] {
        scene.visible.filter { $0.containerId.map(ids.contains) ?? false }
    }

    override func mouseDown(with event: NSEvent) {
        commitTextEditing()
        window?.makeFirstResponder(self)
        let view = convert(event.locationInWindow, from: nil)
        let point = scenePoint(view)
        let tolerance = 6 / zoom

        if event.clickCount == 2, tool == .select || tool == .text {
            doubleClick(at: point)
            return
        }
        if spacePanning || tool == .hand || event.modifierFlags.contains(.option) && tool == .select && BoardGeometry.element(at: point, in: scene, tolerance: tolerance) == nil {
            interaction = .panning(start: view, origin: offset)
            NSCursor.closedHand.set()
            return
        }

        switch tool {
        case .hand:
            break
        case .select:
            if selectedElements.count == 1, let element = selectedElements.first,
               let (handle, _) = handleRects(for: element).first(where: { $0.1.insetBy(dx: -3, dy: -3).contains(view) }) {
                beginGesture()
                switch handle {
                case let .corner(corner): interaction = .resizing(id: element.id, corner: corner, original: element)
                case let .point(index): interaction = .movingPoint(id: element.id, index: index)
                }
                return
            }
            if let hit = BoardGeometry.element(at: point, in: scene, tolerance: tolerance) {
                let members = groupMembers(of: hit)
                if event.modifierFlags.contains(.shift) {
                    selection = selection.isSuperset(of: members) ? selection.subtracting(members) : selection.union(members)
                } else if !selection.contains(hit.id) {
                    selection = members
                }
                let moving = Set(selection).union(boundTexts(of: selection).map(\.id))
                let originals = Dictionary(scene.elements.filter { moving.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                interaction = .moving(start: point, originals: originals, moved: false)
            } else {
                if !event.modifierFlags.contains(.shift) { selection = [] }
                interaction = .marquee(start: point, current: point)
            }
        case .rectangle, .diamond, .ellipse:
            let kind: BoardElement.Kind = tool == .rectangle ? .rectangle : tool == .diamond ? .diamond : .ellipse
            beginGesture()
            let element = newElement(kind, at: point)
            change { $0.elements.append(element) }
            selection = [element.id]
            interaction = .creating(id: element.id, origin: point)
        case .arrow, .line:
            beginGesture()
            var element = newElement(tool == .arrow ? .arrow : .line, at: point)
            element.setAbsolutePoints([point, point])
            change { $0.elements.append(element) }
            interaction = .creating(id: element.id, origin: point)
        case .draw:
            beginGesture()
            let element = newElement(.freedraw, at: point)
            change { $0.elements.append(element) }
            interaction = .drawing(id: element.id)
        case .text:
            beginTextEditing(newTextAt: point, container: nil)
        case .eraser:
            beginGesture()
            interaction = .erasing
            erase(at: point)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let view = convert(event.locationInWindow, from: nil)
        let point = scenePoint(view)
        let shift = event.modifierFlags.contains(.shift)
        switch interaction {
        case .none:
            break
        case let .creating(id, origin):
            change { scene in
                update(id, in: &scene) { element in
                    if element.type.isLinear {
                        element.setAbsolutePoints([origin, shift ? snapAngle(from: origin, to: point) : point])
                    } else {
                        var dx = point.x - origin.x
                        var dy = point.y - origin.y
                        if shift {
                            let side = max(abs(dx), abs(dy))
                            dx = dx < 0 ? -side : side
                            dy = dy < 0 ? -side : side
                        }
                        element.x = min(origin.x, origin.x + dx)
                        element.y = min(origin.y, origin.y + dy)
                        element.width = abs(dx)
                        element.height = abs(dy)
                    }
                }
            }
        case let .drawing(id):
            change { scene in
                update(id, in: &scene) { element in
                    var points = element.absolutePoints
                    if let last = points.last, hypot(last.x - point.x, last.y - point.y) < 1.5 / zoom { return }
                    points.append(point)
                    element.setAbsolutePoints(points)
                }
            }
        case let .moving(start, originals, _):
            var dx = point.x - start.x
            var dy = point.y - start.y
            if shift { if abs(dx) > abs(dy) { dy = 0 } else { dx = 0 } }
            if !undoRecorded { beginGesture() }
            interaction = .moving(start: start, originals: originals, moved: true)
            change { scene in
                for (id, original) in originals {
                    update(id, in: &scene) { element in
                        if element.type.isLinear {
                            element.setAbsolutePoints(original.absolutePoints.map { CGPoint(x: $0.x + dx, y: $0.y + dy) })
                        } else {
                            element.x = original.x + dx
                            element.y = original.y + dy
                        }
                    }
                }
                BoardGeometry.updateBindings(in: &scene, moved: Set(originals.keys))
            }
        case let .resizing(id, corner, original):
            let frame = BoardGeometry.bounds(of: original)
            // The opposite corner stays put.
            let anchor: CGPoint
            switch corner {
            case 0: anchor = CGPoint(x: frame.maxX, y: frame.maxY)
            case 1: anchor = CGPoint(x: frame.minX, y: frame.maxY)
            case 2: anchor = CGPoint(x: frame.minX, y: frame.minY)
            default: anchor = CGPoint(x: frame.maxX, y: frame.minY)
            }
            var width = abs(point.x - anchor.x)
            var height = abs(point.y - anchor.y)
            if shift, frame.height > 0 {
                let ratio = frame.width / frame.height
                if width / max(height, 0.1) > ratio { height = width / ratio } else { width = height * ratio }
            }
            change { scene in
                update(id, in: &scene) { element in
                    element.x = point.x < anchor.x ? anchor.x - width : anchor.x
                    element.y = point.y < anchor.y ? anchor.y - height : anchor.y
                    element.width = max(width, 1)
                    element.height = max(height, 1)
                }
                BoardGeometry.updateBindings(in: &scene, moved: [id])
            }
        case let .movingPoint(id, index):
            change { scene in
                update(id, in: &scene) { element in
                    var points = element.absolutePoints
                    guard points.indices.contains(index) else { return }
                    points[index] = point
                    element.setAbsolutePoints(points)
                }
            }
        case let .marquee(start, _):
            interaction = .marquee(start: start, current: point)
            let rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y))
            let inside = scene.visible.filter { $0.containerId == nil && rect.contains(BoardGeometry.bounds(of: $0)) }
            selection = Set(inside.flatMap { groupMembers(of: $0) })
            needsDisplay = true
        case let .panning(start, origin):
            offset = CGPoint(x: origin.x + view.x - start.x, y: origin.y + view.y - start.y)
            repositionTextEditor()
            needsDisplay = true
        case .erasing:
            erase(at: point)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = scenePoint(event)
        switch interaction {
        case let .creating(id, origin):
            guard let element = element(id) else { break }
            if element.type.isLinear {
                if hypot(point.x - origin.x, point.y - origin.y) < 4 / zoom {
                    change { $0.elements.removeAll { $0.id == id } }
                } else {
                    bindEnds(of: id)
                    selection = [id]
                }
            } else if element.width < 4, element.height < 4 {
                // A click without dragging: a default-sized shape.
                change { scene in update(id, in: &scene) { e in
                    e.x = origin.x - 60
                    e.y = origin.y - 40
                    e.width = 120
                    e.height = 80
                } }
            }
            tool = .select
            selection = [id]
        case let .moving(_, originals, moved):
            if moved {
                // An arrow dragged on its own lets go of the shapes it was attached to.
                change { scene in
                    for id in originals.keys {
                        guard let index = scene.index(of: id), scene.elements[index].type == .arrow || scene.elements[index].type == .line else { continue }
                        if let target = scene.elements[index].startBinding?.elementId, originals[target] == nil { scene.elements[index].startBinding = nil }
                        if let target = scene.elements[index].endBinding?.elementId, originals[target] == nil { scene.elements[index].endBinding = nil }
                    }
                }
            } else if let hit = BoardGeometry.element(at: point, in: scene, tolerance: 6 / zoom), !event.modifierFlags.contains(.shift) {
                selection = groupMembers(of: hit)
            }
        case let .movingPoint(id, _):
            bindEnds(of: id)
        case .drawing, .resizing, .erasing, .marquee, .panning, .none:
            break
        }
        interaction = .none
        endGesture()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    private func snapAngle(from origin: CGPoint, to point: CGPoint) -> CGPoint {
        let angle = atan2(point.y - origin.y, point.x - origin.x)
        let step = CGFloat.pi / 12
        let snapped = (angle / step).rounded() * step
        let length = hypot(point.x - origin.x, point.y - origin.y)
        return CGPoint(x: origin.x + cos(snapped) * length, y: origin.y + sin(snapped) * length)
    }

    private func newElement(_ kind: BoardElement.Kind, at point: CGPoint) -> BoardElement {
        var element = BoardElement(type: kind, x: point.x, y: point.y)
        element.strokeColor = style.strokeColor
        element.backgroundColor = kind.isShape ? style.backgroundColor : "transparent"
        element.fillStyle = style.fillStyle
        element.strokeWidth = style.strokeWidth
        element.strokeStyle = kind == .freedraw ? "solid" : style.strokeStyle
        element.roughness = style.roughness
        element.opacity = style.opacity
        if kind == .rectangle || kind == .diamond { element.roundness = style.rounded ? .init(type: 3) : nil }
        if kind == .arrow { element.endArrowhead = style.endArrowhead }
        if kind == .text {
            element.fontSize = style.fontSize
            element.fontFamily = style.fontFamily
        }
        return element
    }

    /// Attaches an arrow's ends to the shapes they were dropped on.
    private func bindEnds(of id: String) {
        guard let arrow = element(id), arrow.type == .arrow || arrow.type == .line else { return }
        let points = arrow.absolutePoints
        guard let first = points.first, let last = points.last else { return }
        func target(at point: CGPoint) -> BoardElement? {
            scene.elements.reversed().first { other in
                other.id != id && !other.isDeleted && other.containerId == nil && BoardGeometry.isBindable(other)
                    && BoardGeometry.bounds(of: other).insetBy(dx: -10 / zoom, dy: -10 / zoom).contains(point)
            }
        }
        let start = target(at: first)
        let end = target(at: last)
        change { scene in
            update(id, in: &scene) { element in
                element.startBinding = start.map { .init(elementId: $0.id) }
                element.endBinding = end.map { .init(elementId: $0.id) }
            }
            for shape in [start, end].compactMap({ $0 }) {
                update(shape.id, in: &scene) { element in
                    var bound = element.boundElements ?? []
                    if !bound.contains(where: { $0.id == id }) { bound.append(.init(id: id, type: "arrow")) }
                    element.boundElements = bound
                }
            }
            BoardGeometry.updateBindings(in: &scene, moved: Set([start?.id, end?.id].compactMap { $0 }))
        }
    }

    private func erase(at point: CGPoint) {
        guard let hit = BoardGeometry.element(at: point, in: scene, tolerance: 8 / zoom) else { return }
        delete(groupMembers(of: hit))
    }

    // MARK: Text

    private func doubleClick(at point: CGPoint) {
        guard let hit = BoardGeometry.element(at: point, in: scene, tolerance: 6 / zoom) else {
            beginTextEditing(newTextAt: point, container: nil)
            return
        }
        if hit.type == .text {
            beginTextEditing(existing: hit)
        } else if hit.type.isShape || hit.type == .arrow {
            if let text = scene.visible.first(where: { $0.containerId == hit.id }) {
                beginTextEditing(existing: text)
            } else {
                beginTextEditing(newTextAt: point, container: hit)
            }
        }
    }

    private func beginTextEditing(newTextAt point: CGPoint, container: BoardElement?) {
        var text = newElement(.text, at: point)
        text.strokeColor = container?.strokeColor ?? style.strokeColor
        if let container {
            text.containerId = container.id
            text.textAlign = "center"
            text.verticalAlign = "middle"
        }
        beginGesture()
        change { scene in
            scene.elements.append(text)
            if let container {
                update(container.id, in: &scene) { element in
                    element.boundElements = (element.boundElements ?? []) + [.init(id: text.id, type: "text")]
                }
            }
        }
        editingIsNew = true
        openEditor(for: text)
    }

    private func beginTextEditing(existing text: BoardElement) {
        beginGesture()
        editingIsNew = false
        openEditor(for: text)
    }

    private func editorFrame(for text: BoardElement, content: String) -> CGRect {
        var measured = text
        measured.text = content
        let size = BoardRenderer.measure(measured)
        let width = max(size.width + 24, 40) * zoom
        let height = max(size.height, CGFloat(text.fontSize ?? 20) * 1.25) * zoom + 4
        if let container = text.containerId.flatMap(element) {
            let frame = viewRect(BoardGeometry.bounds(of: container))
            return CGRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height)
        }
        let origin = viewPoint(CGPoint(x: text.x, y: text.y))
        return CGRect(x: origin.x - 4, y: origin.y - 2, width: width, height: height)
    }

    private func openEditor(for text: BoardElement) {
        let editor = NSTextView(frame: editorFrame(for: text, content: text.text ?? ""))
        editor.isRichText = false
        editor.drawsBackground = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 2
        var scaled = text
        scaled.fontSize = CGFloat(text.fontSize ?? 20) * zoom
        let renderer = BoardRenderer(dark: isDark)
        editor.typingAttributes = BoardRenderer.textAttributes(scaled, color: renderer.color(text.strokeColor) ?? .labelColor)
        if text.containerId != nil { editor.alignment = .center }
        editor.string = text.text ?? ""
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.insertionPointColor = .controlAccentColor
        editor.delegate = self
        editor.setAccessibilityLabel(L("Text on the whiteboard"))
        addSubview(editor)
        textEditor = editor
        editingID = text.id
        window?.makeFirstResponder(editor)
        needsDisplay = true
    }

    private func repositionTextEditor() {
        guard let editor = textEditor, let id = editingID, let text = element(id) else { return }
        editor.frame = editorFrame(for: text, content: editor.string)
    }

    func textDidChange(_ notification: Notification) {
        repositionTextEditor()
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            commitTextEditing()
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)), NSEvent.modifierFlags.contains(.command) {
            commitTextEditing()
            return true
        }
        return false
    }

    /// The text being edited, typed into the overlay (used by the self-test).
    var editingText: NSTextView? { textEditor }

    func commitTextEditing() {
        guard let editor = textEditor, let id = editingID else { return }
        let content = editor.string
        textEditor = nil
        editingID = nil
        editor.removeFromSuperview()
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        change { scene in
            if trimmed.isEmpty {
                scene.elements.removeAll { $0.id == id }
                for index in scene.elements.indices {
                    scene.elements[index].boundElements?.removeAll { $0.id == id }
                }
                return
            }
            update(id, in: &scene) { element in
                element.text = content
                element.originalText = content
                let size = BoardRenderer.measure(element)
                element.width = size.width
                element.height = size.height
            }
            if let index = scene.index(of: id), let containerID = scene.elements[index].containerId, let container = scene.elements.first(where: { $0.id == containerID }) {
                let frame = BoardGeometry.bounds(of: container)
                scene.elements[index].x = frame.midX - scene.elements[index].width / 2
                scene.elements[index].y = frame.midY - scene.elements[index].height / 2
            }
        }
        endGesture()
        if !trimmed.isEmpty { selection = [id] }
        if tool == .text { tool = .select }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let flags = event.modifierFlags.intersection([.command, .option, .control])
        if flags.isEmpty {
            let tools: [String: Tool] = [
                "h": .hand, "v": .select, "1": .select, "r": .rectangle, "2": .rectangle, "d": .diamond, "3": .diamond,
                "o": .ellipse, "4": .ellipse, "a": .arrow, "5": .arrow, "l": .line, "6": .line, "p": .draw, "7": .draw,
                "t": .text, "8": .text, "e": .eraser, "0": .eraser,
            ]
            if let tool = tools[characters] {
                self.tool = tool
                return
            }
            if characters == " " {
                spacePanning = true
                NSCursor.openHand.set()
                return
            }
            switch event.keyCode {
            case 51, 117:
                delete(selection)
                return
            case 53:
                selection = []
                tool = .select
                return
            case 36, 76:
                if let first = selectedElements.first {
                    doubleClick(at: CGPoint(x: BoardGeometry.bounds(of: first).midX, y: BoardGeometry.bounds(of: first).midY))
                    return
                }
            case 123, 124, 125, 126:
                let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
                let delta: CGPoint = [123: CGPoint(x: -step, y: 0), 124: CGPoint(x: step, y: 0), 125: CGPoint(x: 0, y: step), 126: CGPoint(x: 0, y: -step)][Int(event.keyCode)] ?? .zero
                nudge(delta)
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            spacePanning = false
            window?.invalidateCursorRects(for: self)
            return
        }
        super.keyUp(with: event)
    }

    /// Board shortcuts that collide with menu items meant for text (⌘D, ⌘G).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch (event.charactersIgnoringModifiers?.lowercased(), flags) {
        case ("d", [.command]):
            duplicate(nil)
            return true
        case ("g", [.command]):
            group(nil)
            return true
        case ("g", [.command, .shift]):
            ungroup(nil)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            setZoom(zoom * (1 - event.scrollingDeltaY * 0.01), around: convert(event.locationInWindow, from: nil))
            return
        }
        offset = CGPoint(x: offset.x + event.scrollingDeltaX, y: offset.y + event.scrollingDeltaY)
        repositionTextEditor()
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        setZoom(zoom * (1 + event.magnification), around: convert(event.locationInWindow, from: nil))
    }

    // MARK: Editing commands

    private func nudge(_ delta: CGPoint) {
        guard !selection.isEmpty else { return }
        let moving = selection.union(boundTexts(of: selection).map(\.id))
        change { scene in
            for id in moving {
                update(id, in: &scene) { element in
                    if element.type.isLinear {
                        element.setAbsolutePoints(element.absolutePoints.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) })
                    } else {
                        element.x += delta.x
                        element.y += delta.y
                    }
                }
            }
            BoardGeometry.updateBindings(in: &scene, moved: moving)
        }
    }

    func delete(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let doomed = ids.union(boundTexts(of: ids).map(\.id))
        change { scene in
            for index in scene.elements.indices {
                if doomed.contains(scene.elements[index].id) {
                    scene.elements[index].isDeleted = true
                    scene.elements[index].touch()
                }
                if let binding = scene.elements[index].startBinding, doomed.contains(binding.elementId) { scene.elements[index].startBinding = nil }
                if let binding = scene.elements[index].endBinding, doomed.contains(binding.elementId) { scene.elements[index].endBinding = nil }
            }
            // Deleted elements aren't kept around: Excalidraw needs them only for collaboration.
            scene.elements.removeAll(where: \.isDeleted)
        }
        selection.subtract(doomed)
    }

    override func selectAll(_ sender: Any?) {
        tool = .select
        selection = Set(scene.visible.filter { $0.containerId == nil }.map(\.id))
        needsDisplay = true
    }

    @objc func delete(_ sender: Any?) {
        delete(selection)
    }

    @objc func duplicate(_ sender: Any?) {
        insert(copies(of: selectedElements + boundTexts(of: selection), offset: 16))
    }

    @objc func copy(_ sender: Any?) {
        let elements = selectedElements + boundTexts(of: selection)
        guard !elements.isEmpty, let json = BoardScene.clipboardJSON(elements) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(json, forType: .string)
        if let png = BoardRenderer.png(scene, only: selection, dark: false) { pasteboard.setData(png, forType: .png) }
    }

    @objc func cut(_ sender: Any?) {
        copy(sender)
        delete(selection)
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        if let elements = BoardScene.elements(fromClipboard: text), !elements.isEmpty {
            insert(copies(of: elements, offset: 20))
            return
        }
        // Plain text becomes a text element in the middle of the view.
        var element = newElement(.text, at: scenePoint(CGPoint(x: bounds.midX, y: bounds.midY)))
        element.text = text
        element.originalText = text
        let size = BoardRenderer.measure(element)
        element.width = size.width
        element.height = size.height
        insert([element])
    }

    /// Copies with fresh ids; bindings, containers and groups point to the copies.
    private func copies(of elements: [BoardElement], offset: Double) -> [BoardElement] {
        var ids: [String: String] = [:]
        for element in elements { ids[element.id] = BoardElement.newID() }
        var groups: [String: String] = [:]
        return elements.map { original in
            var element = original
            element.id = ids[original.id]!
            element.seed = Int.random(in: 1...2_000_000_000)
            element.x += offset
            element.y += offset
            element.isDeleted = false
            element.containerId = original.containerId.flatMap { ids[$0] }
            element.boundElements = original.boundElements?.compactMap { bound in ids[bound.id].map { .init(id: $0, type: bound.type) } }
            if let binding = original.startBinding { element.startBinding = ids[binding.elementId].map { .init(elementId: $0) } }
            if let binding = original.endBinding { element.endBinding = ids[binding.elementId].map { .init(elementId: $0) } }
            element.groupIds = original.groupIds.map { group in
                if let mapped = groups[group] { return mapped }
                let fresh = BoardElement.newID()
                groups[group] = fresh
                return fresh
            }
            element.touch()
            return element
        }
    }

    private func insert(_ elements: [BoardElement]) {
        guard !elements.isEmpty else { return }
        change { $0.elements.append(contentsOf: elements) }
        tool = .select
        selection = Set(elements.filter { $0.containerId == nil }.map(\.id))
    }

    @objc func group(_ sender: Any?) {
        guard selection.count > 1 else { return }
        let group = BoardElement.newID()
        let members = selection.union(boundTexts(of: selection).map(\.id))
        change { scene in
            for id in members { update(id, in: &scene) { $0.groupIds.append(group) } }
        }
    }

    @objc func ungroup(_ sender: Any?) {
        change { scene in
            for id in selection { update(id, in: &scene) { element in if !element.groupIds.isEmpty { element.groupIds.removeLast() } } }
        }
    }

    enum LayerMove {
        case back, backward, forward, front
    }

    func moveLayer(_ move: LayerMove) {
        guard !selection.isEmpty else { return }
        change { scene in
            let picked = scene.elements.filter { selection.contains($0.id) || ($0.containerId.map(selection.contains) ?? false) }
            let others = scene.elements.filter { element in !picked.contains { $0.id == element.id } }
            let firstIndex = scene.elements.firstIndex { selection.contains($0.id) } ?? 0
            switch move {
            case .back:
                scene.elements = picked + others
            case .front:
                scene.elements = others + picked
            case .backward:
                let position = max(0, min(others.count, others.firstIndex { scene.elements.firstIndex(of: $0)! >= firstIndex } ?? others.count) - 1)
                scene.elements = Array(others[..<position]) + picked + Array(others[position...])
            case .forward:
                let position = min(others.count, (others.firstIndex { scene.elements.firstIndex(of: $0)! > firstIndex } ?? others.count) + 1)
                scene.elements = Array(others[..<position]) + picked + Array(others[position...])
            }
        }
    }

    // MARK: Style

    /// Properties shown in the inspector: the selection's, or the defaults for new elements.
    var displayedStyle: BoardStyle {
        guard let element = selectedElements.first else { return style }
        var current = style
        current.strokeColor = element.strokeColor
        current.backgroundColor = element.backgroundColor
        current.fillStyle = element.fillStyle
        current.strokeWidth = element.strokeWidth
        current.strokeStyle = element.strokeStyle
        current.roughness = element.roughness
        current.opacity = element.opacity
        current.rounded = element.roundness != nil
        let text = element.type == .text ? element : boundTexts(of: [element.id]).first
        if let text { current.fontSize = text.fontSize ?? 20; current.fontFamily = text.fontFamily ?? 1 }
        if element.type == .arrow { current.endArrowhead = element.endArrowhead }
        return current
    }

    var selectionKinds: Set<BoardElement.Kind> {
        Set(selectedElements.map(\.type))
    }

    /// Changes one property for future elements and for the selected ones.
    func applyStyle(_ body: @escaping (inout BoardStyle) -> Void) {
        body(&style)
        guard !selection.isEmpty else { return }
        let targets = selection.union(boundTexts(of: selection).map(\.id))
        change { scene in
            for id in targets {
                update(id, in: &scene) { element in
                    var current = BoardStyle(strokeColor: element.strokeColor, backgroundColor: element.backgroundColor, fillStyle: element.fillStyle,
                                             strokeWidth: element.strokeWidth, strokeStyle: element.strokeStyle, roughness: element.roughness,
                                             opacity: element.opacity, rounded: element.roundness != nil, fontSize: element.fontSize ?? 20,
                                             fontFamily: element.fontFamily ?? 1, endArrowhead: element.endArrowhead)
                    body(&current)
                    element.strokeColor = current.strokeColor
                    if element.type.isShape { element.backgroundColor = current.backgroundColor }
                    element.fillStyle = current.fillStyle
                    element.strokeWidth = current.strokeWidth
                    if element.type != .freedraw { element.strokeStyle = current.strokeStyle }
                    element.roughness = current.roughness
                    element.opacity = current.opacity
                    if element.type == .rectangle || element.type == .diamond { element.roundness = current.rounded ? .init(type: 3) : nil }
                    if element.type == .arrow { element.endArrowhead = current.endArrowhead }
                    if element.type == .text {
                        element.fontSize = current.fontSize
                        element.fontFamily = current.fontFamily
                        let size = BoardRenderer.measure(element)
                        element.width = size.width
                        element.height = size.height
                    }
                }
            }
        }
    }

    /// Re-reads the scene after it changed on disk.
    func reload() {
        selection = selection.filter { id in scene.visible.contains { $0.id == id } }
        needsDisplay = true
    }

    func pngData() -> Data? {
        BoardRenderer.png(scene, only: selection.isEmpty ? nil : selection, dark: false)
    }
}
