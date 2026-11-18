import AppKit
import PSCore

/// Tab content for `.excalidraw` documents: the canvas plus floating tool bar,
/// properties panel and zoom controls.
final class BoardEditor: NSObject, DocumentEditor {
    let document: Document
    let canvas: BoardCanvas
    private let root = NSView()
    private let toolbar = NSSegmentedControl()
    private let inspector: BoardInspector
    private let zoomLabel = NSButton(title: "100%", target: nil, action: nil)
    /// The protocol wants a text view; a board has none, this one is never shown.
    let textView = NSTextView()
    var onSelectionChange: (() -> Void)?
    var onTextChange: (() -> Void)?

    var rootView: NSView { root }
    var focusView: NSView { canvas }

    private static let tools: [(BoardCanvas.Tool, String, String, String)] = [
        (.hand, "hand.raised", "Hand (H)", "H"),
        (.select, "cursorarrow", "Selection (V or 1)", "1"),
        (.rectangle, "rectangle", "Rectangle (R or 2)", "2"),
        (.diamond, "diamond", "Diamond (D or 3)", "3"),
        (.ellipse, "circle", "Ellipse (O or 4)", "4"),
        (.arrow, "arrow.right", "Arrow (A or 5)", "5"),
        (.line, "line.diagonal", "Line (L or 6)", "6"),
        (.draw, "pencil.tip", "Draw (P or 7)", "7"),
        (.text, "textformat", "Text (T or 8)", "8"),
        (.eraser, "eraser", "Eraser (E or 0)", "0"),
    ]

    init(document: Document) {
        self.document = document
        canvas = BoardCanvas(document: document)
        inspector = BoardInspector(canvas: canvas)
        // Every board change makes its own explicit undo group; the automatic per-event
        // group stayed open across changes and merged them into one step.
        document.undoManager.groupsByEvent = false
        super.init()
        build()
        canvas.onChange = { [weak self] in
            self?.document.userDidEdit()
            self?.inspector.refresh()
            self?.onTextChange?()
        }
        canvas.onSelectionChange = { [weak self] in
            self?.inspector.refresh()
            self?.onSelectionChange?()
        }
        canvas.onToolChange = { [weak self] in
            guard let self else { return }
            self.toolbar.selectedSegment = BoardEditor.tools.firstIndex { $0.0 == self.canvas.tool } ?? 1
            self.inspector.refresh()
        }
        canvas.onZoomChange = { [weak self] in
            guard let self else { return }
            self.zoomLabel.title = "\(Int((self.canvas.zoom * 100).rounded()))%"
        }
        DispatchQueue.main.async { [weak self] in self?.canvas.centerContent() }
    }

    private func floating(_ content: NSView, padding: CGFloat = 6) -> NSVisualEffectView {
        let panel = NSVisualEffectView()
        panel.material = .popover
        panel.state = .active
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 10
        panel.layer?.borderWidth = 0.5
        panel.layer?.borderColor = NSColor.separatorColor.cgColor
        panel.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: padding),
            content.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -padding),
            content.topAnchor.constraint(equalTo: panel.topAnchor, constant: padding),
            content.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -padding),
        ])
        return panel
    }

    private func build() {
        canvas.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(canvas)

        toolbar.segmentCount = BoardEditor.tools.count
        toolbar.trackingMode = .selectOne
        toolbar.segmentStyle = .texturedRounded
        for (index, (_, symbol, tip, _)) in BoardEditor.tools.enumerated() {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: L(tip))?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
            toolbar.setImage(image, forSegment: index)
            toolbar.setToolTip(L(tip), forSegment: index)
            toolbar.setWidth(34, forSegment: index)
        }
        toolbar.selectedSegment = 1
        toolbar.target = self
        toolbar.action = #selector(toolPicked)
        toolbar.setAccessibilityLabel(L("Whiteboard tools"))
        let toolPanel = floating(toolbar)
        root.addSubview(toolPanel)

        let inspectorPanel = floating(inspector, padding: 10)
        root.addSubview(inspectorPanel)

        let zoomOut = NSButton(image: NSImage(systemSymbolName: "minus", accessibilityDescription: L("Zoom Out"))!, target: self, action: #selector(zoomOut))
        let zoomIn = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: L("Zoom In"))!, target: self, action: #selector(zoomIn))
        zoomLabel.target = self
        zoomLabel.action = #selector(zoomReset)
        zoomLabel.toolTip = L("Zoom to fit")
        let undo = NSButton(image: NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: L("Undo"))!, target: self, action: #selector(undo))
        let redo = NSButton(image: NSImage(systemSymbolName: "arrow.uturn.forward", accessibilityDescription: L("Redo"))!, target: self, action: #selector(redo))
        for button in [zoomOut, zoomIn, zoomLabel, undo, redo] {
            button.isBordered = false
            button.contentTintColor = .secondaryLabelColor
            button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        }
        zoomLabel.widthAnchor.constraint(equalToConstant: 46).isActive = true
        let spacer = NSBox()
        spacer.boxType = .separator
        let zoomRow = NSStackView(views: [zoomOut, zoomLabel, zoomIn, spacer, undo, redo])
        zoomRow.spacing = 6
        let zoomPanel = floating(zoomRow)
        root.addSubview(zoomPanel)

        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: root.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            toolPanel.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            toolPanel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            inspectorPanel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            inspectorPanel.topAnchor.constraint(equalTo: toolPanel.bottomAnchor, constant: 12),
            inspectorPanel.bottomAnchor.constraint(lessThanOrEqualTo: zoomPanel.topAnchor, constant: -12),
            zoomPanel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            zoomPanel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        inspector.refresh()
    }

    func applyPreferences() {
        canvas.reload()
        inspector.refresh()
    }

    func detach() {
        canvas.commitTextEditing()
    }

    @objc private func toolPicked() {
        canvas.tool = BoardEditor.tools[toolbar.selectedSegment].0
        canvas.window?.makeFirstResponder(canvas)
    }

    @objc func zoomIn() { canvas.setZoom(canvas.zoom * 1.2) }
    @objc func zoomOut() { canvas.setZoom(canvas.zoom / 1.2) }
    @objc func zoomReset() { canvas.zoom == 1 ? canvas.zoomToFit() : canvas.setZoom(1) }
    @objc private func undo() { document.undoManager.undo() }
    @objc private func redo() { document.undoManager.redo() }
}

/// Properties of the selection (or of the next element drawn), like Excalidraw's panel.
final class BoardInspector: NSView {
    private unowned let canvas: BoardCanvas
    private let stack = NSStackView()
    private var rows: [String: NSView] = [:]
    private var swatchButtons: [(key: String, value: String, button: NSButton)] = []
    private let fill = NSSegmentedControl()
    private let width = NSSegmentedControl()
    private let strokeStyle = NSSegmentedControl()
    private let sloppiness = NSSegmentedControl()
    private let edges = NSSegmentedControl()
    private let fontSize = NSSegmentedControl()
    private let fontFamily = NSSegmentedControl()
    private let arrowhead = NSSegmentedControl()
    private let opacity = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let strokeWell = NSColorWell()
    private let backgroundWell = NSColorWell()

    static let strokes = ["#1e1e1e", "#e03131", "#2f9e44", "#1971c2", "#f08c00"]
    static let backgrounds = ["transparent", "#ffc9c9", "#b2f2bb", "#a5d8ff", "#ffec99"]
    private static let fills = ["hachure", "cross-hatch", "solid"]
    private static let widths: [Double] = [1, 2, 4]
    private static let strokeStyles = ["solid", "dashed", "dotted"]
    private static let roughness: [Double] = [0, 1, 2]
    private static let fontSizes: [Double] = [16, 20, 28, 36]
    private static let arrowheads: [String?] = [nil, "arrow", "triangle", "dot"]

    init(canvas: BoardCanvas) {
        self.canvas = canvas
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10.5, weight: .medium)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func row(_ key: String, _ title: String, _ control: NSView) {
        let column = NSStackView(views: [label(title), control])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        rows[key] = column
        stack.addArrangedSubview(column)
    }

    private func segmented(_ control: NSSegmentedControl, images: [NSImage], labels: [String], action: Selector) {
        control.segmentCount = images.count
        control.trackingMode = .selectOne
        control.segmentStyle = .texturedRounded
        control.controlSize = .small
        for (index, image) in images.enumerated() {
            control.setImage(image, forSegment: index)
            control.setToolTip(labels[index], forSegment: index)
            control.setWidth(32, forSegment: index)
        }
        control.setAccessibilityLabel(labels.joined(separator: ", "))
        control.target = self
        control.action = action
    }

    private func swatches(_ colors: [String], key: String, well: NSColorWell, action: Selector) -> NSView {
        var views: [NSView] = colors.map { hex in
            let button = NSButton(image: BoardInspector.swatchImage(hex), target: self, action: #selector(swatchPicked(_:)))
            button.isBordered = false
            button.toolTip = hex == "transparent" ? L("Transparent") : hex
            button.setAccessibilityLabel(hex == "transparent" ? L("Transparent") : hex)
            button.identifier = NSUserInterfaceItemIdentifier(key + "|" + hex)
            swatchButtons.append((key, hex, button))
            return button
        }
        well.colorWellStyle = .minimal
        well.target = self
        well.action = action
        well.widthAnchor.constraint(equalToConstant: 30).isActive = true
        views.append(well)
        let row = NSStackView(views: views)
        row.spacing = 4
        return row
    }

    private func build() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        row("stroke", L("Stroke"), swatches(Self.strokes, key: "stroke", well: strokeWell, action: #selector(strokeWellChanged)))
        row("background", L("Background"), swatches(Self.backgrounds, key: "background", well: backgroundWell, action: #selector(backgroundWellChanged)))
        segmented(fill, images: Self.fills.map(BoardInspector.fillImage), labels: [L("Hachure"), L("Cross-hatch"), L("Solid")], action: #selector(fillChanged))
        row("fill", L("Fill"), fill)
        segmented(width, images: Self.widths.map { BoardInspector.lineImage(width: $0) }, labels: [L("Thin"), L("Bold"), L("Extra bold")], action: #selector(widthChanged))
        row("width", L("Stroke width"), width)
        segmented(strokeStyle, images: Self.strokeStyles.map { BoardInspector.lineImage(width: 2, style: $0) }, labels: [L("Solid"), L("Dashed"), L("Dotted")], action: #selector(strokeStyleChanged))
        row("style", L("Stroke style"), strokeStyle)
        segmented(sloppiness, images: Self.roughness.map(BoardInspector.sloppinessImage), labels: [L("Architect"), L("Artist"), L("Cartoonist")], action: #selector(sloppinessChanged))
        row("sloppiness", L("Sloppiness"), sloppiness)
        segmented(edges, images: [BoardInspector.cornerImage(rounded: false), BoardInspector.cornerImage(rounded: true)], labels: [L("Sharp"), L("Round")], action: #selector(edgesChanged))
        row("edges", L("Edges"), edges)
        segmented(fontSize, images: ["S", "M", "L", "XL"].map(BoardInspector.textImage), labels: [L("Small"), L("Medium"), L("Large"), L("Extra large")], action: #selector(fontSizeChanged))
        row("fontSize", L("Font size"), fontSize)
        segmented(fontFamily, images: [BoardInspector.textImage("Aa", family: 1), BoardInspector.textImage("Aa", family: 2), BoardInspector.textImage("</>", family: 3)], labels: [L("Hand-drawn"), L("Normal"), L("Code")], action: #selector(fontFamilyChanged))
        row("fontFamily", L("Font family"), fontFamily)
        segmented(arrowhead, images: Self.arrowheads.map(BoardInspector.arrowheadImage), labels: [L("None"), L("Arrow"), L("Triangle"), L("Dot")], action: #selector(arrowheadChanged))
        row("arrowhead", L("Arrowhead"), arrowhead)
        opacity.controlSize = .small
        opacity.target = self
        opacity.action = #selector(opacityChanged)
        opacity.widthAnchor.constraint(equalToConstant: 170).isActive = true
        opacity.setAccessibilityLabel(L("Opacity"))
        row("opacity", L("Opacity"), opacity)

        let layers = NSStackView(views: [
            action("square.3.layers.3d.bottom.filled", L("Send to back"), #selector(sendToBack)),
            action("arrow.down", L("Send backward"), #selector(sendBackward)),
            action("arrow.up", L("Bring forward"), #selector(bringForward)),
            action("square.3.layers.3d.top.filled", L("Bring to front"), #selector(bringToFront)),
            action("plus.square.on.square", L("Duplicate"), #selector(duplicate)),
            action("trash", L("Delete"), #selector(deleteSelection)),
        ])
        layers.spacing = 4
        row("actions", L("Layers & actions"), layers)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(L("Properties"))
    }

    private func action(_ symbol: String, _ label: String, _ selector: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(), target: self, action: selector)
        button.bezelStyle = .texturedRounded
        button.controlSize = .small
        button.toolTip = label
        return button
    }

    /// Shows only the properties that make sense for the selection or the current tool.
    func refresh() {
        let kinds = canvas.selectionKinds
        let tool = canvas.tool
        let drawing = [.rectangle, .diamond, .ellipse, .arrow, .line, .draw, .text].contains(tool)
        superview?.isHidden = kinds.isEmpty && !drawing
        let hasShape = !kinds.intersection([.rectangle, .diamond, .ellipse]).isEmpty || [.rectangle, .diamond, .ellipse].contains(tool)
        let hasText = kinds.contains(.text) || tool == .text || !kinds.isEmpty && !kinds.intersection([.rectangle, .diamond, .ellipse]).isEmpty
        let hasArrow = kinds.contains(.arrow) || tool == .arrow
        let hasCorners = !kinds.intersection([.rectangle, .diamond]).isEmpty || [.rectangle, .diamond].contains(tool)
        let onlyText = kinds == [.text] || tool == .text && kinds.isEmpty
        rows["background"]?.isHidden = !hasShape
        rows["fill"]?.isHidden = !hasShape
        rows["width"]?.isHidden = onlyText
        rows["style"]?.isHidden = onlyText || kinds == [.freedraw] || tool == .draw
        rows["sloppiness"]?.isHidden = onlyText || kinds == [.freedraw] || tool == .draw
        rows["edges"]?.isHidden = !hasCorners
        rows["fontSize"]?.isHidden = !hasText
        rows["fontFamily"]?.isHidden = !hasText
        rows["arrowhead"]?.isHidden = !hasArrow
        rows["actions"]?.isHidden = kinds.isEmpty

        let style = canvas.displayedStyle
        for (key, value, button) in swatchButtons {
            let current = key == "stroke" ? style.strokeColor : style.backgroundColor
            button.image = BoardInspector.swatchImage(value, selected: current.lowercased() == value.lowercased())
        }
        fill.selectedSegment = Self.fills.firstIndex(of: style.fillStyle) ?? 0
        width.selectedSegment = Self.widths.firstIndex { abs($0 - style.strokeWidth) < 0.5 } ?? 1
        strokeStyle.selectedSegment = Self.strokeStyles.firstIndex(of: style.strokeStyle) ?? 0
        sloppiness.selectedSegment = Self.roughness.firstIndex { abs($0 - style.roughness) < 0.5 } ?? 1
        edges.selectedSegment = style.rounded ? 1 : 0
        fontSize.selectedSegment = Self.fontSizes.firstIndex { abs($0 - style.fontSize) < 1 } ?? 1
        fontFamily.selectedSegment = max(0, min(2, style.fontFamily - 1))
        arrowhead.selectedSegment = Self.arrowheads.firstIndex { $0 == style.endArrowhead } ?? 1
        opacity.doubleValue = style.opacity
    }

    // MARK: Actions

    @objc private func swatchPicked(_ sender: NSButton) {
        guard let parts = sender.identifier?.rawValue.split(separator: "|"), parts.count == 2 else { return }
        let value = String(parts[1])
        if parts[0] == "stroke" {
            canvas.applyStyle { $0.strokeColor = value }
        } else {
            canvas.applyStyle { $0.backgroundColor = value }
        }
        refresh()
    }

    private static func hex(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "#1e1e1e" }
        return String(format: "#%02x%02x%02x", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
    }

    @objc private func strokeWellChanged() {
        let value = Self.hex(strokeWell.color)
        canvas.applyStyle { $0.strokeColor = value }
        refresh()
    }

    @objc private func backgroundWellChanged() {
        let value = Self.hex(backgroundWell.color)
        canvas.applyStyle { $0.backgroundColor = value }
        refresh()
    }

    @objc private func fillChanged() {
        let value = Self.fills[fill.selectedSegment]
        canvas.applyStyle { $0.fillStyle = value }
    }

    @objc private func widthChanged() {
        let value = Self.widths[width.selectedSegment]
        canvas.applyStyle { $0.strokeWidth = value }
    }

    @objc private func strokeStyleChanged() {
        let value = Self.strokeStyles[strokeStyle.selectedSegment]
        canvas.applyStyle { $0.strokeStyle = value }
    }

    @objc private func sloppinessChanged() {
        let value = Self.roughness[sloppiness.selectedSegment]
        canvas.applyStyle { $0.roughness = value }
    }

    @objc private func edgesChanged() {
        let value = edges.selectedSegment == 1
        canvas.applyStyle { $0.rounded = value }
    }

    @objc private func fontSizeChanged() {
        let value = Self.fontSizes[fontSize.selectedSegment]
        canvas.applyStyle { $0.fontSize = value }
    }

    @objc private func fontFamilyChanged() {
        let value = fontFamily.selectedSegment + 1
        canvas.applyStyle { $0.fontFamily = value }
    }

    @objc private func arrowheadChanged() {
        let value = Self.arrowheads[arrowhead.selectedSegment]
        canvas.applyStyle { $0.endArrowhead = value }
    }

    @objc private func opacityChanged() {
        let value = opacity.doubleValue.rounded()
        canvas.applyStyle { $0.opacity = value }
    }

    @objc private func sendToBack() { canvas.moveLayer(.back) }
    @objc private func sendBackward() { canvas.moveLayer(.backward) }
    @objc private func bringForward() { canvas.moveLayer(.forward) }
    @objc private func bringToFront() { canvas.moveLayer(.front) }
    @objc private func duplicate() { canvas.duplicate(nil) }
    @objc private func deleteSelection() { canvas.delete(canvas.selection) }

    // MARK: Icons (drawn in code)

    private static func icon(_ size: NSSize = NSSize(width: 20, height: 14), _ draw: @escaping (NSRect) -> Void) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.labelColor.setStroke()
            NSColor.labelColor.setFill()
            draw(rect)
            return true
        }
        image.isTemplate = true
        return image
    }

    static func swatchImage(_ hex: String, selected: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 22), flipped: false) { rect in
            let square = NSBezierPath(roundedRect: rect.insetBy(dx: 3, dy: 3), xRadius: 4, yRadius: 4)
            if hex == "transparent" {
                NSColor.white.setFill()
                square.fill()
                NSGraphicsContext.saveGraphicsState()
                square.addClip()
                NSColor(white: 0.82, alpha: 1).setFill()
                for row in 0..<4 {
                    for column in 0..<4 where (row + column) % 2 == 0 {
                        NSRect(x: 3 + CGFloat(column) * 4, y: 3 + CGFloat(row) * 4, width: 4, height: 4).fill()
                    }
                }
                NSGraphicsContext.restoreGraphicsState()
            } else {
                (NSColor(hex: hex) ?? .gray).setFill()
                square.fill()
            }
            NSColor.black.withAlphaComponent(0.15).setStroke()
            square.lineWidth = 0.5
            square.stroke()
            if selected {
                let ring = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
                NSColor.controlAccentColor.setStroke()
                ring.lineWidth = 1.5
                ring.stroke()
            }
            return true
        }
        return image
    }

    static func fillImage(_ style: String) -> NSImage {
        icon { rect in
            let box = NSRect(x: 4, y: 2, width: 12, height: 10)
            let path = NSBezierPath(roundedRect: box, xRadius: 2, yRadius: 2)
            if style == "solid" {
                path.fill()
                return
            }
            path.stroke()
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            for offset in stride(from: -10.0, through: 20.0, by: 3.5) {
                let line = NSBezierPath()
                line.move(to: NSPoint(x: box.minX + offset, y: box.minY))
                line.line(to: NSPoint(x: box.minX + offset + 10, y: box.maxY))
                if style == "cross-hatch" {
                    line.move(to: NSPoint(x: box.minX + offset, y: box.maxY))
                    line.line(to: NSPoint(x: box.minX + offset + 10, y: box.minY))
                }
                line.lineWidth = 0.8
                line.stroke()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    static func lineImage(width: Double, style: String = "solid") -> NSImage {
        icon { rect in
            let line = NSBezierPath()
            line.move(to: NSPoint(x: 3, y: rect.midY))
            line.line(to: NSPoint(x: rect.maxX - 3, y: rect.midY))
            line.lineWidth = CGFloat(width)
            line.lineCapStyle = .round
            if style == "dashed" { line.setLineDash([4, 2.5], count: 2, phase: 0) }
            if style == "dotted" { line.setLineDash([0.5, 3], count: 2, phase: 0) }
            line.stroke()
        }
    }

    static func sloppinessImage(_ roughness: Double) -> NSImage {
        icon { rect in
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 3, y: rect.midY))
            let amplitude = CGFloat(roughness) * 2.5
            for step in 1...8 {
                let x = 3 + CGFloat(step) * (rect.width - 6) / 8
                path.line(to: NSPoint(x: x, y: rect.midY + (step % 2 == 0 ? amplitude : -amplitude)))
            }
            path.lineWidth = 1.4
            path.lineJoinStyle = .round
            path.stroke()
        }
    }

    static func cornerImage(rounded: Bool) -> NSImage {
        icon { _ in
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 5, y: 2))
            if rounded {
                path.line(to: NSPoint(x: 5, y: 7))
                path.curve(to: NSPoint(x: 10, y: 12), controlPoint1: NSPoint(x: 5, y: 10), controlPoint2: NSPoint(x: 7, y: 12))
            } else {
                path.line(to: NSPoint(x: 5, y: 12))
            }
            path.line(to: NSPoint(x: 16, y: 12))
            path.lineWidth = 1.5
            path.stroke()
        }
    }

    static func textImage(_ text: String) -> NSImage {
        textImage(text, family: 2)
    }

    static func textImage(_ text: String, family: Int) -> NSImage {
        icon(NSSize(width: 24, height: 14)) { rect in
            let font = BoardRenderer.font(family: family, size: 10.5)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
        }
    }

    static func arrowheadImage(_ style: String?) -> NSImage {
        icon { rect in
            let path = NSBezierPath()
            let tip = NSPoint(x: rect.maxX - 3, y: rect.midY)
            path.move(to: NSPoint(x: 3, y: rect.midY))
            path.line(to: tip)
            path.lineWidth = 1.4
            path.stroke()
            switch style {
            case "arrow":
                let head = NSBezierPath()
                head.move(to: NSPoint(x: tip.x - 5, y: tip.y + 4))
                head.line(to: tip)
                head.line(to: NSPoint(x: tip.x - 5, y: tip.y - 4))
                head.lineWidth = 1.4
                head.stroke()
            case "triangle":
                let head = NSBezierPath()
                head.move(to: tip)
                head.line(to: NSPoint(x: tip.x - 6, y: tip.y + 4))
                head.line(to: NSPoint(x: tip.x - 6, y: tip.y - 4))
                head.close()
                head.fill()
            case "dot":
                NSBezierPath(ovalIn: NSRect(x: tip.x - 4, y: tip.y - 3, width: 6, height: 6)).fill()
            default:
                break
            }
        }
    }
}
