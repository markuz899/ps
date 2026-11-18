import AppKit

/// A colour theme loaded from a JSON file (bundled `Themes/*.json` or
/// `~/Library/Application Support/PS/Themes/*.json`).
public struct Theme: Decodable {
    public let name: String
    public let appearance: String
    public let colors: [String: String]
    public let scopes: [String: String]

    public var isDark: Bool { appearance == "dark" }

    public func color(_ key: String) -> NSColor? {
        colors[key].flatMap(NSColor.init(hex:))
    }

    public func scopeColor(_ scope: String) -> NSColor? {
        scopes[scope].flatMap(NSColor.init(hex:))
    }
}

public enum ThemeStore {
    public static let all: [Theme] = load()

    public static func named(_ name: String) -> Theme? {
        all.first { $0.name == name }
    }

    /// Picks the first theme matching the appearance when the requested one is missing.
    public static func theme(named name: String, dark: Bool) -> Theme? {
        named(name) ?? all.first { $0.isDark == dark } ?? all.first
    }

    private static func load() -> [Theme] {
        var directories: [URL] = []
        if let bundled = Bundle.main.url(forResource: "Themes", withExtension: nil) {
            directories.append(bundled)
        } else if let module = Bundle.module.url(forResource: "Themes", withExtension: nil) {
            directories.append(module)
        }
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            directories.append(support.appendingPathComponent("PS/Themes"))
        }

        var themes: [Theme] = []
        let decoder = JSONDecoder()
        for directory in directories {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "json" {
                if let data = try? Data(contentsOf: file), let theme = try? decoder.decode(Theme.self, from: data) {
                    themes.removeAll { $0.name == theme.name }
                    themes.append(theme)
                }
            }
        }
        return themes.sorted { $0.name < $1.name }
    }
}

extension NSColor {
    /// "#RRGGBB" or "#RRGGBBAA".
    public convenience init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6 || value.count == 8, let number = UInt64(value, radix: 16) else { return nil }
        let hasAlpha = value.count == 8
        let r = CGFloat((number >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = CGFloat((number >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = CGFloat((number >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? CGFloat(number & 0xFF) / 255 : 1
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }
}
