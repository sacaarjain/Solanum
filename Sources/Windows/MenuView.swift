import CCanvas
import Foundation

/// Draws a pop-up menu the Windows 11 way: 8-pixel corners, with rows highlighted inset from the edges.
struct MenuView {
    let canvas: Canvas
    let menu: MenuModel

    static let textPixels: Float = 12.5
    static let shortcutPixels: Float = 11.5

    /// How wide a menu has to be for these items.
    static func width(for items: [MenuItem], canvas: Canvas, scale: Float) -> Float {
        // Wide enough for either title, so holding Alt doesn't change its size; and for a group's chip before it.
        let widest = items.map { item -> Float in
            let titles = [item.title] + (item.alternate.map { [$0.title] } ?? [])
            let text = titles.map { title -> Float in
                let units = Array(title.utf16)
                return sol_canvas_measure_label(canvas.raw, units, Int32(units.count), textPixels * scale, 0)
            }.max() ?? 0
            return text + (item.chip.map { chipWidth($0.label, canvas: canvas, scale: scale) + 6 * scale } ?? 0)
        }.max() ?? 0
        let swatches: Float = items.contains { $0.swatch != nil } ? 18 * scale : 0
        // Room for the keys at the right, apart from the title.
        let keys = items.map { item -> Float in
            guard !item.shortcut.isEmpty else { return 0 }
            let units = Array(item.shortcut.utf16)
            return sol_canvas_measure_label(canvas.raw, units, Int32(units.count), shortcutPixels * scale, 0) + 28 * scale
        }.max() ?? 0
        return max(widest + 52 * scale + swatches + keys, 160 * scale).rounded(.up)
    }

    static let chipPixels: Float = 11

    /// A group's chip: its name, semibold, with 6 pixels either side, at most 160 wide, as the Mac's.
    static func chipWidth(_ label: String, canvas: Canvas, scale: Float) -> Float {
        let units = Array(label.utf16)
        let text = sol_canvas_measure_label(canvas.raw, units, Int32(units.count), chipPixels * scale, 1).rounded(.up)
        return min(text + 12 * scale, 160 * scale)
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
            if item.isHeader {
                let units = Array(item.title.utf16)
                sol_canvas_draw_label(canvas.raw, r.x + 8 * scale, r.y, r.width - 16 * scale, r.height, units, Int32(units.count),
                                      11.5 * scale, 1, fg, 0.45)
                continue
            }
            if menu.highlighted == i { sol_canvas_fill_rounded(canvas.raw, r.x, r.y, r.width, r.height, 4 * scale, fg, 0.09) }
            let checkWidth = 22 * scale
            if item.isChecked {
                sol_canvas_draw_icon(canvas.raw, r.x, r.y, checkWidth, r.height, 0xE73E, 10 * scale, TerminalPalette.accent, 1)
            } else if let kind = item.agentMark {
                let side = (AgentMarks.side * scale).rounded()
                AgentMarks.draw(kind, on: canvas, in: UIRect(x: r.x + 4 * scale, y: (r.midY - side / 2).rounded(), width: side, height: side),
                                scale: scale, alpha: item.isEnabled ? 1 : 0.4)
            } else if let icon = item.icon {
                sol_canvas_draw_icon(canvas.raw, r.x + 2 * scale, r.y, checkWidth, r.height, icon, 12 * scale, fg, item.isEnabled ? 0.8 : 0.35)
            }
            var right = r.maxX - 8 * scale
            if !item.shortcut.isEmpty {
                let units = Array(item.shortcut.utf16), pixels = MenuView.shortcutPixels * scale
                let w = sol_canvas_measure_label(canvas.raw, units, Int32(units.count), pixels, 0).rounded(.up)
                sol_canvas_draw_label(canvas.raw, right - w, r.y, w + 2, r.height, units, Int32(units.count), pixels, 0, fg, 0.5)
                right -= w + 16 * scale
            }
            var textX = r.x + checkWidth
            if let swatch = item.swatch {
                sol_canvas_fill_ellipse(canvas.raw, textX + 5 * scale, r.midY, 5 * scale, 5 * scale, swatch, 1)
                textX += 18 * scale
            }
            if let chip = item.chip {
                let w = MenuView.chipWidth(chip.label, canvas: canvas, scale: scale), h = (17 * scale).rounded()
                sol_canvas_fill_rounded(canvas.raw, textX, (r.midY - h / 2).rounded(), w, h, 5 * scale, chip.color, item.isEnabled ? 0.88 : 0.4)
                let ink: UInt32 = HexColor(rgb: chip.color).luminance > 0.6 ? 0x1A1A1A : 0xFFFFFF
                let units = Array(chip.label.utf16)
                sol_canvas_draw_label(canvas.raw, textX + 6 * scale, r.y, w - 12 * scale + 1, r.height, units, Int32(units.count),
                                      MenuView.chipPixels * scale, 1, ink, item.isEnabled ? 1 : 0.6)
                textX += w + 6 * scale
            }
            let units = Array(menu.title(i).utf16)
            sol_canvas_draw_label(canvas.raw, textX, r.y, max(right - textX, 0), r.height, units, Int32(units.count),
                                  MenuView.textPixels * scale, 0, fg, item.isEnabled ? 0.95 : 0.4)
        }
    }
}
