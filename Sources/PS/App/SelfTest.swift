import AppKit
import PSCore

/// `--selftest <workspace> <screenshots>` drives the real app through the acceptance
/// criteria (real windows, files, sheets) and prints PASS/FAIL lines.
/// `--selftest-restore <workspace>` is the second half, run after a relaunch.
enum SelfTest {
    private static var steps: [(String, () -> Void)] = []
    private static var failures = 0
    private static var controller: MainWindowController!
    private static var shots: URL!
    private static var workspace: URL!

    static var isActive: Bool {
        CommandLine.arguments.contains("--selftest") || CommandLine.arguments.contains("--selftest-restore")
    }

    private static func check(_ condition: Bool, _ name: String) {
        print("\(condition ? "PASS" : "FAIL")  \(name)")
        fflush(stdout)
        if !condition { failures += 1 }
    }

    private static func step(_ name: String, _ body: @escaping () -> Void) {
        steps.append((name, body))
    }

    private static func runNext() {
        guard !steps.isEmpty else {
            print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
            fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }
        let (_, body) = steps.removeFirst()
        body()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: runNext)
    }

    /// Captured a moment later, once the window server has the new frame.
    static func screenshot(_ name: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { capture(name) }
    }

    /// The main window's own image (works even with the screen locked), with child panels
    /// and sheets composited on top at their positions.
    private static func capture(_ name: String) {
        guard let window = controller.window, let shots else { return }
        window.displayIfNeeded()
        func image(of window: NSWindow) -> CGImage? {
            CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming])
        }
        guard let base = image(of: window) else {
            print("note: screenshot \(name) unavailable")
            return
        }
        let scale = CGFloat(base.width) / window.frame.width
        let overlays = ((window.childWindows ?? []) + [window.attachedSheet].compactMap { $0 }).filter(\.isVisible)
        guard let context = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        for overlay in overlays {
            guard let picture = image(of: overlay) else { continue }
            let origin = CGPoint(x: (overlay.frame.minX - window.frame.minX) * scale, y: (overlay.frame.minY - window.frame.minY) * scale)
            context.draw(picture, in: CGRect(origin: origin, size: CGSize(width: picture.width, height: picture.height)))
        }
        guard let composed = context.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: composed).representation(using: .png, properties: [:])?.write(to: shots.appendingPathComponent(name + ".png"))
    }

    private static func tab(named name: String) -> Tab? {
        controller.tabs.first { $0.document.url?.lastPathComponent == name }
    }

    private static func color(in tab: Tab, of word: String) -> NSColor? {
        guard let view = tab.editor?.textView, let layoutManager = view.layoutManager else { return nil }
        let range = (view.string as NSString).range(of: word)
        guard range.location != NSNotFound else { return nil }
        return layoutManager.temporaryAttribute(.foregroundColor, atCharacterIndex: range.location, effectiveRange: nil) as? NSColor
    }

    /// Clicks the button with this title on the sheet currently attached to the window.
    private static func clickSheetButton(_ title: String) -> Bool {
        guard let sheet = controller.window?.attachedSheet else { return false }
        func find(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == title { return button }
            for subview in view.subviews { if let found = find(subview) { return found } }
            return nil
        }
        guard let button = sheet.contentView.flatMap(find) else { return false }
        button.performClick(nil)
        return true
    }

    private static func sheetText() -> String {
        guard let sheet = controller.window?.attachedSheet, let content = sheet.contentView else { return "" }
        func collect(_ view: NSView) -> [String] {
            ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(collect)
        }
        return collect(content).joined(separator: " | ")
    }

    static func run(_ controller: MainWindowController) {
        self.controller = controller
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--selftest-restore") {
            workspace = URL(fileURLWithPath: arguments[index + 1])
            restoreSteps()
        } else if let index = arguments.firstIndex(of: "--selftest") {
            workspace = URL(fileURLWithPath: arguments[index + 1])
            shots = URL(fileURLWithPath: arguments[index + 2])
            mainSteps()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: runNext)
    }

    private static func mainSteps() {
        let src = workspace.appendingPathComponent("src")
        let documentURL = workspace.appendingPathComponent("docs/report.rtf")
        let notes = workspace.appendingPathComponent("docs/notes.txt")
        let originalNotes = try? Data(contentsOf: notes)

        step("welcome") { screenshot("01-welcome") }
        step("open folder and five files") {
            controller.openWorkspace(workspace)
            for name in ["main.swift", "app.py", "index.ts", "style.css", "query.sql"] {
                controller.open(src.appendingPathComponent(name))
            }
        }
        step("colours") {
            check(controller.tabs.count == 5, "five tabs open")
            let expected = ["main.swift": ("swift", "struct"), "app.py": ("python", "class"), "index.ts": ("typescript", "interface"), "style.css": ("css", "border-radius"), "query.sql": ("sql", "SELECT")]
            for (name, (language, word)) in expected {
                guard let tab = tab(named: name) else {
                    check(false, "\(name) open")
                    continue
                }
                if let index = controller.tabs.firstIndex(where: { $0 === tab }) { controller.activate(index) }
                check(tab.document.language.id == language, "\(name) detected as \(language)")
                check(color(in: tab, of: word) != nil, "\(name): “\(word)” is coloured")
                check(controller.formatBar.isHidden, "\(name): no formatting bar")
                check(tab.editor?.textView.enclosingScrollView?.rulersVisible == true, "\(name): line numbers visible")
            }
            if let index = controller.tabs.firstIndex(where: { $0.document.url?.lastPathComponent == "main.swift" }) { controller.activate(index) }
        }
        step("tree expanded") {
            controller.sidebar.tree.select(src.appendingPathComponent("main.swift"))
            screenshot("02-code-swift")
        }
        step("change language from status bar") {
            guard let tab = tab(named: "app.py") else { return }
            let before = color(in: tab, of: "class")
            controller.setLanguage(LanguageRegistry.language(id: "plaintext")!, for: tab)
            check(color(in: tab, of: "class") == nil, "app.py as Plain Text: colours removed immediately")
            controller.setLanguage(LanguageRegistry.language(id: "python")!, for: tab)
            check(color(in: tab, of: "class") == before, "app.py back to Python: colours restored")
        }
        step("incremental highlight") {
            guard let tab = tab(named: "main.swift"), let index = controller.tabs.firstIndex(where: { $0 === tab }), let view = tab.editor?.textView else { return }
            controller.activate(index)
            view.setSelectedRange(NSRange(location: 0, length: 0))
            view.insertText("/* ", replacementRange: view.selectedRange())
        }
        step("block comment spans lines") {
            guard let tab = tab(named: "main.swift") else { return }
            let comment = Prefs.theme(for: NSApp.effectiveAppearance)?.scopeColor("comment")
            check(color(in: tab, of: "struct") == comment, "typing “/*” turns the following lines into a comment")
            tab.document.undoManager.undo()
        }
        step("undo restores colours") {
            guard let tab = tab(named: "main.swift") else { return }
            let keyword = Prefs.theme(for: NSApp.effectiveAppearance)?.scopeColor("keyword")
            check(color(in: tab, of: "struct") == keyword, "undo: “struct” is a keyword again")
            check(!tab.document.isDirty, "undo back to the saved text clears the dirty dot")
        }

        // Rich text document created with the bar's commands only.
        step("new rich document") {
            controller.newRichDocument(nil)
        }
        step("write formatted text") {
            guard let rich = controller.activeTab?.editor as? RichEditor else {
                check(false, "rich editor for new document")
                return
            }
            let view = rich.richView
            check(!controller.formatBar.isHidden, "formatting bar shown for a text document")
            check(view.enclosingScrollView?.rulersVisible != true, "no line numbers in a text document")
            view.insertText("Quarterly report", replacementRange: view.selectedRange())
            view.setSelectedRange(NSRange(location: 0, length: 0))
            view.applyParagraphKind(.heading1)
            view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
            view.insertNewline(nil)
            view.applyParagraphKind(.normal)
            view.insertText("Revenue grew strongly this year.", replacementRange: view.selectedRange())
            let text = view.string as NSString
            view.setSelectedRange(text.range(of: "grew strongly"))
            view.toggleBold(nil)
            view.setColor(NSColor(srgbRed: 0.85, green: 0.1, blue: 0.2, alpha: 1), for: .foregroundColor)
            view.setSelectedRange(NSRange(location: text.length, length: 0))
            view.insertNewline(nil)
            view.toggleBulletList(nil)
            view.insertText("First point", replacementRange: view.selectedRange())
            view.insertNewline(nil)
            view.insertText("Second point", replacementRange: view.selectedRange())
            controller.formatBar.refresh()
            screenshot("03-rich-document")
        }
        step("save as RTF") {
            guard let tab = controller.activeTab else { return }
            try? FileManager.default.removeItem(at: documentURL)
            controller.write(tab, to: documentURL) { saved in check(saved, "saved report.rtf") }
        }
        step("close and reopen") {
            controller.closeActiveTab(nil)
            controller.open(documentURL)
        }
        step("formatting survived") {
            guard let tab = tab(named: "report.rtf") else {
                check(false, "report.rtf reopened")
                return
            }
            let storage = tab.document.textStorage
            let text = storage.string as NSString
            let title = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            check(title.map { $0.pointSize >= 27 && NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false, "title is still Title 1")
            let bold = storage.attribute(.font, at: text.range(of: "grew").location, effectiveRange: nil) as? NSFont
            check(bold.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false, "bold word is still bold")
            let red = (storage.attribute(.foregroundColor, at: text.range(of: "grew").location, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB)
            check((red?.redComponent ?? 0) > 0.8 && (red?.greenComponent ?? 1) < 0.2, "coloured word is still red")
            let list = (storage.attribute(.paragraphStyle, at: text.range(of: "Second").location, effectiveRange: nil) as? NSParagraphStyle)?.textLists
            check(list?.first?.markerFormat == .disc, "bulleted list is still a list")
            check(text.contains("•"), "bullet markers present")
            screenshot("04-rich-reopened")
            let textutil = Process()
            textutil.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
            textutil.arguments = ["-convert", "txt", "-stdout", documentURL.path]
            let pipe = Pipe()
            textutil.standardOutput = pipe
            try? textutil.run()
            textutil.waitUntilExit()
            let plain = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            check(plain.contains("Quarterly report") && plain.contains("Second point"), "textutil (TextEdit's engine) reads the RTF")
        }

        // .txt rules
        step("open txt") { controller.open(notes) }
        step("edit txt without formatting") {
            guard let tab = tab(named: "notes.txt"), let rich = tab.editor as? RichEditor else {
                check(false, "notes.txt opens in rich mode")
                return
            }
            check(!controller.formatBar.isHidden, ".txt opens as a document with the formatting bar")
            let view = rich.richView
            view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
            view.insertText("Added line.", replacementRange: view.selectedRange())
            controller.saveDocument(nil)
        }
        step("txt stayed plain") {
            let data = (try? Data(contentsOf: notes)) ?? Data()
            check(data == (originalNotes ?? Data()) + Data("Added line.".utf8), ".txt saved byte-for-byte as plain text with CRLF kept")
            check(controller.window?.attachedSheet == nil, "no prompt for an unformatted .txt")
        }
        step("bold in txt") {
            guard let rich = tab(named: "notes.txt")?.editor as? RichEditor else { return }
            rich.richView.setSelectedRange(NSRange(location: 0, length: 5))
            rich.richView.toggleBold(nil)
            controller.saveDocument(nil)
        }
        step("prompt shown") {
            let text = sheetText()
            check(text.contains("notes.txt"), "saving a formatted .txt asks what to do")
            screenshot("05-txt-prompt")
            check(clickSheetButton(L("Convert to %@", "RTF")), "chose “Convert to RTF”")
        }
        step("converted") {
            let rtf = workspace.appendingPathComponent("docs/notes.rtf")
            check(FileManager.default.fileExists(atPath: rtf.path), "notes.rtf created next to notes.txt")
            check((try? Data(contentsOf: notes)) == (originalNotes ?? Data()) + Data("Added line.".utf8), "notes.txt was not overwritten")
            check(controller.activeTab?.document.url?.lastPathComponent == "notes.rtf", "the tab now points at notes.rtf")
            check(controller.activePane.view.frame.width > 900, "the pane fills the editor area (\(Int(controller.activePane.view.frame.width)) pt, window \(Int(controller.window?.frame.width ?? 0)) pt)")
            check(Int(controller.window?.frame.width ?? 0) == 1180, "the window keeps its size")
        }

        // Folder search
        step("folder search") {
            controller.showFolderSearch(nil)
            controller.sidebar.search.prefill("Greeter")
        }
        step("folder results") {
            screenshot("06-folder-search")
            var found: [FolderMatch] = []
            try? FolderSearch.search(root: workspace, query: "Greeter", options: FindOptions(), includeHidden: false, isCancelled: { false }) { found += $0 }
            check(found.count >= 2, "“Greeter” found in the folder (\(found.count) matches)")
            if let match = found.first(where: { $0.line == 18 }) ?? found.last {
                controller.sidebar.search.onOpen?(match)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    let tab = controller.activeTab
                    let line = tab.map { $0.document.lineIndex.line(at: $0.editor?.textView.selectedRange().location ?? 0) + 1 }
                    check(tab?.document.url?.lastPathComponent == "main.swift" && line == match.line, "clicking a result jumps to main.swift line \(match.line)")
                }
            }
        }

        step("quick open") {
            controller.quickOpenFile(nil)
        }
        step("quick open shot") {
            screenshot("07-quick-open")
            controller.quickOpen.dismiss()
            controller.showExplorer(nil)
        }

        step("find bar") {
            if let index = controller.tabs.firstIndex(where: { $0.document.url?.lastPathComponent == "main.swift" }) { controller.activate(index) }
            controller.showFindReplace(nil)
        }
        step("find shot") {
            screenshot("08-find")
            controller.findBar.hide()
        }

        // Split panes: the same document in two views, then a third pane.
        step("split editor") {
            guard let tab = tab(named: "main.swift") else { return }
            controller.activate(tab)
            controller.splitEditor(nil)
        }
        step("split check") {
            check(controller.panes.count == 2, "Split Editor creates a second pane")
            let views = controller.tabs.filter { $0.document.url?.lastPathComponent == "main.swift" }
            check(views.count == 2 && views[0].document === views[1].document && views[0].editor?.textView !== views[1].editor?.textView,
                  "both panes show main.swift: one document, two views")
            if let right = views.last?.editor?.textView {
                right.setSelectedRange(NSRange(location: 0, length: 0))
                right.insertText("// both panes\n", replacementRange: right.selectedRange())
            }
        }
        step("split sync") {
            let views = controller.tabs.filter { $0.document.url?.lastPathComponent == "main.swift" }
            let left = views.first.flatMap { color(in: $0, of: "both panes") }
            check(views.first?.editor?.textView.string.hasPrefix("// both panes") == true, "typing in the right pane shows up in the left one")
            check(left == Prefs.theme(for: NSApp.effectiveAppearance)?.scopeColor("comment"), "the left pane re-colours the edit too")
            views.first?.document.undoManager.undo()
            if let python = tab(named: "app.py") { controller.move(python, to: controller.panes.last) }
            if let typescript = tab(named: "index.ts") { controller.splitRight(typescript) }
        }
        step("three panes") {
            check(controller.panes.count == 3, "a third pane via Split Right")
            check(Int(controller.window?.frame.width ?? 0) == 1180, "three panes fit in the same window (\(Int(controller.window?.frame.width ?? 0)) pt)")
            let widths = controller.panes.map { Int($0.view.frame.width) }
            check((widths.max() ?? 0) - (widths.min() ?? 0) <= 8, "the three panes have equal widths (\(widths))")
            check(controller.panes.dropFirst().contains { $0.tabs.contains { $0.document.url?.lastPathComponent == "app.py" } } && !controller.panes[0].tabs.contains { $0.document.url?.lastPathComponent == "app.py" }, "app.py moved to another pane")
            screenshot("10-three-panes")
        }
        step("close pane") { controller.closePane(nil) }
        step("pane closed") {
            check(controller.panes.count == 2, "Close Pane removes the third pane")
            if let tab = controller.tabs.first(where: { $0.document.url?.lastPathComponent == "main.swift" }) { controller.activate(tab) }
        }

        // Breadcrumbs
        step("breadcrumb") {
            guard let tab = controller.activeTab, let view = tab.editor?.textView else { return }
            view.setSelectedRange(NSRange(location: (view.string as NSString).range(of: "Repeat").location, length: 0))
        }
        step("breadcrumb check") {
            let titles = controller.activePane.breadcrumb.titles
            check(titles.suffix(3) == ["main.swift", "Greeter", "greet"], "breadcrumb shows main.swift › Greeter › greet (\(titles))")
        }

        // Multiple cursors
        step("multi cursor") {
            guard let editor = controller.activeTab?.editor as? CodeEditor else { return }
            let view = editor.codeView
            let first = (view.string as NSString).range(of: "name")
            view.setSelectedRange(first)
            view.addNextOccurrence(nil)
            view.addNextOccurrence(nil)
            check(view.cursorCount == 3, "Cmd+D twice: three selections of “name”")
            view.insertText("who", replacementRange: NSRange(location: NSNotFound, length: 0))
            let text = view.string
            check(!text.contains("name") || text.components(separatedBy: "name").count < 3, "typing replaces every selection")
            check(text.components(separatedBy: "who").count - 1 == 3, "three “who” after typing")
            screenshot("11-multi-cursor")
        }
        step("multi cursor undo") {
            guard let view = (controller.activeTab?.editor as? CodeEditor)?.codeView else { return }
            controller.activeTab?.document.undoManager.undo()
            check(view.string.components(separatedBy: "name").count - 1 >= 3, "one undo restores all of them")
        }

        // Colour swatches
        step("open css") { controller.open(src.appendingPathComponent("style.css")) }
        step("swatch") {
            guard let editor = tab(named: "style.css")?.editor as? CodeEditor else { return }
            let view = editor.codeView
            view.display()
            check(view.swatchCount >= 1, "a swatch is drawn next to #3b5bdb")
            screenshot("12-css-swatch")
            let range = (view.string as NSString).range(of: "#3b5bdb")
            view.editColorLiteral(at: range)
            NSColorPanel.shared.color = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
            view.changeColor(nil)
            check(view.string.contains("#ff0000"), "picking red in the colour panel rewrites the literal as #ff0000")
            NSColorPanel.shared.orderOut(nil)
            screenshot("12-css-swatch-red")
        }
        step("swatch undo") { tab(named: "style.css")?.document.undoManager.undo() }

        // Replace in folder, with preview
        step("replace in folder") {
            controller.showFolderSearch(nil)
            controller.sidebar.search.prefill("Demo")
        }
        step("replace apply") {
            controller.sidebar.search.applyReplace(query: "Demo", template: "Showcase", options: FindOptions(caseSensitive: true))
        }
        step("replace check") {
            let readme = (try? String(contentsOf: workspace.appendingPathComponent("README.md"))) ?? ""
            check(readme.hasPrefix("# Showcase"), "Replace in folder rewrote README.md on disk")
            controller.showExplorer(nil)
        }

        // Markdown preview
        step("open markdown") { controller.open(workspace.appendingPathComponent("README.md")) }
        step("preview") {
            controller.toggleMarkdownPreview(nil)
            let editor = controller.activeTab?.editor as? CodeEditor
            check(editor?.isPreviewVisible == true, "Markdown preview opens beside the source")
            check(editor?.previewText.hasPrefix("Showcase") == true && editor?.previewText.contains("bold") == true, "preview renders the Markdown (no ** or #)")
            screenshot("13-markdown-preview")
        }

        // Command palette
        step("palette") {
            controller.showCommandPalette(nil)
        }
        step("palette shot") { screenshot("14-command-palette") }
        step("palette run") {
            let before = Prefs.wordWrap
            let ran = controller.quickOpen.runFirst(matching: "word wrap")
            check(ran == L("Word Wrap") && Prefs.wordWrap != before, "Command Palette runs “Word Wrap”")
            Prefs.defaults.set(before, forKey: Prefs.Key.wordWrap)
        }

        // Focus mode on a document
        step("focus mode") {
            if let report = tab(named: "report.rtf") { controller.activate(report) }
            controller.toggleFocusMode(nil)
        }
        step("focus check") {
            check(controller.activePane.tabBar.isHidden && controller.activePane.formatBar.isHidden, "focus mode hides tabs and bars")
            check((controller.activeTab?.editor as? RichEditor)?.richView.focusMode == true, "focus mode dims everything but the current paragraph (\(controller.activeTab?.document.displayName ?? "-"))")
            check(controller.activePane.view.frame.width > 1000, "focus mode gives the whole window to the pane being written in")
            screenshot("15-focus-mode")
        }
        step("focus off") {
            controller.toggleFocusMode(nil)
            check(controller.panes.count == 2 && controller.panes.allSatisfy { $0.view.window != nil }, "leaving focus mode brings the panes back")
        }

        // Code as image
        step("code image") {
            if let tab = tab(named: "main.swift") { controller.activate(tab) }
            controller.activeTab?.editor?.textView.setSelectedRange(NSRange(location: 0, length: 0))
            let data = controller.codeImageData()
            check((data?.count ?? 0) > 20_000, "Export Code as Image produces a PNG (\(data?.count ?? 0) bytes)")
            try? data?.write(to: shots.appendingPathComponent("16-code-image.png"))
        }

        // External change to a clean tab: silent reload (FSEvents).
        step("external change") {
            try? Data("/* changed elsewhere */\n.card { color: red; }\n".utf8).write(to: src.appendingPathComponent("style.css"), options: .atomic)
        }
        step("wait for FSEvents") {}
        step("reloaded") {
            let text = tab(named: "style.css")?.document.textStorage.string ?? ""
            check(text.contains("changed elsewhere"), "file changed on disk is reloaded silently in its clean tab")
            check(tab(named: "style.css")?.document.isDirty == false, "reloaded tab is not marked modified")
        }

        // Two dirty files, then quit.
        step("dirty two files") {
            for name in ["index.ts", "query.sql"] {
                guard let tab = tab(named: name), let index = controller.tabs.firstIndex(where: { $0 === tab }) else { continue }
                controller.activate(index)
                tab.editor?.textView.insertText("// edit\n", replacementRange: NSRange(location: 0, length: 0))
            }
            check(controller.tabs.filter { $0.document.isDirty }.count == 2, "two tabs show the dirty dot")
            screenshot("09-dirty-tabs")
            Session.save(controller)
            controller.confirmCloseAll { proceed in check(proceed, "both prompts answered") }
        }
        step("first prompt") {
            let text = sheetText()
            check(text.contains("index.ts") || text.contains("query.sql"), "asked to save the first file")
            _ = clickSheetButton(L("Don't Save"))
        }
        step("second prompt") {
            let text = sheetText()
            check(text.contains("index.ts") || text.contains("query.sql"), "asked to save the second file")
            _ = clickSheetButton(L("Don't Save"))
        }
        step("session") {
            if let tab = tab(named: "main.swift"), let index = controller.tabs.firstIndex(where: { $0 === tab }) {
                controller.activate(index)
                tab.editor?.textView.setSelectedRange(NSRange(location: 120, length: 0))
            }
            Session.save(controller)
            let state = Prefs.defaults.dictionary(forKey: "session") ?? [:]
            check((state["folder"] as? String) == workspace.standardizedFileURL.path, "session stores the folder")
            let saved = (state["panes"] as? [[String: Any]] ?? []).reduce(0) { $0 + (($1["tabs"] as? [Any])?.count ?? 0) }
            check(saved == controller.tabs.filter { $0.document.url != nil }.count, "session stores every tab of every pane")
        }
    }

    private static func restoreSteps() {
        step("restore session") {
            Session.restore(into: controller) {}
        }
        step("restored") {
            check(controller.folder?.standardizedFileURL.path == workspace.standardizedFileURL.path, "folder restored after relaunch")
            check(controller.tabs.count >= 6, "tabs restored after relaunch (\(controller.tabs.count))")
            check(controller.panes.count == 2, "both panes restored after relaunch")
            check(controller.activeTab?.document.url?.lastPathComponent == "main.swift", "active tab restored")
            check(controller.activeTab?.editor?.textView.selectedRange().location == 120, "cursor position restored")
        }
    }
}
