import AppKit

/// What a theme shows beside its name in the status bar and at the top right of its card in Settings: a planet, the
/// Solanum flower, or a picture of your own (an animated GIF plays).
enum ThemeIcon: Equatable {
    case planet(PlanetArt.Planet)
    case flower
    case picture(URL)

    /// A theme's icon, from its "icon" setting: "planet:<name>", "flower", "none", or a picture's file name in the
    /// themes folder (a full path works too). Without one: the planet it's named after, or the flower for Solanum
    /// Default. A picture that's gone shows nothing.
    static func of(_ t: Theme) -> ThemeIcon? {
        guard let v = t.icon, !v.isEmpty else {
            if let p = PlanetArt.planet(themeName: t.name, isVSCode: ThemeLibrary.isVSCode(t)) { return .planet(p) }
            return !t.isCustom && t.name == ThemeLibrary.solanumDefault.name ? .flower : nil
        }
        if v == "none" { return nil }
        if v == "flower" { return .flower }
        if v.hasPrefix("planet:") { return PlanetArt.Planet(rawValue: String(v.dropFirst(7))).map { .planet($0) } }
        let url = v.hasPrefix("/") ? URL(fileURLWithPath: v) : Config.shared.themesDir.appendingPathComponent(v)
        return FileManager.default.fileExists(atPath: url.path) ? .picture(url) : nil
    }

    private static var images: [String: NSImage] = [:]

    /// A picture icon, read once per version of its file. An animated GIF keeps its frames, which a
    /// `ThemeIconImageView` plays.
    static func image(_ url: URL) -> NSImage? {
        let modified = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(modified)"
        if let hit = images[key] { return hit }
        guard let img = NSImage(contentsOf: url) else { return nil }
        if images.count > 32 { images.removeAll() }
        images[key] = img
        return img
    }

    /// Draws a planet or the flower in `rect` of a flipped view (a picture is a `ThemeIconImageView` instead, so a GIF
    /// plays).
    static func draw(_ icon: ThemeIcon, in rect: NSRect, flippedHeight: CGFloat) {
        switch icon {
        case .planet(let p):
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            // The art is drawn y-up.
            ctx.saveGState()
            ctx.translateBy(x: 0, y: flippedHeight)
            ctx.scaleBy(x: 1, y: -1)
            PlanetArt.draw(p, in: ctx, rect: CGRect(x: rect.minX, y: flippedHeight - rect.maxY, width: rect.width, height: rect.height), icon: true)
            ctx.restoreGState()
        case .flower:
            SolanumArt.flowerImage(size: rect.width).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                                                          respectFlipped: true, hints: nil)
        case .picture:
            break
        }
    }

    /// The choices Settings offers for a theme's icon, as (title, setting): from its name, each planet, the flower,
    /// none. A picture of your own is picked with "Picture…".
    static var choices: [(String, String?)] {
        [("From Its Name", nil)] + PlanetArt.Planet.allCases.map { ($0.rawValue, "planet:\($0.rawValue)") }
            + [("Solanum Flower", "flower"), ("None", "none")]
    }
}

/// A theme's own picture as its icon: scaled to fit, animated if it's a GIF, and never in the way of a click.
final class ThemeIconImageView: NSImageView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        imageScaling = .scaleProportionallyUpOrDown
        animates = true
        isEditable = false
        imageFrameStyle = .none
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shows `url`'s picture at `frame`, or hides with none.
    func show(_ url: URL?, at frame: NSRect) {
        guard let url, let img = ThemeIcon.image(url) else { isHidden = true; return }
        if image !== img { image = img }
        if self.frame != frame { self.frame = frame }
        isHidden = false
    }
}
