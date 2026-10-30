import AppKit

/// An easter egg for the Quantum Moon theme. Like the moon in Outer Wilds, its icon only moves while nobody is
/// looking: each time Solanum comes back to the front, the moon may have left its place beside the theme name
/// (which stays) for the flower's corner of the tab bar, or for the status bar's left side by the folder path.
/// Caught there and clicked, it shows Nomai script being read and translated: Bells' and Solanum's, taking turns.
enum QuantumMoon {
    enum Spot: CaseIterable { case home, flower, folders }

    private(set) static var spot = Spot.home
    private static var observers: [NSObjectProtocol] = []

    /// The theme is Quantum Moon with its icon showing.
    static var active: Bool { Config.shared.themeIcon && PlanetArt.planet(for: Config.shared.theme) == .quantumMoon }

    /// The moon is at `s` right now.
    static func at(_ s: Spot) -> Bool { active && spot == s }

    static func start() {
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                object: nil, queue: .main) { _ in
            guard active else { return }
            // Home half the time; otherwise one of the other spots.
            move(to: Bool.random() ? .home : [.flower, .folders].randomElement()!)
        })
    }

    static func move(to next: Spot) {
        guard next != spot else { return }
        spot = next
        if next != .folders { reading?.dismiss() }
        for w in NSApp.windows { w.contentView.map(redraw) }
    }

    private static func redraw(_ v: NSView) {
        if v is StatusBarView || v is TabBarView { v.needsDisplay = true }
        v.subviews.forEach(redraw)
    }

    // MARK: Reading

    private static let encountersKey = "QuantumMoonEncounters"
    private static weak var reading: NomaiReadingView?

    /// Clicking the moon by the folders: Nomai script rises above it and is read, as with the translator, then its
    /// words are typed out in a box. Bells' and Solanum's take turns, Bells first (the turn is kept across
    /// launches). Clicking again puts it away.
    static func toggleReading(from bar: NSView, moon: NSRect) {
        if let r = reading { r.dismiss(); return }
        guard let root = bar.window?.contentView else { return }
        let seen = UserDefaults.standard.integer(forKey: encountersKey)
        UserDefaults.standard.set(seen + 1, forKey: encountersKey)
        let bells = seen % 2 == 0
        guard let script = NomaiScript.named(bells ? "Bells" : "Solanum") else { return }
        let words = bells ? "BELLS: Be curious on your journey."
            : "SOLANUM: As a child, I considered such unknowns sinister. Now, though, I understand they bear no ill "
                + "will. The universe is, and we are."
        let v = NomaiReadingView(script: script, words: words, width: bells ? 170 : 240, readFor: bells ? 1.4 : 2.4)
        v.anchor = { [weak bar, weak root] in
            guard let bar, let root else { return nil }
            return root.convert(moon, from: bar)
        }
        v.frame = root.bounds
        v.autoresizingMask = [.width, .height]
        root.addSubview(v)
        root.needsLayout = true
        reading = v
        v.start()
    }

    /// Draws the moon in `rect` of a flipped view `height` tall (the art is drawn y-up).
    static func draw(in rect: CGRect, viewHeight height: CGFloat) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.translateBy(x: 0, y: height)
        ctx.scaleBy(x: 1, y: -1)
        PlanetArt.draw(.quantumMoon, in: ctx, rect: CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height), icon: true)
        ctx.restoreGState()
    }
}

/// Nomai script prepared by Tools/nomai_svg.py: strokes and dots in reading order, 1000 units across. Only the
/// absolute M, L, C and Z path commands that tool writes are read.
private struct NomaiScript {
    struct Mark {
        let path: CGPath
        /// Stroke width in script units; nil for a filled dot.
        let width: CGFloat?
        let center: CGPoint
    }

    let size: CGSize
    let marks: [Mark]

    private static var cache: [String: NomaiScript] = [:]

    static func named(_ name: String) -> NomaiScript? {
        if let s = cache[name] { return s }
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg"),
              let text = try? String(contentsOf: url, encoding: .utf8), let s = parse(text) else { return nil }
        cache[name] = s
        return s
    }

    private static func parse(_ svg: String) -> NomaiScript? {
        guard let vb = svg.range(of: "viewBox=\"") else { return nil }
        let box = svg[vb.upperBound...].prefix { $0 != "\"" }.split(separator: " ").compactMap { Double($0) }
        guard box.count == 4 else { return nil }
        var marks: [Mark] = []
        for chunk in svg.components(separatedBy: "<path").dropFirst() {
            guard let st = chunk.range(of: "style=\""), let dr = chunk.range(of: " d=\"") else { continue }
            let style = chunk[st.upperBound...].prefix { $0 != "\"" }
            var width: CGFloat?
            if style.contains("fill:none") {
                width = style.range(of: "stroke-width:").flatMap { Double(style[$0.upperBound...].prefix { $0 != ";" }) }.map { CGFloat($0) } ?? 2
            }
            let path = CGMutablePath()
            var cmd: Character = " ", nums: [CGFloat] = []
            func flush() {
                func pt(_ i: Int) -> CGPoint { CGPoint(x: nums[i], y: nums[i + 1]) }
                switch cmd {
                case "M": if nums.count >= 2 { path.move(to: pt(0)) }
                case "L": for i in stride(from: 0, to: nums.count - 1, by: 2) { path.addLine(to: pt(i)) }
                case "C": for i in stride(from: 0, to: nums.count - 5, by: 6) { path.addCurve(to: pt(i + 4), control1: pt(i), control2: pt(i + 2)) }
                case "Z": path.closeSubpath()
                default: break
                }
                nums = []
            }
            for tok in chunk[dr.upperBound...].prefix(while: { $0 != "\"" }).split(separator: " ") {
                if tok.count == 1, let c = tok.first, c.isLetter { flush(); cmd = c } else if let v = Double(tok) { nums.append(CGFloat(v)) }
            }
            flush()
            guard !path.isEmpty else { continue }
            let b = path.boundingBoxOfPath
            marks.append(Mark(path: path, width: width, center: CGPoint(x: b.midX, y: b.midY)))
        }
        return marks.isEmpty ? nil : NomaiScript(size: CGSize(width: box[2], height: box[3]), marks: marks)
    }
}

/// The easter egg's reading, over the whole window but only catching clicks on the wall and the box (a click anywhere
/// else puts it away, and goes through): a Nomai wall
/// pointing down at the moon like a comment bubble, the quantum symbol at its top and the script beneath, which
/// glows mark by mark from its free end to its center with a bright point at the front (the translator following
/// the line). Then the words type out in Space Mono, in a box that pops out to the right of the wall.
private final class NomaiReadingView: NSView, WindowOverlay {
    private let script: NomaiScript
    private let words: String
    private let scriptWidth: CGFloat
    private let readFor: CFTimeInterval
    /// The moon's rect in this view's superview, wherever the status bar has put it now.
    var anchor: () -> NSRect? = { nil }

    private var timer: Timer?
    private var clickMonitor: Any?
    private var started: CFTimeInterval = 0
    private var dismissedAt: CFTimeInterval?
    private var wallRect = NSRect.zero
    private var tipX: CGFloat = 0
    private var artRect = NSRect.zero
    private var scriptRect = NSRect.zero
    private var boxRect = NSRect.zero
    private static let art = Bundle.main.image(forResource: "QuantumMoon")
    /// Script rendered once unread, and the read marks added to a second bitmap as the reading reaches them.
    private var unread: CGImage?
    private var read: CGContext?
    private var readCount = 0
    private var bitmapScale: CGFloat = 0

    private static let fadeIn: CFTimeInterval = 0.3
    private static let charsPerSecond: Double = 75
    private static let frame: CGFloat = 6
    private static let arrow: CGFloat = 12
    private static let unreadColor = NSColor(srgbRed: 0.24, green: 0.45, blue: 0.95, alpha: 0.7)
    private static let readColor = NSColor(srgbRed: 0.72, green: 0.88, blue: 1, alpha: 1)
    private static let glowColor = NSColor(srgbRed: 0.45, green: 0.75, blue: 1, alpha: 0.9)
    private static let textColor = NSColor(srgbRed: 0.80, green: 0.97, blue: 0.93, alpha: 1)

    init(script: NomaiScript, words: String, width: CGFloat, readFor: CFTimeInterval) {
        self.script = script
        self.words = words
        scriptWidth = width
        self.readFor = readFor
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func start() {
        started = CACurrentMediaTime()
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] e in
            self?.clickedSomewhere(e)
            return e
        }
        run()
    }

    func dismiss() {
        guard dismissedAt == nil else { return }
        dismissedAt = CACurrentMediaTime()
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        clickMonitor = nil
        // The resize strips under it take their cursor back.
        superview?.needsLayout = true
        run()
    }

    /// A click off the wall and the box puts the reading away; the click still lands where it was aimed. One on the
    /// moon is left to the moon, which puts it away itself.
    private func clickedSomewhere(_ e: NSEvent) {
        guard e.window === window else { return dismiss() }
        let p = convert(e.locationInWindow, from: nil)
        if wallRect.contains(p) || boxRect.contains(p) { return }
        if let moon = anchor(), convert(moon, from: superview).contains(p) { return }
        dismiss()
    }

    private func run() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private var readStart: CFTimeInterval { Self.fadeIn + 0.1 }
    private var boxStart: CFTimeInterval { readStart + readFor + 0.15 }
    private var typingEnd: CFTimeInterval { boxStart + Double(words.count) / Self.charsPerSecond }

    private func tick() {
        let now = CACurrentMediaTime()
        if let d = dismissedAt, now - d > 0.2 {
            timer?.invalidate()
            removeFromSuperview()
            return
        }
        // The moon moved on, or the theme changed: the script goes with it.
        if !QuantumMoon.at(.folders) { dismiss() }
        // All typed out: nothing moves until it's dismissed.
        if dismissedAt == nil, now - started > typingEnd + 0.1 {
            timer?.invalidate()
            timer = nil
        }
        needsDisplay = true
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        place()
    }

    private func place() {
        guard let moon = anchor() else { return }
        let m = convert(moon, from: superview)
        let f = Self.frame, pad: CGFloat = 18
        let artSide = min(118, scriptWidth * 0.6)
        let scriptH = scriptWidth * script.size.height / script.size.width
        let w = scriptWidth + 2 * (pad + f)
        let h = f + 14 + artSide + 10 + scriptH + 16 + f
        // The wall stands over the moon, its arrow pointing down at it from near the wall's left end.
        tipX = m.midX
        let x = min(max(8, tipX - 44), bounds.width - w - 8)
        wallRect = NSRect(x: x, y: m.minY - 4 - Self.arrow - h, width: w, height: h).integral
        artRect = NSRect(x: wallRect.midX - artSide / 2, y: wallRect.minY + f + 14, width: artSide, height: artSide)
        scriptRect = NSRect(x: wallRect.minX + f + pad, y: artRect.maxY + 10, width: scriptWidth, height: scriptH)
        // The translation pops out right of the script, centered on it, as wide as one line up to 330pt.
        let full = attributed(shown: words.count)
        let bw = min(330, ceil(full.size().width) + 32)
        let textH = ceil(full.boundingRect(with: NSSize(width: bw - 32, height: 1000), options: [.usesLineFragmentOrigin]).height)
        let bh = textH + 24
        let bx = min(wallRect.maxX + 12, bounds.width - bw - 12)
        boxRect = NSRect(x: bx, y: scriptRect.midY - bh / 2, width: bw, height: bh).integral
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return dismissedAt == nil && (boxRect.contains(p) || wallRect.contains(p)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) { dismiss() }

    var coveredRects: [NSRect] {
        guard dismissedAt == nil else { return [] }
        place()
        return [wallRect, boxRect].map { convert($0, to: superview) }
    }

    // An arrow over the wall and the box; the views underneath (the terminal, the resize strips) don't get a say.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { track(event) }
    override func mouseMoved(with event: NSEvent) { track(event) }

    private func track(_ e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if dismissedAt == nil, wallRect.contains(p) || boxRect.contains(p) { NSCursor.arrow.set() }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        place()
        let now = CACurrentMediaTime(), t = now - started
        var alpha = min(1, t / Self.fadeIn)
        if let d = dismissedAt { alpha *= max(0, 1 - (now - d) / 0.2) }
        ctx.setAlpha(alpha)
        drawWall(ctx)
        drawArt(ctx)
        drawScript(ctx, progress: max(0, min(1, (t - readStart) / readFor)))
        if t > boxStart {
            let boxAlpha = min(1, (t - boxStart) / 0.2)
            drawBox(ctx, alpha: alpha * boxAlpha, shown: min(words.count, Int((t - boxStart) * Self.charsPerSecond)))
        }
    }

    /// The wall and its arrow as one outline.
    private var wallPath: NSBezierPath {
        let r = wallRect, a = Self.arrow
        let tip = min(max(tipX, r.minX + 24), r.maxX - 24)
        let p = NSBezierPath()
        p.move(to: NSPoint(x: r.minX, y: r.minY))
        p.line(to: NSPoint(x: r.maxX, y: r.minY))
        p.line(to: NSPoint(x: r.maxX, y: r.maxY))
        p.line(to: NSPoint(x: tip + a, y: r.maxY))
        p.line(to: NSPoint(x: tipX, y: r.maxY + a))
        p.line(to: NSPoint(x: tip - a, y: r.maxY))
        p.line(to: NSPoint(x: r.minX, y: r.maxY))
        p.close()
        p.lineJoinStyle = .miter
        return p
    }

    private static let bronze = NSColor(srgbRed: 0.27, green: 0.18, blue: 0.11, alpha: 1)
    private static let bronzeLight = NSColor(srgbRed: 0.62, green: 0.46, blue: 0.26, alpha: 1)

    /// A Nomai wall: old plaster, lit from the middle, in a dark bronze frame with stepped brackets in its corners.
    private func drawWall(_ ctx: CGContext) {
        let path = wallPath
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 4), blur: 16, color: NSColor.black.withAlphaComponent(0.55).cgColor)
        Self.bronze.setFill()
        path.fill()
        ctx.restoreGState()

        ctx.saveGState()
        path.addClip()
        plaster(for: wallRect.size).draw(in: wallRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        ctx.restoreGState()

        // Stroked twice as wide but clipped to the outline, so the frame is `frame` wide, all inside it.
        path.lineWidth = Self.frame * 2
        ctx.saveGState()
        path.addClip()
        Self.bronze.setStroke()
        path.stroke()
        ctx.restoreGState()
        // A thin lit edge just inside the frame.
        let inner = wallRect.insetBy(dx: Self.frame + 2, dy: Self.frame + 2)
        Self.bronzeLight.withAlphaComponent(0.55).setStroke()
        let edge = NSBezierPath(rect: inner)
        edge.lineWidth = 1
        edge.stroke()

        // Corner brackets: a bronze triangle in each corner with a stepped line inside it.
        let leg: CGFloat = 22, f = Self.frame
        for (cx, cy, sx, sy) in [(wallRect.minX, wallRect.minY, 1.0, 1.0), (wallRect.maxX, wallRect.minY, -1.0, 1.0),
                                 (wallRect.minX, wallRect.maxY, 1.0, -1.0), (wallRect.maxX, wallRect.maxY, -1.0, -1.0)] {
            let o = NSPoint(x: cx + sx * f, y: cy + sy * f)
            let tri = NSBezierPath()
            tri.move(to: o)
            tri.line(to: NSPoint(x: o.x + sx * leg, y: o.y))
            tri.line(to: NSPoint(x: o.x, y: o.y + sy * leg))
            tri.close()
            Self.bronze.setFill()
            tri.fill()
            let step = NSBezierPath()
            step.move(to: NSPoint(x: o.x + sx * 3, y: o.y + sy * 14))
            step.line(to: NSPoint(x: o.x + sx * 3, y: o.y + sy * 3))
            step.line(to: NSPoint(x: o.x + sx * 14, y: o.y + sy * 3))
            step.move(to: NSPoint(x: o.x + sx * 6, y: o.y + sy * 9))
            step.line(to: NSPoint(x: o.x + sx * 6, y: o.y + sy * 6))
            step.line(to: NSPoint(x: o.x + sx * 9, y: o.y + sy * 6))
            step.lineWidth = 1
            Self.bronzeLight.setStroke()
            step.stroke()
        }
    }

    private var plasterCache: (size: NSSize, image: NSImage)?

    /// The plaster, with its wear: stains and grain, a few hairline cracks and chips at the frame. From a fixed seed,
    /// so a wall wears the same way every time.
    private func plaster(for size: NSSize) -> NSImage {
        if let c = plasterCache, c.size == size { return c.image }
        let img = NSImage(size: size, flipped: true) { r in
            NSGradient(colors: [NSColor(srgbRed: 0.66, green: 0.59, blue: 0.56, alpha: 1),
                                NSColor(srgbRed: 0.47, green: 0.41, blue: 0.40, alpha: 1)])?
                .draw(in: NSBezierPath(rect: r), relativeCenterPosition: NSPoint(x: 0, y: -0.25))
            var rng = SeededRandom(seed: 0x51A2_0E0A)
            let grime = NSColor(srgbRed: 0.24, green: 0.19, blue: 0.17, alpha: 1)
            // Stains, darker and a few lighter, soft-edged.
            for i in 0..<16 {
                let c = NSPoint(x: rng.next(in: r.minX...r.maxX), y: rng.next(in: r.minY...r.maxY))
                let rad = rng.next(in: 10...42)
                let color = i % 5 == 4 ? NSColor.white.withAlphaComponent(rng.next(in: 0.04...0.08))
                    : grime.withAlphaComponent(rng.next(in: 0.05...0.13))
                NSGradient(colors: [color, color.withAlphaComponent(0)])?
                    .draw(in: NSBezierPath(ovalIn: NSRect(x: c.x - rad, y: c.y - rad * 0.8, width: rad * 2, height: rad * 1.6)),
                          relativeCenterPosition: .zero)
            }
            // Grain.
            for _ in 0..<Int(r.width * r.height / 60) {
                let d = rng.next(in: 0.5...1.3)
                (rng.next(in: 0...1) < 0.6 ? grime.withAlphaComponent(rng.next(in: 0.05...0.14))
                    : NSColor.white.withAlphaComponent(rng.next(in: 0.04...0.1))).setFill()
                NSRect(x: rng.next(in: r.minX...r.maxX), y: rng.next(in: r.minY...r.maxY), width: d, height: d).fill()
            }
            // Hairline cracks, each from an edge inwards, with a faint lit lip beside it.
            let inset = Self.frame + 1
            for i in 0..<4 {
                var p: NSPoint
                var dir: CGFloat
                switch i {
                case 0: p = NSPoint(x: rng.next(in: r.width * 0.55...r.width * 0.85), y: inset); dir = .pi / 2
                case 1: p = NSPoint(x: r.width - inset, y: rng.next(in: r.height * 0.3...r.height * 0.6)); dir = .pi
                case 2: p = NSPoint(x: inset, y: rng.next(in: r.height * 0.55...r.height * 0.8)); dir = 0
                default: p = NSPoint(x: rng.next(in: r.width * 0.15...r.width * 0.4), y: r.height - inset); dir = -.pi / 2
                }
                let crack = NSBezierPath()
                crack.move(to: p)
                for _ in 0..<Int(rng.next(in: 4...8)) {
                    dir += rng.next(in: -0.7...0.7)
                    let len = rng.next(in: 4...10)
                    p = NSPoint(x: p.x + cos(dir) * len, y: p.y + sin(dir) * len)
                    crack.line(to: p)
                    // Now and then a short branch.
                    if rng.next(in: 0...1) < 0.25 {
                        let b = dir + (rng.next(in: 0...1) < 0.5 ? -1 : 1) * rng.next(in: 0.6...1.1)
                        crack.line(to: NSPoint(x: p.x + cos(b) * 5, y: p.y + sin(b) * 5))
                        crack.move(to: p)
                    }
                }
                crack.lineWidth = 0.7
                crack.lineJoinStyle = .round
                NSColor.white.withAlphaComponent(0.12).setStroke()
                let lip = crack.copy() as! NSBezierPath
                lip.transform(using: AffineTransform(translationByX: 0.6, byY: 0.6))
                lip.stroke()
                grime.withAlphaComponent(0.45).setStroke()
                crack.stroke()
            }
            // Chips where the plaster meets the frame.
            for _ in 0..<6 {
                let side = Int(rng.next(in: 0...3.99))
                let t = rng.next(in: 0.15...0.85)
                let c: NSPoint = [NSPoint(x: r.width * t, y: inset), NSPoint(x: r.width - inset, y: r.height * t),
                                  NSPoint(x: r.width * t, y: r.height - inset), NSPoint(x: inset, y: r.height * t)][side]
                let chip = NSBezierPath()
                let n = 6
                for k in 0..<n {
                    let a = CGFloat(k) / CGFloat(n) * 2 * .pi
                    let rad = rng.next(in: 1.5...4.5)
                    let q = NSPoint(x: c.x + cos(a) * rad, y: c.y + sin(a) * rad)
                    k == 0 ? chip.move(to: q) : chip.line(to: q)
                }
                chip.close()
                grime.withAlphaComponent(0.35).setFill()
                chip.fill()
            }
            return true
        }
        plasterCache = (size, img)
        return img
    }

    /// The quantum symbol in the blue-violet the wall symbols glow with in the game, made bolder than the source
    /// art so it holds up small on the plaster: drawn over itself, which firms up the faint rays while leaving every
    /// line its own thin width.
    private static let artColor = NSColor(srgbRed: 0.40, green: 0.33, blue: 0.93, alpha: 1)
    private static let tintedArt: NSImage? = art.map { a in
        NSImage(size: a.size, flipped: false) { r in
            for _ in 0..<4 { a.draw(in: r) }
            artColor.setFill()
            r.fill(using: .sourceAtop)
            return true
        }
    }

    /// Where the circle at the symbol's center sits, as a fraction of the image (from the top-left).
    private static let coreCenter = CGPoint(x: 0.378, y: 0.512)

    private func drawArt(_ ctx: CGContext) {
        guard let art = Self.tintedArt else { return }
        let a = art.size, side = artRect.width
        let fit = min(side / a.width, side / a.height)
        let r = NSRect(x: artRect.midX - a.width * fit / 2, y: artRect.midY - a.height * fit / 2, width: a.width * fit, height: a.height * fit)
        ctx.saveGState()
        art.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        // Only the circle at its center glows; on the rays and lines a glow just muddies them.
        let core = CGPoint(x: r.minX + r.width * Self.coreCenter.x, y: r.minY + r.height * Self.coreCenter.y)
        let reach = r.width * 0.12
        ctx.saveGState()
        NSBezierPath(ovalIn: NSRect(x: core.x - reach, y: core.y - reach, width: reach * 2, height: reach * 2)).addClip()
        ctx.setShadow(offset: .zero, blur: 6, color: NSColor(srgbRed: 0.36, green: 0.28, blue: 1, alpha: 0.9).cgColor)
        art.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        ctx.restoreGState()
        // A little of the white source on top lights the solid core lavender (as the symbol's center glows in the
        // game) and barely touches the faint rays.
        Self.art?.draw(in: r, from: .zero, operation: .sourceOver, fraction: 0.4, respectFlipped: true, hints: nil)
        ctx.restoreGState()
    }

    private func drawScript(_ ctx: CGContext, progress: Double) {
        let scale = window?.backingScaleFactor ?? 2
        if unread == nil || bitmapScale != scale { prepareBitmaps(scale) }
        let n = script.marks.count
        let target = Int((Double(n) * progress).rounded())
        if let read, target > readCount {
            for m in script.marks[readCount..<target] { add(m, to: read, color: Self.readColor, glow: 4) }
            readCount = target
        }
        flippedDraw(unread, ctx)
        flippedDraw(read?.makeImage(), ctx)
        guard progress > 0, progress < 1 else { return }
        // The front of the reading: the last few marks white-hot, and a soft light on them.
        let k = script.marks.count / 40 + 1
        let s = scriptRect.width / script.size.width
        ctx.saveGState()
        ctx.translateBy(x: scriptRect.minX, y: scriptRect.minY)
        ctx.scaleBy(x: s, y: s)
        for m in script.marks[max(0, target - k)..<target] {
            ctx.addPath(m.path)
            if let w = m.width {
                ctx.setStrokeColor(NSColor.white.cgColor)
                ctx.setLineWidth(max(w, 1.4 / s))
                ctx.setLineCap(.round)
                ctx.strokePath()
            } else {
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fillPath()
            }
        }
        ctx.restoreGState()
        if target > 0 {
            let c = script.marks[target - 1].center
            let p = CGPoint(x: scriptRect.minX + c.x * s, y: scriptRect.minY + c.y * s)
            let colors = [Self.glowColor.withAlphaComponent(0.8).cgColor, Self.glowColor.withAlphaComponent(0).cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
                ctx.drawRadialGradient(g, startCenter: p, startRadius: 0, endCenter: p, endRadius: 12, options: [])
            }
        }
    }

    private func prepareBitmaps(_ scale: CGFloat) {
        bitmapScale = scale
        func bitmap() -> CGContext? {
            let pad: CGFloat = 8
            let ctx = CGContext(data: nil, width: Int((scriptRect.width + pad * 2) * scale), height: Int((scriptRect.height + pad * 2) * scale),
                                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            // Script units, y down, inset by the glow's room.
            ctx?.translateBy(x: 0, y: CGFloat(ctx?.height ?? 0))
            ctx?.scaleBy(x: scale, y: -scale)
            ctx?.translateBy(x: pad, y: pad)
            let s = scriptRect.width / script.size.width
            ctx?.scaleBy(x: s, y: s)
            return ctx
        }
        if let base = bitmap() {
            for m in script.marks { add(m, to: base, color: Self.unreadColor, glow: 3) }
            unread = base.makeImage()
        }
        read = bitmap()
        readCount = 0
    }

    private func add(_ m: NomaiScript.Mark, to ctx: CGContext, color: NSColor, glow: CGFloat) {
        let s = scriptRect.width / script.size.width
        ctx.setShadow(offset: .zero, blur: glow * bitmapScale, color: Self.glowColor.withAlphaComponent(color.alphaComponent * 0.7).cgColor)
        ctx.addPath(m.path)
        if let w = m.width {
            ctx.setStrokeColor(color.cgColor)
            // At this size the strokes would vanish: keep them at least a hairline.
            ctx.setLineWidth(max(w, 0.9 / s))
            ctx.setLineCap(.round)
            ctx.strokePath()
        } else {
            ctx.setFillColor(color.cgColor)
            ctx.fillPath()
        }
    }

    /// Draws a y-up bitmap made by `prepareBitmaps` over the script's rect in this flipped view.
    private func flippedDraw(_ img: CGImage?, _ ctx: CGContext) {
        guard let img else { return }
        let r = scriptRect.insetBy(dx: -8, dy: -8)
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(origin: .zero, size: r.size))
        ctx.restoreGState()
    }

    private static let spaceMono: NSFont = {
        if let url = Bundle.main.url(forResource: "SpaceMono-Regular", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        return NSFont(name: "SpaceMono-Regular", size: 12.5) ?? .monospacedSystemFont(ofSize: 12.5, weight: .regular)
    }()

    private func attributed(shown: Int) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 3
        let out = NSMutableAttributedString(string: words, attributes: [.font: Self.spaceMono, .paragraphStyle: para, .foregroundColor: Self.textColor])
        // Not yet typed: laid out already (so lines don't rewrap as it types), just invisible.
        let typed = (String(words.prefix(shown)) as NSString).length
        if typed < out.length { out.addAttribute(.foregroundColor, value: NSColor.clear, range: NSRange(location: typed, length: out.length - typed)) }
        return out
    }

    private func drawBox(_ ctx: CGContext, alpha: Double, shown: Int) {
        ctx.saveGState()
        ctx.setAlpha(alpha)
        let path = NSBezierPath(roundedRect: boxRect, xRadius: 9, yRadius: 9)
        ctx.setShadow(offset: .zero, blur: 14, color: NSColor(srgbRed: 0.37, green: 0.83, blue: 0.78, alpha: 0.35).cgColor)
        NSColor(srgbRed: 0.03, green: 0.06, blue: 0.07, alpha: 0.94).setFill()
        path.fill()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        NSColor(srgbRed: 0.5, green: 0.88, blue: 0.84, alpha: 0.35).setStroke()
        path.lineWidth = 1
        path.stroke()
        attributed(shown: shown).draw(with: boxRect.insetBy(dx: 16, dy: 12), options: [.usesLineFragmentOrigin])
        ctx.restoreGState()
    }
}

/// A small fixed-seed generator (SplitMix64), for wear that comes out the same each time.
private struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next(in range: ClosedRange<CGFloat>) -> CGFloat {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return range.lowerBound + CGFloat(Double(z >> 11) / Double(1 << 53)) * (range.upperBound - range.lowerBound)
    }
}
