import CCanvas
import Foundation
import WinSDK

// Pages open in a tab show above its terminal, as on the Mac (EditorArea.swift there): a strip of sub-tabs, then the
// active page (Git Graph, Git Changes, a commit, a file), a line that can be dragged, and the terminal below. The
// terminal button at the strip's right end hides or shows the terminal.

/// A page open above a tab's terminal.
final class EditorItem {
    /// Tells one page from another, so opening the same thing again goes back to it.
    let key: String
    var title: String
    /// Its icon in the strip (Segoe Fluent Icons).
    let glyph: UInt16
    let panel: ColumnPanel

    init(key: String, title: String, glyph: UInt16, panel: ColumnPanel) {
        self.key = key
        self.title = title
        self.glyph = glyph
        self.panel = panel
    }

    enum Glyph {
        static let graph: UInt16 = 0xF003       // branch-like flow
        static let changes: UInt16 = 0xE70F     // pencil
        static let commit: UInt16 = 0xE91F      // a ringed dot
        static let file: UInt16 = 0xE7C3        // a page
        static let image: UInt16 = 0xEB9F       // a photo
        static let terminal: UInt16 = 0xE756    // command prompt
    }
}

extension FileKind {
    /// Its icon on Windows (Segoe Fluent Icons), as the Mac shows an SF Symbol for it (FileSidebarView.symbol).
    var glyph: UInt16 {
        switch self {
        case .image: return 0xEB9F   // a photo
        case .archive: return 0xE7B8 // a package
        case .pdf: return 0xEA90     // PDF
        case .video: return 0xE714   // a film camera
        case .audio: return 0xE8D6   // a note
        case .text: return 0xE8A5    // a page with lines
        case .code: return 0xE943    // </>
        case .other: return 0xE7C3   // a page
        }
    }
}

/// Where a tab's column goes: the pages on top, the line between, and the terminal below.
struct EditorSplit {
    /// The whole column.
    let column: UIRect
    let scale: Float
    let hasEditors: Bool
    let showsTerminal: Bool
    /// How much of the column the pages take.
    let fraction: Float

    var stripHeight: Float { (30 * scale).rounded() }
    private var editorHeight: Float {
        guard hasEditors else { return 0 }
        guard showsTerminal else { return column.height }
        let wanted = (column.height * fraction).rounded()
        return min(max(wanted, (120 * scale).rounded()), max(column.height - (80 * scale).rounded(), 0))
    }

    /// The pages, strip and all; nil without any.
    var editor: UIRect? { hasEditors ? UIRect(x: column.x, y: column.y, width: column.width, height: editorHeight) : nil }
    var strip: UIRect? { editor.map { UIRect(x: $0.x, y: $0.y, width: $0.width, height: stripHeight) } }
    /// The active page, under the strip.
    var page: UIRect? { editor.map { UIRect(x: $0.x, y: $0.y + stripHeight, width: $0.width, height: max($0.height - stripHeight, 0)) } }
    /// The band between pages and terminal, as on the Mac.
    var bandHeight: Float { (6 * scale).rounded() }
    /// The band, and a couple of pixels either side of it, which drag it.
    var divider: UIRect? {
        guard hasEditors, showsTerminal, let e = editor else { return nil }
        let grab = (2 * scale).rounded()
        return UIRect(x: e.x, y: e.maxY - grab, width: e.width, height: bandHeight + grab * 2)
    }
    /// Where the terminal goes. Hidden, it keeps the size it would have, so the shell isn't resized for nothing.
    var terminal: UIRect {
        guard let e = editor, showsTerminal else { return column }
        let top = e.maxY + bandHeight
        return UIRect(x: column.x, y: top, width: column.width, height: max(column.maxY - top, 0))
    }
    /// The fraction that puts the line at `y`.
    func fraction(atY y: Float) -> Float { min(max((y - column.y) / max(column.height, 1), 0.15), 0.85) }
}

/// The strip of sub-tabs: what's where, and drawing it. When they don't all fit, arrows come at both ends, as on the tab
/// bar, and the sub-tabs scroll between them (never under them).
struct EditorStrip {
    let canvas: Canvas
    let strip: UIRect
    let scale: Float
    let items: [EditorItem]
    /// How far the sub-tabs are scrolled along, in pixels; clamped to what there is.
    var scroll: Float = 0

    private static let pixels: Float = 11.5

    var terminalButton: UIRect {
        let side = (22 * scale).rounded()
        return UIRect(x: strip.maxX - side - (8 * scale).rounded(), y: (strip.y + (strip.height - side) / 2).rounded(), width: side, height: side)
    }

    private var gap: Float { (2 * scale).rounded() }
    private var arrowWidth: Float { (22 * scale).rounded() }
    /// Where sub-tabs can go when they all fit: from the strip's start to the terminal button.
    private var room: (start: Float, end: Float) { (strip.x + (6 * scale).rounded(), terminalButton.x - (4 * scale).rounded()) }

    private var widths: [Float] {
        items.map { item in
            let units = Array(item.title.utf16)
            let text = sol_canvas_measure_label(canvas.raw, units, Int32(units.count), Self.pixels * scale, 0)
            return min(max(text + 56 * scale, 90 * scale), 260 * scale).rounded()
        }
    }
    private var contentWidth: Float { widths.reduce(0, +) + gap * Float(max(items.count - 1, 0)) }

    var overflows: Bool { contentWidth > room.end - room.start }
    var scrollLeft: UIRect { UIRect(x: strip.x + (4 * scale).rounded(), y: strip.y + 3 * scale, width: arrowWidth, height: strip.height - 6 * scale) }
    var scrollRight: UIRect { UIRect(x: room.end - arrowWidth, y: strip.y + 3 * scale, width: arrowWidth, height: strip.height - 6 * scale) }
    /// Where the sub-tabs show: between the arrows when there are any.
    var viewport: UIRect {
        guard overflows else { return UIRect(x: room.start, y: strip.y, width: room.end - room.start, height: strip.height) }
        let x = scrollLeft.maxX + gap
        return UIRect(x: x, y: strip.y, width: max(scrollRight.x - gap - x, 0), height: strip.height)
    }
    var maxScroll: Float { overflows ? max(contentWidth - viewport.width, 0) : 0 }
    private var offset: Float { min(max(scroll, 0), maxScroll) }

    /// Each sub-tab: its rectangle and its close button, scrolled. Some may be outside the viewport.
    var tabs: [(rect: UIRect, close: UIRect)] {
        var x = viewport.x - offset
        var out: [(UIRect, UIRect)] = []
        for w in widths {
            let r = UIRect(x: x, y: strip.y + (3 * scale).rounded(), width: w, height: strip.height - (4 * scale).rounded())
            let side = (16 * scale).rounded()
            out.append((r, UIRect(x: r.maxX - side - (4 * scale).rounded(), y: (r.midY - side / 2).rounded(), width: side, height: side)))
            x += w + gap
        }
        return out
    }

    /// The scroll that shows all of sub-tab `i`, starting from `scroll`.
    func revealing(_ i: Int) -> Float {
        guard overflows, tabs.indices.contains(i) else { return 0 }
        let r = tabs[i].rect, v = viewport
        var s = offset
        if r.x < v.x { s -= v.x - r.x } else if r.maxX > v.maxX { s += r.maxX - v.maxX }
        return min(max(s, 0), maxScroll)
    }

    /// Where a sub-tab dragged along the strip to `x` would go: the index it'd go in front of (the count, for the end).
    func insertion(atX x: Float) -> Int { tabs.firstIndex { $0.rect.x + $0.rect.width / 2 > x } ?? items.count }

    enum Part: Equatable { case tab(Int), close(Int), terminal, scrollLeft, scrollRight }

    func part(atX x: Float, y: Float) -> Part? {
        if terminalButton.contains(x, y) { return .terminal }
        if overflows {
            if scrollLeft.contains(x, y) { return .scrollLeft }
            if scrollRight.contains(x, y) { return .scrollRight }
        }
        guard viewport.contains(x, y) else { return nil }
        for (i, t) in tabs.enumerated() where t.rect.contains(x, y) {
            return t.close.contains(x, y) ? .close(i) : .tab(i)
        }
        return nil
    }

    /// `dragged` is a sub-tab being dragged, shown faint where it was; `marker`, where it would land along the strip.
    func draw(active: Int, hovered: Part?, showsTerminal: Bool, focused: Bool, dragged: Int? = nil, marker: Int? = nil) {
        let c = canvas.raw, fg = TerminalPalette.foreground
        sol_canvas_backdrop_rect(c, strip.x, strip.y, strip.width, strip.height, TerminalPalette.chrome)
        sol_canvas_fill_rect(c, strip.x, strip.maxY - 1, strip.width, 1, fg, 0.10)
        let v = viewport, laid = tabs
        sol_canvas_push_clip(c, v.x, v.y, v.width, v.height)
        for (i, t) in laid.enumerated() where t.rect.maxX > v.x && t.rect.x < v.maxX {
            let r = t.rect, isActive = i == active, faint: Float = i == dragged ? 0.35 : 1
            let hoveredHere = dragged == nil && (hovered == .tab(i) || hovered == .close(i))
            if isActive || hoveredHere {
                sol_canvas_fill_rounded(c, r.x, r.y, r.width, r.height, 5 * scale, TerminalPalette.surface, (isActive ? 1 : 0.5) * faint)
            }
            if isActive {
                // The accent underline, dimmer while the keyboard is in the terminal.
                sol_canvas_fill_rounded(c, r.x + 8 * scale, r.maxY - 2 * scale, r.width - 16 * scale, 2 * scale, 1 * scale, TerminalPalette.accent, (focused ? 1 : 0.5) * faint)
            }
            let item = items[i]
            sol_canvas_draw_icon(c, r.x + 6 * scale, r.y, 18 * scale, r.height, item.glyph, 10.5 * scale, isActive ? TerminalPalette.accent : fg, (isActive ? 0.95 : 0.55) * faint)
            let units = Array(item.title.utf16)
            sol_canvas_draw_label(c, r.x + 28 * scale, r.y, r.width - 52 * scale, r.height, units, Int32(units.count), Self.pixels * scale, 0, fg, (isActive ? 1 : 0.6) * faint)
            if (isActive || hoveredHere) && dragged == nil {
                let x = t.close
                if hovered == .close(i) { sol_canvas_fill_rounded(c, x.x, x.y, x.width, x.height, 4 * scale, fg, 0.12) }
                sol_canvas_draw_icon(c, x.x, x.y, x.width, x.height, 0xE8BB, 7.5 * scale, fg, 0.65)
            }
        }
        // Where a sub-tab dragged along the strip would land, as the tab bar shows it.
        if let marker, let dragged, marker != dragged, marker != dragged + 1, !laid.isEmpty {
            let x = marker < laid.count ? laid[marker].rect.x - gap / 2 : laid[laid.count - 1].rect.maxX + gap / 2
            let r = laid[0].rect
            sol_canvas_fill_rounded(c, x - 1.5 * scale, r.y + 2 * scale, 3 * scale, r.height - 4 * scale, 1.5 * scale, TerminalPalette.accent, 1)
        }
        sol_canvas_pop_clip(c)
        if overflows {
            // Faint when there's nothing more that way, as on the tab bar.
            let arrows: [(Part, UIRect, UInt16, Bool)] = [(.scrollLeft, scrollLeft, 0xE76B, offset > 0.5), (.scrollRight, scrollRight, 0xE76C, offset < maxScroll - 0.5)]
            for (part, r, glyph, more) in arrows {
                let on = more && hovered == part
                if on { sol_canvas_fill_rounded(c, r.x, r.y, r.width, r.height, 6 * scale, TerminalPalette.surface, 0.7) }
                sol_canvas_draw_icon(c, r.x, r.y, r.width, r.height, glyph, 10 * scale, fg, more ? (on ? 0.95 : 0.7) : 0.18)
            }
        }
        let b = terminalButton
        if hovered == .terminal { sol_canvas_fill_rounded(c, b.x, b.y, b.width, b.height, 5 * scale, TerminalPalette.surface, 0.7) }
        Self.drawTerminalSymbol(on: canvas, centerX: b.x + b.width / 2, centerY: b.midY, scale: scale, color: showsTerminal ? TerminalPalette.accent : fg,
                                alpha: showsTerminal ? 1 : (hovered == .terminal ? 0.9 : 0.55))
    }

    /// The Mac's terminal symbol (SF Symbols' "terminal", as its strip shows): a rounded window with a prompt, `>_`.
    static func drawTerminalSymbol(on canvas: Canvas, centerX: Float, centerY: Float, scale s: Float, color: UInt32, alpha: Float) {
        let c = canvas.raw, t = max((1.25 * s * 2).rounded() / 2, 1)
        let w = (15 * s).rounded(), h = (12 * s).rounded()
        let x = (centerX - w / 2).rounded() + t / 2, y = (centerY - h / 2).rounded() + t / 2
        sol_canvas_stroke_rounded(c, x, y, w - t, h - t, 3 * s, color, alpha, t)
        // The chevron, then the cursor's underscore after it.
        let px = x + 3.5 * s, py = y + 3.5 * s, ch = 4 * s
        sol_canvas_line(c, px, py, px + ch * 0.6, py + ch / 2, color, alpha, t)
        sol_canvas_line(c, px + ch * 0.6, py + ch / 2, px, py + ch, color, alpha, t)
        sol_canvas_line(c, x + 7.5 * s, py + ch, x + 11 * s, py + ch, color, alpha, t)
    }
}
