import CCanvas
import Foundation
import WinSDK

/// File and folder icons for the sidebars, file tabs and git pages, as on the Mac (IconPacks.swift there): Solanum's own,
/// or a VS Code file icon theme. Packs are unpacked VS Code extensions (a .vsix's `extension` folder), one folder each in
/// %APPDATA%\Solanum\icon-packs; one extension can hold several themes (Catppuccin's flavors). `file-icons` in the
/// config names the theme in use by its id. What a theme says is read by Core (IconThemeData.swift), shared with the Mac.
enum IconPacks {
    /// The packs folder, with "/" between parts (as Core's readers take paths).
    static var folder: String? {
        folderOverride ?? AppSettings.folder.map { $0.appendingPathComponent("icon-packs").path.replacingOccurrences(of: "\\", with: "/") }
    }
    /// For tests: packs kept somewhere else than the settings folder.
    static var folderOverride: String? { didSet { reload() } }

    private(set) static var installed: [IconPackEntry] = folder.map { IconPackEntry.scan(packsFolder: $0) } ?? []
    private static var loaded: (id: String, theme: IconThemeManifest?)?
    /// The pack being downloaded, for Settings to say.
    private(set) static var downloading: String?

    /// The theme showing (see `IconPackCatalog.shownID`): Catppuccin follows the theme's light or dark.
    static var shownID: String {
        IconPackCatalog.shownID(setting: AppSettings.shared.fileIcons, isDark: ThemeColors(AppSettings.shared.theme).isDark)
    }

    /// The theme in use, or nil for Solanum's own icons (also when the one set is missing or can't be read).
    static var current: IconThemeManifest? {
        let id = shownID
        guard id != IconPackCatalog.solanumID else { return nil }
        if let loaded, loaded.id == id { return loaded.theme }
        let theme = installed.first { $0.id == id }.flatMap(IconThemeManifest.init)
        loaded = (id, theme)
        return theme
    }

    static func label(for id: String) -> String? {
        id == IconPackCatalog.solanumID ? "Solanum" : installed.first { $0.id == id }?.label
    }

    static var flavorNote: String? { IconPackCatalog.flavorNote(setting: AppSettings.shared.fileIcons, label: label(for:)) }

    static func reload() {
        installed = folder.map { IconPackEntry.scan(packsFolder: $0) } ?? []
        loaded = nil
    }

    // MARK: Installing

    struct InstallError: Error {
        let message: String
    }

    /// Installs a VS Code icon theme extension from a .vsix (a zip) or an unpacked extension folder, replacing an earlier
    /// copy of the same extension. Its themes. Reads and writes files: off the window's thread.
    static func install(from path: String) throws -> [IconPackEntry] {
        let fm = FileManager.default
        guard let packs = folder else { throw InstallError(message: "There's no settings folder to keep it in.") }
        let temp = NSTemporaryDirectory().replacingOccurrences(of: "\\", with: "/") + "/solanum-icons-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: temp) }
        var isDir: ObjCBool = false
        _ = fm.fileExists(atPath: path, isDirectory: &isDir)
        var root = path.replacingOccurrences(of: "\\", with: "/")
        if !isDir.boolValue {
            try fm.createDirectory(atPath: temp, withIntermediateDirectories: true)
            // A .vsix is a zip; Windows' own tar unpacks those.
            guard unzip(path, into: temp) else { throw InstallError(message: "Couldn't unpack it: it doesn't look like a .vsix file.") }
            // Packs are only read, never run, but links could still point the reader outside the pack.
            if let e = fm.enumerator(at: URL(fileURLWithPath: temp), includingPropertiesForKeys: [.isSymbolicLinkKey]) {
                for case let f as URL in e where (try? f.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                    try? fm.removeItem(at: f)
                }
            }
            root = temp
        }
        if fm.fileExists(atPath: root + "/extension/package.json") { root += "/extension" }
        guard !IconPackEntry.themes(inExtension: root).isEmpty else {
            throw InstallError(message: "This isn't a VS Code file icon theme: its package.json lists no iconThemes.")
        }
        let name = IconPackCatalog.folderName(packageJSON: fm.contents(atPath: root + "/package.json")) ?? UUID().uuidString
        let dest = packs + "/" + name
        try fm.createDirectory(atPath: packs, withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest) { try fm.removeItem(atPath: dest) }
        try fm.copyItem(atPath: root, toPath: dest)
        let added = IconPackEntry.themes(inExtension: dest)
        return added
    }

    /// Unpacks a zip with Windows' tar (Windows 10 1803 and later), waiting for it.
    private static func unzip(_ zip: String, into folder: String) -> Bool {
        let tar = (ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows") + "\\System32\\tar.exe"
        let done = DispatchSemaphore(value: 0)
        var code: Int32 = -1
        guard let p = HiddenProcess(executable: tar, arguments: ["-xf", zip.replacingOccurrences(of: "/", with: "\\"), "-C", folder.replacingOccurrences(of: "/", with: "\\")],
                                    extraEnvironment: [:]) else { return false }
        p.onExit = { c in code = c; done.signal() }
        return done.wait(timeout: .now() + 120) == .success && code == 0
    }

    /// Downloads and installs a catalog pack, then switches to its first theme. `post` runs work on the window's thread;
    /// `changed` is called there when it starts and ends, `done` with what went wrong, if anything.
    static func download(_ label: String, _ source: IconPackCatalog.Source, post: @escaping (@escaping () -> Void) -> Void,
                         changed: @escaping () -> Void, done: @escaping (String?) -> Void) {
        guard downloading == nil else { return }
        downloading = label
        changed()
        Thread.detachNewThread {
            var problem: String?
            var themes: [IconPackEntry] = []
            do {
                themes = try fetchAndInstall(source)
            } catch let e as InstallError {
                problem = e.message
            } catch {
                problem = error.localizedDescription
            }
            post {
                downloading = nil
                reload()
                if problem == nil, let first = themes.first { AppSettings.shared.set("file-icons", first.id) }
                changed()
                done(problem)
            }
        }
    }

    /// Downloads a catalog pack and installs it, waiting for both: off the window's thread.
    static func fetchAndInstall(_ source: IconPackCatalog.Source) throws -> [IconPackEntry] {
        let fm = FileManager.default
        let temp = NSTemporaryDirectory().replacingOccurrences(of: "\\", with: "/") + "/solanum-icons-dl-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: temp) }
        func fetch(_ url: String, to file: String) -> Bool {
            try? fm.createDirectory(atPath: String(file[..<(file.lastIndex(of: "/") ?? file.endIndex)]), withIntermediateDirectories: true)
            return wide(url).withUnsafeBufferPointer { u in wide(file).withUnsafeBufferPointer { sol_download_file(u.baseAddress, $0.baseAddress) } } == 0
        }
        switch source {
        case .openVSX(let ns, let name):
            let info = temp + "/info.json", vsix = temp + "/\(name).vsix"
            guard fetch(IconPackCatalog.openVSXLatest(ns, name), to: info),
                  let link = fm.contents(atPath: info).flatMap(IconPackCatalog.downloadLink) else {
                throw InstallError(message: "Couldn't download it: Open VSX didn't answer, or listed no download.")
            }
            guard fetch(link, to: vsix) else { throw InstallError(message: "Couldn't download it from Open VSX.") }
            return try install(from: vsix)
        case .files(let base, let paths):
            let ext = temp + "/extension"
            for p in paths where !fetch(base + p, to: ext + "/" + p) {
                throw InstallError(message: "Couldn't download \(p).")
            }
            return try install(from: ext)
        }
    }

    /// Opens the packs folder in Explorer, making it first if there isn't one yet.
    static func openFolder() {
        guard let dir = folder else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        _ = wide(dir.replacingOccurrences(of: "/", with: "\\")).withUnsafeBufferPointer { ShellExecuteW(nil, nil, $0.baseAddress, nil, nil, 1) }
    }
}

/// Draws a file's or folder's icon from the icon pack in use, wherever Solanum shows one.
enum FileIcons {
    /// The pack's icon for `name` in a `size` square at (x, y). False when Solanum's own should be drawn instead: no pack,
    /// or nothing in it this can draw.
    @discardableResult
    static func draw(name: String, directory: Bool, expanded: Bool = false, x: Float, y: Float, size: Float, on canvas: Canvas, alpha: Float = 1) -> Bool {
        guard let theme = IconPacks.current else { return false }
        let light = !TerminalPalette.isDark
        for icon in theme.candidates(forName: name, directory: directory, expanded: expanded, light: light) {
            switch icon {
            case .file(let path):
                if path.lowercased().hasSuffix(".svg") {
                    guard let svg = resource("svg|" + path, on: canvas, { data in data.withUnsafeBytes { sol_canvas_load_svg(canvas.raw, $0.bindMemory(to: UInt8.self).baseAddress, Int32($0.count)) } }) else { continue }
                    if sol_canvas_draw_svg(canvas.raw, svg, x.rounded(), y.rounded(), size.rounded()) == 1 { return true }
                } else {
                    guard let image = resource("image|" + path, on: canvas, { data in data.withUnsafeBytes { sol_canvas_load_image(canvas.raw, $0.bindMemory(to: UInt8.self).baseAddress, Int32($0.count)) } }) else { continue }
                    sol_canvas_draw_image(canvas.raw, image, x.rounded(), y.rounded(), size.rounded(), size.rounded(), alpha)
                    return true
                }
            case .glyph(let glyph, let fontID, let color):
                guard let font = theme.fonts.first(where: { $0.id == fontID }), let scalar = glyph.unicodeScalars.first else { continue }
                var face: Int32?
                for path in font.paths {
                    face = resource("font|" + path, on: canvas, { data in data.withUnsafeBytes { sol_canvas_load_icon_font(canvas.raw, $0.bindMemory(to: UInt8.self).baseAddress, Int32($0.count)) } })
                    if face != nil { break }
                }
                guard let face else { continue }
                let ink = color ?? (TerminalPalette.foreground, 0.55)
                if sol_canvas_draw_icon_glyph(canvas.raw, face, scalar.value, x, y, size, font.scale, ink.rgb, ink.alpha * alpha) == 1 { return true }
            }
        }
        return false
    }

    /// Something of the pack's made once per canvas (an SVG, an image, a font) by its file; nil when it can't be.
    private static func resource(_ key: String, on canvas: Canvas, _ make: (Data) -> Int32) -> Int32? {
        if let known = canvas.iconCache[key] { return known >= 0 ? known : nil }
        let path = String(key.drop { $0 != "|" }.dropFirst())
        let made = FileManager.default.contents(atPath: path).map(make) ?? -1
        canvas.iconCache[key] = made
        return made >= 0 ? made : nil
    }
}
