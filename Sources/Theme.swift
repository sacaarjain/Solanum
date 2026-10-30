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
    static let outerWilds: [Theme] = [
        // Ash and Ember Twin: burnt-orange sand under a close, hot sun; red rock, cactus, the Nomai warp towers.
        Theme(name: "Hourglass", bg: "#3A1D0F", bg2: "#160904", fg: "#F6E1C3", accent: "#FFA940", chrome: "#5A2208",
              ansi: ["#4A2A18", "#F05A2E", "#C4BC56", "#FFB83D", "#7FAAD0", "#E58A9C", "#79C7A6", "#E8CEAD",
                     "#8C6448", "#FF7C50", "#D8D27A", "#FFCD6E", "#A2C4E4", "#F2A8B6", "#9ADBBF", "#FFF2DE"]),
        // Home: deep pine forest, red canyon rock, wooden cabins, the campfire and a blue sky.
        Theme(name: "Timber Hearth", bg: "#15291B", bg2: "#08130B", fg: "#EAE4CC", accent: "#9BD465", chrome: "#163A1C",
              ansi: ["#22382A", "#F0683E", "#8FD05E", "#F4C35A", "#6DB6F2", "#C892DC", "#5FCDB4", "#D9D2B8",
                     "#5E7360", "#FF8A62", "#ADE27E", "#FFD57E", "#94CBF6", "#DBAEEA", "#84DEC8", "#F8F3E2"]),
        // Timber Hearth's moon: cold grey dust and deep craters. The light theme.
        Theme(name: "Attlerock", bg: "#ECEDEF", bg2: "#C7C9CE", fg: "#24262B", accent: "#56606E", chrome: "#4A4F58",
              ansi: ["#2A2C31", "#B83A2C", "#3E7D4A", "#946A12", "#33609E", "#7E4CB2", "#22797E", "#8A8D94",
                     "#5C6068", "#D0503E", "#4F955C", "#AD801E", "#4677B8", "#9663C9", "#2F9298", "#B4B7BD"]),
        // A dark slate crust, frosted and cracked, over a black hole; lit orange by the lava of Hollow's Lantern.
        Theme(name: "Brittle Hollow", bg: "#1B1D2B", bg2: "#040408", fg: "#D8DCEA", accent: "#FF7442", chrome: "#22243A",
              ansi: ["#282B3C", "#FF5F45", "#74D3AA", "#FFBF55", "#6F8CFF", "#A98BFF", "#84D6F6", "#C2CBE6",
                     "#525C86", "#FF8668", "#98E2C2", "#FFD381", "#93A8FF", "#C3AAFF", "#A8E4FA", "#EEF2FF"]),
        // Ocean world: deep green water under pale streaming clouds and cyclones.
        Theme(name: "Giant's Deep", bg: "#0B3328", bg2: "#021410", fg: "#D4F0E2", accent: "#4FD8A0", chrome: "#07402F",
              ansi: ["#10402F", "#F4766A", "#43DC92", "#EEDC66", "#3FA4E0", "#B48FEA", "#3EDCD6", "#B9DFD6",
                     "#4A7C76", "#FF968C", "#6AE8AE", "#F6E98E", "#69BBEC", "#C9AAF2", "#6EE8E3", "#E8FCF7"]),
        // A pale icy shell split by black thorned vines; fog, and the anglerfish lures glowing in it. Muted on purpose.
        Theme(name: "Dark Bramble", bg: "#1D1F1D", bg2: "#060606", fg: "#D2D6CE", accent: "#F1D27C", chrome: "#262725",
              ansi: ["#2C322C", "#CF5C46", "#8DA67A", "#E6C266", "#7896AC", "#A891BA", "#8EBAB0", "#B4B9AB",
                     "#5E655D", "#E07A64", "#A7BE95", "#F2D58E", "#95AFC2", "#C0AAD0", "#AACFC6", "#E7EADE"]),
        // The comet: blue-white ice around a core of ghost matter, which only shows up green-blue on camera.
        Theme(name: "Interloper", bg: "#0F2336", bg2: "#02060B", fg: "#E6F4FC", accent: "#8ED8FF", chrome: "#0A2C4C",
              ansi: ["#1B3046", "#F27C8E", "#56F0B4", "#ECE296", "#6FBCFF", "#B3A0FF", "#86EEF6", "#CDE2EE",
                     "#4E6880", "#FF9DAC", "#82F6C8", "#F5EDB2", "#99D0FF", "#CBBDFF", "#ADF4FA", "#F5FBFF"]),
        // Solanum's home: grey rock wrapped in a shifting grey-white fog.
        Theme(name: "Quantum Moon", bg: "#202125", bg2: "#09090B", fg: "#E6E6EA", accent: "#C9CCD6", chrome: "#33304C",
              ansi: ["#2E2F35", "#EC7A8A", "#93D8AE", "#E8D492", "#93A9D8", "#C5A3D8", "#93D2DC", "#CFD0D6",
                     "#62646C", "#F799A6", "#B0E6C6", "#F2E2AE", "#B0C2E6", "#D8BEE6", "#B0E2EA", "#F6F6F8"]),
    ]

    /// Solanum's own look, and the default: near-black with the signature purple (the first Dark Bramble). Its
    /// status-bar mark is the Solanum flower in outline (see `StatusBarView`).
    static let solanumDefault = Theme(name: "Solanum Default", bg: "#111312", bg2: "#050606", fg: "#D7D3C7", accent: "#A584E8",
        ansi: ["#272B28", "#E3573F", "#8BA47B", "#E9B54D", "#6F90A9", "#A98CC1", "#8FB9B1", "#BCB7A9",
               "#5A5F5A", "#F47A63", "#A4BC95", "#F5C86F", "#8DA8BE", "#C0A6D4", "#A9CEC7", "#ECE8DC"])

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

    static var builtIn: [Theme] { [solanumDefault] + outerWilds + vsCode }

    static func isVSCode(_ t: Theme) -> Bool { !t.isCustom && vsCode.contains { $0.name == t.name } }

    static let defaultName = "Solanum Default"

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
