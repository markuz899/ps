import AppKit
import PSCore

/// `--selftest <workspace> <screenshots>` drives the real app through the acceptance
/// criteria (real windows, files, sheets) and prints PASS/FAIL lines.
/// `--selftest-restore <workspace>` is the second half, run after a relaunch.
enum SelfTest {
    private static var steps: [(String, () -> Void)] = []
    private static var savedAppearance = "system"
    private static var failures = 0
    private static var controller: MainWindowController!
    private static var shots: URL!
    private static var workspace: URL!

    static var isActive: Bool {
        CommandLine.arguments.contains("--selftest") || CommandLine.arguments.contains("--selftest-restore")
            || CommandLine.arguments.contains("--selftest-tabs")
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

    /// A screenshot of another window (e.g. a torn-off tab's window).
    static func captureWindow(_ other: MainWindowController, as name: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard let window = other.window, let shots,
                  let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming]) else { return }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: shots.appendingPathComponent(name + ".png"))
        }
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

    private static func mouse(_ type: NSEvent.EventType, _ view: NSView, _ point: CGPoint, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1
        )!
    }

    private static func drag(_ view: NSView, from start: CGPoint, to end: CGPoint, steps: Int = 6) {
        view.mouseDown(with: mouse(.leftMouseDown, view, start))
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            // A slight curve, so freehand strokes aren't straight.
            let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t + sin(t * .pi) * 12)
            view.mouseDragged(with: mouse(.leftMouseDragged, view, point))
        }
        view.mouseUp(with: mouse(.leftMouseUp, view, end))
    }

    private static func click(_ view: NSView, at point: CGPoint, clicks: Int = 1) {
        view.mouseDown(with: mouse(.leftMouseDown, view, point, clicks: clicks))
        view.mouseUp(with: mouse(.leftMouseUp, view, point, clicks: clicks))
    }

    /// A small architecture diagram, for the README screenshot.
    private static func showcaseScene() -> BoardScene {
        var elements: [BoardElement] = []
        func node(_ kind: BoardElement.Kind, _ label: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double, _ color: String, fill: String = "hachure") -> String {
            var shape = BoardElement(type: kind, x: x, y: y, width: w, height: h)
            shape.backgroundColor = color
            shape.fillStyle = fill
            var text = BoardElement(type: .text, x: x, y: y)
            text.text = label
            text.originalText = label
            text.containerId = shape.id
            text.textAlign = "center"
            let size = BoardRenderer.measure(text)
            text.width = size.width
            text.height = size.height
            shape.boundElements = [.init(id: text.id, type: "text")]
            elements += [shape, text]
            return shape.id
        }
        func link(_ from: String, _ to: String, dashed: Bool = false, color: String = "#1e1e1e") {
            var arrow = BoardElement(type: .arrow, x: 0, y: 0)
            arrow.setAbsolutePoints([.zero, CGPoint(x: 1, y: 1)])
            arrow.startBinding = .init(elementId: from)
            arrow.endBinding = .init(elementId: to)
            arrow.strokeColor = color
            if dashed { arrow.strokeStyle = "dashed" }
            elements.append(arrow)
        }
        var title = BoardElement(type: .text, x: 0, y: -10)
        title.text = "Checkout — architecture"
        title.fontSize = 34
        let titleSize = BoardRenderer.measure(title)
        title.width = titleSize.width
        title.height = titleSize.height
        elements.append(title)
        var underline = BoardElement(type: .freedraw, x: 0, y: 40)
        underline.strokeColor = "#e03131"
        underline.setAbsolutePoints((0...24).map { CGPoint(x: Double($0) * 16, y: 44 + sin(Double($0) * 0.6) * 3) })
        elements.append(underline)

        let app = node(.rectangle, "Mobile app", 0, 110, 170, 80, "#a5d8ff")
        let gateway = node(.rectangle, "API Gateway", 290, 110, 190, 80, "#ffec99", fill: "solid")
        let auth = node(.diamond, "Auth?", 600, 90, 160, 120, "#ffc9c9")
        let orders = node(.rectangle, "Orders service", 290, 290, 190, 80, "#b2f2bb")
        let payments = node(.rectangle, "Payments", 600, 290, 160, 80, "#d0bfff", fill: "cross-hatch")
        let database = node(.ellipse, "Postgres", 300, 460, 170, 90, "#a5d8ff", fill: "solid")
        link(app, gateway)
        link(gateway, auth)
        link(auth, gateway, dashed: true, color: "#e03131")
        link(gateway, orders)
        link(orders, payments)
        link(orders, database)
        var note = BoardElement(type: .text, x: 640, y: 450)
        note.text = "idempotency keys\non every payment!"
        note.strokeColor = "#e03131"
        note.fontSize = 20
        let noteSize = BoardRenderer.measure(note)
        note.width = noteSize.width
        note.height = noteSize.height
        elements.append(note)

        var scene = BoardScene(elements: elements)
        BoardGeometry.updateBindings(in: &scene, moved: Set(elements.map(\.id)))
        // Two arrows between the same shapes: bend the dashed one so both show.
        if let index = scene.elements.firstIndex(where: { $0.strokeStyle == "dashed" }) {
            var points = scene.elements[index].absolutePoints
            if points.count == 2 {
                let mid = CGPoint(x: (points[0].x + points[1].x) / 2, y: (points[0].y + points[1].y) / 2 + 46)
                points.insert(mid, at: 1)
                scene.elements[index].setAbsolutePoints(points)
                BoardGeometry.updateBindings(in: &scene, moved: [auth, gateway])
            }
        }
        return scene
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
        // Screenshots in light mode regardless of the system setting.
        if CommandLine.arguments.contains("--light") {
            Prefs.defaults.set("light", forKey: Prefs.Key.appearance)
            Prefs.applyAppearance()
        }
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--selftest-tabs") {
            shots = URL(fileURLWithPath: arguments[index + 1])
            tabSteps()
        } else if let index = arguments.firstIndex(of: "--selftest-restore") {
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

        step("settings") {
            (NSApp.delegate as? AppDelegate)?.showSettings(nil)
        }
        step("settings check") {
            let window = (NSApp.delegate as? AppDelegate)?.settingsWindow
            check(window?.isVisible == true, "Settings opens (no crash)")
            if let window {
                check(abs(window.frame.width - SettingsHost.size.width) < 40, "the Settings window keeps a stable size (\(Int(window.frame.width)) pt)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming]) {
                        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: shots.appendingPathComponent("00-settings.png"))
                    }
                    window.close()
                }
            }
        }
        step("welcome") {
            let items = controller.window?.toolbar?.items.map(\.itemIdentifier) ?? []
            check(items.contains(.toggleSidebar), "the title bar has the show/hide sidebar button")
            screenshot("01-welcome")
        }
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
        step("hide sidebar") {
            controller.sidebar.onClose?()
        }
        step("sidebar hidden") {
            check(controller.isSidebarCollapsed, "the button in the sidebar closes it")
            screenshot("02b-sidebar-hidden")
            controller.toggleSidebar(nil)
        }
        step("sidebar back") {
            check(!controller.isSidebarCollapsed, "the title-bar toggle (⌃⌘S) brings it back")
            check(Int(controller.window?.frame.width ?? 0) == 1180, "hiding and showing the sidebar doesn't resize the window")
        }
        // Sublime Text-style "+" after the tabs, and double-click on the empty bar.
        step("plus button") {
            let pane = controller.activePane!
            let before = pane.tabs.count
            pane.tabBar.addButton.performClick(nil)
            check(pane.tabs.count == before + 1 && controller.activeTab?.document.url == nil && controller.activeTab?.document.mode == .code, "the + after the tabs opens a new file in that pane")
            check(pane.tabBar.addButton.menu?.items.count == 3, "its menu offers file, text document and whiteboard")
            pane.tabBar.mouseDown(with: mouse(.leftMouseDown, pane.tabBar, CGPoint(x: pane.tabBar.bounds.maxX - 10, y: 18), clicks: 2))
            check(pane.tabs.count == before + 2, "double-clicking the empty tab bar opens a new file too")
            screenshot("02c-plus-button")
        }
        step("close new tabs") {
            for tab in controller.tabs where tab.document.url == nil && !tab.document.hasContent { controller.closeTab(tab) }
        }
        step("settings effects") {
            Prefs.defaults.set(false, forKey: Prefs.Key.autoCloseBrackets)
            if let tab = tab(named: "main.swift"), let view = tab.editor?.textView {
                controller.activate(tab)
                view.setSelectedRange(NSRange(location: 0, length: 0))
                view.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0))
                check((view.string as NSString).substring(to: 2) == "(i", "with auto-close off, typing ( adds no )")
                tab.document.undoManager.undo()
            }
            Prefs.defaults.set(true, forKey: Prefs.Key.autoCloseBrackets)
            savedAppearance = Prefs.defaults.string(forKey: Prefs.Key.appearance) ?? "system"
            Prefs.defaults.set(savedAppearance == "dark" ? "light" : "dark", forKey: Prefs.Key.appearance)
        }
        step("appearance setting") {
            let expected: NSAppearance.Name = savedAppearance == "dark" ? .aqua : .darkAqua
            check(NSApp.appearance?.name == expected, "the Appearance setting switches the whole app")
            Prefs.defaults.set(savedAppearance, forKey: Prefs.Key.appearance)
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

        // Regression: closing a code tab with the caret past the start used to crash.
        step("close code tab with caret") {
            guard let python = tab(named: "app.py"), let view = python.editor?.textView else { return }
            controller.activate(python)
            view.setSelectedRange(NSRange(location: 60, length: 0))
            controller.closeTab(python)
            check(tab(named: "app.py") == nil, "a code tab with the caret in the middle closes without crashing")
            controller.open(src.appendingPathComponent("app.py"))
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
            check(!controller.panes.contains { $0.tabBar.hasClippedTabs }, "in narrow panes tabs shrink instead of being cut at the edge")
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

        // Dragging tabs: between panes (tab bar and editor area), then out of the window.
        step("drag between panes") {
            guard controller.panes.count == 2, let python = tab(named: "app.py") else {
                check(false, "two panes before the drag tests")
                return
            }
            TabDrag.tab = python
            let target = controller.panes[0]
            check(controller.acceptDraggedTab(into: target, at: 0), "dropping app.py on the first pane's tab bar is accepted")
            check(target.tabs.first === python && python.pane === target, "app.py is now the first tab of the first pane")
            TabDrag.tab = python
            check(target.container.onDrop?() == true, "dropping on a pane's editor area is accepted too")
        }
        step("drag to the other pane's editor") {
            guard let python = tab(named: "app.py"), let other = controller.panes.last, other !== python.pane else { return }
            TabDrag.tab = python
            check(other.container.onDrop?() == true && python.pane === other, "dropping app.py on the other pane's editor moves it there")
            screenshot("17-dragged-tab")
        }
        step("tear off") {
            guard let css = tab(named: "style.css") else { return }
            let document = css.document
            let point = NSPoint(x: (controller.window?.frame.minX ?? 0) + 260, y: (controller.window?.frame.maxY ?? 800) - 120)
            controller.tearOff(css, at: point)
            let windows = MainWindowController.all
            check(windows.count == 2, "dragging a tab out of the app opens a second window")
            let second = windows.last
            check(second?.tabs.count == 1 && second?.tabs.first?.document === document, "the new window holds that tab, same document")
            check(!controller.tabs.contains { $0.document === document }, "the tab left the first window")
            check(second?.folder?.standardizedFileURL.path == workspace.standardizedFileURL.path, "the new window opens the same folder")
            check((second?.tabs.first?.editor?.textView.window) === second?.window, "its editor now lives in the new window")
        }
        step("tear off shot") {
            if let second = MainWindowController.all.last, second !== controller {
                captureWindow(second, as: "18-new-window")
            }
        }
        step("no duplicates across windows") {
            guard let second = MainWindowController.all.last, second !== controller else { return }
            let before = controller.tabs.count
            controller.open(src.appendingPathComponent("style.css"))
            check(controller.tabs.count == before, "opening style.css again doesn't duplicate it in the first window")
            // Ordering, not key status: key depends on which app the person is using meanwhile.
            let order = NSApp.orderedWindows
            let front = second.window.flatMap { order.firstIndex(of: $0) } ?? .max
            let back = controller.window.flatMap { order.firstIndex(of: $0) } ?? .max
            check(front < back, "the window that has it comes forward")
            // Back: drag the tab from the second window into the first; the empty window closes.
            TabDrag.tab = second.tabs.first
            controller.acceptDraggedTab(into: controller.panes[0], at: nil)
        }
        step("window closed") {
            check(MainWindowController.all.count == 1, "a window left with no tabs closes by itself")
            check(tab(named: "style.css")?.pane?.owner === controller, "style.css is back in the first window")
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

        // Whiteboard: real mouse events on the canvas.
        step("new whiteboard") {
            controller.newWhiteboard(nil)
        }
        step("draw shapes") {
            guard let board = controller.activeTab?.editor as? BoardEditor else {
                check(false, "New Whiteboard opens a board editor")
                return
            }
            check(true, "New Whiteboard opens a board editor")
            check(controller.formatBar.isHidden, "no formatting bar on a whiteboard")
            let canvas = board.canvas
            canvas.tool = .rectangle
            drag(canvas, from: CGPoint(x: 150, y: 150), to: CGPoint(x: 330, y: 250))
            canvas.tool = .ellipse
            drag(canvas, from: CGPoint(x: 520, y: 160), to: CGPoint(x: 700, y: 260))
            let kinds = canvas.scene.visible.map(\.type)
            check(kinds == [.rectangle, .ellipse], "dragging with the rectangle and ellipse tools draws them (\(kinds))")
            check(canvas.tool == .select, "after drawing a shape the tool goes back to selection")
            canvas.tool = .arrow
            drag(canvas, from: CGPoint(x: 334, y: 200), to: CGPoint(x: 516, y: 210))
            let arrow = canvas.scene.visible.first { $0.type == .arrow }
            let box = canvas.scene.visible.first { $0.type == .rectangle }
            let ellipse = canvas.scene.visible.first { $0.type == .ellipse }
            check(arrow?.startBinding?.elementId == box?.id && arrow?.endBinding?.elementId == ellipse?.id, "an arrow drawn between two shapes sticks to both")
        }
        step("label in shape") {
            guard let canvas = (controller.activeTab?.editor as? BoardEditor)?.canvas else { return }
            click(canvas, at: CGPoint(x: 240, y: 200), clicks: 2)
            canvas.editingText?.insertText("API", replacementRange: NSRange(location: NSNotFound, length: 0))
            canvas.commitTextEditing()
            let box = canvas.scene.visible.first { $0.type == .rectangle }
            let label = canvas.scene.visible.first { $0.type == .text }
            check(label?.text == "API" && label?.containerId == box?.id, "double-click in a shape writes text inside it")
            check(box?.boundElements?.contains { $0.id == label?.id } == true, "the shape knows its label (Excalidraw boundElements)")
        }
        step("move shape") {
            guard let canvas = (controller.activeTab?.editor as? BoardEditor)?.canvas,
                  let before = canvas.scene.visible.first(where: { $0.type == .arrow })?.absolutePoints.last else { return }
            // Grabbed by its top edge: on the left side the attached arrow is on top of it.
            drag(canvas, from: CGPoint(x: 610, y: 160), to: CGPoint(x: 610, y: 300))
            let ellipse = canvas.scene.visible.first { $0.type == .ellipse }
            let after = canvas.scene.visible.first { $0.type == .arrow }?.absolutePoints.last
            check(abs((ellipse?.y ?? 0) - 260) < 2, "dragging the ellipse moves it (y \(Int(ellipse?.y ?? 0)))")
            check((after?.y ?? 0) > before.y + 60, "the arrow follows the shape it's attached to")
        }
        step("board undo") {
            guard let canvas = (controller.activeTab?.editor as? BoardEditor)?.canvas else { return }
            let manager = controller.activeTab?.document.undoManager
            check(manager?.groupingLevel == 0, "no undo group left open on the board")
            manager?.undo()
            let ellipse = canvas.scene.visible.first { $0.type == .ellipse }
            check(abs((ellipse?.y ?? 0) - 120) < 2, "undo puts the ellipse back in one step")
            canvas.tool = .draw
            drag(canvas, from: CGPoint(x: 160, y: 380), to: CGPoint(x: 400, y: 420), steps: 12)
            check(canvas.scene.visible.contains { $0.type == .freedraw && ($0.points?.count ?? 0) > 5 }, "the pencil draws a free stroke")
        }
        step("board copy") {
            guard let canvas = (controller.activeTab?.editor as? BoardEditor)?.canvas else { return }
            canvas.selectAll(nil)
            canvas.copy(nil)
            check(NSPasteboard.general.string(forType: .string)?.contains("excalidraw/clipboard") == true, "copied elements use Excalidraw's clipboard format")
            check(canvas.pngData().map { $0.count > 5_000 } == true, "the board exports as PNG")
            screenshot("19-whiteboard-test")
        }
        step("board save") {
            guard let tab = controller.activeTab else { return }
            let url = workspace.appendingPathComponent("docs/flow.excalidraw")
            controller.write(tab, to: url) { saved in check(saved, "saved flow.excalidraw") }
            let json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any]
            check(json?["type"] as? String == "excalidraw" && (json?["elements"] as? [Any])?.count == 5, "the file is Excalidraw JSON with the 5 elements")
            controller.closeActiveTab(nil)
            controller.open(url)
        }
        step("board reopened") {
            let scene = controller.activeTab?.document.board
            let arrow = scene?.visible.first { $0.type == .arrow }
            check(controller.activeTab?.editor is BoardEditor && scene?.visible.count == 5, "reopening flow.excalidraw brings back the board")
            check(arrow?.startBinding != nil && arrow?.endBinding != nil, "the arrow is still attached after reopening")
        }
        step("showcase board") {
            controller.newWhiteboard(nil)
            guard let tab = controller.activeTab, let board = tab.editor as? BoardEditor else { return }
            board.canvas.change { $0 = showcaseScene() }
            check(board.canvas.clipsToBounds || ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 14, "the canvas stays inside its pane")
            // Its own window, so the diagram gets the whole width.
            controller.tearOff(tab, at: nil)
        }
        step("showcase fit") {
            guard let window = MainWindowController.all.last, window !== controller,
                  let board = window.activeTab?.editor as? BoardEditor else { return }
            window.window?.setFrame(controller.window?.frame ?? .zero, display: true)
            window.setSidebarCollapsed(true, animated: false)
            board.canvas.zoomToFit()
        }
        step("showcase shot") {
            if let window = MainWindowController.all.last, window !== controller { captureWindow(window, as: "20-whiteboard") }
        }
        step("showcase close") {
            if let window = MainWindowController.all.last, window !== controller { window.closeWindow() }
        }

        // Keyboard shortcuts list, built from the menus.
        step("shortcuts list") {
            let groups = ShortcutCatalog.groups()
            let entries = groups.flatMap(\.entries)
            check(entries.count > 60, "Settings lists the shortcuts (\(entries.count) in \(groups.count) groups)")
            check(entries.contains { $0.title.hasSuffix(L("Command Palette…")) && $0.keys == "⇧⌘P" }, "including menu shortcuts like ⇧⌘P Command Palette")
            check(groups.contains { $0.title == L("Whiteboard") }, "and the whiteboard keys that aren't in the menus")
        }

        // Whiteboard: pictures and the shape library.
        step("board images") {
            controller.newWhiteboard(nil)
            guard let board = controller.activeTab?.editor as? BoardEditor else { return }
            let picture = NSImage(size: NSSize(width: 400, height: 200), flipped: false) { rect in
                NSGradient(colors: [.systemPurple, .systemOrange])?.draw(in: rect, angle: 0)
                return true
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([picture])
            board.canvas.paste(nil)
            let image = board.canvas.scene.visible.first { $0.type == .image }
            check(image != nil && image.flatMap { board.canvas.scene.files[$0.fileId ?? ""] } != nil, "pasting a picture puts it on the board")
            check(abs((image?.width ?? 0) / max(1, image?.height ?? 1) - 2) < 0.05, "with its proportions")
            board.toggleLibrary()
            check(board.isLibraryVisible, "the Library button opens the shape library")
            let before = board.canvas.scene.visible.count
            if let database = BoardLibrary.items.first(where: { $0.id == "database" }) { board.canvas.insertLibraryItem(database) }
            let added = board.canvas.scene.visible.count - before
            check(added >= 4 && board.canvas.selection.count == added, "a library item is inserted as one selected group (\(added) elements)")
            if let server = BoardLibrary.items.first(where: { $0.id == "server" }) { board.canvas.insertLibraryItem(server) }
            board.canvas.zoomToFit()
        }
        step("board images shot") {
            screenshot("21-library")
            guard let tab = controller.activeTab else { return }
            let url = workspace.appendingPathComponent("docs/assets.excalidraw")
            controller.write(tab, to: url) { _ in }
            controller.closeActiveTab(nil)
            controller.open(url)
        }
        step("board images reopened") {
            let scene = controller.activeTab?.document.board
            let image = scene?.visible.first { $0.type == .image }
            check(image.flatMap { scene?.files[$0.fileId ?? ""]?.data } != nil, "the picture is saved inside the .excalidraw file")
            controller.closeActiveTab(nil)
        }

        // Minimap beside the code.
        step("minimap") {
            controller.newCodeFile(nil)
            guard let editor = controller.activeTab?.editor as? CodeEditor else { return }
            editor.codeView.insertText((1...400).map { "let value\($0) = compute(\($0)) // line \($0)" }.joined(separator: "\n"), replacementRange: NSRange(location: NSNotFound, length: 0))
            check(!editor.minimap.isHidden && editor.minimap.frame.width == MinimapView.width, "the minimap sits beside the code")
            screenshot("22-minimap")
        }
        step("minimap jump") {
            guard let editor = controller.activeTab?.editor as? CodeEditor, let clip = editor.codeView.enclosingScrollView?.contentView else { return }
            clip.scroll(to: .zero)
            editor.minimap.jump(to: editor.minimap.bounds.height * 0.9)
            check(clip.bounds.minY > 200, "clicking low on the minimap scrolls the code down (\(Int(clip.bounds.minY)) pt)")
            Prefs.defaults.set(false, forKey: Prefs.Key.showMinimap)
        }
        step("minimap off") {
            guard let editor = controller.activeTab?.editor as? CodeEditor else { return }
            check(editor.minimap.isHidden, "the Minimap setting hides it")
            Prefs.defaults.set(true, forKey: Prefs.Key.showMinimap)
            editor.codeView.selectAll(nil)
            editor.codeView.delete(nil)
            controller.closeActiveTab(nil)
        }

        // Two dirty files, then quit.
        step("dirty two files") {
            for name in ["index.ts", "query.sql"] {
                guard let tab = tab(named: name), let index = controller.tabs.firstIndex(where: { $0 === tab }) else { continue }
                controller.activate(index)
                tab.editor?.textView.insertText("// edit\n", replacementRange: NSRange(location: 0, length: 0))
            }
            check(controller.tabs.filter { $0.document.isDirty && $0.document.url != nil }.count == 2, "two tabs show the dirty dot")
            screenshot("09-dirty-tabs")
            Session.save(controller)
            // As on quit: untitled documents (the demo board) are kept, not asked about.
            controller.confirmCloseAll(includeUntitled: false) { proceed in check(proceed, "both prompts answered") }
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
            // An untitled document that was never saved: it must come back after relaunch.
            controller.newCodeFile(nil)
            controller.activeTab?.editor?.textView.insertText("draft never saved", replacementRange: NSRange(location: NSNotFound, length: 0))
            if let tab = tab(named: "main.swift") { controller.activate(tab) }
            Session.save(controller)
            let state = (Prefs.defaults.dictionary(forKey: "session")?["windows"] as? [[String: Any]])?.first ?? [:]
            check((state["folder"] as? String) == workspace.standardizedFileURL.path, "session stores the folder")
            let saved = (state["panes"] as? [[String: Any]] ?? []).reduce(0) { $0 + (($1["tabs"] as? [Any])?.count ?? 0) }
            check(saved == controller.tabs.count, "session stores every tab of every pane, the untitled one too")
        }
    }

    /// Just the tab bar, as in a bug report: whiteboard with edits + two new files.
    private static func tabSteps() {
        step("whiteboard") {
            controller.newWhiteboard(nil)
            if let canvas = (controller.activeTab?.editor as? BoardEditor)?.canvas {
                canvas.tool = .rectangle
                drag(canvas, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 320, y: 280))
            }
        }
        step("files") {
            controller.activePane.tabBar.addButton.performClick(nil)
            controller.activePane.tabBar.addButton.performClick(nil)
        }
        step("middle") {
            if controller.activePane.tabs.count == 3 { controller.activate(controller.activePane.tabs[1]) }
            screenshot("tabs")
        }
        step("code then board") {
            controller.activePane.tabs[1].editor?.textView.insertText((1...60).map { "let value\($0) = \($0)" }.joined(separator: "\n"), replacementRange: NSRange(location: NSNotFound, length: 0))
            controller.splitEditor(nil)
        }
        step("left pane board") {
            if let left = controller.panes.first, let code = left.activeTab { controller.activate(code) }
            controller.newWhiteboard(nil)
            guard let board = controller.activeTab?.editor as? BoardEditor else { return }
            let picture = NSImage(size: NSSize(width: 400, height: 200), flipped: false) { rect in
                NSGradient(colors: [.systemPurple, .systemOrange])?.draw(in: rect, angle: 0)
                return true
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([picture])
            board.canvas.paste(nil)
            board.toggleLibrary()
            if let server = BoardLibrary.items.first(where: { $0.id == "server" }) { board.canvas.insertLibraryItem(server) }
            board.canvas.zoomToFit()
        }
        step("wait") {}
        step("board shot") {
            screenshot("board")
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
            let draft = controller.tabs.first { $0.document.url == nil }
            check(draft?.document.textStorage.string == "draft never saved", "the unsaved new file comes back with its text")
            check(draft?.document.isDirty == true, "and it is still marked as unsaved")
            check(controller.activeTab?.document.url?.lastPathComponent == "main.swift", "active tab restored")
            check(controller.activeTab?.editor?.textView.selectedRange().location == 120, "cursor position restored")
            controller.closeFolder(nil)
        }
        step("folder closed") {
            let root = workspace.resolvingSymlinksInPath().path + "/"
            check(controller.folder == nil && controller.sidebar.tree.root == nil, "Close Folder empties the sidebar")
            check(!controller.tabs.contains { $0.document.url?.resolvingSymlinksInPath().path.hasPrefix(root) == true }, "the folder's tabs are closed")
            check(controller.tabs.contains { $0.document.url == nil }, "tabs from outside the folder stay open")
            check(controller.window?.title == "PS", "the window title no longer shows the folder")
            let saved = (Prefs.defaults.dictionary(forKey: "session")?["windows"] as? [[String: Any]])?.first
            check(saved?["folder"] == nil, "the next launch won't reopen it")
        }
    }
}
