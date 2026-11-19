import AppKit
import PSCore

extension Notification.Name {
    /// Posted (object: Document) when name, dirty state, language or format change.
    static let documentStateChanged = Notification.Name("PSDocumentStateChanged")
}

/// What was read from disk, produced off the main thread.
enum LoadedContent {
    case plain(String, TextFormat)
    case rich(NSAttributedString, TextFormat?)
    case board(BoardScene)
}

struct FileStamp: Equatable {
    let modified: Date?
    let size: Int?

    init?(url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        modified = attributes[.modificationDate] as? Date
        size = (attributes[.size] as? NSNumber)?.intValue
    }
}

/// The common document model. Everything outside the two editors (tabs, saving, search,
/// status bar) talks to this type and doesn't care which mode is active.
final class Document: NSObject, NSTextStorageDelegate {
    static let highlightLimit = 5 * 1024 * 1024
    private static var untitledCount = 0

    var url: URL? { didSet { notify() } }
    private(set) var mode: EditorMode
    private(set) var language: Language = LanguageRegistry.plainText
    private(set) var languageIsManual = false
    var format = TextFormat.standard { didSet { notify() } }
    var useTabs = !Prefs.insertSpaces
    var indentWidth = Prefs.tabWidth
    let textStorage = NSTextStorage()
    /// The whiteboard scene, for `.board` documents.
    var board = BoardScene()
    let undoManager = UndoManager()
    let lineIndex = LineIndex()
    private(set) var isDirty = false
    /// Bumped on every text change; lets caches (outline, preview) know they're stale.
    private(set) var version = 0
    private(set) var fileStamp: FileStamp?
    private(set) var highlightingDisabled = false
    /// Copy of the text as last saved, used to clear the dirty dot when undo gets back to
    /// it. Kept only below `Document.cleanTrackingLimit`.
    private var savedText: NSString?
    static let cleanTrackingLimit = 1_000_000
    private let untitledNumber: Int
    /// Edits after the layout managers processed them: (edited range, change in length).
    var editObservers: [(NSRange, Int) -> Void] = []

    /// Stable name of this untitled document's backup in the Unsaved folder.
    let backupID: String
    /// Version last written to the backup (avoids rewriting unchanged backups).
    var backedUpVersion = -1

    init(mode: EditorMode, url: URL? = nil, backupID: String? = nil) {
        self.mode = mode
        self.url = url
        self.backupID = backupID ?? UUID().uuidString
        if url == nil {
            Document.untitledCount += 1
            untitledNumber = Document.untitledCount
        } else {
            untitledNumber = 0
        }
        super.init()
        textStorage.delegate = self
        if mode == .rich {
            textStorage.setAttributedString(NSAttributedString(string: "", attributes: Prefs.richDefaults.attributes))
        }
        markSaved()
    }

    /// Overrides the tab title (used e.g. for read-only diff tabs).
    var customDisplayName: String?

    /// Generated, read-only content (a commit diff): never saved, backed up or restored.
    var isReadOnly = false

    var displayName: String {
        if let customDisplayName { return customDisplayName }
        if let url { return url.lastPathComponent }
        let base: String
        switch mode {
        case .code: base = L("Untitled")
        case .rich: base = L("Untitled Document")
        case .board: base = L("Untitled Whiteboard")
        }
        return untitledNumber > 1 ? "\(base) \(untitledNumber)" : base
    }

    var richKind: RichFileKind? { url.flatMap(RichFileKind.init(url:)) }

    // MARK: Loading

    /// Reads and decodes a file. Safe to call from any thread.
    static func read(_ url: URL, mode: EditorMode, encoding: String.Encoding? = nil) throws -> LoadedContent {
        if mode == .board {
            return .board(try BoardScene.decode(try Data(contentsOf: url)))
        }
        let kind = RichFileKind(url: url)
        if mode == .rich, kind == .rtf || kind == .rtfd {
            return .rich(try RichTextIO.read(url, defaults: Prefs.richDefaults).text, nil)
        }
        let (text, format) = try TextFileIO.decode(try Data(contentsOf: url), forcing: encoding)
        if mode == .rich {
            return .rich(NSAttributedString(string: text, attributes: Prefs.richDefaults.attributes), format)
        }
        return .plain(text, format)
    }

    func apply(_ content: LoadedContent) {
        switch content {
        case let .plain(text, format):
            mode = .code
            self.format = format
            textStorage.beginEditing()
            textStorage.setAttributedString(NSAttributedString(string: text))
            textStorage.endEditing()
            if !languageIsManual {
                let firstLine = text.prefix(200).split(separator: "\n", maxSplits: 1).first.map(String.init)
                language = LanguageRegistry.detect(fileName: url?.lastPathComponent ?? "", firstLine: firstLine)
            }
            if let indent = IndentDetector.detect(text) {
                useTabs = indent.useTabs
                indentWidth = indent.useTabs ? Prefs.tabWidth : indent.width
            }
        case let .rich(text, format):
            mode = .rich
            if let format { self.format = format }
            textStorage.setAttributedString(text)
        case let .board(scene):
            mode = .board
            board = scene
            textStorage.setAttributedString(NSAttributedString())
        }
        highlightingDisabled = textStorage.length > Document.highlightLimit
        lineIndex.rebuild(textStorage.string as NSString)
        if let url { fileStamp = FileStamp(url: url) }
        markSaved()
    }

    /// Switches a .txt between the two editors, keeping the text in memory.
    func convert(to newMode: EditorMode) {
        guard newMode != mode, newMode != .board, mode != .board else { return }
        let wasDirty = isDirty
        if newMode == .code {
            apply(.plain(RichTextIO.plainString(textStorage), format))
        } else {
            apply(.rich(NSAttributedString(string: textStorage.string, attributes: Prefs.richDefaults.attributes), format))
        }
        if wasDirty { setDirty(true) }
    }

    func setLanguage(_ language: Language, manual: Bool) {
        self.language = language
        languageIsManual = manual
        notify()
    }

    // MARK: Saving

    /// Writes the text in the document's own format. Throws on any I/O or encoding error;
    /// the in-memory document is left untouched in that case.
    func write(to target: URL, kind: RichFileKind? = nil) throws {
        if mode == .board {
            try SafeWriter.write(try board.encoded(), to: target)
            return
        }
        if mode == .code {
            try SafeWriter.write(try TextFileIO.encode(textStorage.string, format: format), to: target)
        } else {
            let kind = kind ?? RichFileKind(url: target) ?? .rtf
            let snapshot = NSAttributedString(attributedString: textStorage)
            try RichTextIO.write(snapshot, to: target, kind: kind, plainFormat: format)
        }
    }

    func didSave(to target: URL) {
        if url != target { url = target }
        if mode == .code, !languageIsManual {
            setLanguage(LanguageRegistry.detect(fileName: target.lastPathComponent, firstLine: nil), manual: false)
        }
        fileStamp = FileStamp(url: target)
        markSaved()
        NSDocumentController.shared.noteNewRecentDocumentURL(target)
    }

    func markSaved() {
        // A literal copy + compare is a memcpy/memcmp; String.hashValue would hash Unicode
        // and costs ~50 ms per MB.
        savedText = textStorage.length < Document.cleanTrackingLimit ? NSString(string: textStorage.mutableString) : nil
        setDirty(false)
    }

    /// Called by the editors after every user edit (typing, undo, formatting).
    func userDidEdit() {
        // Undoing back to the saved text clears the dot, as in VS Code. Formatting changes
        // don't alter the string, so rich documents (and huge files) just stay dirty.
        // Untitled: "modified" means "has something worth keeping".
        if url == nil {
            setDirty(hasContent)
            return
        }
        if mode == .code, let saved = savedText {
            let current = textStorage.mutableString
            setDirty(saved.length != current.length || saved.compare(current as String, options: .literal) != .orderedSame)
        } else {
            setDirty(true)
        }
    }

    var hasContent: Bool {
        mode == .board ? !board.visible.isEmpty : textStorage.length > 0
    }

    /// For changes that don't touch the text, e.g. a new line-ending style.
    func markModified() {
        setDirty(true)
    }

    private func setDirty(_ value: Bool) {
        guard value != isDirty else { return }
        isDirty = value
        notify()
    }

    var changedOnDisk: Bool {
        guard let url else { return false }
        return FileStamp(url: url) != fileStamp
    }

    func acknowledgeDiskVersion() {
        if let url { fileStamp = FileStamp(url: url) }
    }

    private func notify() {
        NotificationCenter.default.post(name: .documentStateChanged, object: self)
    }

    // MARK: NSTextStorageDelegate

    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        version += 1
        lineIndex.update(textStorage.string as NSString, edited: editedRange, delta: delta)
        guard !editObservers.isEmpty else { return }
        // Layout managers adjust their temporary attributes after this callback returns,
        // so observers (the highlighter) run on the next turn of the run loop.
        DispatchQueue.main.async { [weak self] in
            self?.editObservers.forEach { $0(editedRange, delta) }
        }
    }
}
