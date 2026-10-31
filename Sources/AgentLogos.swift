import AppKit

/// Agents' logos, kept here so no files need bundling: OpenAI's mark (SVG from Simple Icons), which takes the theme's
/// color, and Gemini's star.
enum AgentLogos {
    private static func image(viewBox: Int, _ paths: String) -> NSImage? {
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(viewBox)\" height=\"\(viewBox)\" viewBox=\"0 0 \(viewBox) \(viewBox)\">\(paths)</svg>"
        return NSImage(data: Data(svg.utf8))
    }

    /// Gemini's four-point star with rounded tips, its colors blending across it: pink at the top, blue at the right,
    /// green at the bottom, yellow at the left.
    static let gemini = NSImage(size: NSSize(width: 48, height: 48), flipped: false) { r in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        let c = CGPoint(x: r.midX, y: r.midY), R = r.width / 2 * 1.05
        let dirs = [CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: -1), CGPoint(x: -1, y: 0)]
        func toward(_ from: CGPoint, _ to: CGPoint, _ d: CGFloat) -> CGPoint {
            let l = max(hypot(to.x - from.x, to.y - from.y), 0.01)
            return CGPoint(x: from.x + (to.x - from.x) / l * d, y: from.y + (to.y - from.y) / l * d)
        }
        let tips = dirs.map { CGPoint(x: c.x + $0.x * R, y: c.y + $0.y * R) }
        // Each side curves in close to the center; a tip is rounded by turning through it just short of the point.
        let waists = (0..<4).map { i in
            CGPoint(x: c.x + (dirs[i].x + dirs[(i + 1) % 4].x) * R * 0.25, y: c.y + (dirs[i].y + dirs[(i + 1) % 4].y) * R * 0.25)
        }
        let round = R * 0.17
        let star = CGMutablePath()
        star.move(to: toward(tips[0], waists[0], round))
        for i in 0..<4 {
            let next = (i + 1) % 4
            star.addQuadCurve(to: toward(tips[next], waists[i], round), control: waists[i])
            star.addQuadCurve(to: toward(tips[next], waists[next], round), control: tips[next])
        }
        star.closeSubpath()
        ctx.addPath(star)
        ctx.clip()
        // Soft pools of color from each tip, blending where they meet: (where, in radii from the center; how far it reaches; color).
        let pools: [(CGPoint, CGFloat, UInt32)] = [
            (CGPoint(x: 0.02, y: -0.80), 0.82, 0x16A155), (CGPoint(x: -0.66, y: 0.05), 1.0, 0xFFD63F), (CGPoint(x: 0, y: 0.80), 0.82, 0xF0468F),
            (CGPoint(x: 0.36, y: 0.40), 0.46, 0xC79AF0), (CGPoint(x: 0.62, y: -0.12), 0.92, 0x2F78F2),
        ]
        ctx.setFillColor(CGColor(srgbRed: 0.72, green: 0.76, blue: 0.70, alpha: 1))
        ctx.fill(r)
        for (at, reach, v) in pools {
            let (red, green, blue) = (CGFloat(v >> 16 & 0xFF) / 255, CGFloat(v >> 8 & 0xFF) / 255, CGFloat(v & 0xFF) / 255)
            let colors = [CGColor(srgbRed: red, green: green, blue: blue, alpha: 1), CGColor(srgbRed: red, green: green, blue: blue, alpha: 0.85), CGColor(srgbRed: red, green: green, blue: blue, alpha: 0)]
            guard let pool = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 0.35, 1]) else { continue }
            let center = CGPoint(x: c.x + at.x * R, y: c.y + at.y * R)
            ctx.drawRadialGradient(pool, startCenter: center, startRadius: 0, endCenter: center, endRadius: reach * R, options: [])
        }
        return true
    }

    private static var openAIs: [NSColor: NSImage] = [:]

    static func openAI(_ color: NSColor) -> NSImage? {
        if let img = openAIs[color] { return img }
        guard let c = color.usingColorSpace(.sRGB) else { return nil }
        let hex = String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
        let img = image(viewBox: 24, "<path fill=\"\(hex)\" fill-opacity=\"\(c.alphaComponent)\" d=\"M22.2819 9.8211a5.9847 5.9847 0 0 0-.5157-4.9108 6.0462 6.0462 0 0 0-6.5098-2.9A6.0651 6.0651 0 0 0 4.9807 4.1818a5.9847 5.9847 0 0 0-3.9977 2.9 6.0462 6.0462 0 0 0 .7427 7.0966 5.98 5.98 0 0 0 .511 4.9107 6.051 6.051 0 0 0 6.5146 2.9001A5.9847 5.9847 0 0 0 13.2599 24a6.0557 6.0557 0 0 0 5.7718-4.2058 5.9894 5.9894 0 0 0 3.9977-2.9001 6.0557 6.0557 0 0 0-.7475-7.0729zm-9.022 12.6081a4.4755 4.4755 0 0 1-2.8764-1.0408l.1419-.0804 4.7783-2.7582a.7948.7948 0 0 0 .3927-.6813v-6.7369l2.02 1.1686a.071.071 0 0 1 .038.052v5.5826a4.504 4.504 0 0 1-4.4945 4.4944zm-9.6607-4.1254a4.4708 4.4708 0 0 1-.5346-3.0137l.142.0852 4.783 2.7582a.7712.7712 0 0 0 .7806 0l5.8428-3.3685v2.3324a.0804.0804 0 0 1-.0332.0615L9.74 19.9502a4.4992 4.4992 0 0 1-6.1408-1.6464zM2.3408 7.8956a4.485 4.485 0 0 1 2.3655-1.9728V11.6a.7664.7664 0 0 0 .3879.6765l5.8144 3.3543-2.0201 1.1685a.0757.0757 0 0 1-.071 0l-4.8303-2.7865A4.504 4.504 0 0 1 2.3408 7.872zm16.5963 3.8558L13.1038 8.364 15.1192 7.2a.0757.0757 0 0 1 .071 0l4.8303 2.7913a4.4944 4.4944 0 0 1-.6765 8.1042v-5.6772a.79.79 0 0 0-.407-.667zm2.0107-3.0231l-.142-.0852-4.7735-2.7818a.7759.7759 0 0 0-.7854 0L9.409 9.2297V6.8974a.0662.0662 0 0 1 .0284-.0615l4.8303-2.7866a4.4992 4.4992 0 0 1 6.6802 4.66zM8.3065 12.863l-2.02-1.1638a.0804.0804 0 0 1-.038-.0567V6.0742a4.4992 4.4992 0 0 1 7.3757-3.4537l-.142.0805L8.704 5.459a.7948.7948 0 0 0-.3927.6813zm1.0976-2.3654l2.602-1.4998 2.6069 1.4998v2.9994l-2.5974 1.4997-2.6067-1.4997Z\"/>")
        openAIs[color] = img
        return img
    }
}
