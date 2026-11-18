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

    /// Saves every window (the argument only says "something changed").
    static func save(_ controller: MainWindowController?) {
        let windows = MainWindowController.all
        // Not registered yet (a window being built): don't overwrite the saved session.
        guard !windows.isEmpty else { return }
        Prefs.defaults.set(["windows": windows.map(state(of:))], forKey: key)
    }

    private static func state(of controller: MainWindowController) -> [String: Any] {
        let panes: [[String: Any]] = controller.panes.map { pane in
            let tabs: [[String: Any]] = pane.tabs.compactMap { tab in
                guard let url = tab.document.url else { return nil }
                return ["path": url.path, "cursor": tab.editor?.textView.selectedRange().location ?? 0]
            }
            return ["tabs": tabs, "active": pane.activeTab?.document.url?.path ?? ""]
        }
        var state: [String: Any] = [
            "panes": panes,
            "activePane": controller.panes.firstIndex { $0 === controller.activePane } ?? 0,
        ]
        if let folder = controller.folder { state["folder"] = folder.path }
        if let frame = controller.window?.frame { state["frame"] = NSStringFromRect(frame) }
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
        func next(_ index: Int) {
            guard index < windows.count else {
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
        // Older sessions had a single "tabs" list.
        let saved = state["panes"] as? [[String: Any]] ?? [["tabs": state["tabs"] ?? [], "active": state["active"] ?? ""]]
        let panes = saved.map { pane -> (tabs: [[String: Any]], active: String) in
            let tabs = (pane["tabs"] as? [[String: Any]] ?? []).filter {
                FileManager.default.fileExists(atPath: $0["path"] as? String ?? "")
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
                guard let entry = remaining.first, let path = entry["path"] as? String else {
                    openPane(index + 1)
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
