import AppKit

/// The Solanum flower, drawn with Core Graphics so the app icon (Tools/MakeIcon.swift), the tab bar and Settings
/// share one drawing: a five-pointed corolla with ruffled edges, pale gold midribs, and a yellow cone of anthers.
enum SolanumArt {
    /// The signature purple used for the cursor, active markers and highlights.
    static let purple = NSColor(srgbRed: 0xA7 / 255.0, green: 0x7B / 255.0, blue: 0xF3 / 255.0, alpha: 1)
    /// A deeper purple that reads on light backgrounds.
    static let purpleOnLight = NSColor(srgbRed: 0x7B / 255.0, green: 0x4F / 255.0, blue: 0xD9 / 255.0, alpha: 1)

    enum Style { case deep, pale }

    private static func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: a)
    }

    private struct Palette {
        let center: UInt32, mid: UInt32, edge: UInt32, streak: UInt32, rib: UInt32
    }

    private static func palette(_ s: Style) -> Palette {
        switch s {
        case .deep: return Palette(center: 0xB89BE6, mid: 0x7B45B8, edge: 0x45186F, streak: 0x2E0C52, rib: 0xE3D58A)
        case .pale: return Palette(center: 0xF1EEFF, mid: 0xC3BCF2, edge: 0x8D84D6, streak: 0x6159B8, rib: 0xE6DC9A)
        }
    }

    /// Draws one flower centered in `rect` (y-up). `turn` rotates it; the anther cone leans toward `coneAngle`.
    static func drawFlower(in ctx: CGContext, rect: CGRect, style: Style = .pale, turn: CGFloat = 0, coneAngle: CGFloat = -0.35) {
        let p = palette(style)
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let R = min(rect.width, rect.height) / 2
        let step = 2 * CGFloat.pi / 5
        let base = CGFloat.pi / 2 + turn   // first tip straight up
        func at(_ angle: CGFloat, _ r: CGFloat) -> CGPoint { CGPoint(x: c.x + cos(angle) * r, y: c.y + sin(angle) * r) }

        let corolla = corollaPath(center: c, radius: R, base: base)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -R * 0.03), blur: R * 0.14, color: rgb(0x0A0418, 0.5))
        ctx.addPath(corolla)
        ctx.setFillColor(rgb(p.mid))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(corolla)
        ctx.clip()
        let wash = CGGradient(colorsSpace: nil, colors: [rgb(p.center), rgb(p.center), rgb(p.mid), rgb(p.edge)] as CFArray,
                              locations: [0, 0.16, 0.6, 1])!
        ctx.drawRadialGradient(wash, startCenter: c, startRadius: 0, endCenter: c, endRadius: R, options: [.drawsAfterEndLocation])
        ctx.setLineCap(.round)
        for k in 0..<5 {
            let a = base + CGFloat(k) * step
            // Watercolor streaks fanning along each lobe.
            for (j, off) in ([-0.30, -0.17, 0.17, 0.30] as [CGFloat]).enumerated() {
                ctx.move(to: at(a + off * 0.35, R * 0.22))
                ctx.addQuadCurve(to: at(a + off * 1.05, R * (0.74 - CGFloat(j % 2) * 0.08)), control: at(a + off * 0.8, R * 0.46))
            }
            ctx.setStrokeColor(rgb(p.streak, 0.20))
            ctx.setLineWidth(max(0.5, R * 0.035))
            ctx.strokePath()
            // A pale fold on one side of each midrib.
            let fold = CGMutablePath()
            fold.move(to: at(a, R * 0.16))
            fold.addQuadCurve(to: at(a, R * 0.92), control: at(a + step * 0.22, R * 0.5))
            fold.addQuadCurve(to: at(a, R * 0.16), control: at(a + step * 0.06, R * 0.5))
            ctx.addPath(fold)
            ctx.setFillColor(rgb(0xFFFFFF, style == .pale ? 0.28 : 0.13))
            ctx.fillPath()
            // Pale gold midrib out to the tip.
            ctx.move(to: at(a, R * 0.12))
            ctx.addQuadCurve(to: at(a + 0.02, R * 0.95), control: at(a - 0.05, R * 0.55))
            ctx.setStrokeColor(rgb(p.rib, 0.9))
            ctx.setLineWidth(max(0.6, R * 0.03))
            ctx.strokePath()
        }
        // Darker rim, like pigment pooling at the edge of a wash.
        ctx.addPath(corolla)
        ctx.setStrokeColor(rgb(p.streak, 0.35))
        ctx.setLineWidth(max(0.6, R * 0.04))
        ctx.strokePath()
        ctx.restoreGState()

        // Anther cone: a ridged golden spindle leaning to one side.
        let coneLen = R * 0.52, coneW = R * 0.30
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.rotate(by: coneAngle)
        let cone = CGMutablePath()
        cone.move(to: CGPoint(x: -coneLen * 0.18, y: 0))
        cone.addCurve(to: CGPoint(x: coneLen, y: 0), control1: CGPoint(x: -coneLen * 0.18, y: coneW * 0.75),
                      control2: CGPoint(x: coneLen * 0.55, y: coneW * 0.55))
        cone.addCurve(to: CGPoint(x: -coneLen * 0.18, y: 0), control1: CGPoint(x: coneLen * 0.55, y: -coneW * 0.55),
                      control2: CGPoint(x: -coneLen * 0.18, y: -coneW * 0.75))
        cone.closeSubpath()
        ctx.setShadow(offset: CGSize(width: 0, height: -R * 0.02), blur: R * 0.08, color: rgb(0x3A2400, 0.55))
        ctx.addPath(cone)
        ctx.setFillColor(rgb(0xEBC23A))
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.addPath(cone)
        ctx.clip()
        let gold = CGGradient(colorsSpace: nil, colors: [rgb(0xFFF6B0), rgb(0xF5D04A), rgb(0xC98F10)] as CFArray, locations: [0, 0.45, 1])!
        ctx.drawLinearGradient(gold, start: CGPoint(x: 0, y: coneW * 0.5), end: CGPoint(x: 0, y: -coneW * 0.5), options: [])
        // Ridges where the anthers meet.
        for f in [-0.55, -0.2, 0.15, 0.5] as [CGFloat] {
            ctx.move(to: CGPoint(x: -coneLen * 0.1, y: coneW * f * 0.8))
            ctx.addQuadCurve(to: CGPoint(x: coneLen * 0.98, y: 0), control: CGPoint(x: coneLen * 0.45, y: coneW * f * 0.75))
        }
        ctx.setStrokeColor(rgb(0x9A6A08, 0.55))
        ctx.setLineWidth(max(0.5, R * 0.018))
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// Corolla outline in polar form: broad lobes narrowing to pointed tips, with a ruffled edge (`ruffled` false
    /// leaves it smooth, for small sizes).
    private static func corollaPath(center c: CGPoint, radius R: CGFloat, base: CGFloat, ruffled: Bool = true) -> CGMutablePath {
        let step = 2 * CGFloat.pi / 5
        let path = CGMutablePath()
        let samples = 400
        for i in 0...samples {
            let a = base + CGFloat(i) / CGFloat(samples) * 2 * .pi
            var d = (a - base).truncatingRemainder(dividingBy: step)
            if d < 0 { d += step }
            let t = abs(d - step / 2) / (step / 2)          // 1 at a tip, 0 in a notch
            let lobe = pow(sin(t * .pi / 2), 0.9)
            let tip = pow(t, 14) * 0.10                       // drawn-out, pointed tips
            let ruffle = ruffled ? sin(a * 46 + 0.7) * 0.018 * (1 - t * 0.7) + sin(a * 23) * 0.012 : 0
            let r = R * (0.42 + 0.48 * lobe + tip + ruffle)
            let pt = CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        path.closeSubpath()
        return path
    }

    /// The flower as a line drawing in one color (y-up): the corolla, a midrib into each lobe, and the anther cone.
    /// Solanum Default's mark in the status bar.
    static func drawOutline(in ctx: CGContext, rect: CGRect, color: CGColor, lineWidth: CGFloat) {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let R = min(rect.width, rect.height) / 2 - lineWidth / 2
        let base = CGFloat.pi / 2
        ctx.saveGState()
        ctx.setStrokeColor(color)
        ctx.setLineWidth(lineWidth)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.addPath(corollaPath(center: c, radius: R, base: base, ruffled: false))
        for k in 0..<5 {
            let a = base + CGFloat(k) * 2 * .pi / 5
            ctx.move(to: CGPoint(x: c.x + cos(a) * R * 0.34, y: c.y + sin(a) * R * 0.34))
            ctx.addLine(to: CGPoint(x: c.x + cos(a) * R * 0.66, y: c.y + sin(a) * R * 0.66))
        }
        ctx.strokePath()
        // The cone, leaning the way the full flower's does.
        ctx.translateBy(x: c.x, y: c.y)
        ctx.rotate(by: -0.35)
        let len = R * 0.5, w = R * 0.3
        ctx.move(to: CGPoint(x: -len * 0.18, y: 0))
        ctx.addCurve(to: CGPoint(x: len, y: 0), control1: CGPoint(x: -len * 0.18, y: w * 0.75), control2: CGPoint(x: len * 0.55, y: w * 0.55))
        ctx.addCurve(to: CGPoint(x: -len * 0.18, y: 0), control1: CGPoint(x: len * 0.55, y: -w * 0.55), control2: CGPoint(x: -len * 0.18, y: -w * 0.75))
        ctx.closePath()
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// The pale flower as an image, for the tab bar and Settings.
    static func flowerImage(size: CGFloat, style: Style = .pale) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            if let ctx = NSGraphicsContext.current?.cgContext { drawFlower(in: ctx, rect: r, style: style) }
            return true
        }
    }

    /// The app icon in a 1024×1024 space (y up): two flowers, deep violet behind pale lavender, on a night-violet squircle.
    static func drawIcon(in ctx: CGContext) {
        let body = CGRect(x: 100, y: 100, width: 824, height: 824)
        let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.45))
        ctx.addPath(bodyPath)
        ctx.setFillColor(rgb(0x160C2A))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(bodyPath)
        ctx.clip()
        let bg = CGGradient(colorsSpace: nil, colors: [rgb(0x34205C), rgb(0x1A0F33), rgb(0x0C0718)] as CFArray, locations: [0, 0.55, 1])!
        ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
        let glow = CGGradient(colorsSpace: nil, colors: [rgb(0xB084FF, 0.45), rgb(0x8B5CF6, 0.14), rgb(0x8B5CF6, 0)] as CFArray,
                              locations: [0, 0.45, 1])!
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 540, y: 520), startRadius: 0, endCenter: CGPoint(x: 540, y: 520),
                               endRadius: 480, options: [])
        let hl = CGGradient(colorsSpace: nil, colors: [rgb(0xFFFFFF, 0.10), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(hl, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 640), options: [])

        drawFlower(in: ctx, rect: CGRect(x: 395 - 235, y: 450 - 235, width: 470, height: 470), style: .deep, turn: 0.35, coneAngle: -0.15)
        drawFlower(in: ctx, rect: CGRect(x: 610 - 275, y: 560 - 275, width: 550, height: 550), style: .pale, turn: -0.12, coneAngle: -0.25)
        ctx.restoreGState()

        ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 2, dy: 2), cornerWidth: 184, cornerHeight: 184, transform: nil))
        ctx.setStrokeColor(rgb(0xFFFFFF, 0.12))
        ctx.setLineWidth(4)
        ctx.strokePath()
    }
}
