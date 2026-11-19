import AppKit
import PSCore

// MARK: - Git Graph commands and delegate wiring

extension MainWindowController {
    @objc func showGitGraph(_ sender: Any?) {
        setSidebarCollapsed(false)
        sidebar.showGraph()
    }

    func setGitDetailCollapsed(_ collapsed: Bool) {
        guard let item = gitDetailItem, item.isCollapsed != collapsed else { return }
        item.animator().isCollapsed = collapsed
    }

    private func showCommitDetail(_ hash: String) {
        gitDetail.show(commit: hash, in: sidebar.graph.store)
        setGitDetailCollapsed(false)
    }

    /// Read-only tab with the unified diff of one file in a commit, +/- lines tinted.
    func openGitDiff(commit: GitCommit, path: String) {
        guard let folder else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try GitClient.diff(folder, commit: commit, path: path) }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case let .success(diff):
                    self.showDiffTab(title: "\(commit.shortHash) · \(path)", diff: diff)
                case let .failure(error):
                    self.presentMessage(L("Couldn't produce the diff."), detail: error.localizedDescription)
                }
            }
        }
    }

    /// A read-only tab with a unified diff. A diff tab with the same title is reused.
    @discardableResult
    func showDiffTab(title: String, diff: String) -> Tab {
        if let existing = tabs.first(where: { $0.document.isReadOnly && $0.document.customDisplayName == title }) {
            existing.document.apply(.plain(diff, .standard))
            if let textView = existing.editor?.textView { tintDiffLines(textView) }
            activate(existing)
            return existing
        }
        let document = Document(mode: .code)
        document.customDisplayName = title
        document.isReadOnly = true
        document.apply(.plain(diff, .standard))
        document.setLanguage(LanguageRegistry.plainText, manual: true)
        let tab = addTab(document)
        if let textView = tab.editor?.textView {
            textView.isEditable = false
            tintDiffLines(textView)
        }
        tab.editor?.applyPreferences()
        return tab
    }

    @objc func showSourceControl(_ sender: Any?) {
        setSidebarCollapsed(false)
        sidebar.showChanges()
    }

    /// Code editors re-read their changed lines; the graph reloads.
    func refreshGitState() {
        sidebar.graph.notifyRepoChanged()
        for tab in tabs { (tab.editor as? CodeEditor)?.refreshGitChanges() }
    }

    private func tintDiffLines(_ view: NSTextView) {
        guard let storage = view.textStorage else { return }
        let text = storage.string as NSString
        let green = NSColor.systemGreen.withAlphaComponent(0.14)
        let red = NSColor.systemRed.withAlphaComponent(0.14)
        var location = 0
        while location < text.length {
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            let line = text.substring(with: lineRange)
            if line.hasPrefix("+"), !line.hasPrefix("+++") {
                storage.addAttribute(.backgroundColor, value: green, range: lineRange)
            } else if line.hasPrefix("-"), !line.hasPrefix("---") {
                storage.addAttribute(.backgroundColor, value: red, range: lineRange)
            } else if line.hasPrefix("@@") {
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: lineRange)
            }
            location = NSMaxRange(lineRange)
        }
    }

    private func confirmAndCheckout(_ hash: String) {
        guard let folder else { return }
        ask(
            L("Checkout commit %@?", String(hash.prefix(7))),
            detail: L("This switches the working tree to that commit. Uncommitted changes may be overwritten."),
            buttons: [L("Checkout"), L("Cancel")]
        ) { [weak self] choice in
            guard choice == 0, let self else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try GitClient.checkout(folder, hash) }
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        self.sidebar.graph.notifyRepoChanged()
                    case let .failure(error):
                        self.presentMessage(L("Checkout failed."), detail: error.localizedDescription)
                    }
                }
            }
        }
    }

    private func promptAndCreateBranch(_ hash: String) {
        guard let folder, let window else { return }
        let alert = NSAlert()
        alert.messageText = L("Create a branch at %@", String(hash.prefix(7)))
        alert.informativeText = L("The branch will point at this commit.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = L("branch-name")
        alert.accessoryView = field
        alert.addButton(withTitle: L("Create"))
        alert.addButton(withTitle: L("Cancel"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains(" ") else {
                self.presentMessage(L("Invalid branch name."), detail: L("Use letters, digits, -, _, /, . — no spaces."))
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try GitClient.createBranch(folder, name, at: hash) }
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        self.sidebar.graph.notifyRepoChanged()
                    case let .failure(error):
                        self.presentMessage(L("Couldn't create the branch."), detail: error.localizedDescription)
                    }
                }
            }
        }
    }
}

extension MainWindowController: GitGraphDelegate {
    func gitGraph(didSelectCommit hash: String) {
        showCommitDetail(hash)
    }

    func gitGraph(didRequestDiff commit: GitCommit, path: String) {
        openGitDiff(commit: commit, path: path)
    }

    func gitGraph(didRequestCheckout hash: String) {
        confirmAndCheckout(hash)
    }

    func gitGraph(didRequestCreateBranch hash: String) {
        promptAndCreateBranch(hash)
    }
}

extension MainWindowController: GitCommitDetailDelegate {
    func gitDetail(didSelectCommit hash: String) {
        sidebar.graph.select(hash: hash)
        showCommitDetail(hash)
    }

    func gitDetail(didOpenFile commit: GitCommit, path: String) {
        openGitDiff(commit: commit, path: path)
    }

    func gitDetailDidClose() {
        setGitDetailCollapsed(true)
    }
}

extension MainWindowController: SourceControlDelegate {
    func sourceControl(showDiffOf entry: GitStatusEntry, staged: Bool, root: URL) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try GitClient.workingDiff(root, entry: entry, staged: staged) }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case let .success(diff):
                    let suffix = staged ? L("staged") : L("working copy")
                    self.showDiffTab(title: "\(URL(fileURLWithPath: entry.path).lastPathComponent) (\(suffix))", diff: diff.isEmpty ? L("No differences.") : diff)
                case let .failure(error):
                    self.presentMessage(L("Couldn't produce the diff."), detail: error.localizedDescription)
                }
            }
        }
    }

    func sourceControl(open url: URL) {
        open(url)
    }

    func sourceControlDidChangeRepository() {
        refreshGitState()
    }
}

// MARK: - Go to definition and completion

extension MainWindowController {
    /// Indexes the folder's declarations in the background (⌘-click, completion).
    func rebuildSymbolIndex() {
        symbols.removeAll()
        guard let folder else {
            symbols.update(tabs.compactMap(\.document.url))
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self, symbols] in
            let files = FolderSearch.files(in: folder, includeHidden: false)
            symbols.update(files)
            DispatchQueue.main.async { self?.symbolIndexReady = true }
        }
    }

    /// The identifier under `index` in `text`, if any.
    static func word(in text: NSString, at index: Int) -> String? {
        guard text.length > 0 else { return nil }
        let characters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_$"))
        var start = min(index, text.length)
        var end = start
        while start > 0, let scalar = Unicode.Scalar(text.character(at: start - 1)), characters.contains(scalar) { start -= 1 }
        while end < text.length, let scalar = Unicode.Scalar(text.character(at: end)), characters.contains(scalar) { end += 1 }
        guard end > start else { return nil }
        let word = text.substring(with: NSRange(location: start, length: end - start))
        return word.first?.isNumber == true ? nil : word
    }

    /// Opens where `name` is declared; with several candidates, a menu lets you pick.
    func goToDefinition(of name: String, from view: NSView, at point: NSPoint) {
        let current = activeTab?.document.url
        let found = symbols.definitions(of: name, preferring: current)
        guard !found.isEmpty else {
            NSSound.beep()
            return
        }
        if found.count == 1 {
            reveal(found[0])
            return
        }
        let menu = NSMenu()
        for location in found.prefix(20) {
            let item = NSMenuItem(title: "\(relativePath(of: location.url)):\(location.line + 1)  \(location.kind) \(location.name)", action: #selector(definitionPicked(_:)), keyEquivalent: "")
            item.representedObject = location.url.path + "\u{0}" + String(location.line)
            item.target = self
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: point, in: view)
    }

    @objc private func definitionPicked(_ item: NSMenuItem) {
        guard let info = (item.representedObject as? String)?.components(separatedBy: "\u{0}"), info.count == 2, let line = Int(info[1]) else { return }
        reveal(SymbolIndex.Location(url: URL(fileURLWithPath: info[0]), line: line, kind: "", name: ""))
    }

    private func relativePath(of url: URL) -> String {
        guard let folder, url.path.hasPrefix(folder.path + "/") else { return url.lastPathComponent }
        return String(url.path.dropFirst(folder.path.count + 1))
    }

    /// Opens the file and selects the declaration's line.
    func reveal(_ location: SymbolIndex.Location) {
        open(location.url) { [weak self] tab in
            guard let self, let tab, let textView = tab.editor?.textView else { return }
            let text = tab.document.textStorage.mutableString
            let lineIndex = tab.document.lineIndex
            let start = lineIndex.start(ofLine: min(location.line, max(0, lineIndex.lineCount - 1)))
            let range = text.lineRange(for: NSRange(location: min(start, text.length), length: 0))
            var trimmed = range
            while trimmed.length > 0, let scalar = Unicode.Scalar(text.character(at: NSMaxRange(trimmed) - 1)), CharacterSet.newlines.contains(scalar) { trimmed.length -= 1 }
            self.select(trimmed, in: tab)
            textView.showFindIndicator(for: trimmed)
        }
    }

    /// F12: the word at the caret.
    @objc func goToDefinitionAtCaret(_ sender: Any?) {
        guard let textView = activeTab?.editor?.textView, activeTab?.document.mode == .code,
              let word = MainWindowController.word(in: textView.textStorage!.mutableString, at: textView.selectedRange().location) else {
            NSSound.beep()
            return
        }
        let caret = textView.firstRect(forCharacterRange: textView.selectedRange(), actualRange: nil)
        let point = textView.window.map { textView.convert($0.convertPoint(fromScreen: caret.origin), from: nil) } ?? .zero
        goToDefinition(of: word, from: textView, at: point)
    }
}
