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
    /// Chrome (tab bar, status bar, sidebars) gets a faint wash of Solanum purple.
    var tabBarTint: NSColor {
        isDark ? NSColor(srgbRed: 0.09, green: 0.03, blue: 0.17, alpha: 0.32) : SolanumArt.purpleOnLight.withAlphaComponent(0.07)
    }

    init(name: String, bg: String, bg2: String? = nil, fg: String, cursor: String? = nil, selection: String? = nil,
         accent: String, ansi: [String]) {
        self.name = name
        background = NSColor(hex: bg)
        background2 = bg2.map { NSColor(hex: $0) }
        foreground = NSColor(hex: fg)
        self.accent = NSColor(hex: accent)
        self.cursor = NSColor(hex: cursor ?? accent)
        self.selection = selection.map { NSColor(hex: $0) } ?? NSColor(hex: accent).withAlphaComponent(0.30)
        self.ansi = ansi.map { NSColor(hex: $0) }
        while self.ansi.count < 16 { self.ansi.append(foreground) }
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
    /// The planets of Outer Wilds. Every theme shares Solanum's purple for the cursor and highlights.
    static let outerWilds: [Theme] = [
        // Ash and Ember Twin: sun-baked sand, red rock, cactus green.
        Theme(name: "Hourglass", bg: "#231811", bg2: "#120B07", fg: "#F2DFC6", accent: "#B488F5",
              ansi: ["#3A2A1F", "#E8603F", "#A9B868", "#F2B45A", "#7FA3C9", "#D486A6", "#73C3B5", "#E3D0B6",
                     "#7A6250", "#FF8461", "#C3D182", "#FFCB7A", "#9EBCDD", "#E8A3BF", "#93D8CB", "#FFF3E0"]),
        // Home: pine forest, wooden cabins, the campfire, a blue sky.
        Theme(name: "Timber Hearth", bg: "#1A1E17", bg2: "#0E110C", fg: "#E7E0CA", accent: "#B086F5",
              ansi: ["#2B3125", "#E2684C", "#8EC25B", "#E9B850", "#6FA9DE", "#BE8DDB", "#6DC5AF", "#D8D1BA",
                     "#626A57", "#F48A6E", "#A8D879", "#F6CE72", "#93C1EA", "#D3A9EA", "#8DD9C4", "#F7F2E1"]),
        // The moon: pale grey dust and craters. The light theme.
        Theme(name: "Attlerock", bg: "#ECEAE6", bg2: "#DCD9D2", fg: "#2F2E2C", cursor: "#7B4FD9", accent: "#7B4FD9",
              ansi: ["#3B3A37", "#BF4536", "#4A8645", "#9E7114", "#3C6CA6", "#8A4FC0", "#2B8787", "#8F8C86",
                     "#66635E", "#D45A4A", "#5C9C56", "#B5861F", "#4F82BD", "#9F66D3", "#379C9C", "#B7B4AE"]),
        // Cracking crust over a black hole, ice crystals, Hollow's Lantern glowing orange.
        Theme(name: "Brittle Hollow", bg: "#141428", bg2: "#070710", fg: "#DCE2F5", accent: "#B28AF7",
              ansi: ["#24263E", "#FF7A48", "#7FD6B1", "#F4C46E", "#6F8EFF", "#B58EFF", "#7FDCF4", "#C8D0E7",
                     "#585D82", "#FF9A70", "#9DE5C6", "#FFD691", "#93AAFF", "#CBADFF", "#A3E8F8", "#F1F4FF"]),
        // Ocean world: deep teal water, green islands, storms and lightning.
        Theme(name: "Giant's Deep", bg: "#0C1F23", bg2: "#051110", fg: "#D5EEE8", accent: "#A98BF2",
              ansi: ["#173438", "#EF706C", "#41D29C", "#E3D46C", "#409CD7", "#A98BE0", "#49D5D1", "#BFDDD6",
                     "#4D6E70", "#FF918C", "#67E3B4", "#F0E38D", "#66B4E6", "#C0A6EC", "#71E4E0", "#EAFAF6"]),
        // Fog, thorned vines, and the anglerfish lights in the dark.
        Theme(name: "Dark Bramble", bg: "#111312", bg2: "#050606", fg: "#D7D3C7", accent: "#A584E8",
              ansi: ["#272B28", "#E3573F", "#8BA47B", "#E9B54D", "#6F90A9", "#A98CC1", "#8FB9B1", "#BCB7A9",
                     "#5A5F5A", "#F47A63", "#A4BC95", "#F5C86F", "#8DA8BE", "#C0A6D4", "#A9CEC7", "#ECE8DC"]),
        // The comet: ice blue and white, with ghost-matter green.
        Theme(name: "Interloper", bg: "#0E1721", bg2: "#060B11", fg: "#E5F2FA", accent: "#B191F7",
              ansi: ["#1E2C38", "#F07C8C", "#5FF2A2", "#E9E28C", "#7CC4FF", "#B89DFF", "#8EF0F5", "#D1E5EF",
                     "#4F6577", "#FF9DAA", "#86F7BA", "#F3EDA8", "#A1D5FF", "#CFBBFF", "#B0F5F8", "#F4FBFF"]),
        // Solanum's home: shifting violet fog, pale light, and the brightest purple of all.
        Theme(name: "Quantum Moon", bg: "#16122A", bg2: "#08060F", fg: "#E6E1F5", accent: "#C3A6FF",
              ansi: ["#2A2442", "#F0718A", "#8FE3B0", "#F2D98A", "#8FA8FF", "#C9A0FF", "#8FE0EC", "#D4CEE8",
                     "#5E5680", "#FF94A8", "#ADF0C8", "#F8E6A8", "#ADC0FF", "#DCBDFF", "#ADEDF5", "#F6F3FF"]),
    ]

    /// VS Code's built-in themes, with its default terminal colors. Listed after Solanum's own.
    static let vsCode: [Theme] = {
        let dark = ["#000000", "#CD3131", "#0DBC79", "#E5E510", "#2472C8", "#BC3FBC", "#11A8CD", "#E5E5E5",
                    "#666666", "#F14C4C", "#23D18B", "#F5F543", "#3B8EEA", "#D670D6", "#29B8DB", "#E5E5E5"]
        let light = ["#000000", "#CD3131", "#107C10", "#949800", "#0451A5", "#BC05BC", "#0598BC", "#555555",
                     "#666666", "#CD3131", "#14CE14", "#B5BA00", "#0451A5", "#BC05BC", "#0598BC", "#A5A5A5"]
        return [
            Theme(name: "Dark Modern", bg: "#181818", fg: "#CCCCCC", cursor: "#0078D4", selection: "#264F78", accent: "#0078D4", ansi: dark),
            Theme(name: "Dark+", bg: "#1E1E1E", fg: "#CCCCCC", cursor: "#AEAFAD", selection: "#264F78", accent: "#007ACC", ansi: dark),
            Theme(name: "Light Modern", bg: "#F8F8F8", fg: "#3B3B3B", cursor: "#005FB8", selection: "#ADD6FF", accent: "#005FB8", ansi: light),
            Theme(name: "Light+", bg: "#FFFFFF", fg: "#333333", cursor: "#000000", selection: "#ADD6FF", accent: "#007ACC", ansi: light),
            Theme(name: "Dark High Contrast", bg: "#000000", fg: "#FFFFFF", cursor: "#FFFFFF", selection: "#FFFFFF66", accent: "#F38518", ansi: dark),
        ]
    }()

    static var builtIn: [Theme] { outerWilds + vsCode }

    static func isVSCode(_ t: Theme) -> Bool { !t.isCustom && vsCode.contains { $0.name == t.name } }

    static let defaultName = "Timber Hearth"

    /// Themes loaded from ~/.config/solanum/themes/*.json
    static private(set) var custom: [Theme] = []

    /// Solanum's themes and the user's own first, VS Code's below.
    static var all: [Theme] { outerWilds + custom + vsCode }

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
                          accent: (j["accent"] as? String) ?? (ansi.count > 4 ? ansi[4] : fg), ansi: ansi)
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
