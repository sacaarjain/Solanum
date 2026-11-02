import CCanvas
import Foundation

/// Draws a pop-up menu the Windows 11 way: 8-pixel corners, with rows highlighted inset from the edges.
struct MenuView {
    let canvas: Canvas
    let menu: MenuModel

    static let textPixels: Float = 12.5

    /// How wide a menu has to be for these items.
    static func width(for items: [MenuItem], canvas: Canvas, scale: Float) -> Float {
        let widest = items.map { item -> Float in
            let units = Array(item.title.utf16)
            return sol_canvas_measure_label(canvas.raw, units, Int32(units.count), textPixels * scale, 0)
        }.max() ?? 0
        return max(widest + 52 * scale, 160 * scale).rounded(.up)
    }

    func draw() {
        let f = menu.frame, scale = menu.scale, radius = 8 * scale, fg = TerminalPalette.foreground
        for (grow, alpha) in [(Float(8), Float(0.05)), (5, 0.08), (2, 0.12)] {
            let g = grow * scale
            sol_canvas_fill_rounded(canvas.raw, f.x - g, f.y - g + 2 * scale, f.width + g * 2, f.height + g * 2, radius + g, 0x000000, alpha)
        }
        sol_canvas_fill_rounded(canvas.raw, f.x, f.y, f.width, f.height, radius, TerminalPalette.mix(TerminalPalette.surface, TerminalPalette.chrome, 0.8), 1)
        sol_canvas_stroke_rounded(canvas.raw, f.x + 0.5, f.y + 0.5, f.width - 1, f.height - 1, radius, fg, 0.14, 1)
        sol_canvas_push_clip(canvas.raw, f.x, f.y + 1, f.width, f.height - 2)
        defer { sol_canvas_pop_clip(canvas.raw) }
        for i in menu.items.indices {
            let r = menu.rect(i)
            guard r.maxY > f.y, r.y < f.maxY else { continue }
            let item = menu.items[i]
            if item.isSeparator {
                sol_canvas_fill_rect(canvas.raw, f.x, (r.midY).rounded(), f.width, 1, fg, 0.10)
                continue
            }
            if menu.highlighted == i { sol_canvas_fill_rounded(canvas.raw, r.x, r.y, r.width, r.height, 4 * scale, fg, 0.09) }
            let checkWidth = 22 * scale
            if item.isChecked {
                sol_canvas_draw_icon(canvas.raw, r.x, r.y, checkWidth, r.height, 0xE73E, 10 * scale, TerminalPalette.accent, 1)
            }
            let units = Array(item.title.utf16)
            sol_canvas_draw_label(canvas.raw, r.x + checkWidth, r.y, r.width - checkWidth - 8 * scale, r.height, units, Int32(units.count),
                                  MenuView.textPixels * scale, 0, fg, item.isEnabled ? 0.95 : 0.4)
        }
    }
}
