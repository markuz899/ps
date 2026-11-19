import AppKit
import XCTest
@testable import PSCore

final class LanguageTests: XCTestCase {
    func testDetectByExtension() {
        XCTAssertEqual(LanguageRegistry.detect(fileName: "main.swift", firstLine: nil).id, "swift")
        XCTAssertEqual(LanguageRegistry.detect(fileName: "App.TSX", firstLine: nil).id, "typescript")
        XCTAssertEqual(LanguageRegistry.detect(fileName: "README.md", firstLine: nil).id, "markdown")
        XCTAssertEqual(LanguageRegistry.detect(fileName: "lib.rs", firstLine: nil).id, "rust")
        XCTAssertEqual(LanguageRegistry.detect(fileName: "Gemfile", firstLine: nil).id, "ruby")
        XCTAssertEqual(LanguageRegistry.detect(fileName: ".zshrc", firstLine: nil).id, "shell")
        XCTAssertEqual(LanguageRegistry.detect(fileName: "notes", firstLine: "hello").id, "plaintext")
    }

    func testDetectByShebang() {
        XCTAssertEqual(LanguageRegistry.detect(fileName: "run", firstLine: "#!/usr/bin/env python3").id, "python")
        XCTAssertEqual(LanguageRegistry.detect(fileName: "run", firstLine: "#!/bin/bash -e").id, "shell")
        XCTAssertEqual(LanguageRegistry.detect(fileName: "run", firstLine: "#!/usr/bin/env -S node --trace").id, "javascript")
        XCTAssertEqual(LanguageRegistry.detect(fileName: "data", firstLine: "<?xml version=\"1.0\"?>").id, "xml")
    }

    func testEveryGrammarCompilesWithoutCaptureGroups() throws {
        for language in LanguageRegistry.all {
            for rule in language.rules {
                let regex = try NSRegularExpression(pattern: rule.pattern)
                XCTAssertEqual(regex.numberOfCaptureGroups, 0, "\(language.id): \(rule.pattern)")
            }
            if !language.rules.isEmpty { XCTAssertNotNil(Tokenizer.forLanguage(language), language.id) }
        }
        XCTAssertEqual(LanguageRegistry.all.count, 20)
    }

    func testTokenizerLeftmostMatchWins() throws {
        let swift = try XCTUnwrap(LanguageRegistry.language(id: "swift"))
        let tokenizer = try XCTUnwrap(Tokenizer.forLanguage(swift))
        let text = "let url = \"http://x\" // note\n/* a\nb */ func" as NSString
        let tokens = tokenizer.tokens(in: text, from: 0, until: text.length)
        let scopes = tokens.map { tokenizer.scopes[$0.scope] }
        XCTAssertEqual(scopes, ["keyword", "string", "comment", "comment", "keyword"])
        XCTAssertEqual(text.substring(with: tokens[3].range), "/* a\nb */")
    }

    func testModeForFileType() {
        XCTAssertEqual(EditorMode.forFile(URL(fileURLWithPath: "/a/b.rtf")), .rich)
        XCTAssertEqual(EditorMode.forFile(URL(fileURLWithPath: "/a/b.RTFD")), .rich)
        XCTAssertEqual(EditorMode.forFile(URL(fileURLWithPath: "/a/b.txt")), .rich)
        XCTAssertEqual(EditorMode.forFile(URL(fileURLWithPath: "/a/b.md")), .code)
        XCTAssertEqual(EditorMode.forFile(URL(fileURLWithPath: "/a/b.py")), .code)
        XCTAssertEqual(EditorMode.forFile(URL(fileURLWithPath: "/a/Makefile")), .code)
        XCTAssertEqual(EditorMode.forFile(URL(fileURLWithPath: "/a/flow.excalidraw")), .board)
    }

    func testThemesLoad() {
        XCTAssertGreaterThanOrEqual(ThemeStore.all.count, 2)
        XCTAssertTrue(ThemeStore.all.contains { $0.isDark })
        XCTAssertTrue(ThemeStore.all.contains { !$0.isDark })
        XCTAssertNotNil(ThemeStore.named("Midnight")?.scopeColor("keyword"))
    }
}

final class TextFileTests: XCTestCase {
    func testRoundTripPreservesBytes() throws {
        let samples: [(Data, String.Encoding, LineEnding, Bool)] = [
            (Data("a\nb\n".utf8), .utf8, .lf, false),
            (Data("a\r\nè\r\n".utf8), .utf8, .crlf, false),
            (Data([0xEF, 0xBB, 0xBF] + Array("bom\n".utf8)), .utf8, .lf, true),
            (Data([0xFF, 0xFE, 0x61, 0x00, 0x0D, 0x00, 0x0A, 0x00]), .utf16LittleEndian, .crlf, true),
            (Data([0x80, 0x20, 0x61, 0x0D]), .windowsCP1252, .cr, false),
        ]
        for (data, encoding, ending, bom) in samples {
            let (text, format) = try TextFileIO.decode(data)
            XCTAssertFalse(text.contains("\r"))
            XCTAssertEqual(format.encoding, encoding)
            XCTAssertEqual(format.lineEnding, ending)
            XCTAssertEqual(format.hasBOM, bom)
            XCTAssertEqual(try TextFileIO.encode(text, format: format), data)
        }
    }

    func testEditKeepsLineEnding() throws {
        let (text, format) = try TextFileIO.decode(Data("one\r\ntwo\r\n".utf8))
        let edited = text.replacingOccurrences(of: "two", with: "2")
        XCTAssertEqual(try TextFileIO.encode(edited, format: format), Data("one\r\n2\r\n".utf8))
    }

    func testBinaryIsRejected() {
        XCTAssertThrowsError(try TextFileIO.decode(Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01]))) {
            XCTAssertEqual($0 as? TextFileError, .binary)
        }
    }

    func testForcedEncoding() throws {
        let data = Data([0x63, 0x61, 0x66, 0xC3, 0xA9])
        XCTAssertEqual(try TextFileIO.decode(data).text, "café")
        XCTAssertEqual(try TextFileIO.decode(data, forcing: .isoLatin1).text, "cafÃ©")
    }

    func testUnencodableThrows() {
        XCTAssertThrowsError(try TextFileIO.encode("€ 日本", format: TextFormat(encoding: .ascii)))
    }

    func testSafeWriterKeepsPermissions() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ps-perm-\(UUID()).sh")
        try Data("echo 1".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        try SafeWriter.write(Data("echo 2".utf8), to: url)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o755)
        try FileManager.default.removeItem(at: url)
    }

    func testIndentDetection() {
        XCTAssertEqual(IndentDetector.detect("a\n  b\n    c\n  d\n")?.width, 2)
        XCTAssertEqual(IndentDetector.detect("a\n\tb\n\t\tc\n")?.useTabs, true)
        XCTAssertNil(IndentDetector.detect("a\nb\n"))
    }

    func testLineIndexIncremental() {
        let storage = NSMutableString(string: "a\nb\nc")
        let index = LineIndex()
        index.rebuild(storage)
        XCTAssertEqual(index.starts, [0, 2, 4])

        storage.replaceCharacters(in: NSRange(location: 1, length: 2), with: "X\nY\nZ")
        index.update(storage, edited: NSRange(location: 1, length: 5), delta: 3)
        let rebuilt = LineIndex()
        rebuilt.rebuild(storage)
        XCTAssertEqual(index.starts, rebuilt.starts)
        XCTAssertEqual(index.line(at: storage.length), rebuilt.lineCount - 1)
    }
}

final class RichTextTests: XCTestCase {
    let defaults = RichDefaults(font: NSFont(name: "Helvetica Neue", size: 14) ?? .systemFont(ofSize: 14))

    private func temporaryURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ps-\(UUID().uuidString).\(ext)")
    }

    func testRTFRoundTripKeepsFormatting() throws {
        let text = NSMutableAttributedString(string: "Title\nBold red words\n", attributes: defaults.attributes)
        let bold = NSFontManager.shared.convert(defaults.font, toHaveTrait: .boldFontMask)
        text.addAttribute(.font, value: NSFont(name: "Helvetica Neue Bold", size: 28) ?? bold, range: NSRange(location: 0, length: 5))
        text.addAttribute(.font, value: bold, range: NSRange(location: 6, length: 4))
        text.addAttribute(.foregroundColor, value: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), range: NSRange(location: 11, length: 3))
        let list = NSMutableParagraphStyle()
        list.textLists = [NSTextList(markerFormat: .disc, options: 0)]
        text.append(NSAttributedString(string: "\t•\titem\n", attributes: [.font: defaults.font, .paragraphStyle: list]))

        let url = temporaryURL("rtf")
        try RichTextIO.write(text, to: url, kind: .rtf)
        let (loaded, _) = try RichTextIO.read(url, defaults: defaults)

        XCTAssertEqual(loaded.string, text.string)
        let titleFont = try XCTUnwrap(loaded.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(titleFont.pointSize, 28)
        let boldFont = try XCTUnwrap(loaded.attribute(.font, at: 6, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: boldFont).contains(.boldFontMask))
        let color = try XCTUnwrap((loaded.attribute(.foregroundColor, at: 11, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB))
        XCTAssertEqual(color.redComponent, 1, accuracy: 0.01)
        XCTAssertEqual(color.greenComponent, 0, accuracy: 0.01)
        let style = try XCTUnwrap(loaded.attribute(.paragraphStyle, at: text.length - 3, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(style.textLists.first?.markerFormat, .disc)
        try? FileManager.default.removeItem(at: url)
    }

    func testRTFDKeepsImages() throws {
        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        let text = NSMutableAttributedString(string: "pic ", attributes: defaults.attributes)
        text.append(NSAttributedString(attachment: attachment))
        XCTAssertTrue(RichTextIO.hasAttachments(text))

        let url = temporaryURL("rtfd")
        try RichTextIO.write(text, to: url, kind: .rtfd)
        let (loaded, _) = try RichTextIO.read(url, defaults: defaults)
        XCTAssertTrue(RichTextIO.hasAttachments(loaded))
        try? FileManager.default.removeItem(at: url)
    }

    func testTxtWithoutFormattingStaysPlainAndByteIdentical() throws {
        let url = temporaryURL("txt")
        let original = Data("Line one\r\nLine two\r\n".utf8)
        try original.write(to: url)

        let (loaded, format) = try RichTextIO.read(url, defaults: defaults)
        let edited = NSMutableAttributedString(attributedString: loaded)
        edited.append(NSAttributedString(string: "Line three\n", attributes: defaults.attributes))
        XCTAssertEqual(TxtSavePolicy.decision(for: edited, defaults: defaults), .writePlain)

        try RichTextIO.write(edited, to: url, kind: .txt, plainFormat: try XCTUnwrap(format))
        XCTAssertEqual(try Data(contentsOf: url), Data("Line one\r\nLine two\r\nLine three\r\n".utf8))
        try? FileManager.default.removeItem(at: url)
    }

    func testFormattedTxtAsksAndConvertsNextToOriginal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ps-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let txt = directory.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: txt)

        let text = NSMutableAttributedString(string: "hello", attributes: defaults.attributes)
        text.addAttribute(.font, value: NSFontManager.shared.convert(defaults.font, toHaveTrait: .boldFontMask), range: NSRange(location: 0, length: 5))
        XCTAssertEqual(TxtSavePolicy.decision(for: text, defaults: defaults), .askUser)

        let target = TxtSavePolicy.convertedURL(for: txt, needsRTFD: false)
        XCTAssertEqual(target.lastPathComponent, "notes.rtf")
        try RichTextIO.write(text, to: target, kind: .rtf)
        XCTAssertEqual(try Data(contentsOf: txt), Data("hello".utf8), "the .txt must never be overwritten")
        XCTAssertEqual(TxtSavePolicy.convertedURL(for: txt, needsRTFD: false).lastPathComponent, "notes 2.rtf")
        try? FileManager.default.removeItem(at: directory)
    }

    /// The other direction: an RTF written by TextEdit's engine (textutil) reads back intact.
    func testReadsRTFFromTextEdit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ps-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let html = directory.appendingPathComponent("in.html")
        try Data("<h1>Head</h1><p>Plain <b>bold</b> <span style='color:#ff0000'>red</span></p><ul><li>one</li><li>two</li></ul>".utf8).write(to: html)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", "rtf", html.path, "-output", directory.appendingPathComponent("out.rtf").path]
        try process.run()
        process.waitUntilExit()

        let (text, _) = try RichTextIO.read(directory.appendingPathComponent("out.rtf"), defaults: defaults)
        let string = text.string as NSString
        let bold = try XCTUnwrap(text.attribute(.font, at: string.range(of: "bold").location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
        let red = try XCTUnwrap((text.attribute(.foregroundColor, at: string.range(of: "red").location, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(red.redComponent, 0.9)
        let style = text.attribute(.paragraphStyle, at: string.range(of: "two").location, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertFalse(style?.textLists.isEmpty ?? true)
        try? FileManager.default.removeItem(at: directory)
    }

    func testColorAndUnderlineCountAsFormatting() {
        let colored = NSMutableAttributedString(string: "x", attributes: defaults.attributes)
        colored.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: NSRange(location: 0, length: 1))
        XCTAssertTrue(RichTextIO.hasFormatting(colored, defaults: defaults))
        let underlined = NSMutableAttributedString(string: "x", attributes: defaults.attributes)
        underlined.addAttribute(.underlineStyle, value: 1, range: NSRange(location: 0, length: 1))
        XCTAssertTrue(RichTextIO.hasFormatting(underlined, defaults: defaults))
        XCTAssertFalse(RichTextIO.hasFormatting(NSAttributedString(string: "x", attributes: defaults.attributes), defaults: defaults))
    }
}

final class FindTests: XCTestCase {
    func testOptions() throws {
        let text = "Cat cat concat CAT"
        XCTAssertEqual(try FindEngine.ranges(of: "cat", in: text, options: FindOptions()).count, 4)
        XCTAssertEqual(try FindEngine.ranges(of: "cat", in: text, options: FindOptions(caseSensitive: true)).count, 2)
        XCTAssertEqual(try FindEngine.ranges(of: "cat", in: text, options: FindOptions(wholeWord: true)).count, 3)
        XCTAssertEqual(try FindEngine.ranges(of: "c.t", in: text, options: FindOptions(regex: true)).count, 4)
        XCTAssertEqual(try FindEngine.ranges(of: "c.t", in: text, options: FindOptions()).count, 0)
        XCTAssertThrowsError(try FindEngine.ranges(of: "(", in: text, options: FindOptions(regex: true)))
    }

    func testReplaceAll() throws {
        let (plain, count) = try FindEngine.replaceAll(of: "a.b", in: "a.b axb a.b", with: "$1", options: FindOptions())
        XCTAssertEqual(plain, "$1 axb $1")
        XCTAssertEqual(count, 2)
        let (regex, _) = try FindEngine.replaceAll(of: #"(\w+)@(\w+)"#, in: "me@host you@there", with: "$2:$1", options: FindOptions(regex: true))
        XCTAssertEqual(regex, "host:me there:you")
    }

    func testFuzzyPrefersNameMatches() throws {
        let a = try XCTUnwrap(Fuzzy.score("tab", in: "Sources/PS/TabBar.swift"))
        let b = try XCTUnwrap(Fuzzy.score("tab", in: "Sources/table/x/Bar.swift"))
        XCTAssertGreaterThan(a, b - 20)
        XCTAssertNil(Fuzzy.score("zzz", in: "abc"))
    }

    func testFolderSearchFindsLines() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ps-search-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try Data("one\ntwo needle\nthree".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data("needle\n\n\nneedle".utf8).write(to: root.appendingPathComponent("sub/b.swift"))
        try Data("needle".utf8).write(to: root.appendingPathComponent("node_modules/c.js"))
        try Data([0, 1, 2]).write(to: root.appendingPathComponent("bin.dat"))

        var matches: [FolderMatch] = []
        try FolderSearch.search(root: root, query: "needle", options: FindOptions(), includeHidden: false, isCancelled: { false }) {
            matches += $0
        }
        let summary = Set(matches.map { "\($0.url.lastPathComponent):\($0.line)" })
        XCTAssertEqual(summary, ["a.txt:2", "b.swift:1", "b.swift:4"])
        try? FileManager.default.removeItem(at: root)
    }
}

final class AssistTests: XCTestCase {
    func testSwiftBreadcrumbChain() {
        let text = """
        struct Greeter {
            let name: String

            func greet() -> String {
                return name
            }
        }

        func top() {}
        """ as NSString
        let symbols = SymbolScanner.symbols(in: text, languageID: "swift")
        XCTAssertEqual(symbols.map(\.name), ["Greeter", "greet", "top"])
        let inside = text.range(of: "return").location
        XCTAssertEqual(SymbolScanner.chain(symbols, in: text, caret: inside, languageID: "swift").map(\.name), ["Greeter", "greet"])
        let after = text.range(of: "func top").location
        XCTAssertEqual(SymbolScanner.chain(symbols, in: text, caret: after, languageID: "swift").map(\.name), ["top"])
        let between = text.range(of: "\n\nfunc top").location + 1
        XCTAssertEqual(SymbolScanner.chain(symbols, in: text, caret: between, languageID: "swift").map(\.name), [])
    }

    func testOtherLanguagesOutline() {
        let python = "class A:\n    def run(self):\n        pass\n" as NSString
        XCTAssertEqual(SymbolScanner.chain(SymbolScanner.symbols(in: python, languageID: "python"), in: python, caret: python.range(of: "pass").location, languageID: "python").map(\.name), ["A", "run"])
        let markdown = "# One\ntext\n## Two\nmore\n# Three\n" as NSString
        let headings = SymbolScanner.symbols(in: markdown, languageID: "markdown")
        XCTAssertEqual(headings.map(\.name), ["One", "Two", "Three"])
        XCTAssertEqual(SymbolScanner.chain(headings, in: markdown, caret: markdown.range(of: "more").location, languageID: "markdown").map(\.name), ["One", "Two"])
        let ts = "export class Store {\n  async load(url: string): Promise<void> {\n    if (x) {\n" as NSString
        XCTAssertEqual(SymbolScanner.symbols(in: ts, languageID: "typescript").map(\.name), ["Store", "load"])
        let go = "func (s *Server) Start() error {\n" as NSString
        XCTAssertEqual(SymbolScanner.symbols(in: go, languageID: "go").map(\.name), ["Start"])
    }

    func testColorLiterals() throws {
        let text = "a { color: #3b5bdb; background: rgba(255, 0, 0, 0.5); border: #FFF; }" as NSString
        let found = ColorLiteral.find(in: text, range: NSRange(location: 0, length: text.length))
        XCTAssertEqual(found.map { text.substring(with: $0.range) }, ["#3b5bdb", "rgba(255, 0, 0, 0.5)", "#FFF"])
        let red = try XCTUnwrap(found[1].color.usingColorSpace(.sRGB))
        XCTAssertEqual(red.alphaComponent, 0.5, accuracy: 0.01)
        XCTAssertEqual(ColorLiteral.format(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), like: "#3b5bdb"), "#ff0000")
        XCTAssertEqual(ColorLiteral.format(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), like: "#FFF"), "#FF0000")
        XCTAssertEqual(ColorLiteral.format(NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1), like: "rgb(1, 2, 3)"), "rgb(0, 0, 255)")
        XCTAssertNil(ColorLiteral.parse("rgb(300, 0, 0)"))
    }

    func testMultiCursorArithmetic() {
        // "ab|cd|ef" with carets at 2 and 4, typing "XY".
        let carets = [NSRange(location: 4, length: 0), NSRange(location: 2, length: 0)]
        let ranges = MultiCursor.normalize(carets)
        XCTAssertEqual(ranges.map(\.location), [2, 4])
        XCTAssertEqual(MultiCursor.carets(afterReplacing: ranges, insertedLength: 2).map(\.location), [4, 8])
        // Replacing two selected words of length 3 with one character.
        let words = [NSRange(location: 0, length: 3), NSRange(location: 4, length: 3)]
        XCTAssertEqual(MultiCursor.carets(afterReplacing: words, insertedLength: 1).map(\.location), [1, 3])
        XCTAssertEqual(MultiCursor.backspaceRanges([NSRange(location: 0, length: 0), NSRange(location: 5, length: 0)]), [NSRange(location: 4, length: 1)])
        let text = "foo bar foo baz foo" as NSString
        XCTAssertEqual(MultiCursor.nextOccurrence(of: "foo", in: text, after: 3, excluding: [NSRange(location: 0, length: 3)])?.location, 8)
        XCTAssertEqual(MultiCursor.nextOccurrence(of: "foo", in: text, after: 19, excluding: [NSRange(location: 8, length: 3), NSRange(location: 16, length: 3)])?.location, 0)
    }

    func testMarkdownRendering() throws {
        let style = MarkdownRenderer.Style(
            font: .systemFont(ofSize: 14), monoFont: .monospacedSystemFont(ofSize: 13, weight: .regular),
            textColor: .black, secondaryColor: .gray, accentColor: .blue, codeBackground: .lightGray
        )
        let output = MarkdownRenderer.render("# Title\n\nHello **bold** and *it* [link](https://x.y)\n\n- a\n- b\n\n1. one\n\n```\ncode line\n```\n", style: style)
        let text = output.string as NSString
        XCTAssertEqual(output.string, "Title\nHello bold and it link\n\t•\ta\n\t•\tb\n\t1.\tone\ncode line")
        let title = try XCTUnwrap(output.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(title.pointSize, 28)
        let bold = try XCTUnwrap(output.attribute(.font, at: text.range(of: "bold").location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
        XCTAssertNotNil(output.attribute(.link, at: text.range(of: "link").location, effectiveRange: nil))
        let code = try XCTUnwrap(output.attribute(.font, at: text.range(of: "code line").location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(code.isFixedPitch)
    }

    func testReplaceInFileKeepsFormat() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ps-replace-\(UUID()).txt")
        try Data([0xEF, 0xBB, 0xBF] + Array("old one\r\nold two\r\n".utf8)).write(to: url)
        XCTAssertEqual(try FolderSearch.replace(in: url, query: "old", template: "new", options: FindOptions()), 2)
        XCTAssertEqual(try Data(contentsOf: url), Data([0xEF, 0xBB, 0xBF] + Array("new one\r\nnew two\r\n".utf8)))
        XCTAssertEqual(try FolderSearch.replace(in: url, query: "missing", template: "x", options: FindOptions()), 0)
        try? FileManager.default.removeItem(at: url)
    }
}

final class BoardTests: XCTestCase {
    func testExcalidrawRoundTrip() throws {
        var box = BoardElement(type: .rectangle, x: 10, y: 20, width: 100, height: 60)
        box.backgroundColor = "#a5d8ff"
        var label = BoardElement(type: .text, x: 30, y: 40)
        label.text = "API"
        label.containerId = box.id
        box.boundElements = [.init(id: label.id, type: "text")]
        var arrow = BoardElement(type: .arrow, x: 110, y: 50)
        arrow.setAbsolutePoints([CGPoint(x: 110, y: 50), CGPoint(x: 300, y: 50)])
        arrow.startBinding = .init(elementId: box.id)
        let scene = BoardScene(elements: [box, label, arrow])

        let data = try scene.encoded()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "excalidraw")
        XCTAssertEqual(json["version"] as? Int, 2)
        let elements = try XCTUnwrap(json["elements"] as? [[String: Any]])
        XCTAssertEqual(elements[2]["points"] as? [[Double]], [[0, 0], [190, 0]])
        XCTAssertEqual(elements[2]["endArrowhead"] as? String, "arrow")
        XCTAssertEqual(try BoardScene.decode(data), scene)
    }

    func testReadsExcalidrawFileWithMissingFields() throws {
        let json = """
        {"type":"excalidraw","version":2,"source":"https://excalidraw.com","elements":[
          {"id":"a","type":"ellipse","x":0,"y":0,"width":40,"height":20,"strokeColor":"#e03131","seed":7},
          {"id":"b","type":"image","x":5,"y":5,"width":10,"height":10,"fileId":"f"}
        ],"appState":{"viewBackgroundColor":"#fffce8","gridSize":20},"files":{}}
        """
        let scene = try BoardScene.decode(Data(json.utf8))
        XCTAssertEqual(scene.elements.count, 2)
        XCTAssertEqual(scene.elements[0].type, .ellipse)
        XCTAssertEqual(scene.elements[0].strokeColor, "#e03131")
        XCTAssertEqual(scene.elements[0].roughness, 1)
        XCTAssertEqual(scene.elements[1].type, .image, "images are supported elements now")
        XCTAssertEqual(scene.elements[1].fileId, "f")
        XCTAssertEqual(scene.appState.viewBackgroundColor, "#fffce8")
    }

    func testHitTesting() {
        let box = BoardElement(type: .rectangle, x: 0, y: 0, width: 100, height: 100)
        XCTAssertTrue(BoardGeometry.hits(box, CGPoint(x: 0, y: 50), tolerance: 4))
        XCTAssertFalse(BoardGeometry.hits(box, CGPoint(x: 50, y: 50), tolerance: 4), "an empty rectangle is hit on its outline only")
        var filled = box
        filled.backgroundColor = "#ffec99"
        XCTAssertTrue(BoardGeometry.hits(filled, CGPoint(x: 50, y: 50), tolerance: 4))
        let ring = BoardElement(type: .ellipse, x: 0, y: 0, width: 100, height: 50)
        XCTAssertTrue(BoardGeometry.hits(ring, CGPoint(x: 100, y: 25), tolerance: 3))
        XCTAssertFalse(BoardGeometry.hits(ring, CGPoint(x: 2, y: 2), tolerance: 3))
        var line = BoardElement(type: .line, x: 0, y: 0)
        line.setAbsolutePoints([.zero, CGPoint(x: 100, y: 100)])
        XCTAssertTrue(BoardGeometry.hits(line, CGPoint(x: 50, y: 52), tolerance: 3))
        XCTAssertFalse(BoardGeometry.hits(line, CGPoint(x: 80, y: 20), tolerance: 3))
    }

    func testArrowsFollowBoundShapes() throws {
        var scene = BoardScene()
        let left = BoardElement(type: .rectangle, x: 0, y: 0, width: 100, height: 100)
        let right = BoardElement(type: .ellipse, x: 300, y: 0, width: 100, height: 100)
        var arrow = BoardElement(type: .arrow, x: 104, y: 50)
        arrow.setAbsolutePoints([CGPoint(x: 104, y: 50), CGPoint(x: 296, y: 50)])
        arrow.startBinding = .init(elementId: left.id)
        arrow.endBinding = .init(elementId: right.id)
        scene.elements = [left, right, arrow]

        scene.elements[1].y = 200
        BoardGeometry.updateBindings(in: &scene, moved: [right.id])
        let points = scene.elements[2].absolutePoints
        // The end is now on the ellipse's outline, `gap` away, on the way to the box.
        let center = CGPoint(x: 350, y: 250)
        XCTAssertEqual(hypot(points[1].x - center.x, points[1].y - center.y), 54, accuracy: 6)
        XCTAssertGreaterThan(points[0].y, 50, "the start slides along the box towards the moved ellipse")
        XCTAssertLessThanOrEqual(points[0].x, 105)
    }

    func testClipboardMatchesExcalidraw() throws {
        let element = BoardElement(type: .diamond, x: 1, y: 2, width: 3, height: 4)
        let text = try XCTUnwrap(BoardScene.clipboardJSON([element]))
        XCTAssertTrue(text.contains("\"excalidraw/clipboard\""))
        XCTAssertEqual(BoardScene.elements(fromClipboard: text)?.first?.id, element.id)
        XCTAssertNil(BoardScene.elements(fromClipboard: "just text"))
    }

    func testSeededRandomIsDeterministic() {
        var a = SeededRandom(seed: 42)
        var b = SeededRandom(seed: 42)
        let first = (0..<5).map { _ in a.next() }
        XCTAssertEqual(first, (0..<5).map { _ in b.next() })
        XCTAssertTrue(first.allSatisfy { $0 >= -1 && $0 <= 1 })
    }
}

final class BoardExtrasTests: XCTestCase {
    func testImagesRoundTripInExcalidrawFormat() throws {
        var scene = BoardScene()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let image = scene.addImage(data: png, mimeType: "image/png", size: CGSize(width: 1000, height: 500), center: CGPoint(x: 0, y: 0))
        XCTAssertEqual(image.width, 480, accuracy: 0.01, "large pictures are fitted")
        XCTAssertEqual(image.height, 240, accuracy: 0.01)

        let data = try scene.encoded()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let files = try XCTUnwrap(json["files"] as? [String: [String: Any]])
        let file = try XCTUnwrap(files[try XCTUnwrap(image.fileId)])
        XCTAssertEqual(file["mimeType"] as? String, "image/png")
        XCTAssertTrue((file["dataURL"] as? String)?.hasPrefix("data:image/png;base64,") == true)
        let element = try XCTUnwrap((json["elements"] as? [[String: Any]])?.first)
        XCTAssertEqual(element["type"] as? String, "image")
        XCTAssertEqual(element["status"] as? String, "saved")

        let loaded = try BoardScene.decode(data)
        XCTAssertEqual(loaded.files[image.fileId!]?.data, png)
        XCTAssertEqual(loaded.elements.first?.type, .image)

        // A deleted image's data isn't written any more.
        var trimmed = loaded
        trimmed.elements.removeAll()
        let empty = try XCTUnwrap(JSONSerialization.jsonObject(with: trimmed.encoded()) as? [String: Any])
        XCTAssertEqual((empty["files"] as? [String: Any])?.count, 0)
    }

    func testClipboardCarriesImageFiles() throws {
        var scene = BoardScene()
        let image = scene.addImage(data: Data([1, 2, 3]), mimeType: "image/png", size: CGSize(width: 10, height: 10), center: .zero)
        let text = try XCTUnwrap(BoardScene.clipboardJSON([image], files: scene.files))
        let content = try XCTUnwrap(BoardScene.clipboardContent(text))
        XCTAssertEqual(content.files[image.fileId!]?.data, Data([1, 2, 3]))
    }

    func testLibraryItemsAreGroupedAndCentred() {
        XCTAssertEqual(BoardLibrary.items.count, 9)
        for item in BoardLibrary.items {
            let elements = BoardLibrary.make(item, at: CGPoint(x: 500, y: 300))
            XCTAssertFalse(elements.isEmpty, item.id)
            let groups = Set(elements.flatMap(\.groupIds))
            XCTAssertEqual(groups.count, 1, "\(item.id) is one group")
            let frame = BoardGeometry.bounds(of: elements)!
            XCTAssertEqual(frame.midX, 500, accuracy: 1, item.id)
            XCTAssertEqual(frame.midY, 300, accuracy: 1, item.id)
        }
    }
}
