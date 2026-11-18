import AppKit

/// Colour literals in code (`#3b5bdb`, `rgb(…)`, `rgba(…)`), for the inline swatches.
public enum ColorLiteral {
    private static let regex = try! NSRegularExpression(
        pattern: #"#(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{3,4})\b|rgba?\(\s*\d{1,3}\s*,\s*\d{1,3}\s*,\s*\d{1,3}\s*(?:,\s*(?:0|1|0?\.\d+)\s*)?\)"#
    )

    public static let languages: Set<String> = ["css", "html", "xml", "javascript", "typescript", "json", "yaml"]

    public static func find(in text: NSString, range: NSRange) -> [(range: NSRange, color: NSColor)] {
        regex.matches(in: text as String, options: [.withTransparentBounds], range: range).compactMap { match in
            parse(text.substring(with: match.range)).map { (match.range, $0) }
        }
    }

    public static func parse(_ literal: String) -> NSColor? {
        if literal.hasPrefix("#") {
            var hex = String(literal.dropFirst())
            if hex.count == 3 || hex.count == 4 { hex = hex.map { "\($0)\($0)" }.joined() }
            return NSColor(hex: hex)
        }
        let numbers = literal
            .drop { $0 != "(" }.dropFirst().prefix { $0 != ")" }
            .split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count >= 3, numbers.prefix(3).allSatisfy({ $0 <= 255 }) else { return nil }
        return NSColor(srgbRed: numbers[0] / 255, green: numbers[1] / 255, blue: numbers[2] / 255, alpha: numbers.count > 3 ? numbers[3] : 1)
    }

    /// Writes `color` in the same notation as `original`.
    public static func format(_ color: NSColor, like original: String) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return original }
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        let a = rgb.alphaComponent
        if original.hasPrefix("#") {
            let uppercase = original.dropFirst().contains { $0.isUppercase }
            var hex = String(format: "#%02x%02x%02x", r, g, b)
            if a < 0.999 || original.count == 9 || original.count == 5 { hex += String(format: "%02x", Int((a * 255).rounded())) }
            return uppercase ? hex.uppercased() : hex
        }
        if a < 0.999 || original.hasPrefix("rgba") {
            return "rgba(\(r), \(g), \(b), \(String(format: "%.2g", a)))"
        }
        return "rgb(\(r), \(g), \(b))"
    }
}

/// Arithmetic for multiple cursors: every edit is applied to all ranges at once.
public enum MultiCursor {
    /// Sorted, with overlapping or touching ranges merged.
    public static func normalize(_ ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            if let last = result.last, range.location <= NSMaxRange(last) {
                result[result.count - 1] = NSUnionRange(last, range)
            } else {
                result.append(range)
            }
        }
        return result
    }

    /// Where the carets land after replacing each (normalized) range with text of the
    /// given UTF-16 length.
    public static func carets(afterReplacing ranges: [NSRange], insertedLength: Int) -> [NSRange] {
        var shift = 0
        return ranges.map { range in
            let caret = NSRange(location: range.location + shift + insertedLength, length: 0)
            shift += insertedLength - range.length
            return caret
        }
    }

    /// Ranges removed by Backspace: the selection itself, or the character before each caret.
    public static func backspaceRanges(_ ranges: [NSRange]) -> [NSRange] {
        normalize(ranges.compactMap { range in
            if range.length > 0 { return range }
            return range.location > 0 ? NSRange(location: range.location - 1, length: 1) : nil
        })
    }

    /// Next occurrence of `needle` after `after`, wrapping around; nil if none is free.
    public static func nextOccurrence(of needle: String, in text: NSString, after: Int, excluding taken: [NSRange]) -> NSRange? {
        guard !needle.isEmpty else { return nil }
        var start = min(after, text.length)
        for _ in 0..<2 {
            var range = NSRange(location: start, length: text.length - start)
            while true {
                let found = text.range(of: needle, options: .literal, range: range)
                if found.location == NSNotFound { break }
                if !taken.contains(where: { NSIntersectionRange($0, found).length > 0 || $0 == found }) { return found }
                range = NSRange(location: NSMaxRange(found), length: text.length - NSMaxRange(found))
            }
            start = 0
        }
        return nil
    }
}

/// Renders Markdown for the side preview, with Foundation's parser (macOS 12+): no WebView.
public enum MarkdownRenderer {
    public struct Style {
        public var font: NSFont
        public var monoFont: NSFont
        public var textColor: NSColor
        public var secondaryColor: NSColor
        public var accentColor: NSColor
        public var codeBackground: NSColor

        public init(font: NSFont, monoFont: NSFont, textColor: NSColor, secondaryColor: NSColor, accentColor: NSColor, codeBackground: NSColor) {
            self.font = font
            self.monoFont = monoFont
            self.textColor = textColor
            self.secondaryColor = secondaryColor
            self.accentColor = accentColor
            self.codeBackground = codeBackground
        }
    }

    public static func render(_ source: String, style: Style) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: source, options: options) else {
            return NSAttributedString(string: source, attributes: [.font: style.font, .foregroundColor: style.textColor])
        }

        let output = NSMutableAttributedString()
        let manager = NSFontManager.shared
        var lastBlock: Int?
        var lastItem: Int?
        var lastRow: Int?

        for run in parsed.runs {
            var text = String(parsed[run.range].characters)
            let components = run.presentationIntent?.components ?? []
            let block = components.first?.identity

            var headerLevel = 0
            var depth = 0
            var quote = 0
            var code = false
            var item: (identity: Int, ordinal: Int)?
            var ordered = false
            var cell: (column: Int, row: Int)?
            var rule = false
            for (index, component) in components.enumerated() {
                switch component.kind {
                case let .header(level): headerLevel = level
                case .unorderedList, .orderedList: depth += 1
                case let .listItem(ordinal):
                    if item == nil {
                        item = (component.identity, ordinal)
                        if index + 1 < components.count, case .orderedList = components[index + 1].kind { ordered = true }
                    }
                case .blockQuote: quote += 1
                case .codeBlock: code = true
                case let .tableCell(column): cell = (column, 0)
                case let .tableRow(row): if cell != nil { cell?.row = row + 1 }
                case .tableHeaderRow: if cell != nil { cell?.row = 0 }
                case .thematicBreak: rule = true
                default: break
                }
            }

            let paragraph = NSMutableParagraphStyle()
            paragraph.lineHeightMultiple = 1.2
            paragraph.paragraphSpacing = style.font.pointSize * 0.6
            var font = style.font
            var color = style.textColor
            var background: NSColor?

            if headerLevel > 0 {
                let scale: [CGFloat] = [2.0, 1.6, 1.3, 1.15, 1.05, 1.0]
                font = manager.convert(manager.convert(style.font, toSize: (style.font.pointSize * scale[min(headerLevel, 6) - 1]).rounded()), toHaveTrait: .boldFontMask)
                paragraph.paragraphSpacingBefore = style.font.pointSize * 0.8
            }
            if depth > 0 {
                let indent = CGFloat(depth) * 24
                paragraph.headIndent = indent
                paragraph.tabStops = [NSTextTab(textAlignment: .right, location: indent - 8), NSTextTab(textAlignment: .left, location: indent)]
                paragraph.paragraphSpacing = style.font.pointSize * 0.25
            }
            if quote > 0 {
                paragraph.headIndent += CGFloat(quote) * 18
                paragraph.firstLineHeadIndent += CGFloat(quote) * 18
                color = style.secondaryColor
                font = manager.convert(font, toHaveTrait: .italicFontMask)
            }
            if code {
                font = style.monoFont
                background = style.codeBackground
                paragraph.headIndent += 12
                paragraph.firstLineHeadIndent += 12
                paragraph.lineHeightMultiple = 1.1
                if text.hasSuffix("\n") { text.removeLast() }
            }

            if let inline = run.inlinePresentationIntent {
                if inline.contains(.stronglyEmphasized) { font = manager.convert(font, toHaveTrait: .boldFontMask) }
                if inline.contains(.emphasized) { font = manager.convert(font, toHaveTrait: .italicFontMask) }
                if inline.contains(.code) {
                    font = NSFont.monospacedSystemFont(ofSize: style.font.pointSize * 0.92, weight: .regular)
                    background = style.codeBackground
                }
                if inline.contains(.softBreak) { text = " " }
                if inline.contains(.lineBreak) { text = "\u{2028}" }
            }

            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
            if let background { attributes[.backgroundColor] = background }
            if let inline = run.inlinePresentationIntent, inline.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link {
                attributes[.link] = link
                attributes[.foregroundColor] = style.accentColor
            }
            if let image = run.imageURL {
                attributes[.link] = image
                text = "🖼 " + text
            }

            if block != lastBlock {
                if output.length > 0 {
                    // Cells of the same table row stay on one line, separated by tabs.
                    let sameRow = cell.map { $0.column > 0 && $0.row == lastRow } ?? false
                    output.append(NSAttributedString(string: sameRow ? "\t" : "\n", attributes: attributes))
                }
                if let item, item.identity != lastItem {
                    let marker = ordered ? "\(item.ordinal)." : (depth > 1 ? "◦" : "•")
                    var markerAttributes = attributes
                    markerAttributes[.foregroundColor] = style.accentColor
                    output.append(NSAttributedString(string: "\t\(marker)\t", attributes: markerAttributes))
                    lastItem = item.identity
                }
                if rule {
                    var ruleAttributes = attributes
                    ruleAttributes[.foregroundColor] = style.secondaryColor
                    output.append(NSAttributedString(string: String(repeating: "─", count: 40), attributes: ruleAttributes))
                }
                lastBlock = block
                lastRow = cell?.row
            }
            if cell?.row == 0 { attributes[.font] = manager.convert(font, toHaveTrait: .boldFontMask) }
            output.append(NSAttributedString(string: text, attributes: attributes))
        }
        return output
    }
}
