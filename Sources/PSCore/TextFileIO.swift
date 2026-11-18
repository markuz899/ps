import Foundation

public enum LineEnding: String, CaseIterable, Codable {
    case lf = "LF"
    case crlf = "CRLF"
    case cr = "CR"

    public var sequence: String {
        switch self {
        case .lf: return "\n"
        case .crlf: return "\r\n"
        case .cr: return "\r"
        }
    }
}

/// Everything needed to write a text file back exactly as it was read.
public struct TextFormat: Equatable {
    public var encoding: String.Encoding
    public var lineEnding: LineEnding
    public var hasBOM: Bool

    public init(encoding: String.Encoding = .utf8, lineEnding: LineEnding = .lf, hasBOM: Bool = false) {
        self.encoding = encoding
        self.lineEnding = lineEnding
        self.hasBOM = hasBOM
    }

    public static let standard = TextFormat()
}

public enum TextFileError: Error, Equatable {
    case binary
    case undecodable
    case unencodable
}

public enum TextFileIO {
    public static let sniffLength = 8192

    /// Encodings offered in the UI, in menu order.
    public static let supportedEncodings: [String.Encoding] = [
        .utf8, .utf16LittleEndian, .utf16BigEndian, .windowsCP1252, .isoLatin1,
        .macOSRoman, .ascii, .shiftJIS, .japaneseEUC,
    ]

    public static func displayName(of encoding: String.Encoding) -> String {
        switch encoding {
        case .utf8: return "UTF-8"
        case .utf16LittleEndian: return "UTF-16 LE"
        case .utf16BigEndian: return "UTF-16 BE"
        case .windowsCP1252: return "Windows 1252"
        case .isoLatin1: return "ISO 8859-1"
        case .macOSRoman: return "Mac Roman"
        case .ascii: return "ASCII"
        case .shiftJIS: return "Shift JIS"
        case .japaneseEUC: return "EUC-JP"
        default: return String.localizedName(of: encoding)
        }
    }

    public static func isProbablyBinary(_ data: Data) -> Bool {
        data.prefix(sniffLength).contains(0)
    }

    /// Decodes file bytes. Without `forcing`, the encoding is detected: BOM, then strict
    /// UTF-8, then the common 8-bit Western encodings. Newlines are normalised to "\n";
    /// the original style is returned in the format so it can be restored on save.
    public static func decode(_ data: Data, forcing: String.Encoding? = nil) throws -> (text: String, format: TextFormat) {
        var encoding: String.Encoding
        var hasBOM = false
        var body = data

        if let forced = forcing {
            encoding = forced
            let bom = byteOrderMark(for: forced)
            if !bom.isEmpty, data.starts(with: bom) {
                hasBOM = true
                body = Data(data.dropFirst(bom.count))
            }
        } else if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            encoding = .utf8
            hasBOM = true
            body = Data(data.dropFirst(3))
        } else if data.starts(with: [0xFF, 0xFE]) {
            encoding = .utf16LittleEndian
            hasBOM = true
            body = Data(data.dropFirst(2))
        } else if data.starts(with: [0xFE, 0xFF]) {
            encoding = .utf16BigEndian
            hasBOM = true
            body = Data(data.dropFirst(2))
        } else {
            if isProbablyBinary(data) { throw TextFileError.binary }
            if String(data: data, encoding: .utf8) != nil {
                encoding = .utf8
            } else {
                encoding = detectLegacyEncoding(data)
                if controlCharacterRatio(data) > 0.05 { throw TextFileError.binary }
            }
        }

        guard let raw = String(data: body, encoding: encoding) else { throw TextFileError.undecodable }
        let format = TextFormat(encoding: encoding, lineEnding: detectLineEnding(raw), hasBOM: hasBOM)
        return (normalizeNewlines(raw), format)
    }

    public static func encode(_ text: String, format: TextFormat) throws -> Data {
        let converted = format.lineEnding == .lf
            ? text
            : text.replacingOccurrences(of: "\n", with: format.lineEnding.sequence)
        guard var data = converted.data(using: format.encoding, allowLossyConversion: false) else {
            throw TextFileError.unencodable
        }
        if format.hasBOM {
            data.insert(contentsOf: byteOrderMark(for: format.encoding), at: 0)
        }
        return data
    }

    /// The majority newline style; LF for files without newlines.
    public static func detectLineEnding(_ text: String) -> LineEnding {
        var lf = 0
        var crlf = 0
        var cr = 0
        var previousWasCR = false
        for byte in text.utf8 {
            if byte == 13 {
                if previousWasCR { cr += 1 }
                previousWasCR = true
            } else {
                if byte == 10 {
                    if previousWasCR { crlf += 1 } else { lf += 1 }
                } else if previousWasCR {
                    cr += 1
                }
                previousWasCR = false
            }
        }
        if previousWasCR { cr += 1 }
        if crlf > lf && crlf >= cr { return .crlf }
        if cr > lf && cr > crlf { return .cr }
        return .lf
    }

    public static func normalizeNewlines(_ text: String) -> String {
        guard text.utf8.contains(13) else { return text }
        return text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    static func byteOrderMark(for encoding: String.Encoding) -> [UInt8] {
        switch encoding {
        case .utf8: return [0xEF, 0xBB, 0xBF]
        case .utf16LittleEndian: return [0xFF, 0xFE]
        case .utf16BigEndian: return [0xFE, 0xFF]
        default: return []
        }
    }

    private static func detectLegacyEncoding(_ data: Data) -> String.Encoding {
        var converted: NSString?
        var lossy = ObjCBool(false)
        let raw = NSString.stringEncoding(
            for: data,
            encodingOptions: [
                .suggestedEncodingsKey: [
                    String.Encoding.windowsCP1252.rawValue,
                    String.Encoding.isoLatin1.rawValue,
                    String.Encoding.macOSRoman.rawValue,
                ],
                .useOnlySuggestedEncodingsKey: true,
                .allowLossyKey: false,
            ],
            convertedString: &converted,
            usedLossyConversion: &lossy
        )
        // ISO 8859-1 maps every byte, so it is the safe last resort.
        return raw == 0 ? .isoLatin1 : String.Encoding(rawValue: raw)
    }

    private static func controlCharacterRatio(_ data: Data) -> Double {
        let sample = data.prefix(sniffLength)
        guard !sample.isEmpty else { return 0 }
        let controls = sample.filter { $0 < 0x20 && $0 != 9 && $0 != 10 && $0 != 13 && $0 != 12 }.count
        return Double(controls) / Double(sample.count)
    }
}

/// Atomic writes that keep the original file's POSIX permissions and follow symlinks.
public enum SafeWriter {
    public static func write(_ data: Data, to url: URL) throws {
        let target = url.resolvingSymlinksInPath()
        let permissions = try? FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions]
        try data.write(to: target, options: .atomic)
        if let permissions {
            try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
        }
    }
}

/// Detects the indentation style of a file from its first lines.
public enum IndentDetector {
    public static func detect(_ text: String, sampleLines: Int = 2000) -> (useTabs: Bool, width: Int)? {
        var tabs = 0
        var spaces = 0
        var widths: [Int: Int] = [:]
        var previous = 0
        var count = 0
        text.enumerateLines { line, stop in
            count += 1
            if count > sampleLines { stop = true }
            guard let first = line.first, first == " " || first == "\t" else {
                if !line.isEmpty { previous = 0 }
                return
            }
            if first == "\t" {
                tabs += 1
                return
            }
            let leading = line.prefix { $0 == " " }.count
            guard leading < line.count else { return }
            spaces += 1
            let delta = abs(leading - previous)
            if delta >= 2 && delta <= 8 { widths[delta, default: 0] += 1 }
            previous = leading
        }
        if tabs == 0 && spaces == 0 { return nil }
        if tabs > spaces { return (true, 4) }
        let width = widths.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? 4
        return (false, width)
    }
}
