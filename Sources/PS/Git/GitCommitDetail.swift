import AppKit
import PSCore

private final class FileChangeCell: NSTableCellView {
    let stats = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        textField = text
        stats.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        stats.alignment = .right
        stats.textColor = .secondaryLabelColor
        addSubview(text)
        addSubview(stats)
        text.translatesAutoresizingMaskIntoConstraints = false
        stats.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            stats.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stats.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(equalTo: stats.leadingAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

protocol GitCommitDetailDelegate: AnyObject {
    func gitDetail(didSelectCommit hash: String)
    func gitDetail(didOpenFile commit: GitCommit, path: String)
    func gitDetailDidClose()
}

/// Right-side panel with the selected commit: hash, author, date, message,
/// clickable parents and the list of changed files.
final class GitCommitDetailController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    weak var delegate: GitCommitDetailDelegate?

    private let titleLabel = NSTextField(labelWithString: "")
    private let hashField = NSTextField(labelWithString: "")
    private let copyButton = NSButton()
    private let authorLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")
    private let parentsLabel = NSTextField(labelWithString: L("Parents"))
    private let parentsStack = NSStackView()
    private let filesLabel = NSTextField(labelWithString: L("Files"))
    private let filesTable = NSTableView()
    private let closeButton = NSButton()
    private let emptyLabel = NSTextField(labelWithString: L("Select a commit to see its details."))

    private var store: GitGraphStore?
    private var commit: GitCommit?
    private var changes: [GitFileChange] = []
    private var parentHashes: [String] = []
    private var loadToken = 0

    override func loadView() {
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.maximumNumberOfLines = 0
        titleLabel.lineBreakMode = .byWordWrapping

        hashField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        hashField.textColor = .secondaryLabelColor
        hashField.lineBreakMode = .byTruncatingMiddle

        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: L("Copy hash"))
        copyButton.isBordered = false
        copyButton.toolTip = L("Copy hash")
        copyButton.setAccessibilityLabel(L("Copy hash"))
        copyButton.target = self
        copyButton.action = #selector(copyHash)

        let hashRow = NSStackView(views: [hashField, copyButton])
        hashRow.spacing = 4

        for label in [authorLabel, dateLabel] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.maximumNumberOfLines = 0
            label.lineBreakMode = .byWordWrapping
        }
        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.maximumNumberOfLines = 0
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.textColor = .labelColor

        for label in [parentsLabel, filesLabel] {
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
        }
        parentsStack.orientation = .vertical
        parentsStack.alignment = .leading
        parentsStack.spacing = 2

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        filesTable.addTableColumn(column)
        filesTable.headerView = nil
        filesTable.style = .plain
        filesTable.rowHeight = 20
        filesTable.dataSource = self
        filesTable.delegate = self
        filesTable.target = self
        filesTable.action = #selector(fileClicked)
        filesTable.doubleAction = #selector(fileClicked)
        filesTable.setAccessibilityLabel(L("Changed files"))
        let filesScroll = NSScrollView()
        filesScroll.documentView = filesTable
        filesScroll.hasVerticalScroller = true
        filesScroll.autohidesScrollers = true
        filesScroll.borderType = .noBorder
        filesScroll.translatesAutoresizingMaskIntoConstraints = false
        filesScroll.heightAnchor.constraint(equalToConstant: 200).isActive = true

        closeButton.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: L("Close"))
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = L("Close")
        closeButton.setAccessibilityLabel(L("Close"))
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.maximumNumberOfLines = 2
        emptyLabel.lineBreakMode = .byWordWrapping

        let content = NSStackView(views: [titleLabel, hashRow, authorLabel, dateLabel, messageLabel, parentsLabel, parentsStack, filesLabel, filesScroll])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 6
        content.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        content.setHuggingPriority(.defaultLow, for: .horizontal)
        for view in content.views where view !== filesScroll {
            view.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            view.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor).isActive = true
        }

        let scroll = NSScrollView()
        scroll.documentView = content
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        let root = NSView()
        root.addSubview(closeButton)
        root.addSubview(scroll)
        root.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 6),
            closeButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -16),
        ])
        view = root
        updateEmpty()
    }

    func show(commit hash: String, in store: GitGraphStore) {
        self.store = store
        loadToken += 1
        let token = loadToken
        guard let index = store.index(ofHash: hash) else { return }
        let commit = store.commits[index]
        self.commit = commit
        titleLabel.stringValue = commit.subject
        hashField.stringValue = commit.hash
        authorLabel.stringValue = "\(commit.authorName) <\(commit.authorEmail)>"
        let date = Date(timeIntervalSince1970: commit.timestamp)
        let absolute = DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
        let relative = RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
        dateLabel.stringValue = "\(absolute) (\(relative))"
        messageLabel.stringValue = commit.message
        messageLabel.isHidden = commit.message == commit.subject

        parentsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        parentHashes = commit.parents
        parentsLabel.isHidden = commit.parents.isEmpty
        parentsStack.isHidden = commit.parents.isEmpty
        for (i, parent) in commit.parents.enumerated() {
            let button = NSButton()
            button.bezelStyle = .inline
            button.title = String(parent.prefix(7))
            button.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            button.setAccessibilityLabel(L("Go to parent commit %@", String(parent.prefix(7))))
            button.target = self
            button.action = #selector(parentClicked(_:))
            button.tag = i
            parentsStack.addArrangedSubview(button)
        }

        changes = []
        filesTable.reloadData()
        updateEmpty()
        guard let root = store.root else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try GitClient.fileChanges(root, commit: commit) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.loadToken == token else { return }
                if case let .success(list) = result { self.changes = list }
                self.filesTable.reloadData()
            }
        }
    }

    private func updateEmpty() {
        emptyLabel.isHidden = commit != nil
    }

    @objc private func copyHash() {
        guard let commit else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commit.hash, forType: .string)
    }

    @objc private func closePressed() {
        delegate?.gitDetailDidClose()
    }

    @objc private func parentClicked(_ sender: NSButton) {
        guard parentHashes.indices.contains(sender.tag) else { return }
        delegate?.gitDetail(didSelectCommit: parentHashes[sender.tag])
    }

    @objc private func fileClicked() {
        let row = filesTable.clickedRow >= 0 ? filesTable.clickedRow : filesTable.selectedRow
        guard row >= 0 && changes.indices.contains(row), let commit else { return }
        delegate?.gitDetail(didOpenFile: commit, path: changes[row].path)
    }

    // MARK: Files table

    func numberOfRows(in tableView: NSTableView) -> Int {
        changes.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard changes.indices.contains(row) else { return nil }
        let change = changes[row]
        let identifier = NSUserInterfaceItemIdentifier("fileRow")
        let view = tableView.makeView(withIdentifier: identifier, owner: self) as? FileChangeCell ?? {
            let cell = FileChangeCell(frame: .zero)
            cell.identifier = identifier
            return cell
        }()
        let letter: String
        switch change.status {
        case .added: letter = "A"
        case .modified: letter = "M"
        case .deleted: letter = "D"
        case .renamed: letter = "R"
        case .copied: letter = "C"
        case .other(let s): letter = s
        }
        let display = change.oldPath.map { "\($0) → \(change.path)" } ?? change.path
        view.textField?.stringValue = "\(letter)  \(display)"
        let added = change.added.map { "+\($0)" } ?? ""
        let deleted = change.deleted.map { "−\($0)" } ?? ""
        view.stats.stringValue = [added, deleted].filter { !$0.isEmpty }.joined(separator: " ")
        view.setAccessibilityLabel("\(letter) \(display)")
        return view
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        20
    }
}
