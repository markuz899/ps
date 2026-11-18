import AppKit
import PSCore

/// Find & replace in the current document, for both editor modes. All matches are painted
/// as temporary background attributes; the counter shows "current of total".
final class FindBar: NSView, NSSearchFieldDelegate, NSTextFieldDelegate {
    weak var textView: NSTextView? {
        willSet { clearHighlights() }
        didSet { if !isHidden { refresh() } }
    }
    var onClose: (() -> Void)?
    var highlightColor = NSColor.systemYellow.withAlphaComponent(0.4)

    private let findField = NSSearchField()
    private let replaceField = NSTextField()
    private let counter = NSTextField(labelWithString: "")
    private let options = NSSegmentedControl()
    private let navigation = NSSegmentedControl()
    private let replaceButton = NSButton(title: L("Replace"), target: nil, action: nil)
    private let replaceAllButton = NSButton(title: L("All"), target: nil, action: nil)
    private let replaceRow = NSStackView()
    private var matches: [NSRange] = []
    private var current = -1
    private var pendingRefresh: DispatchWorkItem?

    var findOptions: FindOptions {
        FindOptions(caseSensitive: options.isSelected(forSegment: 0), wholeWord: options.isSelected(forSegment: 1), regex: options.isSelected(forSegment: 2))
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        findField.placeholderString = L("Find")
        findField.delegate = self
        findField.sendsWholeSearchString = false
        findField.setAccessibilityLabel(L("Find"))
        replaceField.placeholderString = L("Replace")
        replaceField.delegate = self
        replaceField.setAccessibilityLabel(L("Replace"))
        counter.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        counter.textColor = .secondaryLabelColor
        counter.alignment = .right

        options.segmentCount = 3
        options.trackingMode = .selectAny
        options.segmentStyle = .texturedRounded
        options.controlSize = .small
        for (index, (label, tip)) in [("Aa", L("Match Case")), ("ab", L("Whole Word")), (".*", L("Regular Expression"))].enumerated() {
            options.setLabel(label, forSegment: index)
            options.setToolTip(tip, forSegment: index)
            options.setWidth(30, forSegment: index)
        }
        options.setAccessibilityLabel(L("Search options"))
        options.target = self
        options.action = #selector(optionsChanged)

        navigation.segmentCount = 2
        navigation.trackingMode = .momentary
        navigation.segmentStyle = .texturedRounded
        navigation.controlSize = .small
        navigation.setImage(NSImage(systemSymbolName: "chevron.up", accessibilityDescription: L("Previous")), forSegment: 0)
        navigation.setImage(NSImage(systemSymbolName: "chevron.down", accessibilityDescription: L("Next")), forSegment: 1)
        navigation.target = self
        navigation.action = #selector(navigate)

        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: L("Close"))!, target: self, action: #selector(closePressed))
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor

        for button in [replaceButton, replaceAllButton] {
            button.controlSize = .small
            button.bezelStyle = .texturedRounded
            button.target = self
        }
        replaceButton.action = #selector(replaceOne)
        replaceAllButton.action = #selector(replaceAll)
        replaceAllButton.toolTip = L("Replace All")

        let findRow = NSStackView(views: [findField, options, counter, navigation, close])
        findRow.spacing = 8
        replaceRow.setViews([replaceField, replaceButton, replaceAllButton], in: .leading)
        replaceRow.spacing = 8
        let column = NSStackView(views: [findRow, replaceRow])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            replaceField.widthAnchor.constraint(equalTo: findField.widthAnchor),
        ])
        // Preferred sizes only: in a narrow pane the fields shrink instead of widening it.
        for (view, width) in [(findField as NSView, CGFloat(280)), (counter, 92)] {
            let constraint = view.widthAnchor.constraint(equalToConstant: width)
            constraint.priority = .defaultLow
            constraint.isActive = true
            view.setContentCompressionResistancePriority(.init(100), for: .horizontal)
        }
        findField.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        setAccessibilityRole(.group)
        setAccessibilityLabel(L("Find and Replace"))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    func show(replace: Bool) {
        isHidden = false
        replaceRow.isHidden = !replace
        if let view = textView {
            let selection = view.selectedRange()
            if selection.length > 0, selection.length < 200 {
                findField.stringValue = (view.string as NSString).substring(with: selection)
            }
        }
        window?.makeFirstResponder(findField)
        refresh()
    }

    func useSelectionForFind() {
        guard let view = textView else { return }
        let selection = view.selectedRange()
        guard selection.length > 0 else { return }
        findField.stringValue = (view.string as NSString).substring(with: selection)
        refresh()
    }

    func hide() {
        let wasVisible = !isHidden
        clearHighlights()
        isHidden = true
        // Only hand focus back if the bar had it; hiding hidden bars must not move focus.
        if wasVisible, let view = textView { window?.makeFirstResponder(view) }
    }

    /// Re-runs the search after the text changed, coalesced while typing.
    func textDidChange() {
        guard !isHidden else { return }
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh(keepPosition: true) }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func clearHighlights() {
        guard let view = textView, let layoutManager = view.layoutManager else { return }
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: view.textStorage?.length ?? 0))
    }

    private func refresh(keepPosition: Bool = false) {
        clearHighlights()
        guard let view = textView else { return }
        let query = findField.stringValue
        findField.textColor = .labelColor
        do {
            matches = try FindEngine.ranges(of: query, in: view.string, options: findOptions, limit: 20_000)
        } catch {
            matches = []
            findField.textColor = .systemRed
            counter.stringValue = L("Invalid regex")
            return
        }
        for range in matches {
            view.layoutManager?.addTemporaryAttribute(.backgroundColor, value: highlightColor, forCharacterRange: range)
        }
        let caret = view.selectedRange().location
        current = matches.firstIndex { $0.location >= (keepPosition ? caret : caret) } ?? (matches.isEmpty ? -1 : 0)
        updateCounter()
        if !keepPosition, current >= 0 { reveal(matches[current], select: false) }
    }

    private func updateCounter() {
        if findField.stringValue.isEmpty {
            counter.stringValue = ""
        } else if matches.isEmpty {
            counter.stringValue = L("No results")
        } else {
            counter.stringValue = L("%d of %d", current + 1, matches.count)
        }
    }

    private func reveal(_ range: NSRange, select: Bool) {
        guard let view = textView else { return }
        if select { view.setSelectedRange(range) }
        view.scrollRangeToVisible(range)
        view.showFindIndicator(for: range)
    }

    func findNext(forward: Bool = true) {
        if isHidden { show(replace: false) }
        guard !matches.isEmpty, let view = textView else { return }
        let selection = view.selectedRange()
        if forward {
            current = matches.firstIndex { $0.location >= NSMaxRange(selection) && $0 != selection } ?? 0
        } else {
            current = matches.lastIndex { NSMaxRange($0) <= selection.location && $0 != selection } ?? matches.count - 1
        }
        updateCounter()
        reveal(matches[current], select: true)
    }

    @objc private func navigate() { findNext(forward: navigation.selectedSegment == 1) }
    @objc private func optionsChanged() { refresh() }
    @objc private func closePressed() { onClose?() }

    @objc private func replaceOne() {
        guard let view = textView, !matches.isEmpty else { return }
        let selection = view.selectedRange()
        guard let index = matches.firstIndex(of: selection) else {
            findNext()
            return
        }
        let replacement = (try? FindEngine.replacement(for: matches[index], in: view.string, query: findField.stringValue, template: replaceField.stringValue, options: findOptions)) ?? replaceField.stringValue
        if view.shouldChangeText(in: selection, replacementString: replacement) {
            view.textStorage?.replaceCharacters(in: selection, with: replacement)
            view.didChangeText()
        }
        refresh(keepPosition: true)
        findNext()
    }

    @objc private func replaceAll() {
        guard let view = textView,
              let items = try? FindEngine.replacements(of: findField.stringValue, in: view.string, template: replaceField.stringValue, options: findOptions),
              !items.isEmpty else { return }
        // One undoable change for all replacements.
        guard view.shouldChangeText(inRanges: items.map { NSValue(range: $0.range) }, replacementStrings: items.map(\.replacement)) else { return }
        view.textStorage?.beginEditing()
        for item in items.reversed() {
            view.textStorage?.replaceCharacters(in: item.range, with: item.replacement)
        }
        view.textStorage?.endEditing()
        view.didChangeText()
        refresh(keepPosition: true)
        counter.stringValue = L("%d replaced", items.count)
    }

    // MARK: Field delegates

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === findField { refresh() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if control === replaceField {
                replaceOne()
            } else {
                findNext(forward: !NSEvent.modifierFlags.contains(.shift))
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}
