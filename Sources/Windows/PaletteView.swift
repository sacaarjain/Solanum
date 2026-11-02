import CCanvas
import Foundation

/// Draws the command palette over the window.
struct PaletteView {
    let canvas: Canvas
    let model: PaletteModel
    let layout: PaletteLayout
    var hoveredRow: Int?

    private var scale: Float { layout.scale }
    private var fg: UInt32 { TerminalPalette.foreground }

    private func label(_ text: String, _ r: UIRect, pixels: Float, semibold: Bool = false, color: UInt32? = nil, alpha: Float = 1) {
        let units = Array(text.utf16)
        sol_canvas_draw_label(canvas.raw, r.x, r.y, r.width, r.height, units, Int32(units.count), pixels, semibold ? 1 : 0, color ?? fg, alpha)
    }

    private func width(of text: String, pixels: Float, semibold: Bool = false) -> Float {
        let units = Array(text.utf16)
        return sol_canvas_measure_label(canvas.raw, units, Int32(units.count), pixels, semibold ? 1 : 0)
    }

    func draw() {
        let p = layout.panel, radius = 12 * scale
        // A soft edge of shadow, then the panel.
        for (grow, alpha) in [(Float(10), Float(0.06)), (6, 0.08), (3, 0.12)] {
            let g = grow * scale
            sol_canvas_fill_rounded(canvas.raw, p.x - g, p.y - g + 2 * scale, p.width + g * 2, p.height + g * 2, radius + g, 0x000000, alpha)
        }
        sol_canvas_fill_rounded(canvas.raw, p.x, p.y, p.width, p.height, radius, TerminalPalette.mix(TerminalPalette.surface, TerminalPalette.chrome, 0.75), 1)
        sol_canvas_stroke_rounded(canvas.raw, p.x + 0.5, p.y + 0.5, p.width - 1, p.height - 1, radius, fg, 0.14, 1)
        drawField()
        sol_canvas_fill_rect(canvas.raw, p.x + 10 * scale, layout.dividerY, p.width - 20 * scale, 1, fg, 0.10)
        if model.rows.isEmpty {
            label("No matching commands", insetRow(layout.row(0)), pixels: 13 * scale, alpha: 0.55)
            return
        }
        for visible in 0..<model.visibleRowCount where model.scrollTop + visible < model.rows.count {
            drawRow(model.rows[model.scrollTop + visible], index: model.scrollTop + visible, in: layout.row(visible), visible: visible)
        }
    }

    private func drawField() {
        let f = layout.field, pixels = 15 * scale
        sol_canvas_draw_icon(canvas.raw, layout.icon.x, layout.icon.y, layout.icon.width, layout.icon.height, 0xE721, 14 * scale, TerminalPalette.accent, 0.9)
        if model.query.isEmpty {
            label("Type a command…", f, pixels: pixels, alpha: 0.45)
        } else {
            label(model.query, f, pixels: pixels)
        }
        let caretX = f.x + width(of: model.textBeforeCaret, pixels: pixels)
        let height = 20 * scale
        sol_canvas_fill_rect(canvas.raw, caretX.rounded(), (f.midY - height / 2).rounded(), max(scale.rounded(), 1), height, TerminalPalette.accent, 1)
    }

    private func insetRow(_ r: UIRect) -> UIRect {
        let inset = 14 * scale
        return UIRect(x: r.x + inset, y: r.y, width: r.width - inset * 2, height: r.height)
    }

    private func drawRow(_ item: PaletteItem, index: Int, in r: UIRect, visible: Int) {
        if item.isHeader {
            if visible > 0 { sol_canvas_fill_rect(canvas.raw, r.x + 10 * scale, r.y + 8 * scale, r.width - 20 * scale, 1, fg, 0.10) }
            let lowered = UIRect(x: r.x + 14 * scale, y: r.y + 10 * scale, width: r.width - 28 * scale, height: r.height - 10 * scale)
            label(item.title.uppercased(), lowered, pixels: 11 * scale, semibold: true, alpha: 0.5)
            return
        }
        let inset = 2 * scale
        if index == model.selected {
            sol_canvas_fill_rounded(canvas.raw, r.x + inset, r.y + scale, r.width - inset * 2, r.height - scale * 2, 7 * scale, TerminalPalette.accent, 0.20)
        } else if hoveredRow == visible {
            sol_canvas_fill_rounded(canvas.raw, r.x + inset, r.y + scale, r.width - inset * 2, r.height - scale * 2, 7 * scale, fg, 0.06)
        }
        let content = insetRow(r)
        var right = content.maxX
        if !item.shortcut.isEmpty {
            let pixels = 11.5 * scale, textWidth = width(of: item.shortcut, pixels: pixels, semibold: true).rounded(.up)
            let chipWidth = textWidth + 12 * scale, chipHeight = 20 * scale
            let chipX = right - chipWidth, chipY = (r.midY - chipHeight / 2).rounded()
            sol_canvas_fill_rounded(canvas.raw, chipX, chipY, chipWidth, chipHeight, 5 * scale, fg, 0.08)
            label(item.shortcut, UIRect(x: chipX + 6 * scale, y: chipY, width: textWidth + 2, height: chipHeight), pixels: pixels, semibold: true, alpha: 0.75)
            right = chipX - 8 * scale
        }
        if !item.category.isEmpty {
            let pixels = 11.5 * scale, w = width(of: item.category, pixels: pixels).rounded(.up)
            label(item.category, UIRect(x: right - w, y: r.y, width: w + 2, height: r.height), pixels: pixels, alpha: 0.5)
            right -= w + 12 * scale
        }
        label(item.title, UIRect(x: content.x, y: r.y, width: max(right - content.x, 0), height: r.height), pixels: 13 * scale)
    }
}
