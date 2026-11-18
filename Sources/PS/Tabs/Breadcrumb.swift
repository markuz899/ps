import AppKit
import PSCore

/// Path › file › enclosing declarations, under the tab bar. Clicking the file or a
/// declaration opens the file's outline; clicking a folder reveals it in the sidebar.
final class BreadcrumbBar: NSView {
    var onJump: ((Int) -> Void)?
    var onReveal: ((URL) -> Void)?

    private let stack = NSStackView()
    private var cache: (document: ObjectIdentifier, version: Int, language: String, symbols: [Symbol])?
    private var shown: [String] = []
    private var symbols: [Symbol] = []
    private weak var document: Document?

    static let height: CGFloat = 24

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: BreadcrumbBar.height),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(L("Breadcrumbs"))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.withAlphaComponent(0.5).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    override var isFlipped: Bool { true }

    private var pendingScan: DispatchWorkItem?
    private var lastArguments: (root: URL?, caret: Int)?

    /// The outline is rescanned off the main thread, a moment after typing stops; until
    /// then the previous one is used (its offsets are at most a few characters off).
    private func outline(of document: Document) -> [Symbol] {
        let language = document.language.id
        guard document.mode == .code, SymbolScanner.supports(language), document.textStorage.length < 2_000_000 else { return [] }
        let identity = ObjectIdentifier(document)
        if let cache, cache.document == identity, cache.language == language {
            if cache.version != document.version { scheduleScan(document) }
            return cache.symbols
        }
        scheduleScan(document, delay: 0)
        return []
    }

    private func scheduleScan(_ document: Document, delay: TimeInterval = 0.4) {
        pendingScan?.cancel()
        let work = DispatchWorkItem { [weak self, weak document] in
            guard let document else { return }
            let snapshot = NSString(string: document.textStorage.string)
            let version = document.version
            let language = document.language.id
            DispatchQueue.global(qos: .utility).async {
                let symbols = SymbolScanner.symbols(in: snapshot, languageID: language)
                DispatchQueue.main.async {
                    guard let self, document.version == version, self.document === document else { return }
                    self.cache = (ObjectIdentifier(document), version, language, symbols)
                    if let arguments = self.lastArguments {
                        self.update(document: document, root: arguments.root, caret: arguments.caret)
                    }
                }
            }
        }
        pendingScan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Labels currently shown, for the self-test and accessibility.
    var titles: [String] {
        stack.arrangedSubviews.compactMap { ($0 as? NSButton)?.title }
    }

    func update(document: Document, root: URL?, caret: Int) {
        self.document = document
        lastArguments = (root, caret)
        symbols = outline(of: document)
        let chain = SymbolScanner.chain(symbols, in: document.textStorage.string as NSString, caret: caret, languageID: document.language.id)

        var folders: [URL] = []
        if let url = document.url {
            var directory = url.deletingLastPathComponent()
            let stop = root?.deletingLastPathComponent().standardizedFileURL.path ?? directory.deletingLastPathComponent().path
            while directory.standardizedFileURL.path != stop, directory.path != "/", folders.count < 6 {
                folders.insert(directory, at: 0)
                directory = directory.deletingLastPathComponent()
            }
        }
        let signature = folders.map(\.path) + [document.displayName] + chain.map { "\($0.location):\($0.name)" }
        guard signature != shown else { return }
        shown = signature

        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for folder in folders {
            add(crumb(folder.lastPathComponent, image: nil) { [weak self] _ in self?.onReveal?(folder) })
            add(separator())
        }
        add(crumb(document.displayName, image: FileIcon.image(for: document.url, mode: document.mode, size: 10), bold: chain.isEmpty) { [weak self] sender in
            self?.showOutline(from: sender)
        })
        for (index, symbol) in chain.enumerated() {
            add(separator())
            add(crumb(symbol.name, image: icon(for: symbol), bold: index == chain.count - 1) { [weak self] sender in
                self?.showOutline(from: sender)
            })
        }
    }

    private func add(_ view: NSView) {
        stack.addArrangedSubview(view)
    }

    private func icon(for symbol: Symbol) -> NSImage? {
        let name: String
        let color: NSColor
        switch symbol.kind {
        case "class", "struct", "enum", "protocol", "interface", "trait", "type", "actor", "record", "union", "namespace", "module", "mod", "extension", "impl":
            name = "cube"
            color = .systemOrange
        case let kind where kind.hasPrefix("#"):
            name = "number"
            color = .systemTeal
        case "":
            name = document?.language.id == "css" ? "number" : "chevron.left.forwardslash.chevron.right"
            color = .systemPurple
        default:
            name = "function"
            color = .systemPurple
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium).applying(.init(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    }

    private func separator() -> NSView {
        let label = NSTextField(labelWithString: "›")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .tertiaryLabelColor
        return label
    }

    private func crumb(_ title: String, image: NSImage?, bold: Bool = false, action: @escaping (NSButton) -> Void) -> NSButton {
        let button = CrumbButton(action: action)
        button.title = title
        button.image = image
        button.imagePosition = image == nil ? .noImage : .imageLeading
        button.isBordered = false
        button.font = .systemFont(ofSize: 11.5, weight: bold ? .medium : .regular)
        button.contentTintColor = bold ? .labelColor : .secondaryLabelColor
        button.lineBreakMode = .byTruncatingMiddle
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    /// Every declaration of the file, indented like the code.
    private func showOutline(from sender: NSButton) {
        guard !symbols.isEmpty else { return }
        let menu = NSMenu()
        let minimum = symbols.map(\.indent).min() ?? 0
        for symbol in symbols.prefix(400) {
            let item = ClosureMenuItem(title: symbol.name) { [weak self] in self?.onJump?(symbol.location) }
            item.image = icon(for: symbol)
            item.indentationLevel = min(8, document?.language.id == "markdown" ? symbol.indent - 1 : (symbol.indent - minimum) / 2)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }
}

private final class CrumbButton: NSButton {
    private let handler: (NSButton) -> Void

    init(action: @escaping (NSButton) -> Void) {
        handler = action
        super.init(frame: .zero)
        target = self
        self.action = #selector(fire)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func fire() { handler(self) }
}
