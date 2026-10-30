import AppKit
import Compression

/// File and folder icons for the sidebar and editor tabs: Solanum's own (SF Symbols in the theme's colors), or a
/// VS Code file icon theme. Packs are unpacked VS Code extensions (a .vsix's `extension` folder) kept in
/// ~/.config/solanum/icon-packs/<publisher.name>/; one extension can hold several themes (Catppuccin's flavors).
/// `file-icons` in the config names the theme in use by its id.
enum IconPacks {
    static let solanumID = "solanum"
    static var dir: URL { Config.shared.dir.appendingPathComponent("icon-packs") }

    struct Entry {
        let id: String
        let label: String
        let manifest: URL
        /// The extension folder: icon paths may not reach outside it.
        let root: URL
    }

    /// Themes in the installed packs, by label.
    private(set) static var installed: [Entry] = scan()
    private static var loaded: (id: String, theme: VSCodeIconTheme?)?
    /// Set while a pack downloads, for Settings to show.
    private(set) static var downloading: String?

    /// The theme in use, or nil for Solanum's own icons (also when the configured one is missing or unreadable).
    static var current: VSCodeIconTheme? {
        let id = Config.shared.fileIcons
        if let loaded, loaded.id == id { return loaded.theme }
        let theme = installed.first { $0.id == id }.flatMap(VSCodeIconTheme.init)
        loaded = (id, theme)
        return theme
    }

    static func label(for id: String) -> String? {
        id == solanumID ? "Solanum" : installed.first { $0.id == id }?.label
    }

    static func reload() {
        installed = scan()
        loaded = nil
    }

    private static func scan() -> [Entry] {
        let fm = FileManager.default
        let packs = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var seen = Set<String>()
        return packs.flatMap(themes(in:)).filter { seen.insert($0.id).inserted }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    /// The icon themes an extension folder declares in its package.json.
    private static func themes(in root: URL) -> [Entry] {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("package.json")),
              let pkg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = (pkg["contributes"] as? [String: Any])?["iconThemes"] as? [[String: Any]] else { return [] }
        // Labels like "%themeLabel%" are looked up in package.nls.json.
        let nls = (try? Data(contentsOf: root.appendingPathComponent("package.nls.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        return list.compactMap { t in
            guard let id = t["id"] as? String, id != solanumID, let path = t["path"] as? String else { return nil }
            var label = t["label"] as? String ?? id
            if label.count > 2, label.hasPrefix("%"), label.hasSuffix("%") {
                let v = nls[String(label.dropFirst().dropLast())]
                label = v as? String ?? (v as? [String: Any])?["message"] as? String ?? id
            }
            let manifest = root.appendingPathComponent(path).standardizedFileURL
            guard manifest.path.hasPrefix(root.standardizedFileURL.path + "/") else { return nil }
            return Entry(id: id, label: label, manifest: manifest, root: root.standardizedFileURL)
        }
    }

    // MARK: Installing

    enum InstallError: LocalizedError {
        case notIconTheme, unpack(String), download(String)
        var errorDescription: String? {
            switch self {
            case .notIconTheme: return "This isn't a VS Code file icon theme: its package.json lists no iconThemes."
            case .unpack(let s): return "Couldn't unpack it. \(s)"
            case .download(let s): return "Couldn't download it. \(s)"
            }
        }
    }

    /// Installs a VS Code icon theme extension from a .vsix (a zip) or an unpacked extension folder, replacing an
    /// earlier copy of the same extension. Returns its themes.
    @discardableResult
    static func install(from url: URL) throws -> [Entry] {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("solanum-icons-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        var isDir: ObjCBool = false
        fm.fileExists(atPath: url.path, isDirectory: &isDir)
        var root: URL
        if isDir.boolValue {
            root = url
        } else {
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-x", "-k", url.path, tmp.path]
            p.standardError = Pipe()
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw InstallError.unpack("It doesn't look like a .vsix file.") }
            // Packs are only read, never run, but links could still point the reader outside the pack.
            if let e = fm.enumerator(at: tmp, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
                for case let f as URL in e where (try? f.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                    try? fm.removeItem(at: f)
                }
            }
            root = tmp
        }
        if fm.fileExists(atPath: root.appendingPathComponent("extension/package.json").path) { root = root.appendingPathComponent("extension") }
        guard !themes(in: root).isEmpty else { throw InstallError.notIconTheme }

        let pkg = (try? Data(contentsOf: root.appendingPathComponent("package.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let raw = [pkg["publisher"] as? String, pkg["name"] as? String].compactMap { $0 }.joined(separator: ".")
        let name = String(raw.map { $0.isLetter || $0.isNumber || "-_.".contains($0) ? $0 : "-" })
        let dest = dir.appendingPathComponent(name.isEmpty || name.hasPrefix(".") ? UUID().uuidString : name)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        if root.path.hasPrefix(tmp.path) { try fm.moveItem(at: root, to: dest) } else { try fm.copyItem(at: root, to: dest) }
        reload()
        return themes(in: dest).compactMap { t in installed.first { $0.id == t.id } }
    }

    /// Packs Settings offers to download: from Open VSX, or (Seti, which ships inside VS Code) from VS Code's repository.
    enum Source {
        case openVSX(namespace: String, name: String)
        case files(base: String, paths: [String])
    }

    static let catalog: [(label: String, source: Source)] = [
        ("Material Icon Theme", .openVSX(namespace: "PKief", name: "material-icon-theme")),
        ("vscode-icons", .openVSX(namespace: "vscode-icons-team", name: "vscode-icons")),
        ("Seti (VS Code's default)", .files(base: "https://raw.githubusercontent.com/microsoft/vscode/main/extensions/theme-seti/",
                                            paths: ["package.json", "package.nls.json", "icons/vs-seti-icon-theme.json", "icons/seti.woff"])),
        ("Catppuccin Icons", .openVSX(namespace: "Catppuccin", name: "catppuccin-vsc-icons")),
        ("Symbols", .openVSX(namespace: "miguelsolorio", name: "symbols")),
    ]

    /// Downloads and installs a catalog pack, then switches to its first theme. `done` gets nil or the error.
    static func download(_ label: String, _ source: Source, done: @escaping (Error?) -> Void) {
        guard downloading == nil else { return }
        downloading = label
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("solanum-icons-dl-\(UUID().uuidString)")
        func finish(_ result: Result<URL, Error>) {
            DispatchQueue.main.async {
                downloading = nil
                defer { try? fm.removeItem(at: tmp) }
                do {
                    let entries = try install(from: result.get())
                    if let first = entries.first {
                        Config.shared.fileIcons = first.id
                        Config.shared.commit()
                    }
                    done(nil)
                } catch {
                    done(error)
                }
            }
        }
        func fetch(_ url: URL, to file: URL, then next: @escaping () -> Void) {
            URLSession.shared.downloadTask(with: url) { loc, resp, err in
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard let loc, err == nil, status == 200 else {
                    return finish(.failure(InstallError.download(err?.localizedDescription ?? "The server answered \(status).")))
                }
                do {
                    try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: loc, to: file)
                    next()
                } catch { finish(.failure(error)) }
            }.resume()
        }
        switch source {
        case .openVSX(let ns, let name):
            let api = URL(string: "https://open-vsx.org/api/\(ns)/\(name)/latest")!
            URLSession.shared.dataTask(with: api) { data, _, err in
                guard let data, let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let link = (info["files"] as? [String: Any])?["download"] as? String, let url = URL(string: link) else {
                    return finish(.failure(InstallError.download(err?.localizedDescription ?? "Open VSX didn't list a download.")))
                }
                let file = tmp.appendingPathComponent("\(name).vsix")
                fetch(url, to: file) { finish(.success(file)) }
            }.resume()
        case .files(let base, let paths):
            let folder = tmp.appendingPathComponent("extension")
            func next(_ i: Int) {
                guard i < paths.count else { return finish(.success(folder)) }
                fetch(URL(string: base + paths[i])!, to: folder.appendingPathComponent(paths[i])) { next(i + 1) }
            }
            next(0)
        }
    }
}

/// One VS Code file icon theme (https://code.visualstudio.com/api/extension-guides/file-icon-theme): icon
/// definitions (an SVG/PNG, or a glyph of a font the theme ships) and the names, extensions and languages they're for.
final class VSCodeIconTheme {
    private struct Def {
        var path: URL?
        var glyph: String?
        var color: NSColor?
        var fontID: String?
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

    private var defs: [String: Def] = [:]
    private let base: Maps
    private let light: Maps?
    private var fonts: [String: (font: CGFont, scale: CGFloat)] = [:]
    private var defaultFont: String?
    private var cache: [String: NSImage] = [:]
    private var cacheTheme = ""

    init?(_ entry: IconPacks.Entry) {
        guard let data = try? Data(contentsOf: entry.manifest),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let folder = entry.manifest.deletingLastPathComponent()
        func inside(_ rel: String) -> URL? {
            guard !rel.isEmpty else { return nil }
            let u = folder.appendingPathComponent(rel).standardizedFileURL
            return u.path.hasPrefix(entry.root.path + "/") ? u : nil
        }
        for (id, v) in j["iconDefinitions"] as? [String: [String: Any]] ?? [:] {
            defs[id] = Def(path: (v["iconPath"] as? String).flatMap(inside),
                           glyph: (v["fontCharacter"] as? String).flatMap(Self.glyph),
                           color: (v["fontColor"] as? String).flatMap(Self.color),
                           fontID: v["fontId"] as? String)
        }
        for f in j["fonts"] as? [[String: Any]] ?? [] {
            guard let id = f["id"] as? String else { continue }
            let srcs = f["src"] as? [[String: Any]] ?? []
            guard let font = srcs.lazy.compactMap({ s in (s["path"] as? String).flatMap(inside).flatMap(Self.loadFont) }).first else { continue }
            let size = (f["size"] as? String).flatMap { Double($0.replacingOccurrences(of: "%", with: "")) }.map { CGFloat($0) / 100 } ?? 1
            fonts[id] = (font, size)
            if defaultFont == nil { defaultFont = id }
        }
        base = Maps(j)
        light = (j["light"] as? [String: Any]).map(Maps.init)
    }

    /// The icon for a file or folder (16pt square), or nil when the theme has none it can draw.
    func icon(forName name: String, directory: Bool, expanded: Bool = false, light isLight: Bool) -> NSImage? {
        let theme = Config.shared.theme.name
        if theme != cacheTheme { cache.removeAll(); cacheTheme = theme }
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
        for case let k? in keys {
            if let img = image(k) { return img }
        }
        return nil
    }

    private func image(_ id: String) -> NSImage? {
        if let img = cache[id] { return img }
        guard let def = defs[id] else { return nil }
        var img: NSImage?
        if let path = def.path {
            img = NSImage(contentsOf: path)
            img?.size = NSSize(width: 16, height: 16)
        } else if let glyph = def.glyph, let fid = def.fontID ?? defaultFont, let font = fonts[fid] {
            img = Self.render(glyph, font.font, scale: font.scale, color: def.color ?? Config.shared.theme.dimText)
        }
        if let img { cache[id] = img }
        return img
    }

    /// A font glyph centered in a 16pt square. VS Code sizes font icons relative to its 13px UI font.
    private static func render(_ glyph: String, _ cg: CGFont, scale: CGFloat, color: NSColor) -> NSImage? {
        let font = CTFontCreateWithGraphicsFont(cg, 13 * scale, nil, nil)
        let chars = Array(glyph.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        guard CTFontGetGlyphsForCharacters(font, chars, &glyphs, chars.count), glyphs[0] != 0 else { return nil }
        var g = glyphs[0]
        let box = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &g, nil, 1)
        guard box.width > 0, box.height > 0 else { return nil }
        return NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            // Bigger than the square (some fonts' glyphs are): shrink to fit.
            let fit = min(1, rect.width / box.width, rect.height / box.height)
            ctx.translateBy(x: rect.midX, y: rect.midY)
            ctx.scaleBy(x: fit, y: fit)
            ctx.setFillColor(color.cgColor)
            var pos = CGPoint(x: -box.midX, y: -box.midY)
            CTFontDrawGlyphs(font, &g, &pos, 1, ctx)
            return true
        }
    }

    /// "\E001" (as VS Code themes write it) or the character itself.
    private static func glyph(_ s: String) -> String? {
        guard s.hasPrefix("\\") else { return s.isEmpty ? nil : s }
        return UInt32(s.dropFirst(), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
    }

    private static func color(_ s: String) -> NSColor? {
        var hex = s.trimmingCharacters(in: .whitespaces)
        guard hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        if hex.count == 3 || hex.count == 4 { hex = String(hex.flatMap { [$0, $0] }) }
        guard hex.count == 6 || hex.count == 8, let v = UInt64(hex, radix: 16) else { return nil }
        let rgba = hex.count == 6 ? v << 8 | 0xFF : v
        return NSColor(srgbRed: CGFloat(rgba >> 24 & 0xFF) / 255, green: CGFloat(rgba >> 16 & 0xFF) / 255,
                       blue: CGFloat(rgba >> 8 & 0xFF) / 255, alpha: CGFloat(rgba & 0xFF) / 255)
    }

    // MARK: Fonts

    /// TrueType/OpenType as is, WOFF unwrapped. WOFF2 (Brotli plus transformed outlines) isn't read.
    private static func loadFont(_ url: URL) -> CGFont? {
        guard var data = try? Data(contentsOf: url), data.count > 4 else { return nil }
        if data.prefix(4) == Data("wOFF".utf8) {
            guard let sfnt = sfnt(fromWOFF: [UInt8](data)) else { return nil }
            data = sfnt
        }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGFont(provider)
    }

    /// Rebuilds the TrueType/OpenType file a WOFF wraps: same tables, each inflated if it was compressed.
    static func sfnt(fromWOFF b: [UInt8]) -> Data? {
        func u16(_ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
        func u32(_ i: Int) -> Int { u16(i) << 16 | u16(i + 2) }
        guard b.count >= 44, u32(0) == 0x774F4646 else { return nil }
        let n = u16(12)
        guard n > 0, b.count >= 44 + n * 20 else { return nil }
        var tables: [(tag: Int, checksum: Int, data: [UInt8])] = []
        for i in 0..<n {
            let e = 44 + i * 20
            let off = u32(e + 4), comp = u32(e + 8), orig = u32(e + 12)
            guard off + comp <= b.count, comp <= orig else { return nil }
            let slice = Array(b[off..<off + comp])
            guard let data = comp == orig ? slice : inflate(slice, size: orig) else { return nil }
            tables.append((u32(e), u32(e + 16), data))
        }
        var out = [UInt8]()
        func put16(_ v: Int) { out += [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        func put32(_ v: Int) { put16(v >> 16 & 0xFFFF); put16(v & 0xFFFF) }
        var pow2 = 1, log2 = 0
        while pow2 * 2 <= n { pow2 *= 2; log2 += 1 }
        put32(u32(4)); put16(n); put16(pow2 * 16); put16(log2); put16(n * 16 - pow2 * 16)
        var offset = 12 + n * 16
        for t in tables {
            put32(t.tag); put32(t.checksum); put32(offset); put32(t.data.count)
            offset += (t.data.count + 3) & ~3
        }
        for t in tables {
            out += t.data
            out += [UInt8](repeating: 0, count: ((t.data.count + 3) & ~3) - t.data.count)
        }
        return Data(out)
    }

    /// A zlib stream (2-byte header, deflate data); Compression's ZLIB is raw deflate.
    private static func inflate(_ src: [UInt8], size: Int) -> [UInt8]? {
        guard src.count > 2 else { return nil }
        var dst = [UInt8](repeating: 0, count: size)
        let n = src.withUnsafeBufferPointer { s in
            compression_decode_buffer(&dst, size, s.baseAddress! + 2, s.count - 2, nil, COMPRESSION_ZLIB)
        }
        return n == size ? dst : nil
    }
}
