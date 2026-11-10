import AppKit
import CoreImage

/// What shows behind everything in a window, as on Windows (see `BackgroundView`):
/// - `picture`: the theme's own picture (Settings › Appearance › Edit Theme › Background picture), cropped to fill the
///   window and blurred as the theme has it, with the theme's background color over it as much as its tint says. The
///   window is solid then: the see-through setting is for themes without one.
/// - `wallpaper`: with the background see-through and Settings' What shows through on Your Wallpaper, the desktop's
///   picture, drawn by Solanum lined up with the screen (so it looks the same in front or not) and blurred if Blur is on.
/// - `none`: the window is see-through to whatever's behind it (blurred by the system, if Blur is on), or solid.
enum Backdrop: Equatable {
    case none
    case picture(URL, ThemeImage)
    case wallpaper(URL, WallpaperOptions)

    /// For the window on `screen` now.
    static func current(screen: NSScreen?) -> Backdrop {
        let cfg = Config.shared
        if let image = cfg.theme.image, let url = ThemeLibrary.imageURL(image), FileManager.default.fileExists(atPath: url.path) {
            return .picture(url, image)
        }
        if cfg.opacity < 1, cfg.seeThrough == "wallpaper", let w = wallpaper(screen) {
            return .wallpaper(w.url, WallpaperOptions(fits: (w.options[.allowClipping] as? Bool) == false, fill: w.options[.fillColor] as? NSColor))
        }
        return .none
    }

    /// The desktop's picture on `screen` and how it's placed. Not in a headless run (which keeps out of the system's
    /// settings) unless SOLANUM_WALLPAPER names a picture to stand in for it.
    static func wallpaper(_ screen: NSScreen?) -> (url: URL, options: [NSWorkspace.DesktopImageOptionKey: Any])? {
        if let fake = ProcessInfo.processInfo.environment["SOLANUM_WALLPAPER"] { return (URL(fileURLWithPath: fake), [:]) }
        guard !Headless.active, let screen, var url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        // An Aerial wallpaper (.madesktop, a moving one): the still macOS keeps beside it.
        if url.pathExtension == "madesktop" {
            url = url.deletingLastPathComponent().appendingPathComponent(".thumbnails")
                .appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".heic")
        }
        // One that can't be read (or isn't there): the window's see-through as usual instead.
        guard FileManager.default.fileExists(atPath: url.path), CIImage(contentsOf: url) != nil else { return nil }
        return (url, NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:])
    }

    static func == (a: Backdrop, b: Backdrop) -> Bool {
        switch (a, b) {
        case (.none, .none): return true
        case (.picture(let u1, let i1), .picture(let u2, let i2)): return u1 == u2 && i1 == i2
        case (.wallpaper(let u1, _), .wallpaper(let u2, _)): return u1 == u2
        default: return false
        }
    }
}

/// How the desktop's picture is placed: cropped to fill the screen, or fitted inside it on a color.
struct WallpaperOptions: Equatable {
    var fits = false
    var fill: NSColor?
}

/// Pictures for `Backdrop`, blurred once and kept until what they're made from or their size changes.
enum BackdropImages {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static var cache: [String: CGImage] = [:]

    /// `url`'s picture at `size` points (times `scale` pixels): cropped to fill it (`fit`: fitted inside it instead,
    /// on `fill`), blurred by `blur` points.
    static func image(_ url: URL, size: NSSize, scale: CGFloat, blur: CGFloat, fit: Bool = false, fill: NSColor? = nil) -> CGImage? {
        guard size.width >= 1, size.height >= 1 else { return nil }
        // Sizes in steps, so resizing the window doesn't remake it every frame; it's drawn into the exact size.
        let px = NSSize(width: (size.width * scale / 32).rounded(.up) * 32, height: (size.height * scale / 32).rounded(.up) * 32)
        let modified = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(modified)|\(Int(px.width))x\(Int(px.height))|\(blur * scale)|\(fit)|\(fill?.hexString ?? "")"
        if let hit = cache[key] { return hit }
        guard let source = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
        let e = source.extent
        let zoom = fit ? min(px.width / e.width, px.height / e.height) : max(px.width / e.width, px.height / e.height)
        var img = source.transformed(by: CGAffineTransform(scaleX: zoom, y: zoom))
        img = img.transformed(by: CGAffineTransform(translationX: (px.width - img.extent.width) / 2 - img.extent.minX,
                                                    y: (px.height - img.extent.height) / 2 - img.extent.minY))
        let target = CGRect(origin: .zero, size: px)
        if fit, let fill, let c = CIColor(color: fill) {
            img = img.composited(over: CIImage(color: c).cropped(to: target))
        }
        if blur > 0 {
            img = img.clampedToExtent().applyingGaussianBlur(sigma: Double(blur * scale) / 2)
        }
        guard let made = context.createCGImage(img.cropped(to: target), from: target) else { return nil }
        // Only the latest few: a picture's an image the size of the window.
        if cache.count > 6 { cache.removeAll() }
        cache[key] = made
        return made
    }

    /// A picture copied into the themes folder for `theme`, so the theme keeps it wherever the original goes; its name
    /// there (as Windows names it).
    static func importImage(_ path: String, for theme: String) -> String? {
        let dir = Config.shared.themesDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        let slug = theme.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce(into: "") { $0.append($1) }
        let base = slug.isEmpty ? "theme" : slug, suffix = ext.isEmpty ? "jpg" : ext
        var name = "\(base)-background.\(suffix)", n = 2
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) {
            name = "\(base)-background-\(n).\(suffix)"
            n += 1
        }
        guard (try? FileManager.default.copyItem(atPath: path, toPath: dir.appendingPathComponent(name).path)) != nil else { return nil }
        return name
    }
}
