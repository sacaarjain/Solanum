import Foundation

/// The settings file's format, the same as the Mac's: `key = value` lines, with # comments. Keys this app doesn't know
/// are kept as they were, so a file shared with another version loses nothing.
struct SettingsFile {
    private(set) var values: [String: String] = [:]

    init(text: String) {
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            values[key] = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        }
    }

    init() {}

    subscript(key: String) -> String? {
        get { values[key] }
        set { values[key] = newValue }
    }

    func bool(_ key: String, _ fallback: Bool) -> Bool {
        guard let v = values[key]?.lowercased() else { return fallback }
        return ["true", "yes", "on", "1"].contains(v)
    }

    func number(_ key: String, _ fallback: Double, in range: ClosedRange<Double>) -> Double {
        guard let v = values[key].flatMap(Double.init) else { return fallback }
        return min(max(v, range.lowerBound), range.upperBound)
    }

    /// The file's text: each known key under its comment, in order, then any others there were.
    func text(header: String, sections: [(comment: String?, keys: [String])]) -> String {
        var out = header + "\n"
        var written = Set<String>()
        for section in sections {
            out += "\n"
            if let comment = section.comment { out += comment.split(separator: "\n").map { "# " + $0 }.joined(separator: "\n") + "\n" }
            for key in section.keys {
                out += "\(key) = \(values[key] ?? "")\n"
                written.insert(key)
            }
        }
        let others = values.keys.filter { !written.contains($0) }.sorted()
        if !others.isEmpty {
            out += "\n# Kept from elsewhere (another version of Solanum, say).\n"
            for key in others { out += "\(key) = \(values[key] ?? "")\n" }
        }
        return out
    }
}

/// A theme's colors, worked out once: what to draw the terminal and the chrome around it with. Colors are 0xRRGGBB.
struct ThemeColors: Equatable {
    let name: String
    let background: UInt32
    let backgroundBottom: UInt32
    let foreground: UInt32
    let cursor: UInt32
    let selection: UInt32
    let accent: UInt32
    let ansi: [UInt32]
    let isDark: Bool
    /// The faint wash over the tab bar, status bar and sidebars.
    let chrome: UInt32
    /// A slightly raised surface, for the active tab and hover.
    let surface: UInt32

    init(_ spec: ThemeSpec) {
        func hex(_ s: String?, _ fallback: UInt32) -> HexColor { s.flatMap(HexColor.init) ?? HexColor(rgb: fallback) }
        let bg = hex(spec.background, 0x111312), fg = hex(spec.foreground, 0xD7D3C7), accentColor = hex(spec.accent, 0xA584E8)
        name = spec.name
        background = bg.rgb
        backgroundBottom = hex(spec.background2, bg.rgb).rgb
        foreground = fg.rgb
        accent = accentColor.rgb
        cursor = hex(spec.cursor, accentColor.rgb).rgb
        isDark = bg.luminance < 0.5
        // The selection is drawn opaque, so a transparent one is mixed into the background here.
        let picked = spec.selection.flatMap(HexColor.init) ?? HexColor(rgb: accentColor.rgb, alpha: 0.30)
        selection = Self.mix(picked.rgb, bg.rgb, picked.alpha)
        var colors = spec.ansi.compactMap { HexColor($0)?.rgb }
        while colors.count < 16 { colors.append(fg.rgb) }
        ansi = colors
        if let tint = spec.chrome.flatMap(HexColor.init) {
            chrome = Self.mix(tint.rgb, bg.rgb, isDark ? 0.42 : 0.09)
        } else {
            chrome = isDark ? Self.mix(0x17082B, bg.rgb, 0.32) : Self.mix(0x7B4FD9, bg.rgb, 0.07)
        }
        surface = Self.mix(isDark ? 0xFFFFFF : 0x000000, bg.rgb, isDark ? 0.08 : 0.05)
    }

    private init(name: String, background: UInt32, backgroundBottom: UInt32, foreground: UInt32, cursor: UInt32, selection: UInt32,
                 accent: UInt32, ansi: [UInt32], isDark: Bool, chrome: UInt32, surface: UInt32) {
        self.name = name
        self.background = background
        self.backgroundBottom = backgroundBottom
        self.foreground = foreground
        self.cursor = cursor
        self.selection = selection
        self.accent = accent
        self.ansi = ansi
        self.isDark = isDark
        self.chrome = chrome
        self.surface = surface
    }

    /// Part way from one theme's colors to another's (`t` from 0, all `a`, to 1, all `b`): every color mixed, for a theme
    /// change that eases in rather than snapping. Light or dark goes over halfway.
    static func blend(_ a: ThemeColors, _ b: ThemeColors, _ t: Float) -> ThemeColors {
        func m(_ x: UInt32, _ y: UInt32) -> UInt32 { mix(y, x, t) }
        return ThemeColors(name: b.name, background: m(a.background, b.background), backgroundBottom: m(a.backgroundBottom, b.backgroundBottom),
                           foreground: m(a.foreground, b.foreground), cursor: m(a.cursor, b.cursor), selection: m(a.selection, b.selection),
                           accent: m(a.accent, b.accent), ansi: zip(a.ansi, b.ansi).map(m), isDark: t < 0.5 ? a.isDark : b.isDark,
                           chrome: m(a.chrome, b.chrome), surface: m(a.surface, b.surface))
    }

    /// `amount` of `a`, the rest `b`.
    static func mix(_ a: UInt32, _ b: UInt32, _ amount: Float) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let x = Float((a >> shift) & 0xFF), y = Float((b >> shift) & 0xFF)
            return UInt32((x * amount + y * (1 - amount)).rounded()) << shift
        }
        return channel(16) | channel(8) | channel(0)
    }

    /// A theme from a JSON file, as the Mac writes them: name, background, background2, foreground, cursor, selection,
    /// accent, chrome and ansi.
    static func spec(fromJSON data: Data) -> ThemeSpec? {
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = j["name"] as? String, let bg = j["background"] as? String, let fg = j["foreground"] as? String else { return nil }
        return ThemeSpec(name: name, bg: bg, bg2: j["background2"] as? String, fg: fg, cursor: j["cursor"] as? String,
                         selection: j["selection"] as? String, accent: j["accent"] as? String ?? fg, chrome: j["chrome"] as? String,
                         ansi: j["ansi"] as? [String] ?? [])
    }
}
