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
                    let document = Document(mode: .code)
                    document.customDisplayName = "\(commit.shortHash) · \(path)"
                    document.apply(.plain(diff, .standard))
                    document.setLanguage(LanguageRegistry.plainText, manual: true)
                    let tab = self.addTab(document)
                    if let textView = tab.editor?.textView {
                        textView.isEditable = false
                        self.tintDiffLines(textView)
                    }
                    tab.editor?.applyPreferences()
                case let .failure(error):
                    self.presentMessage(L("Couldn't produce the diff."), detail: error.localizedDescription)
                }
            }
        }
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
