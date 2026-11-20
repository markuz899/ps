import Foundation

/// The other half of an HTML/XML tag pair, so renaming `<div>` renames `</div>` too.
/// ponytail: regex scan of tags, not a parser — quotes containing `>` and tags inside
/// `<script>` can confuse it. It only acts when a matching partner is found.
public enum TagPair {
    public static let languages: Set<String> = ["html", "xml", "php"]
    static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr",
    ]
    private static let tag = try! NSRegularExpression(pattern: #"<!--[\s\S]*?-->|<(/?)([A-Za-z][\w:.-]*)(?:[^<>"']|"[^"]*"|'[^']*')*?(/?)>"#)
    /// How far the partner is looked for, each way.
    static let window = 500_000

    public static func isNameCharacter(_ c: unichar) -> Bool {
        guard let scalar = UnicodeScalar(c) else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || c == 0x5F || c == 0x3A || c == 0x2E || c == 0x2D  // _ : . -
    }

    /// The name of the tag that `index` touches (inside it or right after it), and whether it's a closing tag.
    public static func name(in text: NSString, at index: Int) -> (range: NSRange, closing: Bool)? {
        guard index >= 0, index <= text.length else { return nil }
        var start = index
        while start > 0, isNameCharacter(text.character(at: start - 1)) { start -= 1 }
        var end = index
        while end < text.length, isNameCharacter(text.character(at: end)) { end += 1 }
        guard end > start, start > 0 else { return nil }
        if text.character(at: start - 1) == 0x3C { return (NSRange(location: start, length: end - start), false) }  // <
        if text.character(at: start - 1) == 0x2F, start > 1, text.character(at: start - 2) == 0x3C {  // </
            return (NSRange(location: start, length: end - start), true)
        }
        return nil
    }

    /// The tag name at `index` and the name range of its matching partner.
    public static func partner(in text: NSString, at index: Int) -> (own: NSRange, partner: NSRange)? {
        guard let (own, closing) = name(in: text, at: index) else { return nil }
        let tagStart = own.location - (closing ? 2 : 1)
        let name = text.substring(with: own).lowercased()
        guard !voidElements.contains(name) else { return nil }

        // The tag itself must be complete (and not self-closing).
        let rest = NSRange(location: tagStart, length: min(text.length - tagStart, window))
        guard let mine = tag.firstMatch(in: text as String, options: .anchored, range: rest),
              mine.range(at: 2).location == own.location, mine.range(at: 3).length == 0 else { return nil }

        func tags(in range: NSRange) -> [(name: NSRange, closing: Bool)] {
            tag.matches(in: text as String, range: range).compactMap { match in
                let nameRange = match.range(at: 2)
                guard nameRange.location != NSNotFound, match.range(at: 3).length == 0,
                      text.substring(with: nameRange).lowercased() == name else { return nil }
                return (nameRange, match.range(at: 1).length > 0)
            }
        }

        var depth = 0
        if closing {
            let from = max(0, tagStart - window)
            for candidate in tags(in: NSRange(location: from, length: tagStart - from)).reversed() {
                if candidate.closing {
                    depth += 1
                } else if depth == 0 {
                    return (own, candidate.name)
                } else {
                    depth -= 1
                }
            }
        } else {
            let from = NSMaxRange(mine.range)
            for candidate in tags(in: NSRange(location: from, length: min(text.length - from, window))) {
                if !candidate.closing {
                    depth += 1
                } else if depth == 0 {
                    return (own, candidate.name)
                } else {
                    depth -= 1
                }
            }
        }
        return nil
    }
}

/// Web links written in code (comments, strings), for ⌘-click.
public enum CodeLink {
    private static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// The link under `index`. Only explicit ones (`https://…`, `www.…`, `mailto:`), so
    /// `user.name` or `Greeter.greet` never count as links.
    public static func url(in text: NSString, at index: Int) -> URL? {
        guard index >= 0, index <= text.length else { return nil }
        let line = text.lineRange(for: NSRange(location: min(index, text.length), length: 0))
        guard line.length < 10_000 else { return nil }
        for match in detector.matches(in: text as String, range: line) {
            guard let url = match.url, match.range.location <= index, index < NSMaxRange(match.range) else { continue }
            let written = text.substring(with: match.range).lowercased()
            if written.contains("://") || written.hasPrefix("www.") || written.hasPrefix("mailto:") { return url }
        }
        return nil
    }
}
