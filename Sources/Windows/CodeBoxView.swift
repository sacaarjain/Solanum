import CCanvas
import Foundation

/// Claude's code boxes drawn over a terminal, as on the Mac: a tinted, outlined panel behind each code block, and a Copy
/// button at the top right of every box (see Core's CodeBoxFinder for finding them).
struct CodeBoxView {
    let canvas: Canvas
    let terminal: Terminal
    let boxes: [CodeBox]
    /// The absolute line at the top of the screen.
    let top: Int
    let scale: Float

    /// A tinted, outlined panel behind each code block (tables already have their own border, quotes their bar).
    /// Where the panels end on the right: just past the last column of text, and well clear of the window's edge.
    private var panelRight: Float {
        let m = canvas.metrics
        let textEnd = canvas.contentX + Float(terminal.cols) * m.cellWidth
        let limit = (canvas.terminalArea.map { $0.maxX } ?? textEnd + canvas.padding) - 12 * scale
        return min(textEnd + 4 * scale, limit).rounded()
    }

    func drawPanels() {
        guard !boxes.isEmpty, !terminal.usingAlt else { return }
        let m = canvas.metrics, s = scale, c = canvas.raw, fg = TerminalPalette.foreground
        let right = panelRight
        for b in boxes where b.kind == .code {
            let r0 = max(b.first - top, 0), r1 = min(b.last - top, terminal.rows - 1)
            guard r0 <= r1 else { continue }
            var x = max(2 * s, canvas.contentX + Float(b.indent) * m.cellWidth - 9 * s)
            // Keep the edge clear of anything left of the code, such as the "⏺" before a reply's first line.
            var left = -1
            for r in r0...r1 {
                guard let l = terminal.line(abs: top + r) else { continue }
                for col in stride(from: min(b.indent, l.cells.count) - 1, to: left, by: -1) where l.cells[col].ch != 0 && l.cells[col].ch != 0x20 {
                    left = col
                    break
                }
            }
            if left >= 0 {
                x = max(x, min(canvas.contentX + Float(left + 1) * m.cellWidth + 3 * s, canvas.contentX + Float(b.indent) * m.cellWidth - 3 * s))
            }
            let y = canvas.contentY + Float(r0) * m.cellHeight - 1, h = Float(r1 - r0 + 1) * m.cellHeight + 2
            sol_canvas_fill_rounded(c, x, y, right - x, h, 6 * s, fg, 0.045)
            sol_canvas_stroke_rounded(c, x + 0.5, y + 0.5, right - x - 1, h - 1, 6 * s, fg, TerminalPalette.isDark ? 0.10 : 0.14, 1)
        }
    }

    /// "Copy" at the top right of each box whose first line is on screen: above it when the line there is empty (Claude
    /// leaves one), so it never covers a long first line.
    @discardableResult
    func drawButtons(hover hovered: Int?, copied copiedIndex: Int?) -> [(rect: UIRect, box: Int)] {
        var copyButtons: [(rect: UIRect, box: Int)] = []
        guard !boxes.isEmpty, !terminal.usingAlt else { return [] }
        let m = canvas.metrics, s = scale, c = canvas.raw, fg = TerminalPalette.foreground
        let edge = panelRight
        for (i, b) in boxes.enumerated() {
            let r = b.first - top
            guard r >= 0, r < terminal.rows else { continue }
            let copied = copiedIndex == i, hover = hovered == i
            let roomAbove = b.kind != .table && r > 0 && (terminal.line(abs: b.first - 1).map(ImageTokens.isBlank) ?? false)
            let text = copied ? "\u{2713} Copied" : b.kind == .table ? "Copy table" : "Copy"
            let units = Array(text.utf16), px = max(10, Float(AppSettings.shared.fontSize) - 2.5) * s * 1.33
            let tw = sol_canvas_measure_label(c, units, Int32(units.count), px, 1).rounded(.up)
            let iconW: Float = copied ? 0 : px + 4 * s
            let w = tw + 16 * s + iconW, h = (px * 1.25 + 4 * s).rounded()
            let rowY = canvas.contentY + Float(r) * m.cellHeight
            // Above the box, 6 px clear of its top border (which is a pixel above its first row), in the empty line there.
            let y = roomAbove ? rowY - 1 - 6 * s - h : rowY + (m.cellHeight - h) / 2
            // Flush with the panel's right edge above it; a little in from it on the box's first line.
            let rect = UIRect(x: (edge - (roomAbove ? 0 : 6) * scale - w).rounded(), y: y.rounded(), width: w, height: h)
            let ink = copied ? TerminalPalette.ansi[2] : fg
            sol_canvas_fill_rounded(c, rect.x, rect.y, rect.width, rect.height, 5 * s, TerminalPalette.surface, 1)
            if hover || copied { sol_canvas_fill_rounded(c, rect.x, rect.y, rect.width, rect.height, 5 * s, fg, 0.08) }
            sol_canvas_stroke_rounded(c, rect.x + 0.5, rect.y + 0.5, rect.width - 1, rect.height - 1, 5 * s, fg, TerminalPalette.isDark ? 0.10 : 0.14, 1)
            var tx = rect.x + 8 * s
            if !copied {
                sol_canvas_draw_icon(c, tx, rect.y, px, rect.height, 0xE8C8, px * 0.8, ink, hover ? 1 : 0.55)
                tx += iconW
            }
            sol_canvas_draw_label(c, tx, rect.y, tw + 2, rect.height, units, Int32(units.count), px, 1, ink, copied || hover ? 1 : 0.55)
            copyButtons.append((rect, i))
        }
        return copyButtons
    }
}
