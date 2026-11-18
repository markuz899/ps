import Foundation

public struct Token: Equatable {
    public let range: NSRange
    public let scope: Int
}

/// Regex tokenizer: all rules of a language are combined into a single alternation, so
/// the leftmost match wins (a "//" inside a string stays a string). Scanning starts at an
/// arbitrary offset and stops at a limit, which is what makes incremental highlighting cheap.
public final class Tokenizer {
    public let scopes: [String]
    private let regex: NSRegularExpression

    private static var cache: [String: Tokenizer] = [:]
    private static let lock = NSLock()

    public static func forLanguage(_ language: Language) -> Tokenizer? {
        guard !language.rules.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[language.id] { return cached }
        guard let tokenizer = Tokenizer(rules: language.rules) else { return nil }
        cache[language.id] = tokenizer
        return tokenizer
    }

    public init?(rules: [GrammarRule]) {
        let pattern = rules.map { "(\($0.pattern))" }.joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        self.regex = regex
        scopes = rules.map(\.scope)
    }

    /// Tokens starting in `[start, until)`. The last ones may extend past `until`
    /// (block comments, multi-line strings): callers use that to widen the repainted range.
    public func tokens(
        in text: NSString,
        from start: Int,
        until: Int,
        isCancelled: () -> Bool = { false }
    ) -> [Token] {
        var output: [Token] = []
        let groups = scopes.count
        let range = NSRange(location: start, length: text.length - start)
        var counter = 0
        regex.enumerateMatches(
            in: text as String,
            options: [.withTransparentBounds, .withoutAnchoringBounds],
            range: range
        ) { match, _, stop in
            guard let match else { return }
            if match.range.location >= until {
                stop.pointee = true
                return
            }
            counter += 1
            if counter % 2048 == 0, isCancelled() {
                stop.pointee = true
                return
            }
            guard match.range.length > 0 else { return }
            for group in 1...groups where match.range(at: group).location != NSNotFound {
                output.append(Token(range: match.range, scope: group - 1))
                break
            }
        }
        return output
    }
}
