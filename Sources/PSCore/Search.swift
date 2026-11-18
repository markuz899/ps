import Foundation

public struct FindOptions: Equatable {
    public var caseSensitive = false
    public var wholeWord = false
    public var regex = false

    public init(caseSensitive: Bool = false, wholeWord: Bool = false, regex: Bool = false) {
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        self.regex = regex
    }
}

public enum FindEngine {
    public static func makeRegex(_ query: String, options: FindOptions) throws -> NSRegularExpression {
        var pattern = options.regex ? query : NSRegularExpression.escapedPattern(for: query)
        if options.wholeWord { pattern = #"\b(?:"# + pattern + #")\b"# }
        var flags: NSRegularExpression.Options = options.regex ? [.anchorsMatchLines] : []
        if !options.caseSensitive { flags.insert(.caseInsensitive) }
        return try NSRegularExpression(pattern: pattern, options: flags)
    }

    public static func ranges(of query: String, in text: String, options: FindOptions, limit: Int = 100_000) throws -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let regex = try makeRegex(query, options: options)
        var ranges: [NSRange] = []
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) { match, _, stop in
            guard let match, match.range.length > 0 else { return }
            ranges.append(match.range)
            if ranges.count >= limit { stop.pointee = true }
        }
        return ranges
    }

    /// The replacement text for one match ($1 etc. are expanded only in regex mode).
    public static func replacement(for range: NSRange, in text: String, query: String, template: String, options: FindOptions) throws -> String {
        guard options.regex else { return template }
        let regex = try makeRegex(query, options: options)
        guard let match = regex.firstMatch(in: text, range: range) else { return template }
        return regex.replacementString(for: match, in: text, offset: 0, template: template)
    }

    /// All matches with their replacement strings, ready to apply in one undoable edit.
    public static func replacements(of query: String, in text: String, template: String, options: FindOptions) throws -> [(range: NSRange, replacement: String)] {
        guard !query.isEmpty else { return [] }
        let regex = try makeRegex(query, options: options)
        let escaped = options.regex ? template : NSRegularExpression.escapedTemplate(for: template)
        return regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
            .filter { $0.range.length > 0 }
            .map { ($0.range, regex.replacementString(for: $0, in: text, offset: 0, template: escaped)) }
    }

    public static func replaceAll(of query: String, in text: String, with template: String, options: FindOptions) throws -> (text: String, count: Int) {
        let items = try replacements(of: query, in: text, template: template, options: options)
        let result = NSMutableString(string: text)
        for item in items.reversed() {
            result.replaceCharacters(in: item.range, with: item.replacement)
        }
        return (result as String, items.count)
    }
}

/// Subsequence matcher for Quick Open; higher scores are better.
public enum Fuzzy {
    public static func score(_ query: String, in candidate: String) -> Int? {
        let needle = Array(query.lowercased().filter { $0 != " " })
        guard !needle.isEmpty else { return 0 }
        let haystack = Array(candidate.lowercased())
        let original = Array(candidate)
        let nameStart = (candidate.lastIndex(of: "/").map { candidate.distance(from: candidate.startIndex, to: $0) + 1 }) ?? 0

        var score = 0
        var index = 0
        var previous = -2
        for character in needle {
            guard let found = haystack[index...].firstIndex(of: character) else { return nil }
            score += 1
            if found == previous + 1 { score += 5 }
            if found == 0 || "/_-. ".contains(haystack[found - 1]) { score += 8 }
            if found > 0, original[found].isUppercase, original[found - 1].isLowercase { score += 6 }
            if found >= nameStart { score += 3 }
            previous = found
            index = found + 1
        }
        score -= max(0, haystack.count - needle.count) / 8
        return score
    }
}

public struct FolderMatch: Hashable {
    public let url: URL
    /// 1-based line number.
    public let line: Int
    /// Range in the whole file (UTF-16 offsets), used to select the match.
    public let range: NSRange
    public let preview: String
    /// Range of the match inside `preview`.
    public let previewRange: NSRange
}

public enum FolderSearch {
    public static let skippedDirectories: Set<String> = [".git", ".svn", ".hg", "node_modules", ".build", "DerivedData"]
    public static let maxFileSize = 5 * 1024 * 1024

    /// Regular files under `root`, skipping VCS and build folders.
    public static func files(in root: URL, includeHidden: Bool, isCancelled: () -> Bool = { false }) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isPackageKey]
        var options: FileManager.DirectoryEnumerationOptions = []
        if !includeHidden { options.insert(.skipsHiddenFiles) }
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: options) else {
            return []
        }
        var result: [URL] = []
        for case let url as URL in enumerator {
            if isCancelled() { break }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if skippedDirectories.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                } else if url.pathExtension.lowercased() == "rtfd" {
                    enumerator.skipDescendants()
                    result.append(url)
                }
                continue
            }
            if values?.isRegularFile == true { result.append(url) }
        }
        return result
    }

    /// Searches every text file; `onFile` is called once per file with matches.
    public static func search(
        root: URL,
        query: String,
        options: FindOptions,
        includeHidden: Bool,
        maxMatches: Int = 20_000,
        isCancelled: () -> Bool,
        onFile: ([FolderMatch]) -> Void
    ) throws {
        let regex = try FindEngine.makeRegex(query, options: options)
        var total = 0
        for url in files(in: root, includeHidden: includeHidden, isCancelled: isCancelled) {
            if isCancelled() || total >= maxMatches { return }
            guard url.pathExtension.lowercased() != "rtfd",
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxFileSize,
                  let data = try? Data(contentsOf: url),
                  let text = text(of: url, data: data) else { continue }
            let found = matches(in: text, url: url, regex: regex, limit: maxMatches - total)
            if !found.isEmpty {
                total += found.count
                onFile(found)
            }
        }
    }

    /// Replace in one file on disk, keeping its encoding, BOM and line endings.
    /// Returns the number of replacements (0 = file untouched).
    @discardableResult
    public static func replace(in url: URL, query: String, template: String, options: FindOptions) throws -> Int {
        let (text, format) = try TextFileIO.decode(try Data(contentsOf: url))
        let (result, count) = try FindEngine.replaceAll(of: query, in: text, with: template, options: options)
        if count > 0 { try SafeWriter.write(try TextFileIO.encode(result, format: format), to: url) }
        return count
    }

    private static func text(of url: URL, data: Data) -> String? {
        if url.pathExtension.lowercased() == "rtf" {
            return (try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil))?.string
        }
        return try? TextFileIO.decode(data).text
    }

    public static func matches(in text: String, url: URL, regex: NSRegularExpression, limit: Int = .max) -> [FolderMatch] {
        let string = text as NSString
        var result: [FolderMatch] = []
        var line = 1
        var scanned = 0
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: string.length)) { match, _, stop in
            guard let match, match.range.length > 0 else { return }
            line += newlineCount(string, from: scanned, to: match.range.location)
            scanned = match.range.location
            let lineRange = string.lineRange(for: NSRange(location: match.range.location, length: 0))
            var previewText = string.substring(with: lineRange).trimmingCharacters(in: .newlines)
            var offset = match.range.location - lineRange.location
            let leading = previewText.prefix { $0 == " " || $0 == "\t" }.utf16.count
            previewText = String(previewText.dropFirst(previewText.prefix { $0 == " " || $0 == "\t" }.count))
            offset -= leading
            if offset > 60 {
                let cut = offset - 30
                previewText = "…" + String((previewText as NSString).substring(from: cut))
                offset = offset - cut + 1
            }
            let preview = String(previewText.prefix(240))
            let length = min(match.range.length, max(0, (preview as NSString).length - offset))
            result.append(FolderMatch(
                url: url,
                line: line,
                range: match.range,
                preview: preview,
                previewRange: NSRange(location: max(0, offset), length: length)
            ))
            if result.count >= limit { stop.pointee = true }
        }
        return result
    }

    private static func newlineCount(_ string: NSString, from start: Int, to end: Int) -> Int {
        guard end > start else { return 0 }
        var count = 0
        var location = start
        while location < end {
            let found = string.range(of: "\n", options: .literal, range: NSRange(location: location, length: end - location))
            if found.location == NSNotFound { break }
            count += 1
            location = found.location + 1
        }
        return count
    }
}
