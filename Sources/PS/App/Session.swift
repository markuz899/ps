import AppKit
import PSCore

/// Recently opened files and folders (UserDefaults), shown in File ▸ Open Recent and on
/// the welcome screen.
enum Recents {
    private static let key = "recentItems"
    private static let limit = 20

    static var items: [URL] {
        (Prefs.defaults.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0) }
    }

    static func add(_ url: URL) {
        guard !Bench.isActive else { return }
        var paths = Prefs.defaults.stringArray(forKey: key) ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        Prefs.defaults.set(Array(paths.prefix(limit)), forKey: key)
    }

    static func remove(_ url: URL) {
        let paths = (Prefs.defaults.stringArray(forKey: key) ?? []).filter { $0 != url.path }
        Prefs.defaults.set(paths, forKey: key)
    }

    static func clear() {
        Prefs.defaults.removeObject(forKey: key)
    }
}

/// Session restore: folder, tabs, active tab, cursor positions, plus the per-file choices
/// (language picked by hand, .txt opened in the other mode).
enum Session {
    private static let key = "session"
    private static let modesKey = "modeOverrides"
    private static let languagesKey = "languageOverrides"

    /// True while a session is being restored: saving then would store a half-restored
    /// session and delete backups that haven't been read yet.
    private static var restoring = false

    /// Saves every window (the argument only says "something changed").
    static func save(_ controller: MainWindowController?) {
        let windows = MainWindowController.all
        // Not registered yet (a window being built): don't overwrite the saved session.
        guard !windows.isEmpty, !restoring else { return }
        Prefs.defaults.set(["windows": windows.map(state(of:))], forKey: key)
        removeStaleBackups(keeping: Set(windows.flatMap(\.tabs).filter { $0.document.url == nil }.map(\.document.backupID)))
    }

    // MARK: Unsaved (untitled) documents

    static var backupFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // One folder per app identity: the cleanup of a development build must never
        // touch the backups of the installed app.
        let owner = Bundle.main.bundleIdentifier ?? "development"
        return support.appendingPathComponent("PS/Unsaved/\(owner)", isDirectory: true)
    }

    private static func backupURL(for document: Document) -> URL {
        let ext: String
        switch document.mode {
        case .code: ext = "txt"
        case .rich: ext = "rtfd"
        case .board: ext = "excalidraw"
        }
        return backupFolder.appendingPathComponent(document.backupID).appendingPathExtension(ext)
    }

    /// Writes the untitled document's text if it changed since the last backup.
    private static func backUp(_ document: Document) -> URL? {
        let url = backupURL(for: document)
        if document.backedUpVersion == document.version, FileManager.default.fileExists(atPath: url.path) { return url }
        do {
            try FileManager.default.createDirectory(at: backupFolder, withIntermediateDirectories: true)
            switch document.mode {
            case .code:
                try SafeWriter.write(try TextFileIO.encode(document.textStorage.string, format: .standard), to: url)
            case .rich:
                try RichTextIO.write(NSAttributedString(attributedString: document.textStorage), to: url, kind: .rtfd)
            case .board:
                try SafeWriter.write(try document.board.encoded(), to: url)
            }
            document.backedUpVersion = document.version
            return url
        } catch {
            return nil
        }
    }

    private static func removeStaleBackups(keeping ids: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(at: backupFolder, includingPropertiesForKeys: nil)) ?? []
        for file in files where !ids.contains(file.deletingPathExtension().lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func state(of controller: MainWindowController) -> [String: Any] {
        let panes: [[String: Any]] = controller.panes.map { pane in
            let tabs: [[String: Any]] = pane.tabs.compactMap { tab in
                guard !tab.document.isReadOnly else { return nil }
                let cursor = tab.editor?.textView.selectedRange().location ?? 0
                let document = tab.document
                guard let url = document.url else {
                    // Empty untitled tabs aren't worth bringing back.
                    guard document.hasContent, backUp(document) != nil else { return nil }
                    return ["untitled": document.backupID, "mode": document.mode.rawValue, "language": document.language.id, "cursor": cursor]
                }
                return ["path": url.path, "cursor": cursor]
            }
            return ["tabs": tabs, "active": pane.activeTab?.document.url?.path ?? ""]
        }
        var state: [String: Any] = [
            "panes": panes,
            "activePane": controller.panes.firstIndex { $0 === controller.activePane } ?? 0,
        ]
        if let folder = controller.folder { state["folder"] = folder.path }
        if let frame = controller.window?.frame { state["frame"] = NSStringFromRect(frame) }
        state["sidebarCollapsed"] = controller.isSidebarCollapsed
        return state
    }

    /// The first saved window goes into `controller`; any others get new windows.
    static func restore(into controller: MainWindowController, completion: @escaping () -> Void) {
        guard let saved = Prefs.defaults.dictionary(forKey: key) else {
            completion()
            return
        }
        // Older sessions held one window at the top level.
        let windows = saved["windows"] as? [[String: Any]] ?? [saved]
        restoring = true
        func next(_ index: Int) {
            guard index < windows.count else {
                restoring = false
                save(controller)
                completion()
                return
            }
            var target = controller
            if index > 0, let delegate = NSApp.delegate as? AppDelegate {
                target = delegate.newWindow(cascadingFrom: controller)
                if let frame = windows[index]["frame"] as? String { target.window?.setFrame(NSRectFromString(frame), display: false) }
            }
            restoreWindow(windows[index], into: target) { next(index + 1) }
        }
        next(0)
    }

    private static func restoreWindow(_ state: [String: Any], into controller: MainWindowController, completion: @escaping () -> Void) {
        if let folder = state["folder"] as? String, FileManager.default.fileExists(atPath: folder) {
            controller.openWorkspace(URL(fileURLWithPath: folder))
        }
        if state["sidebarCollapsed"] as? Bool == true { controller.setSidebarCollapsed(true, animated: false) }
        // Older sessions had a single "tabs" list.
        let saved = state["panes"] as? [[String: Any]] ?? [["tabs": state["tabs"] ?? [], "active": state["active"] ?? ""]]
        let panes = saved.map { pane -> (tabs: [[String: Any]], active: String) in
            let tabs = (pane["tabs"] as? [[String: Any]] ?? []).filter { entry in
                if let id = entry["untitled"] as? String {
                    return backupFile(id) != nil
                }
                return FileManager.default.fileExists(atPath: entry["path"] as? String ?? "")
            }
            return (tabs, pane["active"] as? String ?? "")
        }.filter { !$0.tabs.isEmpty }
        let activePane = state["activePane"] as? Int ?? 0
        var activeTabs: [Tab?] = Array(repeating: nil, count: panes.count)

        // Panes and tabs are opened one after another so the saved order is kept.
        func openPane(_ index: Int) {
            guard index < panes.count else {
                for tab in activeTabs.compactMap({ $0 }) { controller.activate(tab) }
                if activeTabs.indices.contains(activePane), let tab = activeTabs[activePane] { controller.activate(tab) }
                completion()
                return
            }
            let pane = index == 0 ? controller.panes[0] : controller.appendPane()
            func next(_ remaining: ArraySlice<[String: Any]>) {
                guard let entry = remaining.first else {
                    openPane(index + 1)
                    return
                }
                if let id = entry["untitled"] as? String, let file = backupFile(id),
                   let mode = EditorMode(rawValue: entry["mode"] as? String ?? ""),
                   let content = try? Document.read(file, mode: mode) {
                    let language = (entry["language"] as? String).flatMap(LanguageRegistry.language(id:))
                    let tab = controller.restoreUntitled(content, mode: mode, backupID: id, language: mode == .code ? language : nil, in: pane)
                    if let view = tab.editor?.textView, let cursor = entry["cursor"] as? Int {
                        view.setSelectedRange(NSRange(location: min(cursor, (view.string as NSString).length), length: 0))
                    }
                    next(remaining.dropFirst())
                    return
                }
                guard let path = entry["path"] as? String else {
                    next(remaining.dropFirst())
                    return
                }
                controller.open(URL(fileURLWithPath: path), in: pane) { tab in
                    guard let tab else {
                        next(remaining.dropFirst())
                        return
                    }
                    if let view = tab.editor?.textView, let cursor = entry["cursor"] as? Int {
                        let location = min(cursor, (view.string as NSString).length)
                        view.setSelectedRange(NSRange(location: location, length: 0))
                        // Scroll after the first layout pass so the caret ends up on screen.
                        DispatchQueue.main.async { view.scrollRangeToVisible(view.selectedRange()) }
                    }
                    if path == panes[index].active { activeTabs[index] = tab }
                    next(remaining.dropFirst())
                }
            }
            next(panes[index].tabs[...])
        }
        openPane(0)
    }

    private static func backupFile(_ id: String) -> URL? {
        for ext in ["txt", "rtfd", "excalidraw"] {
            let url = backupFolder.appendingPathComponent(id).appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    static func modeOverride(for url: URL) -> EditorMode? {
        (Prefs.defaults.dictionary(forKey: modesKey)?[url.path] as? String).flatMap(EditorMode.init(rawValue:))
    }

    static func setModeOverride(_ mode: EditorMode, for url: URL) {
        var map = Prefs.defaults.dictionary(forKey: modesKey) ?? [:]
        map[url.path] = mode == EditorMode.forFile(url) ? nil : mode.rawValue
        Prefs.defaults.set(map, forKey: modesKey)
    }

    static func languageOverride(for url: URL) -> Language? {
        (Prefs.defaults.dictionary(forKey: languagesKey)?[url.path] as? String).flatMap(LanguageRegistry.language(id:))
    }

    static func setLanguageOverride(_ language: Language, for url: URL) {
        var map = Prefs.defaults.dictionary(forKey: languagesKey) ?? [:]
        map[url.path] = language.id
        Prefs.defaults.set(map, forKey: languagesKey)
    }
}
