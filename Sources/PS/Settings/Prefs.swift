import AppKit
import PSCore

/// Localised string; the key is the English text (see Resources/it.lproj).
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), arguments: arguments)
}

enum AutoSaveMode: String, CaseIterable {
    case off
    case focus
    case interval
}

/// Preferences, persisted in UserDefaults. The SwiftUI settings view binds to the same keys.
enum Prefs {
    enum Key {
        static let codeFontName = "codeFontName"
        static let codeFontSize = "codeFontSize"
        static let tabWidth = "tabWidth"
        static let insertSpaces = "insertSpaces"
        static let wordWrap = "wordWrap"
        static let lineNumbers = "lineNumbers"
        static let lightTheme = "lightTheme"
        static let darkTheme = "darkTheme"
        static let richFontName = "richFontName"
        static let richFontSize = "richFontSize"
        static let autoSave = "autoSave"
        static let autoSaveInterval = "autoSaveInterval"
        static let showHidden = "showHidden"
    }

    static let defaults = UserDefaults.standard

    static func register() {
        defaults.register(defaults: [
            Key.codeFontName: "",
            Key.codeFontSize: 13.0,
            Key.tabWidth: 4,
            Key.insertSpaces: true,
            Key.wordWrap: false,
            Key.lineNumbers: true,
            Key.lightTheme: "Daylight",
            Key.darkTheme: "Midnight",
            Key.richFontName: "Helvetica Neue",
            Key.richFontSize: 14.0,
            Key.autoSave: AutoSaveMode.off.rawValue,
            Key.autoSaveInterval: 30,
            Key.showHidden: false,
        ])
    }

    static var codeFont: NSFont {
        let size = CGFloat(defaults.double(forKey: Key.codeFontSize))
        let name = defaults.string(forKey: Key.codeFontName) ?? ""
        return (name.isEmpty ? nil : NSFont(name: name, size: size))
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static var tabWidth: Int { max(1, defaults.integer(forKey: Key.tabWidth)) }
    static var insertSpaces: Bool { defaults.bool(forKey: Key.insertSpaces) }
    static var wordWrap: Bool { defaults.bool(forKey: Key.wordWrap) }
    static var lineNumbers: Bool { defaults.bool(forKey: Key.lineNumbers) }
    static var showHidden: Bool { defaults.bool(forKey: Key.showHidden) }
    static var autoSave: AutoSaveMode { AutoSaveMode(rawValue: defaults.string(forKey: Key.autoSave) ?? "") ?? .off }
    static var autoSaveInterval: Int { max(5, defaults.integer(forKey: Key.autoSaveInterval)) }

    static var richDefaults: RichDefaults {
        let size = CGFloat(defaults.double(forKey: Key.richFontSize))
        let name = defaults.string(forKey: Key.richFontName) ?? "Helvetica Neue"
        let font = NSFont(name: name, size: size) ?? NSFont(name: "Helvetica Neue", size: size) ?? .systemFont(ofSize: size)
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.15
        style.paragraphSpacing = size * 0.5
        return RichDefaults(font: font, paragraphStyle: style)
    }

    static func theme(for appearance: NSAppearance) -> Theme? {
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let name = defaults.string(forKey: dark ? Key.darkTheme : Key.lightTheme) ?? ""
        return ThemeStore.theme(named: name, dark: dark)
    }

    /// Everything that affects editors; used to skip work on unrelated defaults changes.
    static var signature: String {
        [Key.codeFontName, Key.codeFontSize, Key.tabWidth, Key.insertSpaces, Key.wordWrap, Key.lineNumbers,
         Key.lightTheme, Key.darkTheme, Key.richFontName, Key.richFontSize, Key.showHidden]
            .map { "\(defaults.object(forKey: $0) ?? "")" }
            .joined(separator: "|")
    }
}
