import Foundation

/// One highlighting rule: a regular expression and the theme scope it paints.
/// Patterns must not contain capturing groups: the tokenizer combines all rules of a
/// language into one alternation and identifies the rule by its group index.
public struct GrammarRule {
    public let scope: String
    public let pattern: String

    public init(_ scope: String, _ pattern: String) {
        self.scope = scope
        self.pattern = pattern
    }
}

public struct Language {
    public let id: String
    public let name: String
    public var extensions: [String] = []
    public var filenames: [String] = []
    public var shebangs: [String] = []
    public var lineComment: String?
    public var blockComment: (open: String, close: String)?
    public var pairs: [(open: Character, close: Character)] = Language.defaultPairs
    /// Regex tested on the text before the cursor: a match adds one indentation level.
    public var indentAfter: String? = #"[\[{(]\s*$"#
    public var rules: [GrammarRule] = []

    public static let defaultPairs: [(open: Character, close: Character)] = [
        ("(", ")"), ("[", "]"), ("{", "}"), ("\"", "\""), ("'", "'"),
    ]
}

/// Shared regex fragments, written as raw strings so they read like plain regex.
enum P {
    static let dq = #""(?:[^"\\\n]|\\.)*"?"#
    static let sq = #"'(?:[^'\\\n]|\\.)*'?"#
    static let cBlock = #"/\*[\s\S]*?(?:\*/|\z)"#
    static let slash = #"//.*"#
    static let hash = #"#.*"#
    static let num = #"\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d+)?)[uUlLfF]*\b"#
    static let fn = #"\b[A-Za-z_]\w*(?=\s*\()"#
    static let type = #"\b[A-Z][A-Za-z0-9_]*\b"#
    static let xmlComment = #"<!--[\s\S]*?(?:-->|\z)"#
    static let tagName = #"</?[A-Za-z][\w:.-]*"#
    static let tagEnd = #"/?>"#
    static let attr = #"\b[A-Za-z_:][\w:.-]*(?=\s*=)"#
    static let attrDq = #"(?<==)\s*"[^"]*""#
    static let attrSq = #"(?<==)\s*'[^']*'"#
    static let entity = #"&#?\w+;"#

    static func words(_ list: String) -> String {
        #"\b(?:"# + list.split(separator: " ").joined(separator: "|") + #")\b"#
    }

    static func wordsCI(_ list: String) -> String {
        #"(?i:\b(?:"# + list.split(separator: " ").joined(separator: "|") + #")\b)"#
    }
}

public enum LanguageRegistry {
    public static let plainText = Language(id: "plaintext", name: "Plain Text", pairs: [], indentAfter: nil)

    private static let jsKeywords = "break case catch class const continue debugger default delete do else export extends finally for function if import in instanceof let new of return static super switch throw try typeof var void while with yield async await from as get set"
    private static let jsConstants = "true false null undefined NaN Infinity this"
    private static let cKeywords = "auto break case const continue default do else enum extern for goto if inline register restrict return sizeof static struct switch typedef union volatile while"
    private static let cTypes = "void char short int long float double signed unsigned bool size_t ssize_t int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t FILE"

    private static func jsRules(extraKeywords: String = "", types: String = "") -> [GrammarRule] {
        var rules = [
            GrammarRule("comment", P.cBlock),
            GrammarRule("comment", P.slash),
            GrammarRule("string", #"`(?:[^`\\]|\\[\s\S])*`?"#),
            GrammarRule("string", P.dq),
            GrammarRule("string", P.sq),
            GrammarRule("constant", P.words(jsConstants)),
            GrammarRule("keyword", P.words(jsKeywords + (extraKeywords.isEmpty ? "" : " " + extraKeywords))),
        ]
        if !types.isEmpty { rules.append(GrammarRule("type", P.words(types))) }
        rules += [
            GrammarRule("type", P.type),
            GrammarRule("number", P.num),
            GrammarRule("function", P.fn),
        ]
        return rules
    }

    private static func xmlRules(html: Bool) -> [GrammarRule] {
        var rules = [GrammarRule("comment", P.xmlComment)]
        if !html {
            rules.append(GrammarRule("string", #"<!\[CDATA\[[\s\S]*?(?:\]\]>|\z)"#))
            rules.append(GrammarRule("preprocessor", #"<\?[\s\S]*?(?:\?>|\z)"#))
        }
        rules += [
            GrammarRule("keyword", #"<![^>\n]*>"#),
            GrammarRule("tag", P.tagName),
            GrammarRule("tag", P.tagEnd),
            GrammarRule("attribute", P.attr),
            GrammarRule("string", P.attrDq),
            GrammarRule("string", P.attrSq),
            GrammarRule("constant", P.entity),
        ]
        return rules
    }

    /// The registry. Adding a language = adding one entry here.
    public static let all: [Language] = [
        Language(
            id: "swift", name: "Swift", extensions: ["swift"], shebangs: ["swift"],
            lineComment: "//", blockComment: ("/*", "*/"),
            rules: [
                GrammarRule("comment", P.cBlock),
                GrammarRule("comment", P.slash),
                GrammarRule("string", #""""[\s\S]*?(?:"""|\z)"#),
                GrammarRule("string", P.dq),
                GrammarRule("attribute", #"@\w+"#),
                GrammarRule("preprocessor", #"#\w+"#),
                GrammarRule("constant", P.words("true false nil self Self super")),
                GrammarRule("keyword", P.words("associatedtype class deinit enum extension fileprivate func import init inout internal let open operator private precedencegroup protocol public rethrows static struct subscript typealias var break case catch continue default defer do else fallthrough for guard if in repeat return throw switch where while as is try throws await async actor some any nonisolated mutating override final lazy weak unowned convenience required dynamic indirect get set willSet didSet")),
                GrammarRule("type", P.type),
                GrammarRule("number", P.num),
                GrammarRule("function", P.fn),
            ]
        ),
        Language(
            id: "python", name: "Python", extensions: ["py", "pyw", "pyi"], shebangs: ["python"],
            lineComment: "#", indentAfter: #":\s*(?:#.*)?$|[\[{(]\s*$"#,
            rules: [
                GrammarRule("string", #"(?:\b[rRbBuUfF]{1,2})?"""[\s\S]*?(?:"""|\z)"#),
                GrammarRule("string", #"(?:\b[rRbBuUfF]{1,2})?'''[\s\S]*?(?:'''|\z)"#),
                GrammarRule("string", #"(?:\b[rRbBuUfF]{1,2})?"# + P.dq),
                GrammarRule("string", #"(?:\b[rRbBuUfF]{1,2})?"# + P.sq),
                GrammarRule("comment", P.hash),
                GrammarRule("attribute", #"@[\w.]+"#),
                GrammarRule("constant", P.words("True False None self cls")),
                GrammarRule("keyword", P.words("and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case")),
                GrammarRule("type", P.type),
                GrammarRule("number", P.num),
                GrammarRule("function", P.fn),
            ]
        ),
        Language(
            id: "javascript", name: "JavaScript", extensions: ["js", "mjs", "cjs", "jsx"],
            shebangs: ["node", "bun"], lineComment: "//", blockComment: ("/*", "*/"),
            pairs: Language.defaultPairs + [("`", "`")],
            rules: jsRules()
        ),
        Language(
            id: "typescript", name: "TypeScript", extensions: ["ts", "tsx", "mts", "cts"],
            shebangs: ["ts-node", "deno"], lineComment: "//", blockComment: ("/*", "*/"),
            pairs: Language.defaultPairs + [("`", "`")],
            rules: jsRules(
                extraKeywords: "interface type enum implements declare readonly abstract namespace module private protected public keyof infer is asserts satisfies override",
                types: "string number boolean any unknown never object symbol bigint"
            )
        ),
        Language(
            id: "html", name: "HTML", extensions: ["html", "htm", "xhtml"],
            blockComment: ("<!--", "-->"), pairs: [("\"", "\""), ("'", "'")],
            indentAfter: #"<(?!/|br|hr|img|input|meta|link)[A-Za-z][^>]*>\s*$"#,
            rules: xmlRules(html: true)
        ),
        Language(
            id: "css", name: "CSS", extensions: ["css", "scss", "less"],
            blockComment: ("/*", "*/"),
            rules: [
                GrammarRule("comment", P.cBlock),
                GrammarRule("string", P.dq),
                GrammarRule("string", P.sq),
                GrammarRule("keyword", #"@[\w-]+|!important"#),
                GrammarRule("number", #"#[0-9a-fA-F]{3,8}\b"#),
                GrammarRule("property", #"[\w-]+(?=\s*:[^{;\n]*[;}])"#),
                GrammarRule("type", #"[.#][A-Za-z_-][\w-]*"#),
                GrammarRule("keyword", #":{1,2}[A-Za-z-]+"#),
                GrammarRule("function", P.fn),
                GrammarRule("number", #"-?\b\d+(?:\.\d+)?(?:px|em|rem|vh|vw|vmin|vmax|s|ms|deg|fr|pt|ch|%)?"#),
            ]
        ),
        Language(
            id: "json", name: "JSON", extensions: ["json", "jsonc", "geojson", "webmanifest"],
            filenames: [".prettierrc", ".eslintrc", ".babelrc"],
            pairs: [("[", "]"), ("{", "}"), ("\"", "\"")],
            rules: [
                GrammarRule("comment", P.slash),
                GrammarRule("property", #""(?:[^"\\\n]|\\.)*"(?=\s*:)"#),
                GrammarRule("string", P.dq),
                GrammarRule("constant", P.words("true false null")),
                GrammarRule("number", #"-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#),
            ]
        ),
        Language(
            id: "markdown", name: "Markdown", extensions: ["md", "markdown", "mdown", "mkd"],
            blockComment: ("<!--", "-->"), pairs: [("(", ")"), ("[", "]"), ("`", "`")],
            indentAfter: nil,
            rules: [
                GrammarRule("string", #"(?m:^\s*```[\s\S]*?(?:^\s*```|\z))"#),
                GrammarRule("comment", P.xmlComment),
                GrammarRule("heading", #"(?m:^#{1,6}\s.*)"#),
                GrammarRule("comment", #"(?m:^\s*>.*)"#),
                GrammarRule("keyword", #"(?m:^\s*(?:[-*+]|\d+[.)])(?=\s))"#),
                GrammarRule("strong", #"\*\*(?=\S)[^\n]*?\S\*\*"#),
                GrammarRule("strong", #"__(?=\S)[^\n]*?\S__"#),
                GrammarRule("emphasis", #"\*[^\s*](?:[^*\n]*[^\s*])?\*"#),
                GrammarRule("emphasis", #"\b_[^_\n]+_\b"#),
                GrammarRule("string", #"`[^`\n]+`"#),
                GrammarRule("link", #"!?\[[^\]\n]*\]\([^)\n]*\)"#),
            ]
        ),
        Language(
            id: "c", name: "C", extensions: ["c", "h"], lineComment: "//", blockComment: ("/*", "*/"),
            rules: [
                GrammarRule("comment", P.cBlock),
                GrammarRule("comment", P.slash),
                GrammarRule("preprocessor", #"(?m:^\s*#\s*[a-z]+)"#),
                GrammarRule("string", #"(?<=include)\s*<[^>\n]*>"#),
                GrammarRule("string", P.dq),
                GrammarRule("string", P.sq),
                GrammarRule("constant", P.words("NULL true false")),
                GrammarRule("keyword", P.words(cKeywords)),
                GrammarRule("type", P.words(cTypes)),
                GrammarRule("number", P.num),
                GrammarRule("function", P.fn),
            ]
        ),
        Language(
            id: "cpp", name: "C++", extensions: ["cpp", "cc", "cxx", "hpp", "hh", "hxx", "ino"],
            lineComment: "//", blockComment: ("/*", "*/"),
            rules: [
                GrammarRule("comment", P.cBlock),
                GrammarRule("comment", P.slash),
                GrammarRule("preprocessor", #"(?m:^\s*#\s*[a-z]+)"#),
                GrammarRule("string", #"(?<=include)\s*<[^>\n]*>"#),
                GrammarRule("string", P.dq),
                GrammarRule("string", P.sq),
                GrammarRule("constant", P.words("nullptr NULL true false this")),
                GrammarRule("keyword", P.words(cKeywords + " alignas alignof and asm catch class concept consteval constexpr constinit const_cast co_await co_return co_yield decltype delete dynamic_cast explicit export friend mutable namespace new noexcept not operator or private protected public reinterpret_cast requires static_assert static_cast template thread_local throw try typeid typename using virtual xor override final")),
                GrammarRule("type", P.words(cTypes + " wchar_t char8_t char16_t char32_t std string vector map")),
                GrammarRule("type", P.type),
                GrammarRule("number", P.num),
                GrammarRule("function", P.fn),
            ]
        ),
        Language(
            id: "java", name: "Java", extensions: ["java"], lineComment: "//", blockComment: ("/*", "*/"),
            rules: [
                GrammarRule("comment", P.cBlock),
                GrammarRule("comment", P.slash),
                GrammarRule("attribute", #"@\w+"#),
                GrammarRule("string", #""""[\s\S]*?(?:"""|\z)"#),
                GrammarRule("string", P.dq),
                GrammarRule("string", P.sq),
                GrammarRule("constant", P.words("true false null this super")),
                GrammarRule("keyword", P.words("abstract assert break case catch class continue default do else enum extends final finally for if implements import instanceof interface native new package private protected public return static strictfp switch synchronized throw throws transient try volatile while var record sealed permits yield")),
                GrammarRule("type", P.words("boolean byte char double float int long short void")),
                GrammarRule("type", P.type),
                GrammarRule("number", P.num),
                GrammarRule("function", P.fn),
            ]
        ),
        Language(
            id: "go", name: "Go", extensions: ["go"], lineComment: "//", blockComment: ("/*", "*/"),
            pairs: Language.defaultPairs + [("`", "`")],
            rules: [
                GrammarRule("comment", P.cBlock),
                GrammarRule("comment", P.slash),
                GrammarRule("string", #"`[\s\S]*?(?:`|\z)"#),
                GrammarRule("string", P.dq),
                GrammarRule("string", P.sq),
                GrammarRule("constant", P.words("true false nil iota")),
                GrammarRule("keyword", P.words("break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var")),
                GrammarRule("type", P.words("bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr any")),
                GrammarRule("type", P.type),
                GrammarRule("number", P.num),
                GrammarRule("function", P.fn),
            ]
        ),
        Language(
            id: "rust", name: "Rust", extensions: ["rs"], lineComment: "//", blockComment: ("/*", "*/"),
            pairs: [("(", ")"), ("[", "]"), ("{", "}"), ("\"", "\"")],
            rules: [
                GrammarRule("comment", P.cBlock),
                GrammarRule("comment", P.slash),
                GrammarRule("attribute", #"#!?\[[^\]\n]*\]"#),
                GrammarRule("string", #""(?:[^"\\]|\\[\s\S])*"?"#),
                GrammarRule("string", #"'(?:[^'\\\n]|\\.)'"#),
                GrammarRule("variable", #"'[A-Za-z_]\w*"#),
                GrammarRule("function", #"\b[A-Za-z_]\w*!"#),
                GrammarRule("constant", P.words("true false self Some None Ok Err")),
                GrammarRule("keyword", P.words("as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref return static struct super trait type unsafe use where while")),
                GrammarRule("type", P.words("i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str")),
                GrammarRule("type", P.type),
                GrammarRule("number", P.num),
                GrammarRule("function", P.fn),
            ]
        ),
        Language(
            id: "php", name: "PHP", extensions: ["php", "phtml"], shebangs: ["php"],
            lineComment: "//", blockComment: ("/*", "*/"),
            rules: [
                GrammarRule("preprocessor", #"<\?(?:php|=)?|\?>"#),
                GrammarRule("comment", P.cBlock),
                GrammarRule("comment", P.slash),
                GrammarRule("comment", P.hash),
                GrammarRule("string", P.dq),
                GrammarRule("string", P.sq),
                GrammarRule("variable", #"\$\w+"#),
                GrammarRule("constant", P.words("true false null TRUE FALSE NULL")),
                GrammarRule("keyword", P.words("abstract and array as break callable case catch class clone const continue declare default do echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile extends final finally fn for foreach function global goto if implements include include_once instanceof insteadof interface isset list match namespace new or print private protected public readonly require require_once return static switch throw trait try unset use var while xor yield")),
                GrammarRule("type", P.type),
                GrammarRule("number", P.num),
                GrammarRule("function", P.fn),
            ]
        ),
        Language(
            id: "ruby", name: "Ruby", extensions: ["rb", "rake", "gemspec"],
            filenames: ["gemfile", "rakefile"], shebangs: ["ruby"], lineComment: "#",
            indentAfter: #"^\s*(?:def|class|module|if|unless|while|until|for|begin|case|else|elsif|when|rescue|ensure)\b|\bdo(?:\s*\|[^|]*\|)?\s*$|[\[{(]\s*$"#,
            rules: [
                GrammarRule("comment", #"(?m:^=begin[\s\S]*?(?:^=end|\z))"#),
                GrammarRule("string", P.dq),
                GrammarRule("string", P.sq),
                GrammarRule("comment", P.hash),
                GrammarRule("constant", #":[A-Za-z_]\w*[?!]?"#),
                GrammarRule("variable", #"@{1,2}\w+|\$\w+"#),
                GrammarRule("constant", P.words("true false nil self")),
                GrammarRule("keyword", P.words("BEGIN END alias and begin break case class def do else elsif end ensure for if in module next not or redo rescue retry return super then undef unless until when while yield require require_relative attr_accessor attr_reader attr_writer private protected public raise lambda proc puts")),
                GrammarRule("type", P.type),
                GrammarRule("number", P.num),
                GrammarRule("function", P.fn),
            ]
        ),
        Language(
            id: "shell", name: "Shell", extensions: ["sh", "bash", "zsh", "ksh", "fish", "command"],
            filenames: [".bashrc", ".zshrc", ".profile", ".bash_profile", ".zprofile", ".zshenv"],
            shebangs: ["sh", "bash", "zsh", "ksh", "dash", "fish"], lineComment: "#",
            indentAfter: #"\b(?:then|do|else)\s*$|[\[{(]\s*$"#,
            rules: [
                GrammarRule("variable", #"\$(?:\{[^}\n]*\}|\w+|[@#?$!*0-9-])"#),
                GrammarRule("comment", #"(?<![^\s;])#.*"#),
                GrammarRule("string", P.dq),
                GrammarRule("string", #"'[^'\n]*'?"#),
                GrammarRule("keyword", P.words("if then else elif fi case esac for select while until do done in function time return exit break continue local export readonly declare unset shift source alias set trap eval exec")),
                GrammarRule("function", P.words("echo printf read cd pwd test")),
                GrammarRule("number", #"\b\d+\b"#),
                GrammarRule("function", P.fn),
            ]
        ),
        Language(
            id: "sql", name: "SQL", extensions: ["sql", "psql", "mysql"],
            lineComment: "--", blockComment: ("/*", "*/"),
            pairs: [("(", ")"), ("\"", "\""), ("'", "'")],
            indentAfter: #"\(\s*$"#,
            rules: [
                GrammarRule("comment", #"--.*"#),
                GrammarRule("comment", P.cBlock),
                GrammarRule("string", #"'(?:[^']|'')*'?"#),
                GrammarRule("variable", #""[^"\n]*"|`[^`\n]*`"#),
                GrammarRule("constant", P.wordsCI("null true false")),
                GrammarRule("keyword", P.wordsCI("select from where and or not insert into values update set delete create alter drop table view index trigger function procedure database schema primary key foreign references unique default check constraint join inner left right full outer cross on as group by order having limit offset distinct union all exists in between like ilike is case when then else end begin commit rollback transaction with returning if replace grant revoke asc desc cascade")),
                GrammarRule("type", P.wordsCI("int integer smallint bigint serial bigserial decimal numeric real float double precision char varchar text boolean bool date time timestamp timestamptz interval uuid json jsonb blob bytea")),
                GrammarRule("number", P.num),
                GrammarRule("function", P.fn),
            ]
        ),
        Language(
            id: "yaml", name: "YAML", extensions: ["yaml", "yml"], lineComment: "#",
            pairs: [("[", "]"), ("{", "}"), ("\"", "\""), ("'", "'")],
            indentAfter: #":\s*$"#,
            rules: [
                GrammarRule("comment", #"(?<![^\s])#.*"#),
                GrammarRule("keyword", #"(?m:^(?:---|\.\.\.)\s*$)"#),
                GrammarRule("string", P.dq),
                GrammarRule("string", P.sq),
                GrammarRule("property", #"[\w./-]+(?=\s*:(?:\s|$))"#),
                GrammarRule("variable", #"[&*][\w-]+"#),
                GrammarRule("type", #"!!?\w+"#),
                GrammarRule("constant", P.words("true false yes no on off null True False Null TRUE FALSE NULL")),
                GrammarRule("keyword", #"(?m:^\s*-(?=\s))"#),
                GrammarRule("number", P.num),
            ]
        ),
        Language(
            id: "xml", name: "XML",
            extensions: ["xml", "plist", "svg", "xsd", "xsl", "xslt", "csproj", "storyboard", "xib"],
            blockComment: ("<!--", "-->"), pairs: [("\"", "\""), ("'", "'")],
            indentAfter: #"<(?![/?!])[^>]*[^/]>\s*$"#,
            rules: xmlRules(html: false)
        ),
        plainText,
    ]

    public static func language(id: String) -> Language? {
        all.first { $0.id == id }
    }

    /// Deduces the language from the file name, then from the first line (shebang, XML prolog).
    public static func detect(fileName: String, firstLine: String?) -> Language {
        let lower = fileName.lowercased()
        if let match = all.first(where: { $0.filenames.contains(lower) }) { return match }

        let ext = (lower as NSString).pathExtension
        if !ext.isEmpty, let match = all.first(where: { $0.extensions.contains(ext) }) { return match }

        guard let line = firstLine else { return plainText }
        if line.hasPrefix("#!"), let interpreter = shebangInterpreter(line) {
            if let match = all.first(where: { $0.shebangs.contains(interpreter) }) { return match }
        }
        if line.hasPrefix("<?xml") { return language(id: "xml") ?? plainText }
        if line.lowercased().hasPrefix("<!doctype html") { return language(id: "html") ?? plainText }
        return plainText
    }

    /// "#!/usr/bin/env -S python3 -u" -> "python"
    static func shebangInterpreter(_ line: String) -> String? {
        let parts = line.dropFirst(2).split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let first = parts.first else { return nil }
        var name = String(first.split(separator: "/").last ?? first)
        if name == "env" {
            guard let arg = parts.dropFirst().first(where: { !$0.hasPrefix("-") }) else { return nil }
            name = String(arg)
        }
        while let last = name.last, last.isNumber || last == "." { name.removeLast() }
        return name.isEmpty ? nil : name
    }
}
