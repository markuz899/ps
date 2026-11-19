import Foundation

/// Declarations of every file in a folder, by name: what ⌘-click and completion use.
/// ponytail: regex declarations (SymbolScanner), not a language server — finds where a
/// name is declared, not which overload or type it resolves to. An LSP client is the upgrade.
public final class SymbolIndex {
    public struct Location: Equatable {
        public let url: URL
        public let line: Int
        public let kind: String
        public let name: String

        public init(url: URL, line: Int, kind: String, name: String) {
            self.url = url
            self.line = line
            self.kind = kind
            self.name = name
        }
    }

    private var byFile: [URL: [Location]] = [:]
    private var byName: [String: [Location]] = [:]
    private let lock = NSLock()

    public init() {}

    /// Files bigger than this are skipped (minified bundles, generated code).
    public static let maxFileSize = 1_000_000

    public var fileCount: Int { lock.withLock { byFile.count } }

    /// (Re)indexes one file; a missing or unsupported file just drops out.
    public func update(_ url: URL) {
        let locations = SymbolIndex.scan(url)
        lock.withLock {
            byFile[url] = locations.isEmpty ? nil : locations
            rebuildNames()
        }
    }

    public func update(_ urls: [URL]) {
        let scanned = urls.map { ($0, SymbolIndex.scan($0)) }
        lock.withLock {
            for (url, locations) in scanned { byFile[url] = locations.isEmpty ? nil : locations }
            rebuildNames()
        }
    }

    public func removeAll() {
        lock.withLock {
            byFile = [:]
            byName = [:]
        }
    }

    /// Where `name` is declared. The file being edited comes first, then files in the same
    /// language, then the rest.
    public func definitions(of name: String, preferring current: URL? = nil) -> [Location] {
        let found = lock.withLock { byName[name] ?? [] }
        let ext = current?.pathExtension.lowercased()
        return found.sorted { a, b in
            func rank(_ location: Location) -> Int {
                if location.url == current { return 0 }
                if location.url.pathExtension.lowercased() == ext { return 1 }
                return 2
            }
            let (ra, rb) = (rank(a), rank(b))
            if ra != rb { return ra < rb }
            if a.url.path != b.url.path { return a.url.path < b.url.path }
            return a.line < b.line
        }
    }

    /// Declared names starting with `prefix` (case-insensitive), shortest first.
    public func names(withPrefix prefix: String, limit: Int = 50) -> [String] {
        let lower = prefix.lowercased()
        let names = lock.withLock { Array(byName.keys) }
        return names
            .filter { $0.count > prefix.count && $0.lowercased().hasPrefix(lower) }
            .sorted { $0.count != $1.count ? $0.count < $1.count : $0 < $1 }
            .prefix(limit)
            .map { $0 }
    }

    private func rebuildNames() {
        var names: [String: [Location]] = [:]
        for locations in byFile.values {
            for location in locations { names[location.name, default: []].append(location) }
        }
        byName = names
    }

    static func scan(_ url: URL) -> [Location] {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxFileSize,
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return [] }
        let firstLine = text.prefix(200).split(separator: "\n", maxSplits: 1).first.map(String.init)
        let language = LanguageRegistry.detect(fileName: url.lastPathComponent, firstLine: firstLine)
        // Headings, CSS rules and YAML keys aren't things you jump to from code.
        guard SymbolScanner.supports(language.id), !["markdown", "css", "yaml"].contains(language.id) else { return [] }
        let string = text as NSString
        let index = LineIndex()
        index.rebuild(string)
        var locations: [Location] = []
        for symbol in SymbolScanner.symbols(in: string, languageID: language.id) {
            // "Greeter.greet" (Swift extensions) and "Foo::bar" (C++, Ruby): index the last part.
            let parts = symbol.name.split(whereSeparator: { $0 == "." || $0 == ":" })
            let name = parts.last.map(String.init) ?? symbol.name
            guard let first = name.first, first.isLetter || first == "_" || first == "$" else { continue }
            locations.append(Location(url: url, line: index.line(at: symbol.location), kind: symbol.kind, name: name))
        }
        return locations
    }
}
