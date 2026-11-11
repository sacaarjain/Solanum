import AppKit

// The planets on the Mac: the pixels Core/PlanetArt.swift makes, as images drawn into the status bar.

extension PlanetArt {
    /// The theme's planet: the one picked as its icon, else the one it's named after (a built-in planet theme, or a
    /// custom one whose name contains a planet's, e.g. "My Hourglass"). See `ThemeIcon`. The Quantum Moon's tricks
    /// follow it, picked or named.
    static func planet(for theme: Theme) -> Planet? {
        if case .planet(let p)? = ThemeIcon.of(theme) { return p }
        return nil
    }

    // MARK: Drawing

    /// Draws `planet` centered in `rect` (in a y-up context), rendered once per size and cached. An `icon` is just
    /// the planet (both twins for Hourglass) filling the square, without moons or the Lantern.
    static func draw(_ planet: Planet, in ctx: CGContext, rect: CGRect, icon: Bool = false) {
        let t = ctx.userSpaceToDeviceSpaceTransform
        let scale = max(1, CGFloat(hypot(Double(t.a), Double(t.b))))
        let side = min(rect.width, rect.height)
        let px = Int((side * scale).rounded())
        guard px >= 8, px <= 1200, let img = image(planet, pixels: px, icon: icon) else { return }
        // Rendered at the exact device size, so it lands on whole pixels unscaled and stays sharp.
        var frame = ctx.convertToDeviceSpace(CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side))
        frame.origin = CGPoint(x: frame.minX.rounded(), y: frame.minY.rounded())
        frame.size = CGSize(width: px, height: px)
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.draw(img, in: ctx.convertToUserSpace(frame))
        ctx.restoreGState()
    }

    private static var cache: [String: CGImage] = [:]

    private static func image(_ planet: Planet, pixels: Int, icon: Bool) -> CGImage? {
        let key = "\(planet.rawValue)|\(pixels)|\(icon)"
        if let c = cache[key] { return c }
        let img = render(planet, pixels: pixels, icon: icon)
        if cache.count > 24 { cache.removeAll() }
        cache[key] = img
        return img
    }

    private static func render(_ planet: Planet, pixels S: Int, icon: Bool) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(pixels(planet, size: S, icon: icon)) as CFData) else { return nil }
        return CGImage(width: S, height: S, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: S * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
