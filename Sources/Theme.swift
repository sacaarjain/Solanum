import AppKit

extension NSColor {
    convenience init(hex: String, alpha: CGFloat = 1) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        if s.count == 3 {
            let r = (v >> 8) & 0xF, g = (v >> 4) & 0xF, b = v & 0xF
            self.init(srgbRed: CGFloat(r * 17) / 255, green: CGFloat(g * 17) / 255, blue: CGFloat(b * 17) / 255, alpha: alpha)
        } else if s.count == 8 {
            // #RRGGBBAA
            self.init(srgbRed: CGFloat((v >> 24) & 0xFF) / 255, green: CGFloat((v >> 16) & 0xFF) / 255,
                      blue: CGFloat((v >> 8) & 0xFF) / 255, alpha: CGFloat(v & 0xFF) / 255)
        } else {
            self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                      blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
        }
    }

    var srgb: NSColor { usingColorSpace(.sRGB) ?? self }

    /// "#RRGGBB", or "#RRGGBBAA" when not fully opaque.
    var hexString: String {
        let (r, g, b) = rgbBytes
        let a = UInt8(max(0, min(255, (srgb.alphaComponent * 255).rounded())))
        return a == 255 ? String(format: "#%02X%02X%02X", r, g, b) : String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }

    var luminance: CGFloat {
        let c = srgb
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    }

    var rgbBytes: (UInt8, UInt8, UInt8) {
        let c = srgb
        return (UInt8(max(0, min(255, c.redComponent * 255))), UInt8(max(0, min(255, c.greenComponent * 255))),
                UInt8(max(0, min(255, c.blueComponent * 255))))
    }

    func mix(_ other: NSColor, _ t: CGFloat) -> NSColor {
        srgb.blended(withFraction: t, of: other.srgb) ?? self
    }
}

struct Theme {
    var name: String
    var background: NSColor
    /// Optional second color for a vertical background gradient (top → bottom).
    var background2: NSColor?
    var foreground: NSColor
    var cursor: NSColor
    var selection: NSColor
    var accent: NSColor
    /// Optional hue for the chrome wash (tab bar, status bar, sidebars); Solanum purple when nil.
    var chrome: NSColor?
    var ansi: [NSColor]
    /// The JSON file a custom theme was loaded from; nil for built-in themes.
    var file: URL?

    var isCustom: Bool { file != nil }

    /// The theme in the JSON format read from ~/.config/solanum/themes/.
    var json: [String: Any] {
        var j: [String: Any] = ["name": name, "background": background.hexString, "foreground": foreground.hexString,
                                "cursor": cursor.hexString, "selection": selection.hexString, "accent": accent.hexString,
                                "ansi": ansi.map(\.hexString)]
        if let b2 = background2 { j["background2"] = b2.hexString }
        if let c = chrome { j["chrome"] = c.hexString }
        return j
    }

    var isDark: Bool { background.luminance < 0.5 }
    var red: NSColor { ansi[1] }
    var green: NSColor { ansi[2] }
    var yellow: NSColor { ansi[3] }

    /// Slightly raised surface used for tabs, palette rows, etc.
    var surface: NSColor { background.mix(isDark ? .white : .black, isDark ? 0.08 : 0.05) }
    var border: NSColor { foreground.withAlphaComponent(isDark ? 0.10 : 0.14) }
    var dimText: NSColor { foreground.withAlphaComponent(0.55) }
    /// Chrome (tab bar, status bar, sidebars) gets a faint wash of the theme's chrome color, or Solanum purple.
    var tabBarTint: NSColor {
        if let c = chrome { return c.withAlphaComponent(isDark ? 0.42 : 0.09) }
        return isDark ? NSColor(srgbRed: 0.09, green: 0.03, blue: 0.17, alpha: 0.32) : SolanumArt.purpleOnLight.withAlphaComponent(0.07)
    }

    init(name: String, bg: String, bg2: String? = nil, fg: String, cursor: String? = nil, selection: String? = nil,
         accent: String, chrome: String? = nil, ansi: [String]) {
        self.name = name
        background = NSColor(hex: bg)
        background2 = bg2.map { NSColor(hex: $0) }
        foreground = NSColor(hex: fg)
        self.accent = NSColor(hex: accent)
        self.chrome = chrome.map { NSColor(hex: $0) }
        self.cursor = NSColor(hex: cursor ?? accent)
        self.selection = selection.map { NSColor(hex: $0) } ?? NSColor(hex: accent).withAlphaComponent(0.30)
        self.ansi = ansi.map { NSColor(hex: $0) }
        while self.ansi.count < 16 { self.ansi.append(foreground) }
    }

    init(spec: ThemeSpec) {
        self.init(name: spec.name, bg: spec.background, bg2: spec.background2, fg: spec.foreground, cursor: spec.cursor,
                  selection: spec.selection, accent: spec.accent, chrome: spec.chrome, ansi: spec.ansi)
    }

    /// Color for an xterm 256-palette index.
    func paletteColor(_ i: Int) -> NSColor {
        if i < 16 { return ansi[i] }
        if i < 232 {
            let n = i - 16
            let levels: [CGFloat] = [0, 95, 135, 175, 215, 255]
            return NSColor(srgbRed: levels[n / 36] / 255, green: levels[(n / 6) % 6] / 255, blue: levels[n % 6] / 255, alpha: 1)
        }
        let g = CGFloat(8 + (i - 232) * 10) / 255
        return NSColor(srgbRed: g, green: g, blue: g, alpha: 1)
    }
}

enum ThemeLibrary {
    /// The planets of Outer Wilds, each colored like the planet itself (and its status-bar icon, see PlanetArt).
    static let outerWilds: [Theme] = ThemeSpecs.outerWilds.map(Theme.init(spec:))

    /// Solanum's own look, and the default: near-black with the signature purple (the first Dark Bramble). Its
    /// status-bar mark is the Solanum flower in outline (see `StatusBarView`).
    static let solanumDefault = Theme(spec: ThemeSpecs.solanumDefault)

    /// VS Code's built-in themes, with its default terminal colors. Listed after Solanum's own.
    static let vsCode: [Theme] = ThemeSpecs.vsCode.map(Theme.init(spec:))

    static var builtIn: [Theme] { [solanumDefault] + outerWilds + vsCode }

    static func isVSCode(_ t: Theme) -> Bool { !t.isCustom && vsCode.contains { $0.name == t.name } }

    static let defaultName = ThemeSpecs.defaultName

    /// Themes loaded from ~/.config/solanum/themes/*.json
    static private(set) var custom: [Theme] = []

    /// Solanum's themes and the user's own first, VS Code's below.
    static var all: [Theme] { [solanumDefault] + outerWilds + custom + vsCode }

    static func theme(named name: String) -> Theme {
        all.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } ?? builtIn.first { $0.name == defaultName } ?? builtIn[0]
    }

    static func loadCustomThemes(from dir: URL) {
        custom = []
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let bg = j["background"] as? String, let fg = j["foreground"] as? String,
                  let ansi = j["ansi"] as? [String] else { continue }
            let name = (j["name"] as? String) ?? f.deletingPathExtension().lastPathComponent
            var t = Theme(name: name, bg: bg, bg2: j["background2"] as? String, fg: fg,
                          cursor: j["cursor"] as? String, selection: j["selection"] as? String,
                          accent: (j["accent"] as? String) ?? (ansi.count > 4 ? ansi[4] : fg), chrome: j["chrome"] as? String, ansi: ansi)
            t.file = f
            custom.append(t)
        }
        custom.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Editing custom themes (Settings › Appearance)

    private static var dir: URL { Config.shared.themesDir }

    /// `base`, or "base 2", "base 3"… so no two themes share a name (case-insensitively). `except` is the theme being renamed.
    static func uniqueName(_ base: String, except: URL? = nil) -> String {
        let taken = Set(all.filter { $0.file == nil || $0.file != except }.map { $0.name.lowercased() })
        let trimmed = base.trimmingCharacters(in: .whitespaces).isEmpty ? "My Theme" : base.trimmingCharacters(in: .whitespaces)
        if !taken.contains(trimmed.lowercased()) { return trimmed }
        var n = 2
        while taken.contains("\(trimmed) \(n)".lowercased()) { n += 1 }
        return "\(trimmed) \(n)"
    }

    /// Writes `theme` to its file (a new one, named after the theme, if it has none) and reloads the custom list.
    @discardableResult
    static func save(_ theme: Theme) -> Theme {
        var t = theme
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if t.file == nil {
            let slug = t.name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce(into: "") { $0.append($1) }
            var url = dir.appendingPathComponent((slug.isEmpty ? "theme" : slug) + ".json")
            var n = 2
            while FileManager.default.fileExists(atPath: url.path) {
                url = dir.appendingPathComponent("\(slug)-\(n).json")
                n += 1
            }
            t.file = url
        }
        if let data = try? JSONSerialization.data(withJSONObject: t.json, options: [.prettyPrinted, .sortedKeys]), let url = t.file {
            try? data.write(to: url, options: .atomic)
        }
        loadCustomThemes(from: dir)
        return t
    }

    /// A new custom theme copied from `base`.
    static func duplicate(_ base: Theme) -> Theme {
        var t = base
        t.file = nil
        t.name = uniqueName(base.isCustom ? base.name : "My \(base.name)")
        return save(t)
    }

    static func delete(_ theme: Theme) {
        guard let url = theme.file else { return }
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        loadCustomThemes(from: dir)
    }
}
