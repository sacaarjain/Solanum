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

/// What hovering the theme's name in the status bar shows just above it: the theme's icon, bigger, with its name below.
final class ThemeHoverCard: NSView {
    static let iconSide: CGFloat = 44
    private static let font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
    private static let pad: CGFloat = 12
    private let pictureView = ThemeIconImageView(frame: .zero)
    private var icon: ThemeIcon?
    private var name = ""

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        addSubview(pictureView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shows `th`, and the size it needs. The Quantum Moon, while it's wandered off the status bar, isn't given away.
    func show(_ th: Theme) -> NSSize {
        let wandered = QuantumMoon.active && !QuantumMoon.at(.home)
        icon = wandered ? nil : ThemeIcon.of(th)
        name = th.name
        let nameWidth = min(220, ceil((name as NSString).size(withAttributes: [.font: Self.font]).width))
        let size = NSSize(width: max(Self.iconSide + 2 * Self.pad + 16, nameWidth + 2 * Self.pad),
                          height: Self.pad + Self.iconSide + 8 + 15 + Self.pad - 2)
        if case .picture(let url)? = icon {
            pictureView.show(url, at: iconRect(in: size))
        } else {
            pictureView.isHidden = true
        }
        needsDisplay = true
        return size
    }

    private func iconRect(in size: NSSize) -> NSRect {
        NSRect(x: ((size.width - Self.iconSide) / 2).rounded(), y: Self.pad, width: Self.iconSide, height: Self.iconSide)
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 10, cornerHeight: 10, transform: nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        let th = Config.shared.theme
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        th.surface.mix(th.isDark ? .white : .black, 0.04).setFill()
        box.fill()
        th.foreground.withAlphaComponent(th.isDark ? 0.16 : 0.18).setStroke()
        box.lineWidth = 1
        box.stroke()
        let r = iconRect(in: bounds.size)
        switch icon {
        case .planet?, .flower?:
            ThemeIcon.draw(icon!, in: r, flippedHeight: bounds.height)
        case .picture?:
            break
        case nil:
            // No icon of its own: the palette the status bar shows for it.
            let config = NSImage.SymbolConfiguration(pointSize: 26, weight: .regular).applying(.init(paletteColors: [th.dimText]))
            if let img = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                img.draw(in: NSRect(x: r.midX - img.size.width / 2, y: r.midY - img.size.height / 2, width: img.size.width, height: img.size.height))
            }
        }
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail
        (name as NSString).draw(in: NSRect(x: 8, y: r.maxY + 8, width: bounds.width - 16, height: 16),
                                withAttributes: [.font: Self.font, .foregroundColor: th.foreground, .paragraphStyle: para])
    }
}
