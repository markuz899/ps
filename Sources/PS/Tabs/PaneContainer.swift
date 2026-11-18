import AppKit

/// Editor panes side by side, laid out with Auto Layout (proportional widths) and
/// separated by draggable dividers. Used instead of NSSplitView, whose frame-based
/// subviews leaked fixed margins into the window's minimum size.
final class PaneContainer: NSView {
    static let minimumWidth: CGFloat = 220

    private(set) var panes: [NSView] = []
    private var fractions: [CGFloat] = []
    private var dividers: [PaneDivider] = []
    private var layoutConstraints: [NSLayoutConstraint] = []

    func setPanes(_ views: [NSView]) {
        // A pane may have been borrowed (focus mode puts it elsewhere): take it back too.
        guard views != panes || views.contains(where: { $0.superview !== self }) else { return }
        for view in panes where !views.contains(view) { view.removeFromSuperview() }
        panes = views
        equalize()
    }

    func equalize() {
        fractions = Array(repeating: 1 / CGFloat(max(1, panes.count)), count: panes.count)
        rebuild()
    }

    private func rebuild() {
        NSLayoutConstraint.deactivate(layoutConstraints)
        layoutConstraints = []
        dividers.forEach { $0.removeFromSuperview() }
        dividers = []

        var previous: NSView?
        for (index, pane) in panes.enumerated() {
            pane.translatesAutoresizingMaskIntoConstraints = false
            if pane.superview !== self { addSubview(pane) }
            layoutConstraints += [
                pane.topAnchor.constraint(equalTo: topAnchor),
                pane.bottomAnchor.constraint(equalTo: bottomAnchor),
            ]
            if let previous {
                let divider = PaneDivider(index: index - 1, container: self)
                addSubview(divider)
                dividers.append(divider)
                layoutConstraints += [
                    divider.leadingAnchor.constraint(equalTo: previous.trailingAnchor),
                    divider.widthAnchor.constraint(equalToConstant: PaneDivider.width),
                    divider.topAnchor.constraint(equalTo: topAnchor),
                    divider.bottomAnchor.constraint(equalTo: bottomAnchor),
                    pane.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
                ]
            } else {
                layoutConstraints.append(pane.leadingAnchor.constraint(equalTo: leadingAnchor))
            }
            if index < panes.count - 1 {
                // Preferred share of the width. Kept below the window's own size priority (500),
                // otherwise Auto Layout would rather grow the window than squeeze a pane.
                let dividers = PaneDivider.width * CGFloat(panes.count - 1)
                let share = pane.widthAnchor.constraint(equalTo: widthAnchor, multiplier: fractions[index], constant: -dividers * fractions[index])
                share.priority = .init(450)
                let minimum = pane.widthAnchor.constraint(greaterThanOrEqualToConstant: PaneContainer.minimumWidth)
                minimum.priority = .init(460)
                layoutConstraints += [share, minimum]
            }
            previous = pane
        }
        if let last = panes.last { layoutConstraints.append(last.trailingAnchor.constraint(equalTo: trailingAnchor)) }
        NSLayoutConstraint.activate(layoutConstraints)
    }

    fileprivate func drag(divider index: Int, to x: CGFloat) {
        guard index + 1 < panes.count, bounds.width > 0 else { return }
        let left = panes[index].frame.minX
        let right = panes[index + 1].frame.maxX
        let width = min(max(x - left, PaneContainer.minimumWidth), right - left - PaneContainer.minimumWidth)
        let pair = fractions[index] + fractions[index + 1]
        fractions[index] = width / bounds.width
        fractions[index + 1] = pair - fractions[index]
        rebuild()
    }

    /// Double-clicking a divider evens out all panes.
    fileprivate func resetWidths() {
        equalize()
    }
}

private final class PaneDivider: NSView {
    static let width: CGFloat = 5
    private let index: Int
    private unowned let container: PaneContainer

    init(index: Int, container: PaneContainer) {
        self.index = index
        self.container = container
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel(L("Pane divider"))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: floor(bounds.midX), y: 0, width: 1, height: bounds.height).fill()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { container.resetWidths() }
    }

    override func mouseDragged(with event: NSEvent) {
        container.drag(divider: index, to: container.convert(event.locationInWindow, from: nil).x)
    }
}
