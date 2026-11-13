import Foundation
import WinSDK

/// Custom themes on Windows, as on the Mac: one JSON file each in the themes folder beside the settings
/// (%APPDATA%\Solanum\themes). Changes there show within a few seconds, in every window.
///
/// Besides Solanum's own format (what the Mac writes: name, background, background2, foreground, cursor, selection,
/// accent, chrome, ansi), a Windows Terminal color scheme or a VS Code color theme dropped in works too.
enum ThemeFiles {
    static var folder: URL? { AppSettings.themesFolder }

    /// Every theme in the folder, by name, with its file.
    static func load() -> [(spec: ThemeSpec, file: URL)] {
        guard let dir = folder else { return [] }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        var out: [(ThemeSpec, URL)] = []
        for name in names where name.lowercased().hasSuffix(".json") {
            let url = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url), let spec = parse(data, fallbackName: String(name.dropLast(5))) else { continue }
            // Two files with one name: the first keeps it.
            if out.contains(where: { $0.0.name.caseInsensitiveCompare(spec.name) == .orderedSame }) { continue }
            out.append((spec, url))
        }
        return out.sorted { $0.0.name.localizedCaseInsensitiveCompare($1.0.name) == .orderedAscending }
    }

    /// What's in the folder and when each changed, to tell when to read it again.
    static func signature() -> String {
        guard let dir = folder, let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return "" }
        return names.filter { $0.lowercased().hasSuffix(".json") }.sorted().map { name -> String in
            let date = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path))?[.modificationDate] as? Date
            return "\(name)@\(date?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: "|")
    }

    // MARK: Reading

    /// A theme from JSON: Solanum's format, a Windows Terminal scheme, or a VS Code color theme. A theme without a
    /// name takes its file's.
    static func parse(_ data: Data, fallbackName: String) -> ThemeSpec? {
        guard let j = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [String: Any] else {
            return parseVSCode(data, fallbackName: fallbackName)
        }
        func color(_ key: String, in dict: [String: Any]? = nil) -> String? {
            guard let s = (dict ?? j)[key] as? String, HexColor(s) != nil else { return nil }
            // #RRGGBBAA as VS Code writes: just the color.
            return s.hasPrefix("#") && s.count == 9 ? String(s.prefix(7)) : s
        }
        let name = (j["name"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? fallbackName
        // VS Code: its colors, the terminal's where it has them.
        if let colors = j["colors"] as? [String: Any] {
            guard let bg = color("terminal.background", in: colors) ?? color("editor.background", in: colors),
                  let fg = color("terminal.foreground", in: colors) ?? color("editor.foreground", in: colors) else { return nil }
            let names = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]
            let ansi = (names.map { "terminal.ansi" + $0 } + names.map { "terminal.ansiBright" + $0 }).compactMap { color($0, in: colors) }
            return ThemeSpec(name: name, bg: bg, fg: fg, cursor: color("terminalCursor.foreground", in: colors) ?? color("editorCursor.foreground", in: colors),
                             selection: color("terminal.selectionBackground", in: colors) ?? color("editor.selectionBackground", in: colors),
                             accent: color("focusBorder", in: colors) ?? (ansi.count > 4 ? ansi[4] : fg), ansi: ansi.count == 16 ? ansi : [])
        }
        guard let bg = color("background"), let fg = color("foreground") else { return nil }
        // Windows Terminal: a color for each name.
        if j["black"] != nil || j["brightBlack"] != nil {
            let names = ["black", "red", "green", "yellow", "blue", "purple", "cyan", "white"]
            let bright = ["brightBlack", "brightRed", "brightGreen", "brightYellow", "brightBlue", "brightPurple", "brightCyan", "brightWhite"]
            let ansi = (names + bright).map { color($0) ?? fg }
            return ThemeSpec(name: name, bg: bg, fg: fg, cursor: color("cursorColor"), selection: color("selectionBackground"),
                             accent: ansi[4], ansi: ansi)
        }
        // Solanum's own. Without an accent, blue from the colors, as the Mac takes it.
        let ansi = (j["ansi"] as? [String] ?? []).compactMap { HexColor($0) != nil ? $0 : nil }
        var spec = ThemeSpec(name: name, bg: bg, bg2: color("background2"), fg: fg, cursor: color("cursor"), selection: color("selection"),
                             accent: color("accent") ?? (ansi.count > 4 ? ansi[4] : fg), chrome: color("chrome"), ansi: ansi)
        // A picture behind it, with how blurred and how tinted.
        if let file = j["background-image"] as? String, !file.isEmpty {
            var image = ThemeImage(file: file)
            if let blur = (j["background-image-blur"] as? NSNumber)?.doubleValue { image.blur = min(max(blur, 0), 100) }
            if let tint = (j["background-image-tint"] as? NSNumber)?.doubleValue { image.tint = min(max(tint, 0), 0.95) }
            spec.image = image
        }
        if let icon = j["icon"] as? String, !icon.isEmpty { spec.icon = icon }
        return spec
    }

    /// Where a theme's picture is: a name in the themes folder, or a full path.
    static func imageURL(_ image: ThemeImage) -> URL? {
        if image.file.contains(":") || image.file.hasPrefix("\\") || image.file.hasPrefix("/") { return URL(fileURLWithPath: image.file) }
        return folder?.appendingPathComponent(image.file)
    }

    /// A picture copied into the themes folder for `theme`, so the theme keeps it wherever the original goes; its name there.
    static func importImage(_ path: String, for theme: String, as kind: String = "background") -> String? {
        guard let dir = folder else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        let slug = theme.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce(into: "") { $0.append($1) }
        var name = "\(slug.isEmpty ? "theme" : slug)-\(kind).\(ext.isEmpty ? "jpg" : ext)", n = 2
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) {
            name = "\(slug.isEmpty ? "theme" : slug)-\(kind)-\(n).\(ext.isEmpty ? "jpg" : ext)"
            n += 1
        }
        guard (try? FileManager.default.copyItem(atPath: path, toPath: dir.appendingPathComponent(name).path)) != nil else { return nil }
        return name
    }

    /// VS Code's themes may have comments and trailing commas, which JSON doesn't allow: without them, once more.
    private static func parseVSCode(_ data: Data, fallbackName: String) -> ThemeSpec? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var out = "", inString = false, escaped = false
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            let next = text.index(after: i) < text.endIndex ? text[text.index(after: i)] : nil
            if inString {
                out.append(c)
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else if c == "/" && next == "/" {
                while i < text.endIndex && text[i] != "\n" { i = text.index(after: i) }
                continue
            } else if c == "/" && next == "*" {
                i = text.index(i, offsetBy: 2)
                while i < text.endIndex, !(text[i] == "*" && text.index(after: i) < text.endIndex && text[text.index(after: i)] == "/") { i = text.index(after: i) }
                i = text.index(i, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
                continue
            } else {
                if c == "\"" { inString = true }
                out.append(c)
            }
            i = text.index(after: i)
        }
        let cleaned = out.replacingOccurrences(of: #",(\s*[}\]])"#, with: "$1", options: .regularExpression)
        guard cleaned != text, let again = cleaned.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: again)) is [String: Any] else { return nil }
        return parse(again, fallbackName: fallbackName)
    }

    // MARK: Writing

    /// A theme as Solanum writes it, the Mac's format, so the file works on both.
    static func json(_ spec: ThemeSpec) -> Data {
        var j: [String: Any] = ["name": spec.name, "background": spec.background, "foreground": spec.foreground, "accent": spec.accent]
        let colors = ThemeColors(spec)
        func hex(_ rgb: UInt32) -> String { String(format: "#%06X", rgb) }
        j["ansi"] = colors.ansi.prefix(16).map(hex)
        j["cursor"] = spec.cursor ?? spec.accent
        if let s = spec.selection { j["selection"] = s }
        if let b = spec.background2 { j["background2"] = b }
        if let c = spec.chrome { j["chrome"] = c }
        if let icon = spec.icon { j["icon"] = icon }
        if let image = spec.image {
            j["background-image"] = image.file
            j["background-image-blur"] = (image.blur * 10).rounded() / 10
            j["background-image-tint"] = (image.tint * 100).rounded() / 100
        }
        return (try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    /// `base`, or "base 2", "base 3"… so no two themes share a name; `except` is a name that may be kept (a theme's own,
    /// when it's renamed).
    static func uniqueName(_ base: String, except: String? = nil) -> String {
        let taken = Set(AppSettings.shared.allThemes.map { $0.name.lowercased() }).subtracting([except?.lowercased() ?? ""])
        let trimmed = base.trimmingCharacters(in: .whitespaces).isEmpty ? "My Theme" : base.trimmingCharacters(in: .whitespaces)
        if !taken.contains(trimmed.lowercased()) { return trimmed }
        var n = 2
        while taken.contains("\(trimmed) \(n)".lowercased()) { n += 1 }
        return "\(trimmed) \(n)"
    }

    /// A file in the folder that isn't taken yet, named after `name`.
    private static func newFile(for name: String) -> URL? {
        guard let dir = folder else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce(into: "") { $0.append($1) }
        let base = slug.isEmpty ? "theme" : slug
        var url = dir.appendingPathComponent(base + ".json"), n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base)-\(n).json")
            n += 1
        }
        return url
    }

    /// A new theme copied from `base`, named "My …" (a custom theme keeps its name, numbered); its file.
    static func duplicate(_ base: ThemeSpec) -> (name: String, file: URL)? {
        let isCustom = AppSettings.shared.customThemes.contains { $0.name == base.name }
        let name = uniqueName(isCustom ? base.name : "My \(base.name)")
        var copy = ThemeSpec(name: name, bg: base.background, bg2: base.background2, fg: base.foreground, cursor: base.cursor,
                             selection: base.selection, accent: base.accent, chrome: base.chrome, ansi: base.ansi)
        copy.image = base.image
        copy.icon = base.icon
        guard let url = newFile(for: name), (try? json(copy).write(to: url, options: .atomic)) != nil else { return nil }
        AppSettings.shared.reloadThemes()
        return (name, url)
    }

    /// A theme file from elsewhere (Solanum's, a Windows Terminal scheme or a VS Code theme), copied into the folder in
    /// Solanum's format; the theme's name, or nil if it isn't one.
    static func importFile(_ path: String) -> String? {
        let fallback = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        guard let data = FileManager.default.contents(atPath: path), let spec = parse(data, fallbackName: fallback) else { return nil }
        let name = uniqueName(spec.name)
        let renamed = ThemeSpec(name: name, bg: spec.background, bg2: spec.background2, fg: spec.foreground, cursor: spec.cursor,
                                selection: spec.selection, accent: spec.accent, chrome: spec.chrome, ansi: spec.ansi)
        guard let url = newFile(for: name), (try? json(renamed).write(to: url, options: .atomic)) != nil else { return nil }
        AppSettings.shared.reloadThemes()
        return name
    }

    /// A custom theme written to its file, as the editor in Settings changes it, and shown in every window.
    static func save(_ spec: ThemeSpec, to file: URL) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? json(spec).write(to: file, options: .atomic)
        AppSettings.shared.reloadThemes()
    }

    /// To the Recycle Bin, where it can be brought back from.
    static func delete(_ name: String) {
        guard let url = AppSettings.shared.customThemeFiles[name] else { return }
        _ = FileOps.recycle([url.path])
        AppSettings.shared.reloadThemes()
        // The theme in use goes back to Solanum's own.
        if AppSettings.shared.file["theme"]?.caseInsensitiveCompare(name) == .orderedSame { AppSettings.shared.set("theme", ThemeSpecs.defaultName) }
    }

    /// Windows' Open dialog, for a theme file to import. Nil if nothing was picked.
    static func pickFile(owner: HWND?) -> String? {
        pickFile(owner: owner, title: "Import Theme", filter: "Themes (*.json)\u{0}*.json\u{0}All files\u{0}*.*\u{0}\u{0}")
    }

    /// A picture for a theme's background.
    /// A picture for a theme's icon: a PNG, JPEG or (animated) GIF.
    static func pickIcon(owner: HWND?) -> String? {
        pickFile(owner: owner, title: "Choose an Icon", filter: "Pictures\u{0}*.png;*.jpg;*.jpeg;*.gif;*.bmp\u{0}All files\u{0}*.*\u{0}\u{0}")
    }

    static func pickImage(owner: HWND?) -> String? {
        pickFile(owner: owner, title: "Choose a Background Picture",
                 filter: "Pictures\u{0}*.jpg;*.jpeg;*.png;*.bmp;*.gif;*.webp;*.heic;*.tif;*.tiff\u{0}All files\u{0}*.*\u{0}\u{0}")
    }

    static func pickFile(owner: HWND?, title titleText: String, filter filterText: String) -> String? {
        var buffer = [UInt16](repeating: 0, count: 4096)
        var filter = Array(filterText.utf16)
        var title = wide(titleText)
        let picked = buffer.withUnsafeMutableBufferPointer { file -> Bool in
            filter.withUnsafeMutableBufferPointer { filterText -> Bool in
                title.withUnsafeMutableBufferPointer { titleText -> Bool in
                    var info = OPENFILENAMEW()
                    info.lStructSize = DWORD(MemoryLayout<OPENFILENAMEW>.size)
                    info.hwndOwner = owner
                    info.lpstrFile = file.baseAddress
                    info.nMaxFile = DWORD(file.count)
                    info.lpstrFilter = UnsafePointer(filterText.baseAddress)
                    info.lpstrTitle = UnsafePointer(titleText.baseAddress)
                    info.Flags = DWORD(OFN_EXPLORER | OFN_FILEMUSTEXIST | OFN_NOCHANGEDIR)
                    return GetOpenFileNameW(&info)
                }
            }
        }
        guard picked, let end = buffer.firstIndex(of: 0), end > 0 else { return nil }
        return String(decoding: buffer[..<end], as: UTF16.self)
    }
}

extension ThemeSpec {
    /// A copy with some colors changed. A `nil` gradient, cursor or selection removes it; leaving one out keeps it.
    func with(name: String? = nil, background: String? = nil, background2: String?? = nil, foreground: String? = nil,
              cursor: String?? = nil, selection: String?? = nil, accent: String? = nil, ansi: [String]? = nil,
              image: ThemeImage?? = nil, icon: String?? = nil) -> ThemeSpec {
        var spec = ThemeSpec(name: name ?? self.name, bg: background ?? self.background, bg2: background2 ?? self.background2,
                             fg: foreground ?? self.foreground, cursor: cursor ?? self.cursor, selection: selection ?? self.selection,
                             accent: accent ?? self.accent, chrome: chrome, ansi: ansi ?? self.ansi)
        spec.image = image ?? self.image
        spec.icon = icon ?? self.icon
        return spec
    }
}
