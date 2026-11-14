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

    /// The file it shows, for its icon from an icon pack; nil for pages that aren't a file (git's).
    var fileName: String? {
        if let f = panel as? FileEditorPanel { return f.name }
        if let m = panel as? MarkdownPreviewPanel { return m.name }
        return nil
    }

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
    /// Where the card the pages float on starts and ends across (it's set in from the column beside a sidebar or the
    /// window's edge): the sub-tabs and page are inset from it, not the column. The column's edges when not given.
    /// (Plain numbers rather than an optional tuple: Swift 6.4's code generator crashed on that here.)
    var cardLeft: Float = -1
    var cardRight: Float = -1
    /// Where the bottom card ends (above the status bar's gap); the column's bottom when not given.
    var cardBottom: Float = -1
    private var hasCard: Bool { cardRight > cardLeft }
    private var span: (x0: Float, x1: Float) { hasCard ? (cardLeft, cardRight) : (column.x, column.maxX) }

    var stripHeight: Float { (30 * scale).rounded() }
    private var editorHeight: Float {
        guard hasEditors else { return 0 }
        guard showsTerminal else { return column.height }
        let wanted = (column.height * fraction).rounded()
        return min(max(wanted, (120 * scale).rounded()), max(column.height - (80 * scale).rounded(), 0))
    }

    /// The pages, strip and all; nil without any.
    var editor: UIRect? { hasEditors ? UIRect(x: column.x, y: column.y, width: column.width, height: editorHeight) : nil }
    var strip: UIRect? { editor.map { UIRect(x: span.x0, y: $0.y, width: span.x1 - span.x0, height: stripHeight) } }
    /// How far the sub-tabs and the page float in from the card's edges, so their corners (`EditorStrip.radius`) are
    /// concentric with the card's (8) and the gaps around them even, as on the Mac.
    var inset: Float { (3 * scale).rounded() }
    /// The active page, under the strip: a rounded panel of its own inside the card, inset as the sub-tabs are.
    var page: UIRect? {
        editor.map { UIRect(x: span.x0 + inset, y: $0.y + stripHeight, width: max(span.x1 - span.x0 - 2 * inset, 0), height: max($0.height - stripHeight - inset, 0)) }
    }
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
        // Inside its card, set in from the card's edges as the page is, so its first and last columns aren't cut by the
        // card's rounded outline.
        let m: Float = hasCard ? inset : 0
        let x0 = span.x0 + m, x1 = span.x1 - m, bottom = min(column.maxY, cardBottom > 0 ? cardBottom : column.maxY) - m
        let top = editor.map { showsTerminal ? $0.maxY + bandHeight : column.y } ?? column.y
        return UIRect(x: x0, y: top, width: max(x1 - x0, 0), height: max(bottom - top, 0))
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
    /// The sub-tabs' and page's corners: concentric with the card's, `inset` in.
    static func radius(_ scale: Float) -> Float { 5 * scale }
    private var inset: Float { (3 * scale).rounded() }
    /// How far the active sub-tab's sides curve out where they meet the page.
    private var flare: Float { (4 * scale).rounded() }

    var terminalButton: UIRect {
        let side = (22 * scale).rounded()
        return UIRect(x: strip.maxX - side - (8 * scale).rounded(), y: (strip.y + (strip.height - side) / 2).rounded(), width: side, height: side)
    }

    private var gap: Float { inset }
    private var arrowWidth: Float { (22 * scale).rounded() }
    /// Where sub-tabs can go when they all fit: from the strip's start to the terminal button.
    private var room: (start: Float, end: Float) { (strip.x + inset, terminalButton.x - (4 * scale).rounded()) }

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
            let r = UIRect(x: x, y: strip.y + inset, width: w, height: strip.height - 2 * inset)
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

    /// The active sub-tab, if it's docked (all of it showing, not being dragged): its rect, and whether it's the first,
    /// on the page's left edge, where its side runs straight down into the page's (whose corner is square then).
    func docked(active: Int, dragged: Int?) -> (rect: UIRect, flush: Bool)? {
        let laid = tabs, v = viewport
        guard laid.indices.contains(active), active != dragged else { return nil }
        let r = laid[active].rect
        guard r.x >= v.x - 0.5, r.maxX <= v.maxX + 0.5 else { return nil }
        return (r, !overflows && r.x <= room.start + 0.5)
    }

    /// The active sub-tab opening onto the page below, as a main tab opens onto its card: rounded on top, its sides
    /// running down to the page and curving out onto its edge, or, `flush`, the page's left edge carried straight up.
    /// Backdrops throughout, so it's one surface with the page however see-through the window is.
    private func drawDock(_ r: UIRect, flush: Bool) {
        let c = canvas.raw, f = flare, rad = Self.radius(scale), bottom = strip.maxY
        let page = TerminalPalette.page, card = TerminalPalette.background
        let x0 = flush ? r.x : r.x - f, x1 = r.maxX + f
        sol_canvas_backdrop_rect(c, x0, r.y, x1 - x0, bottom - r.y, page)
        // The card again outside its rounded top (and either side of it, where the feet go).
        let top: [Float] = [r.x, r.y, r.width, bottom - r.y + rad]
        top.withUnsafeBufferPointer { sol_canvas_backdrop_frame(c, x0, r.y, x1 - x0, bottom - r.y, $0.baseAddress, 1, rad, card) }
        // The feet: the page's color in the corner outside a quarter circle, curving from the tab's side onto the page.
        let far: Float = 100 * scale
        var feet: [([Float], UIRect)] = [([r.maxX, bottom - f - far, far + f, far + f], UIRect(x: r.maxX, y: bottom - f, width: f, height: f))]
        if !flush { feet.append(([r.x - f - far, bottom - f - far, far + f, far + f], UIRect(x: r.x - f, y: bottom - f, width: f, height: f))) }
        for (shape, o) in feet {
            shape.withUnsafeBufferPointer { sol_canvas_backdrop_frame(c, o.x, o.y, o.width, o.height, $0.baseAddress, 1, f, page) }
        }
    }

    /// `dragged` is a sub-tab being dragged, shown faint where it was; `marker`, where it would land along the strip.
    /// On the card's own background, as on the Mac: the active sub-tab opens onto the page below, one piece with it;
    /// the others are just their names, a pill on hover.
    func draw(active: Int, hovered: Part?, showsTerminal: Bool, focused: Bool, dragged: Int? = nil, marker: Int? = nil) {
        let c = canvas.raw, fg = TerminalPalette.foreground, rad = Self.radius(scale)
        let v = viewport, laid = tabs, dock = docked(active: active, dragged: dragged)
        // A little past the viewport, for the docked tab's curved feet.
        sol_canvas_push_clip(c, v.x - flare, v.y, v.width + 2 * flare, v.height)
        for (i, t) in laid.enumerated() where t.rect.maxX > v.x && t.rect.x < v.maxX {
            let r = t.rect, isActive = i == active, faint: Float = i == dragged ? 0.35 : 1
            let hoveredHere = dragged == nil && (hovered == .tab(i) || hovered == .close(i))
            if isActive, let dock {
                drawDock(dock.rect, flush: dock.flush)
            } else if isActive {
                // Lifted (being dragged) or partly scrolled away: a pill of the same surface.
                sol_canvas_fill_rounded(c, r.x, r.y, r.width, r.height, rad, TerminalPalette.page, faint)
            } else if hoveredHere {
                sol_canvas_fill_rounded(c, r.x, r.y, r.width, r.height, rad, TerminalPalette.surface, 0.5)
            }
            let item = items[i]
            // A file's icon from the icon pack in use, else Solanum's own.
            let side = (14 * scale).rounded()
            if !(item.fileName.map { FileIcons.draw(name: $0, directory: false, x: r.x + 8 * scale, y: (r.midY - side / 2).rounded(), size: side, on: canvas, alpha: faint) } ?? false) {
                sol_canvas_draw_icon(c, r.x + 6 * scale, r.y, 18 * scale, r.height, item.glyph, 10.5 * scale, isActive ? TerminalPalette.accent : fg, (isActive ? 0.95 : 0.55) * faint)
            }
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
    /// `thin`: the size and line of the icon font's icons beside it (the status bar), rather than the strip's bolder one.
    static func drawTerminalSymbol(on canvas: Canvas, centerX: Float, centerY: Float, scale: Float, color: UInt32, alpha: Float, thin: Bool = false) {
        // The status bar's is drawn smaller throughout, as its neighbors are.
        let s = thin ? scale * 0.8 : scale
        let c = canvas.raw, t = thin ? max((0.75 * scale * 2).rounded() / 2, 1) : max((1.25 * s * 2).rounded() / 2, 1)
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
