import Foundation

// VS Code file icon themes as data, shared by the Mac (IconPacks.swift there) and Windows: the themes an extension
// declares, which icon a file or folder gets, and the packs Settings offers to download. Each app draws the icons its
// own way. https://code.visualstudio.com/api/extension-guides/file-icon-theme

/// The packs Settings offers, and the setting's own rules.
enum IconPackCatalog {
    static let solanumID = "solanum"

    /// Where a pack comes from: Open VSX, or (Seti, which ships inside VS Code) files from VS Code's repository.
    enum Source: Equatable {
        case openVSX(namespace: String, name: String)
        case files(base: String, paths: [String])
    }

    static let packs: [(label: String, source: Source)] = [
        ("Material Icon Theme", .openVSX(namespace: "PKief", name: "material-icon-theme")),
        ("vscode-icons", .openVSX(namespace: "vscode-icons-team", name: "vscode-icons")),
        ("Seti (VS Code's default)", .files(base: "https://raw.githubusercontent.com/microsoft/vscode/main/extensions/theme-seti/",
                                            paths: ["package.json", "package.nls.json", "icons/vs-seti-icon-theme.json", "icons/seti.woff"])),
        ("Catppuccin Icons", .openVSX(namespace: "Catppuccin", name: "catppuccin-vsc-icons")),
        ("Symbols", .openVSX(namespace: "miguelsolorio", name: "symbols")),
    ]

    static func openVSXLatest(_ namespace: String, _ name: String) -> String { "https://open-vsx.org/api/\(namespace)/\(name)/latest" }

    /// The download link in Open VSX's answer about an extension's latest version.
    static func downloadLink(fromOpenVSX data: Data) -> String? {
        guard let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (info["files"] as? [String: Any])?["download"] as? String
    }

    private static let catppuccin = ["catppuccin-latte", "catppuccin-mocha", "catppuccin-macchiato", "catppuccin-frappe"]

    /// The theme shown for the `file-icons` setting: Catppuccin's flavors are made for one kind of background, so its dark
    /// ones give way to Latte on a light Solanum theme, and Latte to Mocha on a dark one. The setting keeps what was
    /// picked, so a Frappé or Macchiato comes back with a dark theme.
    static func shownID(setting id: String, isDark: Bool) -> String {
        guard catppuccin.contains(id) else { return id }
        return isDark ? darkFlavor(of: id) : "catppuccin-latte"
    }

    private static func darkFlavor(of id: String) -> String { id == "catppuccin-latte" ? "catppuccin-mocha" : id }

    /// For Settings: which flavor shows when, since the one checked is only the one showing now.
    static func flavorNote(setting id: String, label: (String) -> String?) -> String? {
        guard catppuccin.contains(id), let dark = label(darkFlavor(of: id)) else { return nil }
        return "Latte on light themes, \(dark.replacingOccurrences(of: "Catppuccin ", with: "")) on dark ones."
    }

    /// A folder name for an extension's copy in the packs folder: "publisher.name", nothing that could leave the folder.
    static func folderName(packageJSON data: Data?) -> String? {
        let pkg = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let raw = [pkg["publisher"] as? String, pkg["name"] as? String].compactMap { $0 }.joined(separator: ".")
        let name = String(raw.map { $0.isLetter || $0.isNumber || "-_.".contains($0) ? $0 : "-" })
        return name.isEmpty || name.hasPrefix(".") ? nil : name
    }
}

/// One icon theme an extension declares.
struct IconPackEntry: Equatable {
    let id: String
    let label: String
    /// The theme's manifest, and the extension's folder (icon paths may not reach outside it), as paths with "/".
    let manifest: String
    let root: String

    /// The icon themes an extension folder (with "/" between parts) declares in its package.json.
    static func themes(inExtension root: String) -> [IconPackEntry] {
        let fm = FileManager.default
        guard let data = fm.contents(atPath: root + "/package.json"),
              let pkg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = (pkg["contributes"] as? [String: Any])?["iconThemes"] as? [[String: Any]] else { return [] }
        // Labels like "%themeLabel%" are looked up in package.nls.json.
        let nls = fm.contents(atPath: root + "/package.nls.json").flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        return list.compactMap { t in
            guard let id = t["id"] as? String, id != IconPackCatalog.solanumID, let path = t["path"] as? String,
                  let manifest = IconThemeManifest.inside(root, path) else { return nil }
            var label = t["label"] as? String ?? id
            if label.count > 2, label.hasPrefix("%"), label.hasSuffix("%") {
                let v = nls[String(label.dropFirst().dropLast())]
                label = v as? String ?? (v as? [String: Any])?["message"] as? String ?? id
            }
            return IconPackEntry(id: id, label: label, manifest: manifest, root: root)
        }
    }

    /// Every theme in the packs folder (one extension folder each), by label; the first of an id wins.
    static func scan(packsFolder dir: String) -> [IconPackEntry] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted()
        var seen = Set<String>()
        return names.flatMap { themes(inExtension: dir + "/" + $0) }.filter { seen.insert($0.id).inserted }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }
}

/// A theme's manifest: icon definitions (an SVG or PNG, or a glyph of a font the theme ships) and the names,
/// extensions and languages they're for.
struct IconThemeManifest {
    enum Icon: Equatable {
        /// A picture file, by its path.
        case file(String)
        /// A character of one of the theme's fonts, in a color (nil: the theme's text color).
        case glyph(String, fontID: String, color: (rgb: UInt32, alpha: Float)?)

        static func == (a: Icon, b: Icon) -> Bool {
            switch (a, b) {
            case (.file(let x), .file(let y)): return x == y
            case (.glyph(let g1, let f1, let c1), .glyph(let g2, let f2, let c2)):
                return g1 == g2 && f1 == f2 && c1?.rgb == c2?.rgb && c1?.alpha == c2?.alpha
            default: return false
            }
        }
    }

    struct Font: Equatable {
        let id: String
        /// Its files, first that can be read wins.
        let paths: [String]
        /// Its size against VS Code's 13px UI font ("150%" is 1.5).
        let scale: Float
    }

    private struct Maps {
        var file, folder, folderExpanded: String?
        var fileExtensions: [String: String] = [:]
        var fileNames: [String: String] = [:]
        var folderNames: [String: String] = [:]
        var folderNamesExpanded: [String: String] = [:]
        var languageIds: [String: String] = [:]

        init(_ j: [String: Any]) {
            func map(_ k: String) -> [String: String] {
                var out: [String: String] = [:]
                for (key, v) in j[k] as? [String: String] ?? [:] { out[key.lowercased()] = v }
                return out
            }
            file = j["file"] as? String
            folder = j["folder"] as? String
            folderExpanded = j["folderExpanded"] as? String
            fileExtensions = map("fileExtensions")
            fileNames = map("fileNames")
            folderNames = map("folderNames")
            folderNamesExpanded = map("folderNamesExpanded")
            languageIds = j["languageIds"] as? [String: String] ?? [:]
        }
    }

    private(set) var icons: [String: Icon] = [:]
    private(set) var fonts: [Font] = []
    private let base: Maps
    private let light: Maps?

    /// `rel` from `base` (a folder, "/" between parts), as a full path; nil if it would reach outside `root` (by default
    /// `base` itself). "../icons/x.svg" from a manifest in dist/ is fine, as long as it stays in the extension.
    static func inside(_ base: String, _ rel: String, within root: String? = nil) -> String? {
        guard !rel.isEmpty else { return nil }
        let top = root ?? base
        guard base == top || base.hasPrefix(top + "/") else { return nil }
        var parts = base.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let depth = top.split(separator: "/", omittingEmptySubsequences: false).count
        for p in rel.replacingOccurrences(of: "\\", with: "/").split(separator: "/") {
            if p == "." { continue }
            if p == ".." {
                guard parts.count > depth else { return nil }
                parts.removeLast()
            } else {
                parts.append(String(p))
            }
        }
        return parts.count > depth ? parts.joined(separator: "/") : nil
    }

    init?(_ entry: IconPackEntry) {
        guard let data = FileManager.default.contents(atPath: entry.manifest),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let folder = String(entry.manifest[..<(entry.manifest.lastIndex(of: "/") ?? entry.manifest.endIndex)])
        func resolve(_ rel: String) -> String? { Self.inside(folder, rel, within: entry.root) }
        var fontList: [Font] = []
        for f in j["fonts"] as? [[String: Any]] ?? [] {
            guard let id = f["id"] as? String else { continue }
            let paths = (f["src"] as? [[String: Any]] ?? []).compactMap { ($0["path"] as? String).flatMap(resolve) }
            let size = (f["size"] as? String).flatMap { Float($0.replacingOccurrences(of: "%", with: "")) }.map { $0 / 100 } ?? 1
            fontList.append(Font(id: id, paths: paths, scale: size))
        }
        fonts = fontList
        let defaultFont = fontList.first?.id
        for (id, v) in j["iconDefinitions"] as? [String: [String: Any]] ?? [:] {
            if let path = (v["iconPath"] as? String).flatMap(resolve) {
                icons[id] = .file(path)
            } else if let glyph = (v["fontCharacter"] as? String).flatMap(Self.glyph), let font = (v["fontId"] as? String) ?? defaultFont {
                icons[id] = .glyph(glyph, fontID: font, color: (v["fontColor"] as? String).flatMap(Self.color))
            }
        }
        base = Maps(j)
        light = (j["light"] as? [String: Any]).map(Maps.init)
    }

    /// The icons a theme would use for a file or folder, best first: by its exact name, then its extensions (longest
    /// first), its language, and the theme's default. On a light background the theme's light set comes before the rest.
    func candidates(forName name: String, directory: Bool, expanded: Bool = false, light isLight: Bool) -> [Icon] {
        let maps = isLight && light != nil ? [light!, base] : [base]
        let lower = name.lowercased()
        var keys: [String?] = []
        if directory {
            if expanded { keys += maps.map { $0.folderNamesExpanded[lower] } }
            keys += maps.map { $0.folderNames[lower] }
            if expanded { keys += maps.map { $0.folderExpanded } }
            keys += maps.map { $0.folder }
        } else {
            keys += maps.map { $0.fileNames[lower] }
            // Longest extension first: "d.ts" before "ts" (and ".gitignore" is extension "gitignore").
            var i = lower.startIndex
            while let dot = lower[i...].firstIndex(of: ".") {
                let ext = String(lower[lower.index(after: dot)...])
                keys += maps.map { $0.fileExtensions[ext] }
                i = lower.index(after: dot)
            }
            if let lang = VSCodeLanguages.id(forFileName: name) { keys += maps.map { $0.languageIds[lang] } }
            keys += maps.map { $0.file }
        }
        var out: [Icon] = []
        for case let k? in keys { if let icon = icons[k], !out.contains(icon) { out.append(icon) } }
        return out
    }

    /// "\E001" (as VS Code themes write it) or the character itself.
    static func glyph(_ s: String) -> String? {
        guard s.hasPrefix("\\") else { return s.isEmpty ? nil : s }
        return UInt32(s.dropFirst(), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
    }

    /// "#RGB", "#RGBA", "#RRGGBB" or "#RRGGBBAA".
    static func color(_ s: String) -> (rgb: UInt32, alpha: Float)? {
        var hex = s.trimmingCharacters(in: .whitespaces)
        guard hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        if hex.count == 3 || hex.count == 4 { hex = String(hex.flatMap { [$0, $0] }) }
        guard hex.count == 6 || hex.count == 8, let v = UInt64(hex, radix: 16) else { return nil }
        let rgba = hex.count == 6 ? v << 8 | 0xFF : v
        return (UInt32(rgba >> 8), Float(rgba & 0xFF) / 255)
    }
}
