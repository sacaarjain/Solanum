import Foundation

/// A theme as plain data, shared by the Mac and Windows: its name and its colors as hex strings ("#RRGGBB", or
/// "#RRGGBBAA" with transparency). Each app turns it into its own colors.
struct ThemeSpec {
    let name: String
    let background: String
    /// A second color for a vertical gradient behind the terminal, top to bottom.
    let background2: String?
    let foreground: String
    let cursor: String?
    let selection: String?
    let accent: String
    /// The hue washed over the tab bar, status bar and sidebars. Solanum purple when nil.
    let chrome: String?
    let ansi: [String]

    init(name: String, bg: String, bg2: String? = nil, fg: String, cursor: String? = nil, selection: String? = nil,
         accent: String, chrome: String? = nil, ansi: [String]) {
        self.name = name
        background = bg
        background2 = bg2
        foreground = fg
        self.cursor = cursor
        self.selection = selection
        self.accent = accent
        self.chrome = chrome
        self.ansi = ansi
    }
}

/// Solanum's built-in themes.
enum ThemeSpecs {
    static let outerWilds: [ThemeSpec] = [
        // Ash and Ember Twin: burnt-orange sand under a close, hot sun; red rock, cactus, the Nomai warp towers.
        ThemeSpec(name: "Hourglass", bg: "#3A1D0F", bg2: "#160904", fg: "#F6E1C3", accent: "#FFA940", chrome: "#5A2208",
              ansi: ["#4A2A18", "#F05A2E", "#C4BC56", "#FFB83D", "#7FAAD0", "#E58A9C", "#79C7A6", "#E8CEAD",
                     "#8C6448", "#FF7C50", "#D8D27A", "#FFCD6E", "#A2C4E4", "#F2A8B6", "#9ADBBF", "#FFF2DE"]),
        // Home: deep pine forest, red canyon rock, wooden cabins, the campfire and a blue sky.
        ThemeSpec(name: "Timber Hearth", bg: "#15291B", bg2: "#08130B", fg: "#EAE4CC", accent: "#9BD465", chrome: "#163A1C",
              ansi: ["#22382A", "#F0683E", "#8FD05E", "#F4C35A", "#6DB6F2", "#C892DC", "#5FCDB4", "#D9D2B8",
                     "#5E7360", "#FF8A62", "#ADE27E", "#FFD57E", "#94CBF6", "#DBAEEA", "#84DEC8", "#F8F3E2"]),
        // Timber Hearth's moon: cold grey dust and deep craters. The light theme.
        ThemeSpec(name: "Attlerock", bg: "#ECEDEF", bg2: "#C7C9CE", fg: "#24262B", accent: "#56606E", chrome: "#4A4F58",
              ansi: ["#2A2C31", "#B83A2C", "#3E7D4A", "#946A12", "#33609E", "#7E4CB2", "#22797E", "#8A8D94",
                     "#5C6068", "#D0503E", "#4F955C", "#AD801E", "#4677B8", "#9663C9", "#2F9298", "#B4B7BD"]),
        // A dark slate crust, frosted and cracked, over a black hole; lit orange by the lava of Hollow's Lantern.
        ThemeSpec(name: "Brittle Hollow", bg: "#1B1D2B", bg2: "#040408", fg: "#D8DCEA", accent: "#FF7442", chrome: "#22243A",
              ansi: ["#282B3C", "#FF5F45", "#74D3AA", "#FFBF55", "#6F8CFF", "#A98BFF", "#84D6F6", "#C2CBE6",
                     "#525C86", "#FF8668", "#98E2C2", "#FFD381", "#93A8FF", "#C3AAFF", "#A8E4FA", "#EEF2FF"]),
        // Ocean world: deep green water under pale streaming clouds and cyclones.
        ThemeSpec(name: "Giant's Deep", bg: "#0B3328", bg2: "#021410", fg: "#D4F0E2", accent: "#4FD8A0", chrome: "#07402F",
              ansi: ["#10402F", "#F4766A", "#43DC92", "#EEDC66", "#3FA4E0", "#B48FEA", "#3EDCD6", "#B9DFD6",
                     "#4A7C76", "#FF968C", "#6AE8AE", "#F6E98E", "#69BBEC", "#C9AAF2", "#6EE8E3", "#E8FCF7"]),
        // A pale icy shell split by black thorned vines; fog, and the anglerfish lures glowing in it. Muted on purpose.
        ThemeSpec(name: "Dark Bramble", bg: "#1D1F1D", bg2: "#060606", fg: "#D2D6CE", accent: "#F1D27C", chrome: "#262725",
              ansi: ["#2C322C", "#CF5C46", "#8DA67A", "#E6C266", "#7896AC", "#A891BA", "#8EBAB0", "#B4B9AB",
                     "#5E655D", "#E07A64", "#A7BE95", "#F2D58E", "#95AFC2", "#C0AAD0", "#AACFC6", "#E7EADE"]),
        // The comet: blue-white ice around a core of ghost matter, which only shows up green-blue on camera.
        ThemeSpec(name: "Interloper", bg: "#0F2336", bg2: "#02060B", fg: "#E6F4FC", accent: "#8ED8FF", chrome: "#0A2C4C",
              ansi: ["#1B3046", "#F27C8E", "#56F0B4", "#ECE296", "#6FBCFF", "#B3A0FF", "#86EEF6", "#CDE2EE",
                     "#4E6880", "#FF9DAC", "#82F6C8", "#F5EDB2", "#99D0FF", "#CBBDFF", "#ADF4FA", "#F5FBFF"]),
        // Solanum's home: grey rock wrapped in a shifting grey-white fog.
        ThemeSpec(name: "Quantum Moon", bg: "#202125", bg2: "#09090B", fg: "#E6E6EA", accent: "#C9CCD6", chrome: "#33304C",
              ansi: ["#2E2F35", "#EC7A8A", "#93D8AE", "#E8D492", "#93A9D8", "#C5A3D8", "#93D2DC", "#CFD0D6",
                     "#62646C", "#F799A6", "#B0E6C6", "#F2E2AE", "#B0C2E6", "#D8BEE6", "#B0E2EA", "#F6F6F8"]),
    ]

    /// Solanum's own look, and the default: near-black with the signature purple (the first Dark Bramble). Its
    /// status-bar mark is the Solanum flower in outline (see `StatusBarView`).
    static let solanumDefault = ThemeSpec(name: "Solanum Default", bg: "#111312", bg2: "#050606", fg: "#D7D3C7", accent: "#A584E8",
        ansi: ["#272B28", "#E3573F", "#8BA47B", "#E9B54D", "#6F90A9", "#A98CC1", "#8FB9B1", "#BCB7A9",
               "#5A5F5A", "#F47A63", "#A4BC95", "#F5C86F", "#8DA8BE", "#C0A6D4", "#A9CEC7", "#ECE8DC"])

    /// VS Code's built-in themes, with its default terminal colors. Listed after Solanum's own.
    static let vsCode: [ThemeSpec] = {
        let dark = ["#000000", "#CD3131", "#0DBC79", "#E5E510", "#2472C8", "#BC3FBC", "#11A8CD", "#E5E5E5",
                    "#666666", "#F14C4C", "#23D18B", "#F5F543", "#3B8EEA", "#D670D6", "#29B8DB", "#E5E5E5"]
        let light = ["#000000", "#CD3131", "#107C10", "#949800", "#0451A5", "#BC05BC", "#0598BC", "#555555",
                     "#666666", "#CD3131", "#14CE14", "#B5BA00", "#0451A5", "#BC05BC", "#0598BC", "#A5A5A5"]
        return [
            ThemeSpec(name: "Dark Modern", bg: "#181818", fg: "#CCCCCC", cursor: "#0078D4", selection: "#264F78", accent: "#0078D4", ansi: dark),
            ThemeSpec(name: "Dark+", bg: "#1E1E1E", fg: "#CCCCCC", cursor: "#AEAFAD", selection: "#264F78", accent: "#007ACC", ansi: dark),
            ThemeSpec(name: "Light Modern", bg: "#F8F8F8", fg: "#3B3B3B", cursor: "#005FB8", selection: "#ADD6FF", accent: "#005FB8", ansi: light),
            ThemeSpec(name: "Light+", bg: "#FFFFFF", fg: "#333333", cursor: "#000000", selection: "#ADD6FF", accent: "#007ACC", ansi: light),
            ThemeSpec(name: "Dark High Contrast", bg: "#000000", fg: "#FFFFFF", cursor: "#FFFFFF", selection: "#FFFFFF66", accent: "#F38518", ansi: dark),
        ]
    }()

    static let defaultName = "Solanum Default"
}

/// A color from a hex string: 0xRRGGBB and its alpha, from 0 to 1.
struct HexColor: Equatable {
    let rgb: UInt32
    let alpha: Float

    init?(_ hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard let v = UInt64(s, radix: 16) else { return nil }
        switch s.count {
        case 3:
            let r = (v >> 8) & 0xF, g = (v >> 4) & 0xF, b = v & 0xF
            rgb = UInt32(r * 17) << 16 | UInt32(g * 17) << 8 | UInt32(b * 17)
            alpha = 1
        case 6:
            rgb = UInt32(v)
            alpha = 1
        case 8:
            rgb = UInt32(v >> 8)
            alpha = Float(v & 0xFF) / 255
        default:
            return nil
        }
    }

    init(rgb: UInt32, alpha: Float = 1) {
        self.rgb = rgb
        self.alpha = alpha
    }

    var luminance: Float {
        0.2126 * Float((rgb >> 16) & 0xFF) / 255 + 0.7152 * Float((rgb >> 8) & 0xFF) / 255 + 0.0722 * Float(rgb & 0xFF) / 255
    }
}
