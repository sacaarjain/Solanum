import CCanvas
import Foundation

/// Draws every dropdown in the app the one way, as the Mac's ThemedDropdown looks: a frosted, rounded panel with a soft
/// shadow; an optional search box at the top; small uppercase headings; the highlighted row in the accent color; and
/// what's checked ticked and in the accent. Each row's extras (a group's dot or chip, an agent's mark, an icon, a detail,
/// keys, an icon at the right) are drawn only when it has them.
struct MenuView {
    let canvas: Canvas
    let menu: MenuModel

    static let textPixels: Float = 12.5
    static let smallPixels: Float = 11.5
    static let chipPixels: Float = 11
    static let headerPixels: Float = 10.5
    /// How the last one's glass went (see sol_canvas_frost_rounded): 1 blurred. For tests.
    static var lastFrost: Int32 = 0

    private static func measure(_ text: String, _ pixels: Float, semibold: Bool = false, canvas: Canvas) -> Float {
        let units = Array(text.utf16)
        return sol_canvas_measure_label(canvas.raw, units, Int32(units.count), pixels, semibold ? 1 : 0).rounded(.up)
    }

    /// A group's chip: its name, semibold, with 6 pixels either side, at most 160 wide.
    static func chipWidth(_ label: String, canvas: Canvas, scale: Float) -> Float {
        min(measure(label, chipPixels * scale, semibold: true, canvas: canvas) + 12 * scale, 160 * scale)
    }

    /// How wide a dropdown has to be for these items (and at least `minWidth`).
    static func width(for items: [MenuItem], canvas: Canvas, scale: Float, minWidth: Float = 0) -> Float {
        // A long list is measured by its first few hundred rows; the rest truncate if they must.
        let widest = items.prefix(400).map { item -> Float in
            // Wide enough for either title, so holding Alt doesn't change its size.
            let titles = [item.title] + (item.alternate.map { [$0.title] } ?? [])
            var w = titles.map { measure($0, textPixels * scale, semibold: item.isChecked, canvas: canvas) }.max() ?? 0
            if let chip = item.chip { w += chipWidth(chip.label, canvas: canvas, scale: scale) + 6 * scale }
            if item.swatch != nil { w += 18 * scale }
            if let detail = item.detail { w += measure(detail, smallPixels * scale, canvas: canvas) + 8 * scale }
            if !item.shortcut.isEmpty { w += measure(item.shortcut, smallPixels * scale, canvas: canvas) + 28 * scale }
            if item.trailingIcon != nil { w += 24 * scale }
            return w
        }.max() ?? 0
        return max(widest + 52 * scale, 180 * scale, minWidth).rounded(.up)
    }

    func draw() {
        let f = menu.frame, s = menu.scale, radius = 10 * s, fg = TerminalPalette.foreground, c = canvas.raw
        // A soft shadow under it, then frosted glass: what's behind, blurred, under a wash of the theme's surface.
        for (grow, alpha) in [(Float(12), Float(0.04)), (7, 0.07), (3, 0.10)] {
            let g = grow * s
            sol_canvas_fill_rounded(c, f.x - g, f.y - g + 4 * s, f.width + g * 2, f.height + g * 2, radius + g, 0x000000, alpha)
        }
        let surface = TerminalPalette.mix(TerminalPalette.surface, TerminalPalette.chrome, 0.8)
        MenuView.lastFrost = sol_canvas_frost_rounded(c, f.x, f.y, f.width, f.height, radius, 16 * s, surface, 0.6)
        sol_canvas_stroke_rounded(c, f.x + 0.5, f.y + 0.5, f.width - 1, f.height - 1, radius, fg, 0.14, 1)
        if menu.search != nil { drawSearch() }
        let rows = UIRect(x: f.x, y: f.y + menu.top - menu.padding + 1, width: f.width, height: f.height - menu.top + menu.padding - 2)
        sol_canvas_push_clip(c, rows.x, rows.y, rows.width, rows.height)
        defer { sol_canvas_pop_clip(c) }
        if menu.items.isEmpty {
            let r = menu.rect(0)
            label("No matches", UIRect(x: r.x + 26 * s, y: r.y, width: r.width - 30 * s, height: r.height), MenuView.textPixels, alpha: 0.45)
        }
        for i in menu.items.indices {
            let r = menu.rect(i)
            guard r.maxY > rows.y, r.y < rows.maxY else { continue }
            drawRow(i, r)
        }
    }

    private func label(_ text: String, _ r: UIRect, _ pixels: Float, semibold: Bool = false, color: UInt32? = nil, alpha: Float = 1) {
        let units = Array(text.utf16)
        sol_canvas_draw_label(canvas.raw, r.x, r.y, max(r.width, 0), r.height, units, Int32(units.count), pixels * menu.scale, semibold ? 1 : 0,
                              color ?? TerminalPalette.foreground, alpha)
    }

    /// The search box: a magnifying glass, then what's typed (or the placeholder) and the caret.
    private func drawSearch() {
        let b = menu.searchBox, s = menu.scale, c = canvas.raw, fg = TerminalPalette.foreground
        sol_canvas_fill_rounded(c, b.x, b.y, b.width, b.height, 6 * s, fg, 0.06)
        sol_canvas_stroke_rounded(c, b.x + 0.5, b.y + 0.5, b.width - 1, b.height - 1, 6 * s, fg, 0.12, 1)
        sol_canvas_draw_icon(c, b.x + 6 * s, b.y, 16 * s, b.height, 0xE721, 11 * s, fg, 0.5)
        let inner = UIRect(x: b.x + 26 * s, y: b.y, width: b.width - 32 * s, height: b.height)
        let field = menu.search ?? TextFieldState("")
        sol_canvas_push_clip(c, inner.x, inner.y, inner.width, inner.height)
        let caretX = MenuView.measure(field.beforeCaret, MenuView.textPixels * s, canvas: canvas)
        let shift = max(0, caretX - inner.width + 4 * s)
        if field.text.isEmpty {
            label(menu.placeholder, inner, MenuView.textPixels, alpha: 0.45)
        } else {
            label(field.text, UIRect(x: inner.x - shift, y: inner.y, width: MenuView.measure(field.text, MenuView.textPixels * s, canvas: canvas) + 4, height: inner.height),
                  MenuView.textPixels)
        }
        sol_canvas_fill_rect(c, (inner.x - shift + caretX).rounded(), b.y + 7 * s, max((1.5 * s).rounded(), 1), b.height - 14 * s, TerminalPalette.accent, 1)
        sol_canvas_pop_clip(c)
    }

    private func drawRow(_ i: Int, _ r: UIRect) {
        let item = menu.items[i], s = menu.scale, c = canvas.raw, fg = TerminalPalette.foreground, accent = TerminalPalette.accent
        if item.isSeparator {
            sol_canvas_fill_rect(c, r.x + 6 * s, r.midY.rounded(), r.width - 12 * s, 1, fg, 0.10)
            return
        }
        if item.isHeader {
            label(item.title.uppercased(), UIRect(x: r.x + 8 * s, y: r.y + 3 * s, width: r.width - 16 * s, height: r.height), MenuView.headerPixels,
                  semibold: true, alpha: 0.45)
            return
        }
        let on: Float = item.isEnabled ? 1 : 0.4
        if menu.highlighted == i { sol_canvas_fill_rounded(c, r.x, r.y + 1, r.width, r.height - 2, 6 * s, accent, 0.2) }
        // Before the title: a tick for what's checked, else the row's mark or icon.
        let slot = UIRect(x: r.x + 4 * s, y: r.y, width: 18 * s, height: r.height)
        if item.isChecked && item.swatch == nil {
            sol_canvas_draw_icon(c, slot.x, r.y, slot.width, r.height, 0xE73E, 10 * s, accent, on)
        } else if let kind = item.agentMark {
            let side = (AgentMarks.side * s).rounded()
            AgentMarks.draw(kind, on: canvas, in: UIRect(x: slot.x + ((slot.width - side) / 2).rounded(), y: (r.midY - side / 2).rounded(), width: side, height: side),
                            scale: s, alpha: on)
        } else if let icon = item.icon {
            sol_canvas_draw_icon(c, slot.x, r.y, slot.width, r.height, icon, 12 * s, fg, 0.75 * on)
        }
        var x = r.x + 26 * s
        // At the right: an icon, and the keys before it.
        var right = r.maxX - 8 * s
        if let icon = item.trailingIcon {
            sol_canvas_draw_icon(c, right - 16 * s, r.y, 16 * s, r.height, icon, 11 * s, fg, 0.55 * on)
            right -= 22 * s
        }
        if !item.shortcut.isEmpty {
            let w = MenuView.measure(item.shortcut, MenuView.smallPixels * s, canvas: canvas)
            label(item.shortcut, UIRect(x: right - w, y: r.y, width: w + 2, height: r.height), MenuView.smallPixels, alpha: 0.5 * on)
            right -= w + 16 * s
        }
        if let swatch = item.swatch {
            sol_canvas_fill_ellipse(c, x + 5 * s, r.midY, 5 * s, 5 * s, swatch, on)
            if item.isChecked {
                sol_canvas_stroke_rounded(c, x - 2.5 * s, r.midY - 7.5 * s, 15 * s, 15 * s, 7.5 * s, swatch, on, 1.5 * s)
            }
            x += 18 * s
        }
        if let chip = item.chip {
            let w = MenuView.chipWidth(chip.label, canvas: canvas, scale: s), h = (17 * s).rounded()
            sol_canvas_fill_rounded(c, x, (r.midY - h / 2).rounded(), w, h, 5 * s, chip.color, 0.88 * on)
            let ink: UInt32 = HexColor(rgb: chip.color).luminance > 0.6 ? 0x1A1A1A : 0xFFFFFF
            label(chip.label, UIRect(x: x + 6 * s, y: r.y, width: w - 12 * s + 1, height: r.height), MenuView.chipPixels, semibold: true, color: ink, alpha: on)
            x += w + 6 * s
        }
        // What's checked reads in the accent, a little heavier, as on the Mac.
        let ticked = item.isChecked && item.swatch == nil
        let title = menu.title(i)
        label(title, UIRect(x: x, y: r.y, width: max(right - x, 0), height: r.height), MenuView.textPixels, semibold: ticked,
              color: ticked ? accent : nil, alpha: (ticked ? 1 : 0.95) * on)
        if let detail = item.detail {
            let dx = x + MenuView.measure(title, MenuView.textPixels * s, semibold: ticked, canvas: canvas) + 8 * s
            if dx < right - 30 * s { label(detail, UIRect(x: dx, y: r.y, width: right - dx, height: r.height), MenuView.smallPixels, alpha: 0.5 * on) }
        }
    }
}
