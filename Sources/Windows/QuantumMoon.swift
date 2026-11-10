import CCanvas
import Foundation
import WinSDK

/// An easter egg for the Quantum Moon theme, as on the Mac (QuantumMoon.swift there). Like the moon in Outer Wilds, its
/// icon only moves while nobody is looking: each time Solanum comes back to the front, the moon may have left its place
/// beside the theme name (which stays) for the flower's corner of the tab bar, or for the status bar's left side by the
/// folder path. Caught there and clicked, it shows Nomai script being read and translated: Bells' and Solanum's, taking
/// turns.
enum QuantumMoon {
    enum Spot: CaseIterable { case home, flower, folders }

    private(set) static var spot = Spot.home
    private static var movedAt = Date.distantPast

    /// The theme is Quantum Moon with its icon showing.
    static var active: Bool { AppSettings.shared.themeIcon && AppSettings.shared.themePlanet == .quantumMoon }

    /// The moon is at `s` right now.
    static func at(_ s: Spot) -> Bool { active && spot == s }

    /// Solanum has come back to the front: the moon may have moved while nobody was looking. True if it did. Several
    /// windows hear of it at once; it moves once.
    static func cameToFront() -> Bool {
        guard active, Date().timeIntervalSince(movedAt) > 1 else { return false }
        movedAt = Date()
        // Home half the time; otherwise one of the other spots.
        let next: Spot = Bool.random() ? .home : [Spot.flower, .folders].randomElement()!
        guard next != spot else { return false }
        spot = next
        return true
    }

    // MARK: Reading

    /// How many times the moon has been read, which decides whose words come next: Bells' first, then Solanum's,
    /// taking turns, kept across launches as on the Mac.
    private static var encountersFile: URL? { AppSettings.folder?.appendingPathComponent("quantum-moon") }

    static func nextReading() -> NomaiReading? {
        let seen = encountersFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        if let url = encountersFile { try? "\(seen + 1)".write(to: url, atomically: true, encoding: .utf8) }
        let bells = seen % 2 == 0
        guard let script = NomaiScript.named(bells ? "BELLS_SVG" : "SOLANUM_SVG") else { return nil }
        let words = bells ? "BELLS: Be curious on your journey."
            : "SOLANUM: As a child, I considered such unknowns sinister. Now, though, I understand they bear no ill "
                + "will. The universe is, and we are."
        return NomaiReading(script: script, words: words, width: bells ? 170 : 240, readFor: bells ? 1.4 : 2.4)
    }
}

/// Solanum's own files, built into the program (Support\Windows\Solanum.rc).
enum EmbeddedResource {
    private static var cache: [String: Data] = [:]

    static func data(_ name: String) -> Data? {
        if let d = cache[name] { return d }
        let module = GetModuleHandleW(nil)
        // RT_RCDATA, which the SDK only has as a macro.
        guard let found = wide(name).withUnsafeBufferPointer({ FindResourceW(module, $0.baseAddress, UnsafePointer<WCHAR>(bitPattern: 10)) }),
              let loaded = LoadResource(module, found), let bytes = LockResource(loaded) else { return nil }
        let d = Data(bytes: bytes, count: Int(SizeofResource(module, found)))
        cache[name] = d
        return d
    }
}

/// Nomai script prepared by Tools/nomai_svg.py: strokes and dots in reading order, 1000 units across. Only the absolute
/// M, L, C and Z path commands that tool writes are read, as on the Mac.
struct NomaiScript {
    struct Mark {
        /// The path, as SVG path data for the canvas.
        let d: String
        /// Stroke width in script units; nil for a filled dot.
        let width: Float?
        let center: (x: Float, y: Float)
    }

    let size: (width: Float, height: Float)
    let marks: [Mark]

    private static var cache: [String: NomaiScript] = [:]

    static func named(_ resource: String) -> NomaiScript? {
        if let s = cache[resource] { return s }
        guard let data = EmbeddedResource.data(resource), let text = String(data: data, encoding: .utf8), let s = parse(text) else { return nil }
        cache[resource] = s
        return s
    }

    private static func parse(_ svg: String) -> NomaiScript? {
        guard let vb = svg.range(of: "viewBox=\"") else { return nil }
        let box = svg[vb.upperBound...].prefix { $0 != "\"" }.split(separator: " ").compactMap { Float($0) }
        guard box.count == 4 else { return nil }
        var marks: [Mark] = []
        for chunk in svg.components(separatedBy: "<path").dropFirst() {
            guard let st = chunk.range(of: "style=\""), let dr = chunk.range(of: " d=\"") else { continue }
            let style = chunk[st.upperBound...].prefix { $0 != "\"" }
            var width: Float?
            if style.contains("fill:none") {
                width = style.range(of: "stroke-width:").flatMap { Float(style[$0.upperBound...].prefix { $0 != ";" }) } ?? 2
            }
            let d = String(chunk[dr.upperBound...].prefix { $0 != "\"" })
            // Its middle, from the points it goes through.
            var xs: [Float] = [], ys: [Float] = []
            var numbers: [Float] = []
            for token in d.split(separator: " ") {
                if let v = Float(token) { numbers.append(v) } else { numbers.removeAll(keepingCapacity: true) }
                if numbers.count == 2 {
                    xs.append(numbers[0])
                    ys.append(numbers[1])
                    numbers.removeAll(keepingCapacity: true)
                }
            }
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { continue }
            marks.append(Mark(d: d, width: width, center: ((minX + maxX) / 2, (minY + maxY) / 2)))
        }
        return marks.isEmpty ? nil : NomaiScript(size: (box[2], box[3]), marks: marks)
    }
}

/// The easter egg's reading, drawn over the window: a Nomai wall pointing down at the moon like a comment bubble, the
/// quantum symbol at its top and the script beneath, which glows mark by mark from its free end to its center with a
/// bright point at the front (the translator following the line). Then the words type out in Space Mono, in a box that
/// pops out to the right of the wall. Any click puts it away; one off the wall and the box still lands where it was
/// aimed. As on the Mac (NomaiReadingView there), in points times the display's scale.
final class NomaiReading {
    private let script: NomaiScript
    private let words: String
    private let scriptWidth: Float
    private let readFor: Double

    private var started = Date()
    private(set) var dismissedAt: Date?

    private(set) var wallRect = UIRect(x: 0, y: 0, width: 0, height: 0)
    private(set) var boxRect = UIRect(x: 0, y: 0, width: 0, height: 0)
    private var tipX: Float = 0
    private var artRect = UIRect(x: 0, y: 0, width: 0, height: 0)
    private var scriptRect = UIRect(x: 0, y: 0, width: 0, height: 0)
    private var scale: Float = 1

    /// The script unread, drawn once, and the marks read so far, added as the reading reaches them; and the wall's
    /// plaster. Layers on the window's canvas, made again for a new size or a lost device.
    private var unreadLayer: Int32 = -1, readLayer: Int32 = -1, plasterLayer: Int32 = -1
    private var layersFor: (scale: Float, script: Float, wall: (Float, Float))?
    private var plasterSize: (Float, Float) = (0, 0)
    private var readCount = 0
    /// The canvas the layers are on, to let them go with the reading.
    private weak var layerCanvas: Canvas?

    deinit {
        guard let c = layerCanvas else { return }
        for layer in [unreadLayer, readLayer, plasterLayer] { sol_canvas_layer_free(c.raw, layer) }
    }

    private static let fadeIn = 0.3
    private static let charsPerSecond = 75.0
    private static let frame: Float = 6
    private static let arrow: Float = 12
    private static let unread: (UInt32, Float) = (0x3D73F2, 0.7)
    private static let readColor: UInt32 = 0xB8E0FF
    private static let glow: UInt32 = 0x73BFFF
    private static let textColor: UInt32 = 0xCCF7ED
    private static let bronze: UInt32 = 0x452E1C
    private static let bronzeLight: UInt32 = 0x9E7542
    private static let artColor: UInt32 = 0x6654ED
    private static let font = Array("Space Mono".utf16) + [0]
    private static let fontPixels: Float = 12.5

    init(script: NomaiScript, words: String, width: Float, readFor: Double) {
        self.script = script
        self.words = words
        scriptWidth = width
        self.readFor = readFor
    }

    func dismiss() { if dismissedAt == nil { dismissedAt = Date() } }

    /// As if it had been showing `seconds` already: for drawing a moment of it off-screen (--draw-quantum-moon).
    func pretend(elapsed seconds: Double) { started = Date().addingTimeInterval(-seconds) }

    /// Whose words these are, Bells' or Solanum's, for drawing either off-screen.
    static func forTesting(bells: Bool) -> NomaiReading? {
        guard let script = NomaiScript.named(bells ? "BELLS_SVG" : "SOLANUM_SVG") else { return nil }
        return NomaiReading(script: script, words: bells ? "BELLS: Be curious on your journey."
            : "SOLANUM: As a child, I considered such unknowns sinister. Now, though, I understand they bear no ill will. The universe is, and we are.",
                            width: bells ? 170 : 240, readFor: bells ? 1.4 : 2.4)
    }

    /// Faded away after being put away: it can go.
    var finished: Bool { dismissedAt.map { Date().timeIntervalSince($0) > 0.2 } ?? false }

    /// Still changing from one frame to the next, so the window keeps drawing it.
    var animating: Bool { dismissedAt != nil || Date().timeIntervalSince(started) < typingEnd + 0.1 }

    func contains(_ x: Float, _ y: Float) -> Bool { dismissedAt == nil && (wallRect.contains(x, y) || boxRect.contains(x, y)) }

    private var readStart: Double { Self.fadeIn + 0.1 }
    private var boxStart: Double { readStart + readFor + 0.15 }
    private var typingEnd: Double { boxStart + Double(words.count) / Self.charsPerSecond }

    // MARK: Layout

    /// Where it all goes, over the moon at `moon` in a window `width` across.
    func place(moon: UIRect, width: Float, scale s: Float, canvas: Canvas) {
        scale = s
        let f = Self.frame * s, pad = 18 * s, a = Self.arrow * s
        let artSide = min(118, scriptWidth * 0.6) * s
        let sw = scriptWidth * s, sh = sw * script.size.height / script.size.width
        let w = sw + 2 * (pad + f)
        let h = f + 14 * s + artSide + 10 * s + sh + 16 * s + f
        // The wall stands over the moon, its arrow pointing down at it from near the wall's left end.
        tipX = moon.x + moon.width / 2
        let x = min(max(8 * s, tipX - 44 * s), width - w - 8 * s)
        wallRect = UIRect(x: x.rounded(), y: (moon.y - 4 * s - a - h).rounded(), width: w.rounded(), height: h.rounded())
        artRect = UIRect(x: wallRect.x + wallRect.width / 2 - artSide / 2, y: wallRect.y + f + 14 * s, width: artSide, height: artSide)
        scriptRect = UIRect(x: wallRect.x + f + pad, y: artRect.maxY + 10 * s, width: sw, height: sh)
        // The translation pops out right of the script, centered on it, as wide as one line up to 330pt.
        let full = measureText(canvas, width: 10000)
        let bw = min(330 * s, full.width.rounded(.up) + 32 * s)
        let textH = measureText(canvas, width: bw - 32 * s).height.rounded(.up)
        let bh = textH + 24 * s
        let bx = min(wallRect.maxX + 12 * s, width - bw - 12 * s)
        boxRect = UIRect(x: bx.rounded(), y: (scriptRect.midY - bh / 2).rounded(), width: bw.rounded(), height: bh.rounded())
    }

    private func measureText(_ canvas: Canvas, width: Float) -> (width: Float, height: Float) {
        Self.ensureFont(canvas)
        let units = Array(words.utf16)
        var used: Float = 0
        let h = Self.font.withUnsafeBufferPointer { family in
            sol_canvas_text_in(canvas.raw, family.baseAddress, 0, 0, width, units, Int32(units.count), Self.fontPixels * scale, 3 * scale, 0, 0,
                               Int32(units.count), 1, &used)
        }
        return (used, h)
    }

    private static var fontAdded: Set<ObjectIdentifier> = []

    /// Space Mono, as on the Mac, from the copy built into Solanum; once for each canvas.
    private static func ensureFont(_ canvas: Canvas) {
        guard !fontAdded.contains(ObjectIdentifier(canvas)) else { return }
        fontAdded.insert(ObjectIdentifier(canvas))
        guard let data = EmbeddedResource.data("SPACE_MONO_TTF") else { return }
        _ = data.withUnsafeBytes { sol_canvas_add_font(canvas.raw, $0.bindMemory(to: UInt8.self).baseAddress, Int32(data.count)) }
    }

    // MARK: Drawing

    func draw(on canvas: Canvas) {
        let now = Date(), t = now.timeIntervalSince(started)
        var alpha = Float(min(1, t / Self.fadeIn))
        if let d = dismissedAt { alpha *= Float(max(0, 1 - now.timeIntervalSince(d) / 0.2)) }
        guard alpha > 0 else { return }
        prepareLayers(canvas)
        drawWall(canvas, alpha: alpha)
        drawArt(canvas, alpha: alpha)
        drawScript(canvas, progress: max(0, min(1, (t - readStart) / readFor)), alpha: alpha)
        if t > boxStart {
            let boxAlpha = Float(min(1, (t - boxStart) / 0.2))
            drawBox(canvas, alpha: alpha * boxAlpha, shown: min(words.count, Int((t - boxStart) * Self.charsPerSecond)))
        }
    }

    /// The wall and its arrow as one outline.
    private var wallOutline: [Float] {
        let r = wallRect, a = Self.arrow * scale
        let tip = min(max(tipX, r.x + 24 * scale), r.maxX - 24 * scale)
        return [r.x, r.y, r.maxX, r.y, r.maxX, r.maxY, tip + a, r.maxY, tipX, r.maxY + a, tip - a, r.maxY, r.x, r.maxY]
    }

    private func polygon(_ c: Canvas, _ xy: [Float], _ rgb: UInt32, _ alpha: Float) {
        xy.withUnsafeBufferPointer { sol_canvas_fill_polygon(c.raw, $0.baseAddress, Int32(xy.count / 2), rgb, alpha) }
    }

    private func polyline(_ c: Canvas, _ xy: [Float], closed: Bool = false, _ rgb: UInt32, _ alpha: Float, width: Float) {
        xy.withUnsafeBufferPointer { sol_canvas_stroke_polyline(c.raw, $0.baseAddress, Int32(xy.count / 2), closed ? 1 : 0, rgb, alpha, width) }
    }

    /// A Nomai wall: old plaster, lit from the middle, in a dark bronze frame with stepped brackets in its corners.
    private func drawWall(_ c: Canvas, alpha: Float) {
        let s = scale, f = Self.frame * s, outline = wallOutline
        // Its shadow, soft below it.
        for (dy, spread, a) in [(Float(4), Float(10), Float(0.10)), (4, 5, 0.14), (4, 1, 0.2)] {
            let grown = UIRect(x: wallRect.x - spread * s, y: wallRect.y - spread * s + dy * s, width: wallRect.width + spread * 2 * s, height: wallRect.height + spread * 2 * s)
            sol_canvas_fill_rounded(c.raw, grown.x, grown.y, grown.width, grown.height, spread * s, 0x000000, a * alpha)
        }
        // Bronze all over (the frame, and the arrow, which is all frame), then the plaster inside the frame.
        polygon(c, outline, Self.bronze, alpha)
        sol_canvas_layer_draw(c.raw, plasterLayer, wallRect.x + f, wallRect.y + f, wallRect.width - 2 * f, wallRect.height - 2 * f, alpha)
        // A thin lit edge just inside the frame.
        let inner = UIRect(x: wallRect.x + f + 2 * s, y: wallRect.y + f + 2 * s, width: wallRect.width - 2 * (f + 2 * s), height: wallRect.height - 2 * (f + 2 * s))
        polyline(c, [inner.x, inner.y, inner.maxX, inner.y, inner.maxX, inner.maxY, inner.x, inner.maxY], closed: true, Self.bronzeLight, 0.55 * alpha, width: max(s, 1))
        // Corner brackets: a bronze triangle in each corner with a stepped line inside it.
        let leg = 22 * s
        for (cx, cy, sx, sy) in [(wallRect.x, wallRect.y, Float(1), Float(1)), (wallRect.maxX, wallRect.y, -1, 1),
                                 (wallRect.x, wallRect.maxY, 1, -1), (wallRect.maxX, wallRect.maxY, -1, -1)] {
            let ox = cx + sx * f, oy = cy + sy * f
            polygon(c, [ox, oy, ox + sx * leg, oy, ox, oy + sy * leg], Self.bronze, alpha)
            polyline(c, [ox + sx * 3 * s, oy + sy * 14 * s, ox + sx * 3 * s, oy + sy * 3 * s, ox + sx * 14 * s, oy + sy * 3 * s], Self.bronzeLight, alpha, width: max(s, 1))
            polyline(c, [ox + sx * 6 * s, oy + sy * 9 * s, ox + sx * 6 * s, oy + sy * 6 * s, ox + sx * 9 * s, oy + sy * 6 * s], Self.bronzeLight, alpha, width: max(s, 1))
        }
    }

    /// The plaster, with its wear: stains and grain, a few hairline cracks and chips at the frame. From the Mac's fixed
    /// seed, so a wall wears the same way every time, on either.
    private func paintPlaster(_ c: Canvas, width w: Float, height h: Float) {
        let s = scale, raw = c.raw
        // The Mac paints the whole wall, frame and all, and the frame covers its edge: the same here, shifted in.
        let f = Self.frame * s
        let full = (w: w + 2 * f, h: h + 2 * f)
        func at(_ x: Float, _ y: Float) -> (Float, Float) { (x * s - f, y * s - f) }
        sol_canvas_fill_rect_radial(raw, 0, 0, w, h, full.w / 2 - f, full.h * 0.625 - f, hypot(full.w, full.h) * 0.6, hypot(full.w, full.h) * 0.6, 0xA8968F, 0x786966)
        var rng = SeededRandom(seed: 0x51A2_0E0A)
        let r = (width: full.w / s, height: full.h / s)
        let grime: UInt32 = 0x3D302B
        // Stains, darker and a few lighter, soft-edged.
        for i in 0..<16 {
            let cx = rng.next(in: 0...r.width), cy = rng.next(in: 0...r.height)
            let rad = rng.next(in: 10...42)
            let light = i % 5 == 4
            let a = light ? rng.next(in: 0.04...0.08) : rng.next(in: 0.05...0.13)
            let color: UInt32 = light ? 0xFFFFFF : grime
            let (x, y) = at(cx, cy)
            sol_canvas_fill_radial(raw, x, y, rad * s, rad * 0.8 * s, color, a, color, 0)
        }
        // Grain.
        for _ in 0..<Int(r.width * r.height / 60) {
            let d = rng.next(in: 0.5...1.3)
            let dark = rng.next(in: 0...1) < 0.6
            let a = dark ? rng.next(in: 0.05...0.14) : rng.next(in: 0.04...0.1)
            let (x, y) = at(rng.next(in: 0...r.width), rng.next(in: 0...r.height))
            sol_canvas_fill_rect(raw, x, y, d * s, d * s, dark ? grime : 0xFFFFFF, a)
        }
        // Hairline cracks, each from an edge inwards, with a faint lit lip beside it.
        let inset = Self.frame + 1
        for i in 0..<4 {
            var p: (x: Float, y: Float), dir: Float
            switch i {
            case 0: p = (rng.next(in: r.width * 0.55...r.width * 0.85), inset); dir = .pi / 2
            case 1: p = (r.width - inset, rng.next(in: r.height * 0.3...r.height * 0.6)); dir = .pi
            case 2: p = (inset, rng.next(in: r.height * 0.55...r.height * 0.8)); dir = 0
            default: p = (rng.next(in: r.width * 0.15...r.width * 0.4), r.height - inset); dir = -.pi / 2
            }
            var runs: [[(Float, Float)]] = [[p]]
            for _ in 0..<Int(rng.next(in: 4...8)) {
                dir += rng.next(in: -0.7...0.7)
                let len = rng.next(in: 4...10)
                p = (p.x + cos(dir) * len, p.y + sin(dir) * len)
                runs[runs.count - 1].append(p)
                // Now and then a short branch.
                if rng.next(in: 0...1) < 0.25 {
                    let b = dir + (rng.next(in: 0...1) < 0.5 ? -1 : 1) * rng.next(in: 0.6...1.1)
                    runs[runs.count - 1].append((p.x + cos(b) * 5, p.y + sin(b) * 5))
                    runs.append([p])
                }
            }
            for run in runs where run.count > 1 {
                let lip = run.flatMap { q -> [Float] in let (x, y) = at(q.0 + 0.6, q.1 + 0.6); return [x, y] }
                let line = run.flatMap { q -> [Float] in let (x, y) = at(q.0, q.1); return [x, y] }
                polyline(c, lip, 0xFFFFFF, 0.12, width: 0.7 * s)
                polyline(c, line, grime, 0.45, width: 0.7 * s)
            }
        }
        // Chips where the plaster meets the frame.
        for _ in 0..<6 {
            let side = Int(rng.next(in: 0...3.99))
            let t = rng.next(in: 0.15...0.85)
            let centers: [(Float, Float)] = [(r.width * t, inset), (r.width - inset, r.height * t), (r.width * t, r.height - inset), (inset, r.height * t)]
            let center = centers[side]
            var points: [Float] = []
            for k in 0..<6 {
                let a = Float(k) / 6 * 2 * .pi
                let rad = rng.next(in: 1.5...4.5)
                let (x, y) = at(center.0 + cos(a) * rad, center.1 + sin(a) * rad)
                points += [x, y]
            }
            polygon(c, points, grime, 0.35)
        }
    }

    // MARK: The quantum symbol

    /// The symbol in the blue-violet the wall symbols glow with in the game, made bolder than the source art so it holds
    /// up small on the plaster (as the Mac draws it over itself); and the white source, for the lit core.
    private static var art: [ObjectIdentifier: (tinted: Int32, white: Int32, width: Float, height: Float)] = [:]

    /// Where the circle at the symbol's center sits, as a fraction of the image (from the top-left).
    private static let coreCenter: (x: Float, y: Float) = (0.378, 0.512)

    private func drawArt(_ c: Canvas, alpha: Float) {
        guard let art = Self.loadArt(c) else { return }
        let side = artRect.width, fit = min(side / art.width, side / art.height)
        let r = UIRect(x: artRect.x + side / 2 - art.width * fit / 2, y: artRect.y + side / 2 - art.height * fit / 2, width: art.width * fit, height: art.height * fit)
        sol_canvas_draw_image(c.raw, art.tinted, r.x, r.y, r.width, r.height, alpha)
        // Only the circle at its center glows.
        let core = (x: r.x + r.width * Self.coreCenter.x, y: r.y + r.height * Self.coreCenter.y), reach = r.width * 0.12
        sol_canvas_fill_radial(c.raw, core.x, core.y, reach * 1.6, reach * 1.6, 0x5C47FF, 0.55 * alpha, 0x5C47FF, 0)
        sol_canvas_draw_image(c.raw, art.tinted, r.x, r.y, r.width, r.height, 0.5 * alpha)
        // A little of the white source on top lights the solid core lavender and barely touches the faint rays.
        sol_canvas_draw_image(c.raw, art.white, r.x, r.y, r.width, r.height, 0.4 * alpha)
    }

    private static func loadArt(_ c: Canvas) -> (tinted: Int32, white: Int32, width: Float, height: Float)? {
        if let a = art[ObjectIdentifier(c)] { return a }
        guard let png = EmbeddedResource.data("QUANTUM_MOON_PNG") else { return nil }
        var pixels: UnsafeMutablePointer<UInt8>?
        var w: Int32 = 0, h: Int32 = 0
        let decoded = png.withUnsafeBytes { sol_canvas_decode_png(c.raw, $0.bindMemory(to: UInt8.self).baseAddress, Int32(png.count), &pixels, &w, &h) }
        guard decoded == 0, let pixels else { return nil }
        defer { sol_canvas_free(pixels) }
        let count = Int(w * h * 4)
        var bold = [UInt8](repeating: 0, count: count)
        // Drawn over itself four times: faint parts firm up, solid ones stay as they are.
        for i in stride(from: 0, to: count, by: 4) {
            let a = Float(pixels[i + 3]) / 255, boosted = 1 - pow(1 - a, 4)
            bold[i + 3] = UInt8((boosted * 255).rounded())
        }
        let tinted = bold.withUnsafeBufferPointer { sol_canvas_load_rgba(c.raw, $0.baseAddress, w, h, artColor) }
        let white = png.withUnsafeBytes { sol_canvas_load_image(c.raw, $0.bindMemory(to: UInt8.self).baseAddress, Int32(png.count)) }
        let made = (tinted, white, Float(w), Float(h))
        art[ObjectIdentifier(c)] = made
        return made
    }

    // MARK: The script

    /// The layers, made (again) when there are none, the device was lost, or the size changed.
    private func prepareLayers(_ c: Canvas) {
        let f = Self.frame * scale
        let wall = (wallRect.width - 2 * f, wallRect.height - 2 * f)
        let fresh = layersFor.map { $0.scale == scale && $0.script == scriptRect.width && $0.wall == wall } ?? false
        let alive = sol_canvas_layer_alive(c.raw, unreadLayer) != 0 && sol_canvas_layer_alive(c.raw, readLayer) != 0 && sol_canvas_layer_alive(c.raw, plasterLayer) != 0
        guard !fresh || !alive else { return }
        layersFor = (scale, scriptRect.width, wall)
        if let old = layerCanvas { for layer in [unreadLayer, readLayer, plasterLayer] { sol_canvas_layer_free(old.raw, layer) } }
        layerCanvas = c
        let pad = 8 * scale
        let lw = scriptRect.width + pad * 2, lh = scriptRect.height + pad * 2
        unreadLayer = sol_canvas_layer_make(c.raw, lw, lh)
        readLayer = sol_canvas_layer_make(c.raw, lw, lh)
        plasterLayer = sol_canvas_layer_make(c.raw, wall.0, wall.1)
        readCount = 0
        if sol_canvas_layer_begin(c.raw, unreadLayer, 1) != 0 {
            for m in script.marks { add(m, on: c, color: Self.unread.0, alpha: Self.unread.1, glow: 3) }
            sol_canvas_layer_end(c.raw)
        }
        if sol_canvas_layer_begin(c.raw, readLayer, 1) != 0 { sol_canvas_layer_end(c.raw) }
        if sol_canvas_layer_begin(c.raw, plasterLayer, 1) != 0 {
            paintPlaster(c, width: wall.0, height: wall.1)
            sol_canvas_layer_end(c.raw)
        }
    }

    /// Script units to the layer's pixels: inset by the glow's room.
    private var unit: Float { scriptRect.width / script.size.width }

    /// One mark into a layer, with a glow around it (drawn wider and fainter underneath).
    private func add(_ m: NomaiScript.Mark, on c: Canvas, color: UInt32, alpha: Float, glow: Float) {
        let k = unit, origin = 8 * scale
        let glowUnits = glow * scale / k, glowAlpha = alpha * 0.7
        m.d.withCString { d in
            if let w = m.width {
                // At this size the strokes would vanish: keep them at least a hairline.
                let width = max(w, 0.9 * scale / k)
                sol_canvas_stroke_svg_path(c.raw, d, origin, origin, k, Self.glow, glowAlpha * 0.1, width + glowUnits * 1.6)
                sol_canvas_stroke_svg_path(c.raw, d, origin, origin, k, Self.glow, glowAlpha * 0.2, width + glowUnits * 0.8)
                sol_canvas_stroke_svg_path(c.raw, d, origin, origin, k, color, alpha, width)
            } else {
                sol_canvas_stroke_svg_path(c.raw, d, origin, origin, k, Self.glow, glowAlpha * 0.15, glowUnits * 1.2)
                sol_canvas_fill_svg_path(c.raw, d, origin, origin, k, color, alpha)
            }
        }
    }

    private func drawScript(_ c: Canvas, progress: Double, alpha: Float) {
        let n = script.marks.count
        let target = Int((Double(n) * progress).rounded())
        if target > readCount, sol_canvas_layer_begin(c.raw, readLayer, 0) != 0 {
            for m in script.marks[readCount..<target] { add(m, on: c, color: Self.readColor, alpha: 1, glow: 4) }
            sol_canvas_layer_end(c.raw)
            readCount = target
        }
        let pad = 8 * scale
        let r = UIRect(x: scriptRect.x - pad, y: scriptRect.y - pad, width: scriptRect.width + pad * 2, height: scriptRect.height + pad * 2)
        sol_canvas_layer_draw(c.raw, unreadLayer, r.x, r.y, r.width, r.height, alpha)
        sol_canvas_layer_draw(c.raw, readLayer, r.x, r.y, r.width, r.height, alpha)
        guard progress > 0, progress < 1 else { return }
        // The front of the reading: the last few marks white-hot, and a soft light on them.
        let k = unit, front = n / 40 + 1
        for m in script.marks[max(0, target - front)..<target] {
            m.d.withCString { d in
                if let w = m.width {
                    sol_canvas_stroke_svg_path(c.raw, d, scriptRect.x, scriptRect.y, k, 0xFFFFFF, alpha, max(w, 1.4 * scale / k))
                } else {
                    sol_canvas_fill_svg_path(c.raw, d, scriptRect.x, scriptRect.y, k, 0xFFFFFF, alpha)
                }
            }
        }
        if target > 0 {
            let center = script.marks[target - 1].center
            let x = scriptRect.x + center.x * k, y = scriptRect.y + center.y * k
            sol_canvas_fill_radial(c.raw, x, y, 12 * scale, 12 * scale, Self.glow, 0.8 * 0.9 * alpha, Self.glow, 0)
        }
    }

    // MARK: The translation

    private func drawBox(_ c: Canvas, alpha: Float, shown: Int) {
        let s = scale, b = boxRect, radius = 9 * s
        // Its glow, the teal of the translator's screen.
        for (spread, a) in [(Float(10), Float(0.06)), (6, 0.08), (3, 0.1)] {
            sol_canvas_fill_rounded(c.raw, b.x - spread * s, b.y - spread * s, b.width + spread * 2 * s, b.height + spread * 2 * s, radius + spread * s, 0x5ED4C7, a * alpha)
        }
        sol_canvas_fill_rounded(c.raw, b.x, b.y, b.width, b.height, radius, 0x080F12, 0.94 * alpha)
        sol_canvas_stroke_rounded(c.raw, b.x + 0.5, b.y + 0.5, b.width - 1, b.height - 1, radius, 0x80E0D6, 0.35 * alpha, max(s, 1))
        Self.ensureFont(c)
        let units = Array(words.utf16)
        // How many UTF-16 units the first `shown` characters take.
        let typed = String(words.prefix(shown)).utf16.count
        var used: Float = 0
        _ = Self.font.withUnsafeBufferPointer { family in
            sol_canvas_text_in(c.raw, family.baseAddress, b.x + 16 * s, b.y + 12 * s, b.width - 32 * s, units, Int32(units.count), Self.fontPixels * s, 3 * s,
                               Self.textColor, alpha, Int32(typed), 0, &used)
        }
    }
}

/// A small fixed-seed generator (SplitMix64), for wear that comes out the same each time, as on the Mac.
private struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next(in range: ClosedRange<Float>) -> Float {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return range.lowerBound + Float(Double(z >> 11) / Double(1 << 53)) * (range.upperBound - range.lowerBound)
    }
}
