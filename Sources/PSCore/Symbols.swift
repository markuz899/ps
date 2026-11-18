import Foundation

/// A declaration found in a file: function, type, heading, CSS rule...
public struct Symbol: Equatable {
    public let name: String
    public let kind: String
    /// Offset of the start of the declaration's line.
    public let location: Int
    /// Indentation of that line (tabs count as 4), or the heading level for Markdown.
    public let indent: Int
}

/// Regex-based outline for the breadcrumb bar. Each pattern uses the named groups
/// `indent`, `kind` (optional) and `name`. Good enough for navigation, not a parser.
public enum SymbolScanner {
    private static let typeModifiers = #"(?:(?:@\w+(?:\([^)\n]*\))?|public|private|fileprivate|internal|open|static|final|override|mutating|nonisolated|convenience|required|indirect|lazy|class(?=\s+(?:func|var)))\s+)*"#
    private static let cLikeTypes = #"^(?<indent>[ \t]*)(?:(?:public|private|protected|static|final|abstract|export|sealed)\s+)*(?<kind>class|struct|namespace|interface|enum|record|union)\s+(?<name>[A-Za-z_]\w*)"#
    private static let cLikeFunctions = #"^(?<indent>[ \t]*)(?:[\w:<>,\*&\[\]]+[ \t]+)+\**(?<name>[A-Za-z_~][\w:~]*)[ \t]*\([^;{}\n]*\)[ \t]*(?:const[ \t]*)?(?:throws[ \w.,]+)?\{?[ \t]*$"#
    private static let jsMethods = #"^(?<indent>[ \t]*)(?:(?:public|private|protected|static|async|readonly|get|set|export|default)\s+)*(?<name>[A-Za-z_$][\w$]*)[ \t]*\([^)\n]*\)[ \t]*(?::[^{=\n]+)?\{[ \t]*$"#

    private static let patterns: [String: [String]] = [
        "swift": [#"^(?<indent>[ \t]*)"# + typeModifiers + #"(?<kind>func|class|struct|enum|protocol|extension|actor|init|subscript)\b[ \t]*(?<name>[A-Za-z_][\w.]*)?"#],
        "python": [#"^(?<indent>[ \t]*)(?:async[ \t]+)?(?<kind>def|class)[ \t]+(?<name>\w+)"#],
        "javascript": [
            #"^(?<indent>[ \t]*)(?:export[ \t]+)?(?:default[ \t]+)?(?:async[ \t]+)?(?<kind>function\*?|class)[ \t]+(?<name>[A-Za-z_$][\w$]*)"#,
            #"^(?<indent>[ \t]*)(?:export[ \t]+)?(?<kind>const|let|var)[ \t]+(?<name>[A-Za-z_$][\w$]*)[ \t]*=[ \t]*(?:async[ \t]*)?(?:function|\([^)\n]*\)[ \t]*=>|[A-Za-z_$][\w$]*[ \t]*=>)"#,
            jsMethods,
        ],
        "typescript": [
            #"^(?<indent>[ \t]*)(?:export[ \t]+)?(?:default[ \t]+)?(?:declare[ \t]+)?(?:abstract[ \t]+)?(?:async[ \t]+)?(?<kind>function\*?|class|interface|enum|type|namespace)[ \t]+(?<name>[A-Za-z_$][\w$]*)"#,
            #"^(?<indent>[ \t]*)(?:export[ \t]+)?(?<kind>const|let|var)[ \t]+(?<name>[A-Za-z_$][\w$]*)[ \t]*(?::[^=\n]+)?=[ \t]*(?:async[ \t]*)?(?:function|\([^)\n]*\)[^=\n]*=>|[A-Za-z_$][\w$]*[ \t]*=>)"#,
            jsMethods,
        ],
        "go": [#"^(?<indent>)(?<kind>func|type)[ \t]+(?:\([^)\n]*\)[ \t]*)?(?<name>[A-Za-z_]\w*)"#],
        "rust": [#"^(?<indent>[ \t]*)(?:pub(?:\([\w ]+\))?[ \t]+)?(?:(?:async|unsafe|const|extern)[ \t]+)*(?<kind>fn|struct|enum|trait|impl|mod|type)\b(?:<[^>\n]*>)?[ \t]*(?<name>[A-Za-z_][\w:]*(?:<[^>\n]*>)?(?:[ \t]+for[ \t]+[A-Za-z_][\w:]*)?)"#],
        "c": [cLikeTypes, cLikeFunctions],
        "cpp": [cLikeTypes, cLikeFunctions],
        "java": [cLikeTypes, cLikeFunctions],
        "php": [#"^(?<indent>[ \t]*)(?:(?:public|private|protected|static|final|abstract)[ \t]+)*(?<kind>function|class|interface|trait|enum)[ \t]+(?<name>\w+)"#],
        "ruby": [#"^(?<indent>[ \t]*)(?<kind>def|class|module)[ \t]+(?<name>[\w.:?!=]+)"#],
        "shell": [#"^(?<indent>[ \t]*)(?:function[ \t]+)?(?<name>[A-Za-z_][\w-]*)[ \t]*\(\)"#],
        "markdown": [#"^(?<kind>#{1,6})[ \t]+(?<name>.+?)[ \t#]*$"#],
        "css": [#"^(?<indent>[ \t]*)(?<name>@media[^{\n]*|[^\s{}/@][^{};\n]*?)[ \t]*\{"#],
        "sql": [#"(?i)^(?<indent>[ \t]*)create[ \t]+(?:or[ \t]+replace[ \t]+)?(?<kind>table|view|function|procedure|index|trigger)[ \t]+(?:if[ \t]+not[ \t]+exists[ \t]+)?(?<name>[\w."]+)"#],
        "yaml": [#"^(?<indent>[ \t]*)(?<name>[\w.-]+):[ \t]*$"#],
    ]

    /// Names that the C-like and JS method patterns would otherwise pick up.
    private static let keywords: Set<String> = ["if", "for", "while", "switch", "catch", "return", "else", "do", "sizeof", "new", "function", "with"]

    private static var compiled: [String: [NSRegularExpression]] = [:]
    private static let lock = NSLock()

    private static func regexes(for languageID: String) -> [NSRegularExpression] {
        lock.lock()
        defer { lock.unlock() }
        if let cached = compiled[languageID] { return cached }
        let list = (patterns[languageID] ?? []).compactMap { try? NSRegularExpression(pattern: $0, options: [.anchorsMatchLines]) }
        compiled[languageID] = list
        return list
    }

    public static func supports(_ languageID: String) -> Bool {
        patterns[languageID] != nil
    }

    public static func symbols(in text: NSString, languageID: String, limit: Int = 5000) -> [Symbol] {
        var result: [Symbol] = []
        let full = NSRange(location: 0, length: text.length)
        for regex in regexes(for: languageID) {
            regex.enumerateMatches(in: text as String, range: full) { match, _, stop in
                guard let match else { return }
                let nameRange = match.range(withName: "name")
                let kindRange = match.range(withName: "kind")
                let kind = kindRange.location == NSNotFound ? "" : text.substring(with: kindRange)
                var name = nameRange.location == NSNotFound ? kind : text.substring(with: nameRange)
                name = name.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !keywords.contains(name) else { return }
                let indent: Int
                if languageID == "markdown" {
                    indent = kind.count
                } else {
                    let indentRange = match.range(withName: "indent")
                    let whitespace = indentRange.location == NSNotFound ? "" : text.substring(with: indentRange)
                    indent = whitespace.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
                }
                result.append(Symbol(name: name, kind: kind, location: match.range.location, indent: indent))
                if result.count >= limit { stop.pointee = true }
            }
        }
        // Several patterns per language: put them back in file order, one per line.
        var seen = Set<Int>()
        return result.sorted { $0.location < $1.location }.filter { seen.insert($0.location).inserted }
    }

    /// The declarations enclosing `caret`, outermost first (e.g. `Greeter › greet`).
    /// A declaration encloses the caret when it starts before it and is less indented
    /// than the caret's line; Markdown uses heading levels instead.
    public static func chain(_ symbols: [Symbol], in text: NSString, caret: Int, languageID: String) -> [Symbol] {
        let caret = min(max(0, caret), text.length)
        let lineStart = text.lineRange(for: NSRange(location: caret, length: 0)).location
        var threshold = languageID == "markdown" ? Int.max : indentOfContext(text, lineStart: lineStart)
        var chain: [Symbol] = []
        for symbol in symbols.reversed() where symbol.location <= caret {
            if symbol.location == lineStart || symbol.indent < threshold {
                chain.insert(symbol, at: 0)
                threshold = symbol.indent
                if threshold == 0 { break }
            }
        }
        return chain
    }

    /// Indentation of the caret's line, or of the nearest non-blank line above it.
    private static func indentOfContext(_ text: NSString, lineStart: Int) -> Int {
        var start = lineStart
        for _ in 0..<500 {
            let line = text.substring(with: text.lineRange(for: NSRange(location: start, length: 0)))
            if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            }
            if start == 0 { break }
            start = text.lineRange(for: NSRange(location: start - 1, length: 0)).location
        }
        return 0
    }
}
