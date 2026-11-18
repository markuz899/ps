import AppKit
import PSCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private(set) var controllers: [MainWindowController] = []

    /// The window commands go to: the frontmost editor window.
    var controller: MainWindowController! {
        (NSApp.keyWindow?.windowController as? MainWindowController)
            ?? (NSApp.mainWindow?.windowController as? MainWindowController)
            ?? controllers.first
    }
    private var settingsWindow: NSWindow?
    private var pendingOpen: [URL] = []
    private var launched = false
    private let recentMenu = NSMenu(title: L("Open Recent"))

    func applicationWillFinishLaunching(_ notification: Notification) {
        Prefs.register()
        NSApp.mainMenu = buildMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let first = MainWindowController()
        controllers = [first]
        first.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        launched = true

        if Bench.isActive {
            Bench.run(controller)
            return
        }
        if SelfTest.isActive {
            SelfTest.run(controller)
            return
        }
        let files = pendingOpen
        pendingOpen = []
        if files.isEmpty {
            Session.restore(into: controller) {}
        } else {
            files.forEach { controller.open($0) }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard launched else {
            pendingOpen += urls
            return
        }
        urls.forEach { controller.open($0) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Untitled documents don't need an answer: they are backed up and restored.
        let dirty = controllers.filter { $0.tabs.contains { $0.document.isDirty && $0.document.url != nil } }
        guard !SelfTest.isActive, !dirty.isEmpty else { return .terminateNow }
        // One window after another, each asking about its own documents.
        func next(_ remaining: ArraySlice<MainWindowController>) {
            guard let window = remaining.first else {
                NSApp.reply(toApplicationShouldTerminate: true)
                return
            }
            window.window?.makeKeyAndOrderFront(nil)
            window.confirmCloseAll(includeUntitled: false) { proceed in
                proceed ? next(remaining.dropFirst()) : NSApp.reply(toApplicationShouldTerminate: false)
            }
        }
        next(dirty[...])
        return .terminateLater
    }

    func newWindow(cascadingFrom source: MainWindowController?) -> MainWindowController {
        let window = MainWindowController(primary: false)
        controllers.append(window)
        if let frame = source?.window?.frame ?? controller?.window?.frame {
            window.window?.setFrame(frame.offsetBy(dx: 28, dy: -28), display: false)
        }
        window.showWindow(nil)
        return window
    }

    func remove(_ window: MainWindowController) {
        controllers.removeAll { $0 === window }
    }

    @objc func newEditorWindow(_ sender: Any?) {
        _ = newWindow(cascadingFrom: controller)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if !Bench.isActive && !SelfTest.isActive { Session.save(controller) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: Forwarding
    //
    // Document commands live on the window controller. When another window is key (e.g.
    // Settings) the responder chain ends here, so those actions are forwarded.

    private func forwards(_ selector: Selector) -> Bool {
        controller != nil
            && MainWindowController.instancesRespond(to: selector)
            && !NSWindowController.instancesRespond(to: selector)
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || forwards(selector)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        forwards(selector) ? controller : super.forwardingTarget(for: selector)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let action = menuItem.action, forwards(action) { return controller.validateMenuItem(menuItem) }
        return true
    }

    // MARK: App commands

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil { settingsWindow = SettingsHost.makeWindow() }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showAbout(_ sender: Any?) {
        let credits = NSAttributedString(
            string: L("Prose & Source — one fast editor for code and documents."),
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        )
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationIcon: AppIcon.image(size: 256),
            .applicationName: "PS",
            .credits: credits,
        ])
    }

    @objc func openRecentItem(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { controller.open(url) }
    }

    @objc func clearRecents(_ sender: Any?) {
        Recents.clear()
        NSDocumentController.shared.clearRecentDocuments(nil)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        for url in Recents.items {
            let item = menu.addItem(withTitle: url.lastPathComponent, action: #selector(openRecentItem(_:)), keyEquivalent: "")
            item.representedObject = url
            item.target = self
            item.toolTip = url.path
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            item.image = FileIcon.image(for: url, isDirectory: isDirectory.boolValue && url.pathExtension != "rtfd")
        }
        if menu.items.isEmpty { menu.addItem(withTitle: L("No Recent Items"), action: nil, keyEquivalent: "").isEnabled = false }
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Clear Menu"), action: #selector(clearRecents(_:)), keyEquivalent: "").target = self
    }

    // MARK: Menus

    private func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.tag = tag
        return item
    }

    private func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        menu(title, items)
    }

    private func encodingItems(_ action: Selector) -> [NSMenuItem] {
        TextFileIO.supportedEncodings.map { item(TextFileIO.displayName(of: $0), action, "", [], tag: Int($0.rawValue)) }
    }

    private func buildMainMenu() -> NSMenu {
        typealias W = MainWindowController
        let main = NSMenu()
        let undo = Selector(("undo:"))
        let redo = Selector(("redo:"))

        let services = NSMenu()
        NSApp.servicesMenu = services
        let servicesItem = item(L("Services"), nil)
        servicesItem.submenu = services

        main.addItem(menu("PS", [
            item(L("About PS"), #selector(showAbout(_:))),
            .separator(),
            item(L("Settings…"), #selector(showSettings(_:)), ","),
            .separator(),
            servicesItem,
            .separator(),
            item(L("Hide PS"), #selector(NSApplication.hide(_:)), "h"),
            item(L("Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item(L("Show All"), #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item(L("Quit PS"), #selector(NSApplication.terminate(_:)), "q"),
        ]))

        recentMenu.delegate = self
        let recentItem = item(L("Open Recent"), nil)
        recentItem.submenu = recentMenu
        main.addItem(menu(L("File"), [
            item(L("New File"), #selector(W.newCodeFile(_:)), "n"),
            item(L("New Text Document"), #selector(W.newRichDocument(_:)), "n", [.command, .shift]),
            .separator(),
            item(L("Open…"), #selector(W.openDocument(_:)), "o"),
            item(L("Open Folder…"), #selector(W.openFolder(_:)), "o", [.command, .shift]),
            recentItem,
            item(L("Quick Open…"), #selector(W.quickOpenFile(_:)), "p"),
            item(L("Command Palette…"), #selector(W.showCommandPalette(_:)), "p", [.command, .shift]),
            .separator(),
            item(L("Save"), #selector(W.saveDocument(_:)), "s"),
            item(L("Save As…"), #selector(W.saveDocumentAs(_:)), "s", [.command, .shift]),
            item(L("Save All"), #selector(W.saveAllDocuments(_:)), "s", [.command, .option]),
            item(L("Revert to Saved"), #selector(W.revertDocumentToSaved(_:))),
            .separator(),
            submenu(L("Reopen with Encoding"), encodingItems(#selector(W.reopenWithEncoding(_:)))),
            submenu(L("Save with Encoding"), encodingItems(#selector(W.saveWithEncoding(_:)))),
            item(L("Open as Plain Text"), #selector(W.openAsPlainText(_:))),
            item(L("Open as Formatted Document"), #selector(W.openAsFormattedDocument(_:))),
            .separator(),
            item(L("Export as PDF…"), #selector(W.exportPDF(_:))),
            item(L("Export as Word (.docx)…"), #selector(W.exportWord(_:))),
            item(L("Export as HTML…"), #selector(W.exportHTML(_:))),
            .separator(),
            item(L("Close Tab"), #selector(W.closeActiveTab(_:)), "w"),
            item(L("Close Window"), #selector(NSWindow.performClose(_:)), "w", [.command, .shift]),
            .separator(),
            item(L("Page Setup…"), #selector(NSApplication.runPageLayout(_:)), "p", [.command, .shift, .option]),
            item(L("Print…"), #selector(W.printDocument(_:)), "p", [.command, .option]),
        ]))

        main.addItem(menu(L("Edit"), [
            item(L("Undo"), undo, "z"),
            item(L("Redo"), redo, "z", [.command, .shift]),
            .separator(),
            item(L("Cut"), #selector(NSText.cut(_:)), "x"),
            item(L("Copy"), #selector(NSText.copy(_:)), "c"),
            item(L("Paste"), #selector(NSText.paste(_:)), "v"),
            item(L("Paste and Match Style"), #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]),
            item(L("Delete"), #selector(NSText.delete(_:))),
            item(L("Select All"), #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            submenu(L("Find"), [
                item(L("Find…"), #selector(W.showFind(_:)), "f"),
                item(L("Find and Replace…"), #selector(W.showFindReplace(_:)), "f", [.command, .option]),
                item(L("Find Next"), #selector(W.findNextMatch(_:)), "g"),
                item(L("Find Previous"), #selector(W.findPreviousMatch(_:)), "g", [.command, .shift]),
                item(L("Use Selection for Find"), #selector(W.useSelectionForFind(_:)), "e"),
                .separator(),
                item(L("Find in Folder…"), #selector(W.showFolderSearch(_:)), "f", [.command, .shift]),
            ]),
            submenu(L("Spelling and Grammar"), [
                item(L("Show Spelling and Grammar"), #selector(NSText.showGuessPanel(_:)), ":"),
                item(L("Check Document Now"), #selector(NSText.checkSpelling(_:)), ";"),
                item(L("Check Spelling While Typing"), #selector(NSTextView.toggleContinuousSpellChecking(_:))),
            ]),
        ]))

        let paragraphItems = ParagraphKind.allCases.map { kind in
            item(kind.title, #selector(RichTextView.applyParagraphKindFromMenu(_:)), "\(kind.rawValue)", [.command, .option], tag: kind.rawValue)
        }
        main.addItem(menu(L("Format"), [
            item(L("Bold"), #selector(RichTextView.toggleBold(_:)), "b"),
            item(L("Italic"), #selector(RichTextView.toggleItalic(_:)), "i"),
            item(L("Underline"), #selector(RichTextView.toggleUnderline(_:)), "u"),
            item(L("Strikethrough"), #selector(RichTextView.toggleStrikethrough(_:)), "x", [.command, .shift]),
            .separator(),
            submenu(L("Paragraph Style"), paragraphItems),
            submenu(L("Alignment"), [
                item(L("Align Left"), #selector(NSText.alignLeft(_:)), "{"),
                item(L("Center"), #selector(NSText.alignCenter(_:)), "|"),
                item(L("Align Right"), #selector(NSText.alignRight(_:)), "}"),
                item(L("Justify"), #selector(NSTextView.alignJustified(_:))),
            ]),
            item(L("Bulleted List"), #selector(RichTextView.toggleBulletList(_:)), "8", [.command, .shift]),
            item(L("Numbered List"), #selector(RichTextView.toggleNumberedList(_:)), "7", [.command, .shift]),
            item(L("Increase Indent"), #selector(RichTextView.psIndent(_:)), "]"),
            item(L("Decrease Indent"), #selector(RichTextView.psOutdent(_:)), "["),
            .separator(),
            item(L("Insert Link…"), #selector(RichTextView.insertLink(_:)), "k"),
            item(L("Insert Table…"), #selector(NSTextView.orderFrontTablePanel(_:))),
            item(L("Clear Formatting"), #selector(RichTextView.clearFormatting(_:)), "\\", [.command, .option]),
            .separator(),
            item(L("Show Fonts"), #selector(NSFontManager.orderFrontFontPanel(_:)), "t"),
            item(L("Show Colors"), #selector(NSApplication.orderFrontColorPanel(_:)), "c", [.command, .shift]),
            item(L("Show Ruler"), #selector(NSText.toggleRuler(_:))),
        ]))

        main.addItem(menu(L("Code"), [
            item(L("Toggle Comment"), #selector(CodeTextView.toggleComment(_:)), "/"),
            item(L("Duplicate Line"), #selector(CodeTextView.duplicateLine(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.shift, .option]),
            item(L("Move Line Up"), #selector(CodeTextView.moveLineUp(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.option]),
            item(L("Move Line Down"), #selector(CodeTextView.moveLineDown(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.option]),
            item(L("Delete Line"), #selector(CodeTextView.deleteLine(_:)), "k", [.command, .shift]),
            .separator(),
            item(L("Add Next Occurrence"), #selector(CodeTextView.addNextOccurrence(_:)), "d"),
            item(L("Add Cursor Above"), #selector(CodeTextView.addCursorAbove(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command, .option]),
            item(L("Add Cursor Below"), #selector(CodeTextView.addCursorBelow(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command, .option]),
            .separator(),
            item(L("Change Language Mode…"), #selector(W.showLanguagePicker(_:)), "l", [.command, .shift]),
            item(L("Go to Line…"), #selector(W.goToLine(_:)), "g", [.control]),
            .separator(),
            item(L("Copy Code as Image"), #selector(W.copyCodeImage(_:)), "c", [.command, .option, .shift]),
            item(L("Export Code as Image…"), #selector(W.exportCodeImage(_:))),
            .separator(),
            item(L("Word Wrap"), #selector(W.toggleWordWrap(_:)), "z", [.option]),
            item(L("Line Numbers"), #selector(W.toggleLineNumbers(_:))),
        ]))

        let fontManager = NSFontManager.shared
        fontManager.target = nil
        main.addItem(menu(L("View"), [
            item(L("Toggle Sidebar"), #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]),
            item(L("Explorer"), #selector(W.showExplorer(_:)), "e", [.command, .shift]),
            item(L("Search"), #selector(W.showFolderSearch(_:)), "f", [.command, .shift, .control]),
            item(L("Show Hidden Files"), #selector(W.toggleHiddenFiles(_:)), ".", [.command, .shift]),
            .separator(),
            item(L("Split Editor"), #selector(W.splitEditor(_:)), "\\"),
            item(L("Focus Next Pane"), #selector(W.focusNextPane(_:)), String(UnicodeScalar(NSRightArrowFunctionKey)!), [.command, .control]),
            item(L("Focus Previous Pane"), #selector(W.focusPreviousPane(_:)), String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.command, .control]),
            item(L("Close Pane"), #selector(W.closePane(_:))),
            .separator(),
            item(L("Markdown Preview"), #selector(W.toggleMarkdownPreview(_:)), "v", [.command, .shift]),
            item(L("Focus Mode"), #selector(W.toggleFocusMode(_:)), "\r", [.command, .shift]),
            .separator(),
            item(L("Zoom In"), #selector(W.zoomIn(_:)), "+"),
            item(L("Zoom Out"), #selector(W.zoomOut(_:)), "-"),
            item(L("Actual Size"), #selector(W.zoomReset(_:)), "0"),
            .separator(),
            item(L("Enter Full Screen"), #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]))

        var windowItems: [NSMenuItem] = [
            item(L("Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"),
            item(L("Zoom"), #selector(NSWindow.performZoom(_:))),
            item(L("New Window"), #selector(newEditorWindow(_:)), "n", [.command, .option]),
            .separator(),
            item(L("Next Tab"), #selector(W.selectNextTab(_:)), "\t", [.control]),
            item(L("Previous Tab"), #selector(W.selectPreviousTab(_:)), "\t", [.control, .shift]),
        ]
        for number in 1...9 {
            let tabItem = item(L("Tab %d", number), #selector(W.selectTabByNumber(_:)), "\(number)", .command, tag: number)
            tabItem.isHidden = true
            tabItem.allowsKeyEquivalentWhenHidden = true
            windowItems.append(tabItem)
        }
        windowItems += [.separator(), item(L("Bring All to Front"), #selector(NSApplication.arrangeInFront(_:)))]
        let windowMenu = menu(L("Window"), windowItems)
        NSApp.windowsMenu = windowMenu.submenu
        main.addItem(windowMenu)

        let helpMenu = menu(L("Help"), [])
        NSApp.helpMenu = helpMenu.submenu
        main.addItem(helpMenu)
        return main
    }
}
