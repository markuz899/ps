import AppKit
import PSCore
import SwiftUI

/// SwiftUI is used only here: settings are a secondary surface, loaded on first open,
/// and @AppStorage binds straight to the same UserDefaults keys the editors read.
enum SettingsHost {
    static let size = NSSize(width: 780, height: 540)

    /// A fixed-size window. The SwiftUI view must not drive the window size: with both the
    /// window and the hosting view resizing each other AppKit recursed until it aborted.
    static func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: true)
        let host = NSHostingView(rootView: SettingsView())
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        window.title = L("Settings")
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}

/// System Settings–style window: sections in a sidebar, grouped forms on the right.
struct SettingsView: View {
    enum Section: String, CaseIterable, Identifiable {
        case general, editor, themes, documents, whiteboard, shortcuts, about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return L("General")
            case .editor: return L("Code Editor")
            case .themes: return L("Themes")
            case .documents: return L("Documents")
            case .whiteboard: return L("Whiteboard")
            case .shortcuts: return L("Keyboard Shortcuts")
            case .about: return L("About")
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape.fill"
            case .editor: return "chevron.left.forwardslash.chevron.right"
            case .themes: return "paintpalette.fill"
            case .documents: return "doc.richtext.fill"
            case .whiteboard: return "scribble.variable"
            case .shortcuts: return "keyboard.fill"
            case .about: return "info.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .general: return .gray
            case .editor: return .blue
            case .themes: return .purple
            case .documents: return .indigo
            case .whiteboard: return .pink
            case .shortcuts: return .orange
            case .about: return .teal
            }
        }
    }

    @State private var section: Section? = .general

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $section) { item in
                Label {
                    Text(item.title)
                } icon: {
                    Image(systemName: item.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(item.tint.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .padding(.vertical, 2)
                .tag(item)
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            ScrollView {
                Group {
                    switch section ?? .general {
                    case .general: GeneralPane()
                    case .editor: EditorPane()
                    case .themes: ThemesPane()
                    case .documents: DocumentsPane()
                    case .whiteboard: WhiteboardPane()
                    case .shortcuts: ShortcutsPane()
                    case .about: AboutPane()
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .navigationTitle((section ?? .general).title)
        }
        .frame(width: SettingsHost.size.width, height: SettingsHost.size.height)
    }
}

/// A titled group of rows on a rounded card, like System Settings.
private struct Card<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 4)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5))
        }
        .padding(.bottom, 14)
    }
}

/// One row of a card: label (+ optional explanation) on the left, control on the right.
private struct Row<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.vertical, 7)
    }
}

private struct Divided: View {
    var body: some View { Divider().opacity(0.6) }
}

// MARK: - General

private struct GeneralPane: View {
    @AppStorage(Prefs.Key.appearance) private var appearance = "system"
    @AppStorage(Prefs.Key.restoreSession) private var restoreSession = true
    @AppStorage(Prefs.Key.autoSave) private var autoSave = AutoSaveMode.off.rawValue
    @AppStorage(Prefs.Key.autoSaveInterval) private var autoSaveInterval = 30
    @AppStorage(Prefs.Key.showHidden) private var showHidden = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Card(L("Appearance")) {
                HStack(spacing: 14) {
                    ForEach([("system", L("Automatic"), "circle.lefthalf.filled"), ("light", L("Light"), "sun.max.fill"), ("dark", L("Dark"), "moon.fill")], id: \.0) { value, title, symbol in
                        Button {
                            appearance = value
                        } label: {
                            VStack(spacing: 6) {
                                AppearanceSwatch(mode: value)
                                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(appearance == value ? Color.accentColor : .clear, lineWidth: 2.5))
                                Label(title, systemImage: symbol).font(.caption)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 8)
            }
            Card(L("Startup")) {
                Row(title: L("Reopen folders, tabs and unsaved files at launch")) {
                    Toggle("", isOn: $restoreSession).toggleStyle(.switch).labelsHidden()
                }
            }
            Card(L("Saving")) {
                Row(title: L("Save automatically"), detail: L("Untitled documents, and documents that would need a format decision, are never saved automatically.")) {
                    Picker("", selection: $autoSave) {
                        Text(L("Off")).tag(AutoSaveMode.off.rawValue)
                        Text(L("When focus changes")).tag(AutoSaveMode.focus.rawValue)
                        Text(L("Every few seconds")).tag(AutoSaveMode.interval.rawValue)
                    }
                    .labelsHidden()
                    .frame(width: 190)
                }
                if autoSave == AutoSaveMode.interval.rawValue {
                    Divided()
                    Row(title: L("Every %d seconds", autoSaveInterval)) {
                        Stepper("", value: $autoSaveInterval, in: 5...600, step: 5).labelsHidden()
                    }
                }
            }
            Card(L("Files")) {
                Row(title: L("Show hidden files"), detail: L("In the explorer, Quick Open and folder search.")) {
                    Toggle("", isOn: $showHidden).toggleStyle(.switch).labelsHidden()
                }
            }
        }
    }
}

private struct AppearanceSwatch: View {
    let mode: String

    var body: some View {
        let light = LinearGradient(colors: [Color(white: 0.98), Color(white: 0.9)], startPoint: .top, endPoint: .bottom)
        let dark = LinearGradient(colors: [Color(white: 0.22), Color(white: 0.1)], startPoint: .top, endPoint: .bottom)
        ZStack {
            switch mode {
            case "light": light
            case "dark": dark
            default:
                HStack(spacing: 0) { light; dark }
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach([0.8, 0.55, 0.7], id: \.self) { width in
                    Capsule().fill(Color.accentColor.opacity(0.75)).frame(width: 60 * width, height: 4)
                }
            }
        }
        .frame(width: 96, height: 62)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}

// MARK: - Code editor

private struct EditorPane: View {
    @AppStorage(Prefs.Key.codeFontName) private var codeFontName = ""
    @AppStorage(Prefs.Key.codeFontSize) private var codeFontSize = 13.0
    @AppStorage(Prefs.Key.lineHeight) private var lineHeight = 1.12
    @AppStorage(Prefs.Key.tabWidth) private var tabWidth = 4
    @AppStorage(Prefs.Key.insertSpaces) private var insertSpaces = true
    @AppStorage(Prefs.Key.wordWrap) private var wordWrap = false
    @AppStorage(Prefs.Key.lineNumbers) private var lineNumbers = true
    @AppStorage(Prefs.Key.highlightCurrentLine) private var highlightCurrentLine = true
    @AppStorage(Prefs.Key.autoCloseBrackets) private var autoCloseBrackets = true
    @AppStorage(Prefs.Key.highlightOccurrences) private var highlightOccurrences = true
    @AppStorage(Prefs.Key.colorSwatches) private var colorSwatches = true
    @AppStorage(Prefs.Key.showMinimap) private var showMinimap = true
    @Environment(\.colorScheme) private var scheme

    private let monospaced = (NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []).sorted()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CodePreview(themeName: nil, dark: scheme == .dark, height: 118)
                .padding(.bottom, 14)
            Card(L("Font")) {
                Row(title: L("Font")) {
                    Picker("", selection: $codeFontName) {
                        Text(L("System Monospaced")).tag("")
                        ForEach(monospaced, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
                Divided()
                Row(title: L("Size: %d pt", Int(codeFontSize))) {
                    Slider(value: $codeFontSize, in: 9...28, step: 1).frame(width: 220)
                }
                Divided()
                Row(title: L("Line height: %@", String(format: "%.2f", lineHeight))) {
                    Slider(value: $lineHeight, in: 1...2, step: 0.05).frame(width: 220)
                }
            }
            Card(L("Indentation")) {
                Row(title: L("Tab width: %d", tabWidth)) {
                    Stepper("", value: $tabWidth, in: 1...8).labelsHidden()
                }
                Divided()
                Row(title: L("Insert spaces instead of tabs"), detail: L("Files that already use tabs keep them.")) {
                    Toggle("", isOn: $insertSpaces).toggleStyle(.switch).labelsHidden()
                }
            }
            Card(L("Display")) {
                toggleRow(L("Line numbers"), $lineNumbers)
                Divided()
                toggleRow(L("Minimap"), $showMinimap)
                Divided()
                toggleRow(L("Word wrap"), $wordWrap)
                Divided()
                toggleRow(L("Highlight the current line"), $highlightCurrentLine)
                Divided()
                toggleRow(L("Highlight other occurrences of the word"), $highlightOccurrences)
                Divided()
                toggleRow(L("Colour swatches next to CSS colours"), $colorSwatches)
            }
            Card(L("Typing")) {
                toggleRow(L("Close brackets and quotes automatically"), $autoCloseBrackets)
            }
        }
    }

    private func toggleRow(_ title: String, _ value: Binding<Bool>) -> some View {
        Row(title: title) { Toggle("", isOn: value).toggleStyle(.switch).labelsHidden() }
    }
}

/// A few lines of Swift coloured with a theme and the chosen font: live preview.
private struct CodePreview: View {
    let themeName: String?
    let dark: Bool
    var height: CGFloat = 96
    @AppStorage(Prefs.Key.codeFontName) private var codeFontName = ""
    @AppStorage(Prefs.Key.codeFontSize) private var codeFontSize = 13.0
    @AppStorage(Prefs.Key.lineHeight) private var lineHeight = 1.12
    @AppStorage(Prefs.Key.lightTheme) private var lightTheme = "Daylight"
    @AppStorage(Prefs.Key.darkTheme) private var darkTheme = "Midnight"

    static let sample = """
    // Greets a few times
    struct Greeter {
        let name = "PS"
        func greet(times: Int) -> String {
            (0..<times).map { "Hi, \\(name) #\\($0)" }.joined()
        }
    }
    """

    private var theme: Theme? {
        ThemeStore.theme(named: themeName ?? (dark ? darkTheme : lightTheme), dark: dark)
    }

    private var attributed: AttributedString {
        let size = CGFloat(themeName == nil ? codeFontSize : 11)
        let font = (codeFontName.isEmpty ? nil : NSFont(name: codeFontName, size: size)) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = themeName == nil ? CGFloat(lineHeight) : 1.1
        let text = NSMutableAttributedString(string: CodePreview.sample, attributes: [
            .font: font, .foregroundColor: theme?.color("foreground") ?? .textColor, .paragraphStyle: style,
        ])
        if let swift = LanguageRegistry.language(id: "swift"), let tokenizer = Tokenizer.forLanguage(swift) {
            let string = text.string as NSString
            for token in tokenizer.tokens(in: string, from: 0, until: string.length) {
                if let color = theme?.scopeColor(tokenizer.scopes[token.scope]) { text.addAttribute(.foregroundColor, value: color, range: token.range) }
            }
        }
        return (try? AttributedString(text, including: \.appKit)) ?? AttributedString(CodePreview.sample)
    }

    var body: some View {
        Text(attributed)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
            .padding(12)
            .background(Color(nsColor: theme?.color("background") ?? .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
            .clipped()
    }
}

// MARK: - Themes

private struct ThemesPane: View {
    @AppStorage(Prefs.Key.lightTheme) private var lightTheme = "Daylight"
    @AppStorage(Prefs.Key.darkTheme) private var darkTheme = "Midnight"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("The code theme follows the appearance: one for light mode, one for dark mode."))
                .font(.callout).foregroundStyle(.secondary).padding(.bottom, 12)
            themeGrid(L("Light appearance"), dark: false, selection: $lightTheme)
            themeGrid(L("Dark appearance"), dark: true, selection: $darkTheme)
            Text(L("The theme follows the system appearance. Add your own JSON themes in ~/Library/Application Support/PS/Themes."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func themeGrid(_ title: String, dark: Bool, selection: Binding<String>) -> some View {
        Card(title) {
            HStack(spacing: 14) {
                ForEach(ThemeStore.all.filter { $0.isDark == dark }, id: \.name) { theme in
                    Button {
                        selection.wrappedValue = theme.name
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            CodePreview(themeName: theme.name, dark: dark, height: 62)
                                .frame(width: 230)
                                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selection.wrappedValue == theme.name ? Color.accentColor : .clear, lineWidth: 2.5))
                            HStack(spacing: 4) {
                                if selection.wrappedValue == theme.name { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                                Text(theme.name).font(.callout.weight(.medium))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 10)
        }
    }
}

// MARK: - Documents

private struct DocumentsPane: View {
    @AppStorage(Prefs.Key.richFontName) private var richFontName = "Helvetica Neue"
    @AppStorage(Prefs.Key.richFontSize) private var richFontSize = 14.0
    @AppStorage(Prefs.Key.spellCheck) private var spellCheck = true
    private let families = NSFontManager.shared.availableFontFamilies

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Quarterly report")).font(.custom(richFontName, size: richFontSize * 1.6).weight(.bold))
                Text(L("Text documents (.rtf, .rtfd, .txt) open as a page you can format, like a word processor."))
                    .font(.custom(richFontName, size: richFontSize))
            }
            .foregroundStyle(Color.black)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            .padding(.bottom, 16)
            Card(L("Default font for new documents")) {
                Row(title: L("Font")) {
                    Picker("", selection: $richFontName) {
                        ForEach(families, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
                Divided()
                Row(title: L("Size: %d pt", Int(richFontSize))) {
                    Slider(value: $richFontSize, in: 9...32, step: 1).frame(width: 220)
                }
            }
            Card(L("Writing")) {
                Row(title: L("Check spelling while typing")) {
                    Toggle("", isOn: $spellCheck).toggleStyle(.switch).labelsHidden()
                }
            }
        }
    }
}

// MARK: - Whiteboard

private struct WhiteboardPane: View {
    @AppStorage(Prefs.Key.boardGrid) private var grid = true
    @AppStorage(Prefs.Key.boardRoughness) private var roughness = 1.0
    @AppStorage(Prefs.Key.boardFont) private var font = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Card(L("Canvas")) {
                Row(title: L("Show the dot grid")) {
                    Toggle("", isOn: $grid).toggleStyle(.switch).labelsHidden()
                }
            }
            Card(L("New elements")) {
                Row(title: L("Sloppiness"), detail: L("How hand-drawn new shapes look.")) {
                    Picker("", selection: $roughness) {
                        Text(L("Architect")).tag(0.0)
                        Text(L("Artist")).tag(1.0)
                        Text(L("Cartoonist")).tag(2.0)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 260)
                }
                Divided()
                Row(title: L("Font family")) {
                    Picker("", selection: $font) {
                        Text(L("Hand-drawn")).tag(1)
                        Text(L("Normal")).tag(2)
                        Text(L("Code")).tag(3)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 260)
                }
            }
            Text(L("Boards are saved as .excalidraw files: they also open on excalidraw.com."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - About

private struct AboutPane: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: AppIcon.image(size: 128))
            Text("PS").font(.system(size: 30, weight: .heavy, design: .rounded))
            Text(L("Prose & Source — one fast editor for code and documents.")).foregroundStyle(.secondary)
            Text(L("Version %@", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"))
                .font(.caption).foregroundStyle(.tertiary)
            Link(destination: URL(string: "https://github.com/markuz899/ps")!) {
                Label("github.com/markuz899/ps", systemImage: "arrow.up.right.square")
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 30)
    }
}

// MARK: - Keyboard shortcuts

struct ShortcutEntry: Identifiable, Hashable {
    let title: String
    let keys: String
    var id: String { title + keys }
}

struct ShortcutGroup: Identifiable {
    let title: String
    let entries: [ShortcutEntry]
    var id: String { title }
}

/// Every shortcut: read from the menu bar (so it's always current), plus the ones that
/// aren't menu items (whiteboard tools, mouse gestures, tab handling).
enum ShortcutCatalog {
    static func groups() -> [ShortcutGroup] {
        var groups: [ShortcutGroup] = []
        for top in NSApp.mainMenu?.items ?? [] {
            guard let menu = top.submenu else { continue }
            var entries: [ShortcutEntry] = []
            func walk(_ menu: NSMenu, prefix: String) {
                for item in menu.items where !item.isSeparatorItem {
                    if let submenu = item.submenu {
                        walk(submenu, prefix: prefix + item.title + " › ")
                        continue
                    }
                    let keys = MainWindowController.shortcut(of: item)
                    guard !keys.isEmpty, !item.isHidden else { continue }
                    entries.append(ShortcutEntry(title: prefix + item.title, keys: keys))
                }
            }
            walk(menu, prefix: "")
            if top.title == L("Window") {
                entries.append(ShortcutEntry(title: L("Go to tab 1…8, last tab"), keys: "⌘1 … ⌘9"))
            }
            if !entries.isEmpty { groups.append(ShortcutGroup(title: top.title, entries: entries)) }
        }
        groups.append(ShortcutGroup(title: L("Tabs"), entries: [
            ShortcutEntry(title: L("New file in this pane"), keys: L("double-click the tab bar")),
            ShortcutEntry(title: L("Close a tab"), keys: L("middle-click")),
            ShortcutEntry(title: L("Move a tab to another pane or window"), keys: L("drag it out of the bar")),
        ]))
        groups.append(ShortcutGroup(title: L("Code editing"), entries: [
            ShortcutEntry(title: L("Indent / outdent the selection"), keys: "⇥ / ⇧⇥"),
            ShortcutEntry(title: L("Add a caret"), keys: L("⌥ click")),
            ShortcutEntry(title: L("Back to one caret"), keys: "⎋"),
            ShortcutEntry(title: L("Jump with the minimap"), keys: L("click the minimap")),
        ]))
        let tools: [(String, String)] = [
            ("Hand", "H"), ("Selection", "V · 1"), ("Rectangle", "R · 2"), ("Diamond", "D · 3"), ("Ellipse", "O · 4"),
            ("Arrow", "A · 5"), ("Line", "L · 6"), ("Draw", "P · 7"), ("Text", "T · 8"), ("Eraser", "E · 0"),
        ]
        groups.append(ShortcutGroup(title: L("Whiteboard"), entries: tools.map { ShortcutEntry(title: L($0.0), keys: $0.1) } + [
            ShortcutEntry(title: L("Pan the canvas"), keys: L("Space + drag")),
            ShortcutEntry(title: L("Zoom"), keys: L("pinch · ⌘ scroll · ⌘+ ⌘−")),
            ShortcutEntry(title: L("Square shapes, 15° lines"), keys: L("⇧ while drawing")),
            ShortcutEntry(title: L("Write inside a shape"), keys: L("double-click · ↩")),
            ShortcutEntry(title: L("Duplicate"), keys: "⌘D"),
            ShortcutEntry(title: L("Group / ungroup"), keys: "⌘G / ⇧⌘G"),
            ShortcutEntry(title: L("Nudge"), keys: L("arrows (⇧ ×10)")),
            ShortcutEntry(title: L("Delete"), keys: "⌫"),
        ]))
        return groups
    }
}

private struct ShortcutsPane: View {
    @State private var query = ""
    private let groups = ShortcutCatalog.groups()

    private var filtered: [ShortcutGroup] {
        guard !query.isEmpty else { return groups }
        let needle = query.lowercased()
        return groups.compactMap { group in
            let entries = group.entries.filter { $0.title.lowercased().contains(needle) || $0.keys.lowercased().contains(needle) || group.title.lowercased().contains(needle) }
            return entries.isEmpty ? nil : ShortcutGroup(title: group.title, entries: entries)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L("Search shortcuts"), text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            .padding(.bottom, 14)
            if filtered.isEmpty {
                Text(L("No results")).foregroundStyle(.secondary).padding(.top, 20)
            }
            ForEach(filtered) { group in
                Card(group.title) {
                    ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divided() }
                        HStack {
                            Text(entry.title)
                            Spacer(minLength: 12)
                            KeyCaps(keys: entry.keys)
                        }
                        .padding(.vertical, 5)
                    }
                }
            }
            Text(L("Shortcuts follow macOS conventions (and VS Code where they don't clash). They can't be changed yet."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Keys drawn as little key caps: "⇧⌘P" becomes ⇧ ⌘ P.
private struct KeyCaps: View {
    let keys: String

    /// Symbol-only shortcuts are split into caps; anything with words is shown as text.
    private var caps: [String]? {
        let symbols = "⌃⌥⇧⌘"
        guard keys.unicodeScalars.allSatisfy({ !CharacterSet.letters.contains($0) || keys.count <= 6 }), !keys.contains(" ") else { return nil }
        var result: [String] = []
        var rest = Substring(keys)
        while let first = rest.first, symbols.contains(first) {
            result.append(String(first))
            rest = rest.dropFirst()
        }
        if !rest.isEmpty { result.append(String(rest)) }
        return result
    }

    var body: some View {
        if let caps {
            HStack(spacing: 3) {
                ForEach(Array(caps.enumerated()), id: \.offset) { _, cap in
                    Text(cap)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .frame(minWidth: 22, minHeight: 20)
                        .padding(.horizontal, cap.count > 1 ? 5 : 0)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.12), radius: 0, y: 1)
                }
            }
        } else {
            Text(keys).font(.callout).foregroundStyle(.secondary)
        }
    }
}
