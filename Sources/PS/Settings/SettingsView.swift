import AppKit
import PSCore
import SwiftUI

/// SwiftUI is used only here: settings are a secondary surface, loaded on first open,
/// and @AppStorage binds straight to the same UserDefaults keys the editors read.
enum SettingsHost {
    static func make() -> NSViewController {
        let host = NSHostingController(rootView: SettingsView())
        host.preferredContentSize = NSSize(width: 520, height: 360)
        return host
    }
}

struct SettingsView: View {
    @AppStorage(Prefs.Key.codeFontName) private var codeFontName = ""
    @AppStorage(Prefs.Key.codeFontSize) private var codeFontSize = 13.0
    @AppStorage(Prefs.Key.tabWidth) private var tabWidth = 4
    @AppStorage(Prefs.Key.insertSpaces) private var insertSpaces = true
    @AppStorage(Prefs.Key.wordWrap) private var wordWrap = false
    @AppStorage(Prefs.Key.lineNumbers) private var lineNumbers = true
    @AppStorage(Prefs.Key.lightTheme) private var lightTheme = "Daylight"
    @AppStorage(Prefs.Key.darkTheme) private var darkTheme = "Midnight"
    @AppStorage(Prefs.Key.richFontName) private var richFontName = "Helvetica Neue"
    @AppStorage(Prefs.Key.richFontSize) private var richFontSize = 14.0
    @AppStorage(Prefs.Key.autoSave) private var autoSave = AutoSaveMode.off.rawValue
    @AppStorage(Prefs.Key.autoSaveInterval) private var autoSaveInterval = 30
    @AppStorage(Prefs.Key.showHidden) private var showHidden = false

    private let monospaced = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
    private let families = NSFontManager.shared.availableFontFamilies

    var body: some View {
        TabView {
            Form {
                Picker(L("Font"), selection: $codeFontName) {
                    Text(L("System Monospaced")).tag("")
                    ForEach(monospaced, id: \.self) { Text($0).tag($0) }
                }
                Stepper(value: $codeFontSize, in: 8...40, step: 1) {
                    Text(L("Size: %d pt", Int(codeFontSize)))
                }
                Stepper(value: $tabWidth, in: 1...8) {
                    Text(L("Tab width: %d", tabWidth))
                }
                Toggle(L("Insert spaces instead of tabs"), isOn: $insertSpaces)
                Toggle(L("Word wrap"), isOn: $wordWrap)
                Toggle(L("Line numbers"), isOn: $lineNumbers)
                Toggle(L("Show hidden files"), isOn: $showHidden)
            }
            .padding(20)
            .tabItem { Label(L("Code"), systemImage: "chevron.left.forwardslash.chevron.right") }

            Form {
                Picker(L("Light appearance"), selection: $lightTheme) {
                    ForEach(ThemeStore.all.filter { !$0.isDark }, id: \.name) { Text($0.name).tag($0.name) }
                }
                Picker(L("Dark appearance"), selection: $darkTheme) {
                    ForEach(ThemeStore.all.filter(\.isDark), id: \.name) { Text($0.name).tag($0.name) }
                }
                Text(L("The theme follows the system appearance. Add your own JSON themes in ~/Library/Application Support/PS/Themes."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .tabItem { Label(L("Themes"), systemImage: "paintpalette") }

            Form {
                Picker(L("Default font"), selection: $richFontName) {
                    ForEach(families, id: \.self) { Text($0).tag($0) }
                }
                Stepper(value: $richFontSize, in: 8...48, step: 1) {
                    Text(L("Size: %d pt", Int(richFontSize)))
                }
            }
            .padding(20)
            .tabItem { Label(L("Documents"), systemImage: "doc.richtext") }

            Form {
                Picker(L("Save automatically"), selection: $autoSave) {
                    Text(L("Off")).tag(AutoSaveMode.off.rawValue)
                    Text(L("When focus changes")).tag(AutoSaveMode.focus.rawValue)
                    Text(L("Every few seconds")).tag(AutoSaveMode.interval.rawValue)
                }
                if autoSave == AutoSaveMode.interval.rawValue {
                    Stepper(value: $autoSaveInterval, in: 5...600, step: 5) {
                        Text(L("Every %d seconds", autoSaveInterval))
                    }
                }
                Text(L("Untitled documents, and documents that would need a format decision, are never saved automatically."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .tabItem { Label(L("Saving"), systemImage: "externaldrive") }
        }
        .frame(width: 520, height: 340)
    }
}
