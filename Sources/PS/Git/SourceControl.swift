import AppKit
import PSCore

protocol SourceControlDelegate: AnyObject {
    /// Shows the diff of a changed file (staged or working copy).
    func sourceControl(showDiffOf entry: GitStatusEntry, staged: Bool, root: URL)
    func sourceControl(open url: URL)
    /// After a commit, pull or stage: the graph and the gutters refresh.
    func sourceControlDidChangeRepository()
}

/// Sidebar "Source Control": changed files split into staged and unstaged, a message
/// field and Commit / Pull / Push. Every action is a plain git command.
/// ponytail: whole files only — staging single hunks is the next step if needed.
final class SourceControlController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    weak var delegate: SourceControlDelegate?

    private(set) var entries: [GitStatusEntry] = []
    private var rows: [Row] = []
    private var repository: URL?
    private var refreshToken = 0

    private enum Row {
        case header(String, staged: Bool)
        case file(GitStatusEntry, staged: Bool)
    }

    private let branchLabel = NSTextField(labelWithString: "")
    let messageField = NSTextField()
    let commitButton = NSButton()
    private let pullButton = NSButton()
    private let pushButton = NSButton()
    private let refreshButton = NSButton()
    private let table = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var busy = false

    /// The folder open in the window; the repository is the git top level above it.
    var root: URL? {
        didSet {
            guard root != oldValue else { return }
            repository = nil
            entries = []
            refresh()
        }
    }

    override func loadView() {
        branchLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        branchLabel.textColor = .secondaryLabelColor
        branchLabel.lineBreakMode = .byTruncatingMiddle

        configure(refreshButton, symbol: "arrow.clockwise", tip: L("Refresh"), action: #selector(refreshPressed))
        configure(pullButton, symbol: "arrow.down.circle", tip: L("Pull"), action: #selector(pullPressed))
        configure(pushButton, symbol: "arrow.up.circle", tip: L("Push"), action: #selector(pushPressed))
        let header = NSStackView(views: [branchLabel, NSView(), pullButton, pushButton, refreshButton])
        header.spacing = 6

        messageField.placeholderString = L("Message (⌘↩ to commit)")
        messageField.font = .systemFont(ofSize: 12)
        messageField.usesSingleLineMode = false
        messageField.cell?.wraps = true
        messageField.cell?.isScrollable = false
        messageField.lineBreakMode = .byWordWrapping
        messageField.delegate = self
        messageField.setAccessibilityLabel(L("Commit message"))
        messageField.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

        commitButton.title = L("Commit")
        commitButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        commitButton.imagePosition = .imageLeading
        commitButton.bezelStyle = .rounded
        commitButton.controlSize = .regular
        commitButton.keyEquivalent = ""
        commitButton.target = self
        commitButton.action = #selector(commitPressed)
        commitButton.toolTip = L("Commit the staged changes (all changes if nothing is staged)")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = 22
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.doubleAction = #selector(rowDoubleClicked)
        table.setAccessibilityLabel(L("Changed files"))
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.maximumNumberOfLines = 3
        emptyLabel.lineBreakMode = .byWordWrapping

        let root = NSView()
        for view in [header, messageField, commitButton, scroll, emptyLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            messageField.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            messageField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            messageField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            commitButton.topAnchor.constraint(equalTo: messageField.bottomAnchor, constant: 6),
            commitButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            commitButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: commitButton.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -16),
        ])
        view = root
        updateChrome()
    }

    private func configure(_ button: NSButton, symbol: String, tip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tip
        button.setAccessibilityLabel(tip)
        button.target = self
        button.action = action
    }

    // MARK: Status

    /// Re-reads `git status` in the background. Cheap enough to call on every file change.
    func refresh(completion: (() -> Void)? = nil) {
        guard let root else {
            entries = []
            reloadRows()
            completion?()
            return
        }
        refreshToken += 1
        let token = refreshToken
        let known = repository
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let repository = known ?? GitClient.topLevel(of: root)
            let entries = repository.flatMap { try? GitClient.status($0) } ?? []
            let branch = repository.flatMap { GitClient.currentBranch($0) }
            DispatchQueue.main.async {
                guard let self, token == self.refreshToken else { return }
                self.repository = repository
                self.entries = entries
                self.branchLabel.stringValue = repository == nil ? "" : "⎇ " + (branch ?? L("detached HEAD"))
                self.reloadRows()
                completion?()
            }
        }
    }

    private func reloadRows() {
        let staged = entries.filter(\.hasStagedChanges)
        let unstaged = entries.filter(\.hasUnstagedChanges)
        rows = []
        if !staged.isEmpty {
            rows.append(.header(L("Staged Changes"), staged: true))
            rows += staged.map { .file($0, staged: true) }
        }
        if !unstaged.isEmpty {
            rows.append(.header(L("Changes"), staged: false))
            rows += unstaged.map { .file($0, staged: false) }
        }
        if isViewLoaded {
            table.reloadData()
            updateChrome()
        }
    }

    private func updateChrome() {
        let isRepo = repository != nil
        emptyLabel.isHidden = isRepo && !entries.isEmpty
        if root == nil {
            emptyLabel.stringValue = L("Open a folder to see its changes.")
        } else if !isRepo {
            emptyLabel.stringValue = L("This folder isn't a git repository.")
        } else {
            emptyLabel.stringValue = L("No changes.")
        }
        for control in [messageField, pullButton, pushButton, refreshButton] as [NSControl] { control.isEnabled = isRepo && !busy }
        commitButton.isEnabled = isRepo && !busy && !entries.isEmpty
        let count = entries.count
        commitButton.title = count == 0 ? L("Commit") : L("Commit (%@)", String(entries.filter(\.hasStagedChanges).isEmpty ? count : entries.filter(\.hasStagedChanges).count))
    }

    // MARK: Actions

    /// Runs git off the main thread, then refreshes; errors are shown in a sheet.
    private func perform(_ title: String, _ work: @escaping (URL) throws -> Void, done: (() -> Void)? = nil) {
        guard let repository, !busy else { return }
        busy = true
        updateChrome()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try work(repository) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                if case let .failure(error) = result {
                    let detail: String
                    if case let GitError.commandFailed(message)? = error as? GitError { detail = message } else { detail = error.localizedDescription }
                    (self.view.window?.windowController as? MainWindowController)?.presentMessage(title, detail: detail)
                } else {
                    done?()
                }
                self.refresh { self.delegate?.sourceControlDidChangeRepository() }
            }
        }
    }

    func stage(_ paths: [String]) {
        perform(L("Couldn't stage the changes.")) { try GitClient.stage($0, paths: paths) }
    }

    func unstage(_ paths: [String]) {
        perform(L("Couldn't unstage the changes.")) { try GitClient.unstage($0, paths: paths) }
    }

    @objc func commitPressed() {
        let message = messageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            NSSound.beep()
            view.window?.makeFirstResponder(messageField)
            return
        }
        // Like VS Code's "smart commit": nothing staged means commit everything.
        let stageAll = !entries.contains(where: \.hasStagedChanges)
        let paths = entries.map(\.path)
        perform(L("Couldn't commit.")) { repository in
            if stageAll { try GitClient.stage(repository, paths: paths) }
            try GitClient.commit(repository, message: message)
        } done: { [weak self] in
            self?.messageField.stringValue = ""
        }
    }

    @objc private func pullPressed() {
        perform(L("Couldn't pull.")) { _ = try GitClient.pull($0) }
    }

    @objc private func pushPressed() {
        perform(L("Couldn't push.")) { _ = try GitClient.push($0) }
    }

    @objc private func refreshPressed() {
        refresh { [weak self] in self?.delegate?.sourceControlDidChangeRepository() }
    }

    @objc private func rowClicked() {
        guard table.clickedRow >= 0, let repository else { return }
        // The stage/unstage button handles its own clicks.
        if case let .file(entry, staged) = rows[table.clickedRow] {
            delegate?.sourceControl(showDiffOf: entry, staged: staged, root: repository)
        }
    }

    @objc private func rowDoubleClicked() {
        guard table.clickedRow >= 0, let repository, case let .file(entry, _) = rows[table.clickedRow], !entry.worktree.isDeletion else { return }
        delegate?.sourceControl(open: repository.appendingPathComponent(entry.path))
    }

    @objc fileprivate func toggleStage(_ sender: NSButton) {
        let row = table.row(for: sender)
        guard row >= 0 else { return }
        switch rows[row] {
        case let .file(entry, staged): staged ? unstage([entry.path]) : stage([entry.path])
        case let .header(_, staged): staged ? unstage(entries.filter(\.hasStagedChanges).map(\.path)) : stage(entries.filter(\.hasUnstagedChanges).map(\.path))
        }
    }

    // ⌘↩ in the message commits.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)), NSApp.currentEvent?.modifierFlags.contains(.command) == true {
            commitPressed()
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            textView.insertNewlineIgnoringFieldEditor(nil)
            return true
        }
        return false
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .header = rows[row] { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = ChangeRowView()
        switch rows[row] {
        case let .header(title, staged):
            cell.configureHeader(title: title, count: staged ? entries.filter(\.hasStagedChanges).count : entries.filter(\.hasUnstagedChanges).count, staged: staged, target: self)
        case let .file(entry, staged):
            cell.configure(entry: entry, staged: staged, target: self)
        }
        return cell
    }
}

extension SourceControlController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard table.clickedRow >= 0, case let .file(entry, staged) = rows[table.clickedRow] else { return }
        let stageItem = NSMenuItem(title: staged ? L("Unstage") : L("Stage"), action: #selector(menuToggle(_:)), keyEquivalent: "")
        stageItem.representedObject = [entry.path, staged] as [Any]
        stageItem.target = self
        menu.addItem(stageItem)
        let openItem = NSMenuItem(title: L("Open File"), action: #selector(rowDoubleClicked), keyEquivalent: "")
        openItem.target = self
        openItem.isEnabled = !entry.worktree.isDeletion
        menu.addItem(openItem)
    }

    @objc private func menuToggle(_ item: NSMenuItem) {
        guard let info = item.representedObject as? [Any], let path = info[0] as? String, let staged = info[1] as? Bool else { return }
        staged ? unstage([path]) : stage([path])
    }
}

private extension Character {
    var isDeletion: Bool { self == "D" }
}

/// A row: status letter, file name, folder, and a +/− button to stage or unstage.
private final class ChangeRowView: NSTableCellView {
    private let status = NSTextField(labelWithString: "")
    private let name = NSTextField(labelWithString: "")
    private let folder = NSTextField(labelWithString: "")
    private let button = NSButton()

    init() {
        super.init(frame: .zero)
        status.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        status.alignment = .center
        name.font = .systemFont(ofSize: 12)
        name.lineBreakMode = .byTruncatingMiddle
        folder.font = .systemFont(ofSize: 10)
        folder.textColor = .tertiaryLabelColor
        folder.lineBreakMode = .byTruncatingHead
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        let stack = NSStackView(views: [status, name, folder, NSView(), button])
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        status.widthAnchor.constraint(equalToConstant: 14).isActive = true
        name.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        folder.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func configureHeader(title: String, count: Int, staged: Bool, target: SourceControlController) {
        status.isHidden = true
        name.stringValue = title.uppercased()
        name.font = .systemFont(ofSize: 10, weight: .semibold)
        name.textColor = .secondaryLabelColor
        folder.stringValue = "\(count)"
        setButton(staged: staged, target: target, all: true)
    }

    func configure(entry: GitStatusEntry, staged: Bool, target: SourceControlController) {
        let letter: Character = entry.isUntracked ? "U" : (staged ? entry.index : entry.worktree)
        status.stringValue = entry.isUntracked ? "U" : (entry.isConflicted ? "!" : String(letter))
        status.textColor = {
            if entry.isConflicted { return .systemRed }
            switch letter {
            case "A", "U", "?": return .systemGreen
            case "D": return .systemRed
            case "R", "C": return .systemPurple
            default: return .systemOrange
            }
        }()
        let url = URL(fileURLWithPath: entry.path)
        name.stringValue = url.lastPathComponent
        name.textColor = letter == "D" ? .secondaryLabelColor : .labelColor
        let dir = url.deletingLastPathComponent().relativePath
        folder.stringValue = dir == "." ? "" : (entry.oldPath.map { "← " + $0 } ?? dir)
        setAccessibilityLabel("\(url.lastPathComponent), \(status.stringValue)")
        setButton(staged: staged, target: target, all: false)
    }

    private func setButton(staged: Bool, target: SourceControlController, all: Bool) {
        let tip = staged ? (all ? L("Unstage All") : L("Unstage")) : (all ? L("Stage All") : L("Stage"))
        button.image = NSImage(systemSymbolName: staged ? "minus" : "plus", accessibilityDescription: tip)
        button.toolTip = tip
        button.setAccessibilityLabel(tip)
        button.target = target
        button.action = #selector(SourceControlController.toggleStage(_:))
    }
}
