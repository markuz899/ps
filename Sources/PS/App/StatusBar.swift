import AppKit
import PSCore

/// Bottom bar. In code mode: cursor, selection, language, encoding, line ending, indent.
/// In rich mode: word and character counts.
final class StatusBar: NSView {
    let position = StatusBar.button()
    let selection = StatusBar.label()
    let notice = StatusBar.label()
    let indent = StatusBar.button()
    let encoding = StatusBar.button()
    let lineEnding = StatusBar.button()
    let language = StatusBar.button()
    let counts = StatusBar.label()
    let kind = StatusBar.label()

    static let height: CGFloat = 24

    private static func button() -> NSButton {
        let button = NSButton(title: "", target: nil, action: nil)
        button.isBordered = false
        button.font = .systemFont(ofSize: 11)
        button.contentTintColor = .secondaryLabelColor
        button.setButtonType(.momentaryChange)
        return button
    }

    private static func label() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        notice.textColor = .systemOrange
        let left = NSStackView(views: [position, selection, counts, notice])
        let right = NSStackView(views: [kind, indent, encoding, lineEnding, language])
        for stack in [left, right] {
            stack.orientation = .horizontal
            stack.spacing = 14
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: StatusBar.height),
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            left.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            right.centerYAnchor.constraint(equalTo: centerYAnchor),
            left.trailingAnchor.constraint(lessThanOrEqualTo: right.leadingAnchor, constant: -12),
        ])
        setAccessibilityElement(false)
        position.setAccessibilityLabel(L("Go to Line"))
        language.setAccessibilityLabel(L("Change Language Mode"))
        encoding.setAccessibilityLabel(L("Encoding"))
        lineEnding.setAccessibilityLabel(L("Line Ending"))
        indent.setAccessibilityLabel(L("Indentation"))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    func showCode(_ visible: Bool) {
        for view in [position, selection, indent, encoding, lineEnding, language] as [NSView] { view.isHidden = !visible }
        counts.isHidden = visible
        kind.isHidden = visible
    }

    func clear() {
        for view in [position, selection, indent, encoding, lineEnding, language, counts, kind, notice] as [NSView] {
            view.isHidden = true
        }
    }
}

/// Filterable language list shown from the status bar (and the menu).
final class LanguagePicker: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let search = NSSearchField()
    private let table = NSTableView()
    private var filtered = LanguageRegistry.all
    private let current: String
    var onPick: ((Language) -> Void)?

    init(current: String) {
        self.current = current
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 320))
        search.placeholderString = L("Select Language Mode")
        search.delegate = self
        search.translatesAutoresizingMaskIntoConstraints = false
        let column = NSTableColumn(identifier: .init("name"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 22
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(pick)
        table.action = #selector(pick)
        table.style = .inset
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(search)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(search)
        if let index = filtered.firstIndex(where: { $0.id == current }) {
            table.selectRowIndexes([index], byExtendingSelection: false)
            table.scrollRowToVisible(index)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let language = filtered[row]
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: language.name + (language.id == current ? "  ✓" : ""))
        let extensions = NSTextField(labelWithString: language.extensions.prefix(3).map { "." + $0 }.joined(separator: " "))
        extensions.textColor = .tertiaryLabelColor
        extensions.font = .systemFont(ofSize: 11)
        let stack = NSStackView(views: [label, extensions])
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func controlTextDidChange(_ obj: Notification) {
        let query = search.stringValue
        filtered = query.isEmpty ? LanguageRegistry.all : LanguageRegistry.all
            .compactMap { language in Fuzzy.score(query, in: language.name + " " + language.extensions.joined(separator: " ")).map { (language, $0) } }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
        table.reloadData()
        if !filtered.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            let delta = selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let row = min(max(0, table.selectedRow + delta), filtered.count - 1)
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            pick()
            return true
        default:
            return false
        }
    }

    @objc private func pick() {
        guard filtered.indices.contains(table.selectedRow) else { return }
        onPick?(filtered[table.selectedRow])
    }
}
