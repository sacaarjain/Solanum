import CCanvas
import Foundation

/// The terminal's and the chrome's colors, from the current theme. All 0xRRGGBB.
enum TerminalPalette {
    static var current = ThemeColors(ThemeSpecs.solanumDefault)
    static var boldIsBright = false

    static var background: UInt32 { current.background }
    static var backgroundBottom: UInt32 { current.backgroundBottom }
    static var foreground: UInt32 { current.foreground }
    static var cursor: UInt32 { current.cursor }
    static var selection: UInt32 { current.selection }
    static var accent: UInt32 { current.accent }
    static var chrome: UInt32 { current.chrome }
    static var surface: UInt32 { current.surface }
    static var isDark: Bool { current.isDark }
    static var ansi: [UInt32] { current.ansi }

    static func indexed(_ i: Int) -> UInt32 {
        if i < 16 { return ansi[i] }
        if i < 232 {
            let n = i - 16
            let levels: [UInt32] = [0, 95, 135, 175, 215, 255]
            return levels[n / 36] << 16 | levels[(n / 6) % 6] << 8 | levels[n % 6]
        }
        let g = UInt32(8 + (i - 232) * 10)
        return g << 16 | g << 8 | g
    }

    /// A cell's packed color (`TermColor`), or `fallback` for the default.
    @inline(__always) static func resolve(_ packed: UInt32, default fallback: UInt32) -> UInt32 {
        switch packed >> 24 {
        case 1: return indexed(Int(packed & 0xFF))
        case 2: return packed & 0xFF_FFFF
        default: return fallback
        }
    }

    /// `amount` of `a`, the rest `b`.
    static func mix(_ a: UInt32, _ b: UInt32, _ amount: Float) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let x = Float((a >> shift) & 0xFF), y = Float((b >> shift) & 0xFF)
            return UInt32(x * amount + y * (1 - amount)) << shift
        }
        return channel(16) | channel(8) | channel(0)
    }

    static func tuple(_ rgb: UInt32) -> (UInt8, UInt8, UInt8) {
        (UInt8((rgb >> 16) & 0xFF), UInt8((rgb >> 8) & 0xFF), UInt8(rgb & 0xFF))
    }
}

/// Owns a canvas: a window's, or a bitmap for snapshots.
final class Canvas {
    let raw: OpaquePointer
    private(set) var metrics: SolMetrics
    /// Empty space around the terminal, in pixels: 6 at 100% display scaling.
    var padding: Float = 6
    /// An icon pack's SVGs, images and fonts made on this canvas, by their file (see FileIcons); -1 for one that can't be.
    var iconCache: [String: Int32] = [:]
    /// The part of the canvas the terminal has, before padding: all of it unless a window's chrome takes some.
    var terminalArea: UIRect?
    var contentX: Float { (terminalArea?.x ?? 0) + padding }
    var contentY: Float { (terminalArea?.y ?? 0) + padding }

    private init(raw: OpaquePointer) {
        self.raw = raw
        metrics = sol_canvas_metrics(raw)
    }

    convenience init?(window: UnsafeMutableRawPointer, fontPixels: Float) {
        var hr: Int32 = 0
        guard let raw = sol_canvas_create_window(window, fontPixels, &hr) else {
            Canvas.lastError = hr
            return nil
        }
        self.init(raw: raw)
    }

    convenience init?(width: Int, height: Int, fontPixels: Float) {
        var hr: Int32 = 0
        guard let raw = sol_canvas_create_bitmap(Int32(width), Int32(height), fontPixels, &hr) else {
            Canvas.lastError = hr
            return nil
        }
        self.init(raw: raw)
    }

    deinit { sol_canvas_destroy(raw) }

    /// The HRESULT of the last failed creation.
    static var lastError: Int32 = 0

    func setFontPixels(_ pixels: Float) {
        if sol_canvas_set_font_pixels(raw, pixels) >= 0 { metrics = sol_canvas_metrics(raw) }
    }

    func setFont(family: String, pixels: Float, lineHeight: Float) {
        if sol_canvas_set_font(raw, Array(family.utf16) + [0], pixels, lineHeight) >= 0 { metrics = sol_canvas_metrics(raw) }
    }

    private var loadedArt: [String: Int32] = [:]

    /// Draws a piece of Solanum's art (`ArtData`) into a rectangle, from the rendering made for this display scale.
    func drawArt(_ name: String, _ r: UIRect, scale: Float, alpha: Float = 1) {
        let key = "\(name)@\(min(max(Int(scale.rounded(.up)), 1), 4))"
        var image = loadedArt[key]
        if image == nil {
            guard let encoded = ArtData.images[key], let png = Data(base64Encoded: encoded) else { return }
            image = png.withUnsafeBytes { sol_canvas_load_image(raw, $0.bindMemory(to: UInt8.self).baseAddress, Int32($0.count)) }
            loadedArt[key] = image
        }
        sol_canvas_draw_image(raw, image ?? -1, r.x, r.y, r.width, r.height, alpha)
    }

    /// A theme's planet (see Core/PlanetArt.swift), as its icon, filling the square `r`: rendered once for each size, at
    /// the exact pixel size, so it stays sharp.
    func drawPlanet(_ planet: PlanetArt.Planet, _ r: UIRect, alpha: Float = 1) {
        let side = Int(min(r.width, r.height).rounded())
        guard side >= 8, side <= 1200 else { return }
        let key = "planet:\(planet.rawValue)@\(side)"
        var image = loadedArt[key]
        if image == nil {
            let pixels = PlanetArt.pixels(planet, size: side, icon: true)
            image = pixels.withUnsafeBufferPointer { sol_canvas_load_rgba(raw, $0.baseAddress, Int32(side), Int32(side), 0xFFFF_FFFF) }
            loadedArt[key] = image
        }
        let x = (r.x + (r.width - Float(side)) / 2).rounded(), y = (r.y + (r.height - Float(side)) / 2).rounded()
        sol_canvas_draw_image(raw, image ?? -1, x, y, Float(side), Float(side), alpha)
    }

    func savePNG(to path: String) -> Bool {
        let wide = Array(path.utf16) + [0]
        return sol_canvas_save_png(raw, wide) >= 0
    }
}

/// A selection in absolute lines, so it stays on the same text as the terminal scrolls.
struct TerminalSelection: Equatable {
    var anchor: (line: Int, col: Int)
    var head: (line: Int, col: Int)

    static func == (a: TerminalSelection, b: TerminalSelection) -> Bool {
        a.anchor == b.anchor && a.head == b.head
    }

    var ordered: (start: (line: Int, col: Int), end: (line: Int, col: Int)) {
        if anchor.line < head.line || (anchor.line == head.line && anchor.col <= head.col) { return (anchor, head) }
        return (head, anchor)
    }

    var isEmpty: Bool { anchor == head }

    /// `ordered`, with an end at the very start of a row moved back to the end of the row above.
    func trimmed(cols: Int) -> (start: (line: Int, col: Int), end: (line: Int, col: Int)) {
        let (start, end) = ordered
        if end.col == 0 && end.line > start.line { return (start: start, end: (line: end.line - 1, col: cols)) }
        return (start: start, end: end)
    }

    @inline(__always) func contains(line: Int, col: Int) -> Bool {
        let (s, e) = ordered
        if line < s.line || line > e.line { return false }
        if line == s.line && col < s.col { return false }
        if line == e.line && col >= e.col { return false }
        return true
    }

    func text(in terminal: Terminal) -> String {
        let (s, e) = ordered
        var out = ""
        for a in s.line...e.line {
            guard let l = terminal.line(abs: a) else { continue }
            let from = a == s.line ? s.col : 0
            if a == e.line && e.col == 0 { break }
            let to = a == e.line ? e.col - 1 : terminal.cols - 1
            out += l.text(from: from, to: to, trim: !l.wrapped)
            if !l.wrapped && a != e.line { out += "\r\n" }
        }
        return out
    }
}

/// Draws a terminal. One function for the window and for snapshots, so a snapshot shows what the window would.
struct TerminalRenderer {
    /// Text left undrawn, by line: "[Image #N]" where its image is drawn instead.
    var hiddenText: [Int: [Range<Int>]] = [:]
    let canvas: Canvas
    let terminal: Terminal
    var scrollOffset = 0
    var selection: TerminalSelection?
    var focused = true
    /// Off for the dark half of a blink.
    var cursorShown = true
    /// The DECSCUSR shape to use when the program hasn't asked for one: 2 block, 4 underline, 6 bar.
    var cursorStyle = 6

    /// Grid size for a client area of this many pixels.
    static func grid(width: Int, height: Int, canvas: Canvas) -> (cols: Int, rows: Int) {
        let w = max((canvas.terminalArea?.width ?? Float(width)) - canvas.padding * 2, 0)
        let h = max((canvas.terminalArea?.height ?? Float(height)) - canvas.padding * 2, 0)
        return (max(Int(w / canvas.metrics.cellWidth), 2), max(Int(h / canvas.metrics.cellHeight), 1))
    }

    /// Returns a negative HRESULT if the frame couldn't be drawn.
    @discardableResult
    func draw() -> Int32 {
        let begun = sol_canvas_begin(canvas.raw, TerminalPalette.background)
        guard begun >= 0 else { return begun }
        drawContents()
        return sol_canvas_end(canvas.raw)
    }

    /// The terminal, within a frame someone else has begun.
    func drawContents() {
        let top = terminal.screenTopAbs - scrollOffset
        for row in 0..<terminal.rows {
            if let line = terminal.line(abs: top + row) { draw(line, abs: top + row, row: row) }
        }
        drawCursor(top: top)
        drawScrollPosition()
    }

    private func colors(_ cell: Cell, selected: Bool) -> (fg: UInt32, bg: UInt32) {
        var fgPacked = cell.fg
        // Bold in one of the first eight colors takes its bright one, as older terminals did, when asked for.
        if TerminalPalette.boldIsBright, cell.flags.contains(.bold), fgPacked >> 24 == 1, fgPacked & 0xFF < 8 { fgPacked += 8 }
        var fg = TerminalPalette.resolve(fgPacked, default: TerminalPalette.foreground)
        var bg = TerminalPalette.resolve(cell.bg, default: TerminalPalette.background)
        if cell.flags.contains(.inverse) != terminal.reverseVideo { swap(&fg, &bg) }
        if selected { bg = TerminalPalette.selection }
        if cell.flags.contains(.invisible) { fg = bg }
        else if cell.flags.contains(.dim) { fg = TerminalPalette.mix(fg, bg, 0.6) }
        return (fg, bg)
    }

    private func style(_ flags: CellFlags) -> Int32 {
        (flags.contains(.bold) ? Int32(SOL_STYLE_BOLD) : 0) | (flags.contains(.italic) ? Int32(SOL_STYLE_ITALIC) : 0)
    }

    private func draw(_ line: Line, abs: Int, row: Int) {
        let m = canvas.metrics
        let y = canvas.contentY + Float(row) * m.cellHeight
        let cols = terminal.cols

        // Backgrounds first, in runs, so that a glyph overhanging its cell isn't cut off by its neighbor's.
        var col = 0
        while col < cols {
            let start = col
            let bg = colors(line.cell(col), selected: selection?.contains(line: abs, col: col) ?? false).bg
            col += 1
            while col < cols, colors(line.cell(col), selected: selection?.contains(line: abs, col: col) ?? false).bg == bg { col += 1 }
            if bg != TerminalPalette.background {
                sol_canvas_fill_rect(canvas.raw, canvas.contentX + Float(start) * m.cellWidth, y,
                                     Float(col - start) * m.cellWidth, m.cellHeight, bg, 1)
            }
        }

        var scalars: [UInt32] = []
        var widths: [UInt8] = []
        var runStart = 0, runColor: UInt32 = 0, runStyle: Int32 = 0
        func flush() {
            guard !scalars.isEmpty else { return }
            sol_canvas_draw_cells(canvas.raw, canvas.contentX + Float(runStart) * m.cellWidth, y, scalars, widths,
                                  Int32(scalars.count), runColor, runStyle)
            scalars.removeAll(keepingCapacity: true)
            widths.removeAll(keepingCapacity: true)
        }
        col = 0
        while col < cols {
            let cell = line.cell(col)
            defer { col += 1 }
            if cell.width == 0 { continue }
            let (fg, _) = colors(cell, selected: selection?.contains(line: abs, col: col) ?? false)
            let cellStyle = style(cell.flags)
            drawDecorations(cell, col: col, y: y, color: fg)
            let extras = line.extras?[col]
            // "[Image #N]" under its thumbnail (see ImageChips) isn't drawn.
            if let covered = hiddenText[abs], covered.contains(where: { $0.contains(col) }) {
                flush()
                continue
            }
            if cell.ch == 0 || cell.ch == 32 || cell.flags.contains(.invisible) {
                flush()
                continue
            }
            if let extras, let base = Unicode.Scalar(cell.ch) {
                flush()
                let text = Array((String(Character(base)) + extras).utf16)
                sol_canvas_draw_text(canvas.raw, canvas.contentX + Float(col) * m.cellWidth, y, Int32(cell.width), text,
                                     Int32(text.count), fg, cellStyle)
                continue
            }
            if !scalars.isEmpty, fg != runColor || cellStyle != runStyle { flush() }
            if scalars.isEmpty {
                runStart = col
                runColor = fg
                runStyle = cellStyle
            }
            scalars.append(cell.ch)
            widths.append(max(cell.width, 1))
        }
        flush()
    }

    private func drawDecorations(_ cell: Cell, col: Int, y: Float, color: UInt32) {
        guard !cell.flags.isDisjoint(with: [.underline, .doubleUnderline, .curlyUnderline, .strike]) else { return }
        let m = canvas.metrics
        let x = canvas.contentX + Float(col) * m.cellWidth
        let width = m.cellWidth * Float(max(cell.width, 1))
        if !cell.flags.isDisjoint(with: CellFlags.anyUnderline) {
            sol_canvas_fill_rect(canvas.raw, x, y + m.underlineY, width, m.lineThickness, color, 1)
        }
        if cell.flags.contains(.doubleUnderline) {
            sol_canvas_fill_rect(canvas.raw, x, y + m.underlineY + m.lineThickness * 2, width, m.lineThickness, color, 1)
        }
        if cell.flags.contains(.strike) {
            sol_canvas_fill_rect(canvas.raw, x, y + m.strikeY, width, m.lineThickness, color, 1)
        }
    }

    private func drawCursor(top: Int) {
        guard terminal.cursorVisible, scrollOffset == 0, cursorShown || !focused else { return }
        let m = canvas.metrics
        let col = min(terminal.cursorX, terminal.cols - 1)
        let line = terminal.line(abs: top + terminal.cursorY)
        let cell = line?.cell(col) ?? Cell()
        let x = canvas.contentX + Float(col) * m.cellWidth
        let y = canvas.contentY + Float(terminal.cursorY) * m.cellHeight
        let width = m.cellWidth * Float(max(cell.width, 1))
        guard focused else {
            sol_canvas_stroke_rect(canvas.raw, x, y, width, m.cellHeight, TerminalPalette.cursor, m.lineThickness)
            return
        }
        switch terminal.cursorShape.flatMap({ $0 == 0 ? nil : $0 }) ?? cursorStyle {
        case 1, 2:
            sol_canvas_fill_rect(canvas.raw, x, y, width, m.cellHeight, TerminalPalette.cursor, 1)
            if cell.ch != 0, cell.ch != 32 {
                var scalar = cell.ch
                var cells = max(cell.width, 1)
                sol_canvas_draw_cells(canvas.raw, x, y, &scalar, &cells, 1, TerminalPalette.background, style(cell.flags))
            }
        case 3, 4:
            sol_canvas_fill_rect(canvas.raw, x, y + m.cellHeight - m.lineThickness * 2, width, m.lineThickness * 2, TerminalPalette.cursor, 1)
        default:
            sol_canvas_fill_rect(canvas.raw, x, y, max(m.lineThickness * 2, 2), m.cellHeight, TerminalPalette.cursor, 1)
        }
    }

    /// While scrolled back: how far, on the right edge.
    private func drawScrollPosition() {
        guard scrollOffset > 0 else { return }
        let m = canvas.metrics
        let height = Float(terminal.rows) * m.cellHeight
        let total = Float(terminal.scrollback.count + terminal.rows)
        let thumb = max(height * Float(terminal.rows) / total, 16)
        let position = 1 - Float(scrollOffset) / Float(max(terminal.scrollback.count, 1))
        let x = canvas.contentX + Float(terminal.cols) * m.cellWidth + 1
        sol_canvas_fill_rect(canvas.raw, x, canvas.contentY + (height - thumb) * position, 3, thumb, TerminalPalette.foreground, 0.4)
    }
}
