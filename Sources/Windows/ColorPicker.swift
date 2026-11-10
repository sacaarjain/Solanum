import CCanvas
import Foundation

/// A color as hue, saturation and brightness, each 0 to 1, with its opacity: what the picker moves through.
struct HSVColor: Equatable {
    var hue: Float
    var saturation: Float
    var brightness: Float
    var alpha: Float

    init(hue: Float, saturation: Float, brightness: Float, alpha: Float = 1) {
        self.hue = hue
        self.saturation = saturation
        self.brightness = brightness
        self.alpha = alpha
    }

    init(_ color: HexColor) {
        let r = Float((color.rgb >> 16) & 0xFF) / 255, g = Float((color.rgb >> 8) & 0xFF) / 255, b = Float(color.rgb & 0xFF) / 255
        let high = max(r, g, b), low = min(r, g, b), range = high - low
        var h: Float = 0
        if range > 0 {
            if high == r { h = (g - b) / range } else if high == g { h = 2 + (b - r) / range } else { h = 4 + (r - g) / range }
            h /= 6
            if h < 0 { h += 1 }
        }
        self.init(hue: h, saturation: high > 0 ? range / high : 0, brightness: high, alpha: color.alpha)
    }

    var rgb: UInt32 { Self.rgb(hue: hue, saturation: saturation, brightness: brightness) }

    static func rgb(hue: Float, saturation: Float, brightness: Float) -> UInt32 {
        let h = (hue >= 1 ? 0 : max(hue, 0)) * 6, i = Int(h), f = h - Float(i)
        let v = brightness, p = v * (1 - saturation), q = v * (1 - saturation * f), t = v * (1 - saturation * (1 - f))
        let (r, g, b): (Float, Float, Float)
        switch i {
        case 0: (r, g, b) = (v, t, p)
        case 1: (r, g, b) = (q, v, p)
        case 2: (r, g, b) = (p, v, t)
        case 3: (r, g, b) = (p, q, v)
        case 4: (r, g, b) = (t, p, v)
        default: (r, g, b) = (v, p, q)
        }
        func byte(_ x: Float) -> UInt32 { UInt32((min(max(x, 0), 1) * 255).rounded()) }
        return byte(r) << 16 | byte(g) << 8 | byte(b)
    }

    /// "#RRGGBB", or "#RRGGBBAA" when it's see-through.
    var hex: String { Self.hex(rgb, alpha: alpha) }

    static func hex(_ rgb: UInt32, alpha: Float) -> String {
        alpha < 0.999 ? String(format: "#%06X%02X", rgb, Int((alpha * 255).rounded())) : String(format: "#%06X", rgb)
    }
}

/// The color picker that opens from a swatch in Settings: a square of saturation and brightness, a hue bar, an opacity
/// bar where a color may be see-through (the selection), and the color's hex to type. It stands in for the Mac's color
/// panel, drawn in the theme like the rest of Settings. Every move reports the color, so the theme changes as you go.
final class ColorPicker {
    enum Part { case square, hue, alpha, hexField, swatch(Int) }

    /// Which control opened it, to tell a second click on the same swatch.
    let id: String
    let allowsAlpha: Bool
    private(set) var color: HSVColor
    let onChange: (String) -> Void
    /// The part being dragged.
    var dragging: Part?
    /// Colors from the theme, to pick one already in it.
    let suggestions: [UInt32]
    private(set) var frame = UIRect(x: 0, y: 0, width: 0, height: 0)
    private var scale: Float = 1

    init(id: String, hex: String, allowsAlpha: Bool, suggestions: [UInt32], onChange: @escaping (String) -> Void) {
        self.id = id
        self.allowsAlpha = allowsAlpha
        color = HSVColor(HexColor(hex) ?? HexColor(rgb: 0x808080))
        if !allowsAlpha { color.alpha = 1 }
        self.suggestions = suggestions
        self.onChange = onChange
    }

    // MARK: Layout

    private var pad: Float { 12 * scale }
    private var inner: Float { frame.width - pad * 2 }
    var square: UIRect { UIRect(x: frame.x + pad, y: frame.y + pad, width: inner, height: (150 * scale).rounded()) }
    var hueBar: UIRect { UIRect(x: frame.x + pad, y: square.maxY + 12 * scale, width: inner, height: 14 * scale) }
    var alphaBar: UIRect? { allowsAlpha ? UIRect(x: frame.x + pad, y: hueBar.maxY + 10 * scale, width: inner, height: 14 * scale) : nil }
    private var barsBottom: Float { (alphaBar ?? hueBar).maxY }
    var preview: UIRect { UIRect(x: frame.x + pad, y: barsBottom + 12 * scale, width: 30 * scale, height: 28 * scale) }
    var hexField: UIRect { UIRect(x: preview.maxX + 8 * scale, y: preview.y, width: frame.maxX - pad - preview.maxX - 8 * scale, height: 28 * scale) }
    private var swatchSize: Float { ((inner - 7 * 6 * scale) / 8).rounded(.down) }

    func swatch(_ i: Int) -> UIRect {
        let size = swatchSize, top = preview.maxY + 12 * scale
        return UIRect(x: frame.x + pad + Float(i % 8) * (size + 6 * scale), y: top + Float(i / 8) * (18 * scale + 6 * scale), width: size, height: 18 * scale)
    }

    private var height: Float {
        let rows = (suggestions.count + 7) / 8
        return (barsBottom - frame.y) + 12 * scale + 28 * scale + (rows > 0 ? 12 * scale + Float(rows) * 24 * scale - 6 * scale : 0) + pad
    }

    /// Placed under the control it opened from, its right edge with the control's, or above it if there's no room below.
    func place(under anchor: UIRect, in window: UIRect, scale: Float) {
        self.scale = scale
        frame = UIRect(x: 0, y: 0, width: (244 * scale).rounded(), height: 0)
        frame.height = height
        var x = anchor.maxX - frame.width, y = anchor.maxY + 6 * scale
        if y + frame.height > window.maxY - 8 * scale { y = max(anchor.y - 6 * scale - frame.height, window.y + 8 * scale) }
        x = min(max(x, window.x + 8 * scale), window.maxX - frame.width - 8 * scale)
        frame = UIRect(x: x.rounded(), y: y.rounded(), width: frame.width, height: frame.height)
    }

    func part(atX x: Float, y: Float) -> Part? {
        let slop = 4 * scale
        func near(_ r: UIRect) -> Bool { x >= r.x - slop && x <= r.maxX + slop && y >= r.y - slop && y <= r.maxY + slop }
        if square.contains(x, y) { return .square }
        if near(hueBar) { return .hue }
        if let a = alphaBar, near(a) { return .alpha }
        if hexField.contains(x, y) { return .hexField }
        for i in suggestions.indices where swatch(i).contains(x, y) { return .swatch(i) }
        return nil
    }

    // MARK: Changing it

    /// Moves the part being dragged, or just pressed, to the pointer.
    func drag(_ part: Part, toX x: Float, y: Float) {
        func fraction(_ v: Float, _ start: Float, _ length: Float) -> Float { min(max((v - start) / max(length, 1), 0), 1) }
        switch part {
        case .square:
            color.saturation = fraction(x, square.x, square.width)
            color.brightness = 1 - fraction(y, square.y, square.height)
        case .hue:
            color.hue = min(fraction(x, hueBar.x, hueBar.width), 0.9999)
        case .alpha:
            guard let a = alphaBar else { return }
            color.alpha = (fraction(x, a.x, a.width) * 100).rounded() / 100
        case .swatch(let i):
            let alpha = color.alpha
            color = HSVColor(HexColor(rgb: suggestions[i]))
            color.alpha = alpha
        case .hexField:
            return
        }
        onChange(color.hex)
    }

    /// Hex as typed (#RGB, #RRGGBB or #RRGGBBAA, the # optional) as Solanum writes it, or nil if it isn't a color. Without
    /// `allowsAlpha` the opacity is dropped.
    static func parse(_ text: String, allowsAlpha: Bool) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        let digits = t.hasPrefix("#") ? String(t.dropFirst()) : t
        guard [3, 6, 8].contains(digits.count), digits.allSatisfy(\.isHexDigit), let color = HexColor(digits) else { return nil }
        return HSVColor.hex(color.rgb, alpha: allowsAlpha ? color.alpha : 1)
    }

    /// Hex typed in: #RGB, #RRGGBB or #RRGGBBAA. False if it isn't a color.
    @discardableResult
    func typed(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        let digits = t.hasPrefix("#") ? String(t.dropFirst()) : t
        guard [3, 6, 8].contains(digits.count), digits.allSatisfy(\.isHexDigit), var parsed = HexColor(digits).map(HSVColor.init) else { return false }
        if !allowsAlpha { parsed.alpha = 1 }
        // A gray keeps the hue it had, so the square doesn't jump to red.
        if parsed.saturation == 0 { parsed.hue = color.hue }
        color = parsed
        onChange(color.hex)
        return true
    }

    // MARK: Drawing

    /// `hexText` is the field's text while it's typed in, and `caret` the caret's x within it.
    func draw(on target: Canvas, hexText: String?, caretX: Float?) {
        let c = target.raw, s = scale, fg = TerminalPalette.foreground
        // A shadow, then the panel in the chrome's color.
        sol_canvas_fill_rounded(c, frame.x - 1 * s, frame.y + 2 * s, frame.width + 2 * s, frame.height + 3 * s, 12 * s, 0x000000, 0.28)
        sol_canvas_fill_rounded(c, frame.x, frame.y, frame.width, frame.height, 10 * s, TerminalPalette.mix(TerminalPalette.chrome, TerminalPalette.background, 0.6), 1)
        sol_canvas_fill_rounded(c, frame.x, frame.y, frame.width, frame.height, 10 * s, TerminalPalette.surface, 0.5)
        sol_canvas_stroke_rounded(c, frame.x + 0.5, frame.y + 0.5, frame.width - 1, frame.height - 1, 10 * s, fg, 0.14, 1)

        // Saturation across, brightness down, in the hue.
        let sq = square, r = 6 * s
        let hueRGB = HSVColor.rgb(hue: color.hue, saturation: 1, brightness: 1)
        linear(c, sq, r, horizontal: true, [(0xFFFFFF, 1, 0), (hueRGB, 1, 1)])
        linear(c, sq, r, horizontal: false, [(0x000000, 0, 0), (0x000000, 1, 1)])
        sol_canvas_stroke_rounded(c, sq.x + 0.5, sq.y + 0.5, sq.width - 1, sq.height - 1, r, fg, 0.15, 1)
        let knobX = sq.x + color.saturation * sq.width, knobY = sq.y + (1 - color.brightness) * sq.height
        sol_canvas_fill_ellipse(c, knobX, knobY, 7 * s, 7 * s, 0x000000, 0.35)
        sol_canvas_fill_ellipse(c, knobX, knobY, 6 * s, 6 * s, 0xFFFFFF, 1)
        sol_canvas_fill_ellipse(c, knobX, knobY, 4.5 * s, 4.5 * s, color.rgb, 1)

        // The hues, red round to red.
        let hb = hueBar
        let hues: [(UInt32, Float, Float)] = (0...6).map { (HSVColor.rgb(hue: Float($0) / 6, saturation: 1, brightness: 1), 1, Float($0) / 6) }
        linear(c, hb, hb.height / 2, horizontal: true, hues)
        knob(c, x: hb.x + color.hue * hb.width, bar: hb, fill: hueRGB)

        if let ab = alphaBar {
            checkerboard(c, ab, radius: ab.height / 2)
            linear(c, ab, ab.height / 2, horizontal: true, [(color.rgb, 0, 0), (color.rgb, 1, 1)])
            knob(c, x: ab.x + color.alpha * ab.width, bar: ab, fill: color.rgb)
        }

        // What it is now, and its hex.
        let pv = preview
        checkerboard(c, pv, radius: 6 * s)
        sol_canvas_fill_rounded(c, pv.x, pv.y, pv.width, pv.height, 6 * s, color.rgb, color.alpha)
        sol_canvas_stroke_rounded(c, pv.x + 0.5, pv.y + 0.5, pv.width - 1, pv.height - 1, 6 * s, fg, 0.2, 1)
        let field = hexField, typing = hexText != nil
        sol_canvas_fill_rounded(c, field.x, field.y, field.width, field.height, 5 * s, TerminalPalette.mix(0x000000, TerminalPalette.background, 0.25), 1)
        sol_canvas_stroke_rounded(c, field.x + 0.5, field.y + 0.5, field.width - 1, field.height - 1, 5 * s, typing ? TerminalPalette.accent : fg, typing ? 0.9 : 0.12, 1)
        let text = Array((hexText ?? color.hex).utf16)
        sol_canvas_draw_label(c, field.x + 9 * s, field.y, field.width - 18 * s, field.height, text, Int32(text.count), 13 * s, 0, fg, 1)
        if let caretX {
            sol_canvas_fill_rect(c, (field.x + 9 * s + caretX).rounded(), field.y + 7 * s, max(s.rounded(), 1), field.height - 14 * s, TerminalPalette.accent, 1)
        }

        // The theme's own colors.
        for (i, rgb) in suggestions.enumerated() {
            let sw = swatch(i)
            sol_canvas_fill_rounded(c, sw.x, sw.y, sw.width, sw.height, 4 * s, rgb, 1)
            sol_canvas_stroke_rounded(c, sw.x + 0.5, sw.y + 0.5, sw.width - 1, sw.height - 1, 4 * s, fg, rgb == color.rgb ? 0.9 : 0.15, rgb == color.rgb ? 1.5 * s : 1)
        }
    }

    private func linear(_ c: OpaquePointer?, _ r: UIRect, _ radius: Float, horizontal: Bool, _ stops: [(UInt32, Float, Float)]) {
        let colors = stops.map(\.0), alphas = stops.map(\.1), positions = stops.map(\.2)
        let x1 = horizontal ? r.maxX : r.x, y1 = horizontal ? r.y : r.maxY
        colors.withUnsafeBufferPointer { cs in
            alphas.withUnsafeBufferPointer { a in
                positions.withUnsafeBufferPointer { p in
                    sol_canvas_fill_linear(c, r.x, r.y, r.width, r.height, radius, r.x, r.y, x1, y1, cs.baseAddress, a.baseAddress, p.baseAddress, Int32(stops.count))
                }
            }
        }
    }

    /// Grey and white squares behind a see-through color.
    private func checkerboard(_ c: OpaquePointer?, _ r: UIRect, radius: Float) {
        sol_canvas_fill_rounded(c, r.x, r.y, r.width, r.height, radius, 0xFFFFFF, 1)
        let cell = max((5 * scale).rounded(), 2)
        sol_canvas_push_clip(c, r.x + radius * 0.3, r.y, r.width - radius * 0.6, r.height)
        var row = 0, y = r.y
        while y < r.maxY {
            var x = r.x + (row % 2 == 0 ? 0 : cell)
            while x < r.maxX {
                sol_canvas_fill_rect(c, x, y, min(cell, r.maxX - x), min(cell, r.maxY - y), 0xC8C8C8, 1)
                x += cell * 2
            }
            y += cell
            row += 1
        }
        sol_canvas_pop_clip(c)
    }

    private func knob(_ c: OpaquePointer?, x: Float, bar: UIRect, fill: UInt32) {
        let s = scale, rad = bar.height / 2 + 2 * s
        sol_canvas_fill_ellipse(c, x, bar.midY, rad + 1 * s, rad + 1 * s, 0x000000, 0.3)
        sol_canvas_fill_ellipse(c, x, bar.midY, rad, rad, 0xFFFFFF, 1)
        sol_canvas_fill_ellipse(c, x, bar.midY, rad - 2.5 * s, rad - 2.5 * s, fill, 1)
    }
}
