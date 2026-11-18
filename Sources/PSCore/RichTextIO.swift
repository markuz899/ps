import AppKit

/// Which editor a document gets. Decided once at open time from the file type.
public enum EditorMode: String, Codable {
    case code
    case rich
    /// Whiteboard (Excalidraw-compatible `.excalidraw` files).
    case board

    public static let richExtensions: Set<String> = ["rtf", "rtfd", "txt"]

    public static func forFile(_ url: URL) -> EditorMode {
        let ext = url.pathExtension.lowercased()
        if ext == "excalidraw" { return .board }
        return richExtensions.contains(ext) ? .rich : .code
    }
}

public enum RichFileKind: Equatable {
    case rtf
    case rtfd
    case txt

    public init?(url: URL) {
        switch url.pathExtension.lowercased() {
        case "rtf": self = .rtf
        case "rtfd": self = .rtfd
        case "txt": self = .txt
        default: return nil
        }
    }
}

/// The "unformatted" look of a rich document. Text that only carries these attributes
/// counts as plain text for the .txt save rules.
public struct RichDefaults {
    public var font: NSFont
    public var paragraphStyle: NSParagraphStyle

    public init(font: NSFont, paragraphStyle: NSParagraphStyle = .default) {
        self.font = font
        self.paragraphStyle = paragraphStyle
    }

    /// No foreground colour on purpose: stored text stays black (portable RTF) and the
    /// text view maps it for dark mode.
    public var attributes: [NSAttributedString.Key: Any] {
        [.font: font, .paragraphStyle: paragraphStyle]
    }
}

public enum RichTextIO {
    public static func read(_ url: URL, defaults: RichDefaults) throws -> (text: NSAttributedString, format: TextFormat?) {
        switch RichFileKind(url: url) {
        case .rtf:
            let text = try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            return (text, nil)
        case .rtfd:
            let text = try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
            return (text, nil)
        case .txt, .none:
            let (string, format) = try TextFileIO.decode(try Data(contentsOf: url))
            return (NSAttributedString(string: string, attributes: defaults.attributes), format)
        }
    }

    public static func rtfData(_ text: NSAttributedString) throws -> Data {
        try text.data(
            from: NSRange(location: 0, length: text.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }

    public static func rtfdWrapper(_ text: NSAttributedString) throws -> FileWrapper {
        try text.fileWrapper(
            from: NSRange(location: 0, length: text.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        )
    }

    public static func export(_ text: NSAttributedString, as type: NSAttributedString.DocumentType) throws -> Data {
        try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: type])
    }

    public static func write(_ text: NSAttributedString, to url: URL, kind: RichFileKind, plainFormat: TextFormat = .standard) throws {
        switch kind {
        case .rtf:
            try SafeWriter.write(try rtfData(text), to: url)
        case .rtfd:
            try rtfdWrapper(text).write(to: url, options: .atomic, originalContentsURL: nil)
        case .txt:
            try SafeWriter.write(try TextFileIO.encode(plainString(text), format: plainFormat), to: url)
        }
    }

    public static func hasAttachments(_ text: NSAttributedString) -> Bool {
        var found = false
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            if value != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    /// The characters only, without attachment placeholders.
    public static func plainString(_ text: NSAttributedString) -> String {
        text.string.replacingOccurrences(of: "\u{FFFC}", with: "")
    }

    /// True when any run carries something other than the default font and paragraph style.
    public static func hasFormatting(_ text: NSAttributedString, defaults: RichDefaults) -> Bool {
        var formatted = false
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, _, stop in
            for (key, value) in attributes {
                switch key {
                case .font:
                    if let font = value as? NSFont,
                       font.fontName != defaults.font.fontName || abs(font.pointSize - defaults.font.pointSize) > 0.01 {
                        formatted = true
                    }
                case .paragraphStyle:
                    if let style = value as? NSParagraphStyle,
                       style != defaults.paragraphStyle && style != NSParagraphStyle.default {
                        formatted = true
                    }
                case .foregroundColor:
                    if let color = value as? NSColor, !isPlainTextColor(color) { formatted = true }
                default:
                    formatted = true
                }
                if formatted {
                    stop.pointee = true
                    return
                }
            }
        }
        return formatted
    }

    private static func isPlainTextColor(_ color: NSColor) -> Bool {
        if color == .textColor || color == .labelColor || color == .controlTextColor { return true }
        guard let rgb = color.usingColorSpace(.sRGB) else { return false }
        return rgb.redComponent < 0.01 && rgb.greenComponent < 0.01 && rgb.blueComponent < 0.01 && rgb.alphaComponent > 0.99
    }
}

/// Rules for saving a document that was opened from a .txt file.
public enum TxtSavePolicy {
    public enum Decision: Equatable {
        /// Nothing but text: write the .txt in place.
        case writePlain
        /// Formatting would be lost: ask "convert to RTF" vs "save as plain text".
        case askUser
    }

    public static func decision(for text: NSAttributedString, defaults: RichDefaults) -> Decision {
        RichTextIO.hasFormatting(text, defaults: defaults) ? .askUser : .writePlain
    }

    /// The file created by "Convert to RTF": next to the original, never overwriting anything.
    public static func convertedURL(for original: URL, needsRTFD: Bool, fileManager: FileManager = .default) -> URL {
        let directory = original.deletingLastPathComponent()
        let base = original.deletingPathExtension().lastPathComponent
        let ext = needsRTFD ? "rtfd" : "rtf"
        var candidate = directory.appendingPathComponent(base).appendingPathExtension(ext)
        var index = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) \(index)").appendingPathExtension(ext)
            index += 1
        }
        return candidate
    }
}
