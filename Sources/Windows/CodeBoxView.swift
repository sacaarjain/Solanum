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

    /// Prompts sent to Claude Code, in place of the grey it paints behind them: a box in the theme's accent with a border,
    /// as the code boxes have. Returns the lines whose grey the renderer shouldn't paint (see TerminalRenderer).
    func drawPromptBands() -> [Int: UInt32] {
        // From a little above the screen, so a prompt that starts above it is still known as one.
        let bands = PromptBands.find({ terminal.line(abs: $0) }, from: max(top - 40, 0), through: top + terminal.rows - 1)
        var plain: [Int: UInt32] = [:]
        let m = canvas.metrics, s = scale, c = canvas.raw, accent = TerminalPalette.accent
        for b in bands {
            for a in b.first...b.last { plain[a] = b.bg }
            let r0 = max(b.first - top, 0), r1 = min(b.last - top, terminal.rows - 1)
            guard r0 <= r1 else { continue }
            let x = max(2 * s, canvas.contentX - 6 * s), right = canvas.contentX + Float(terminal.cols) * m.cellWidth + 4 * s
            let y = canvas.contentY + Float(r0) * m.cellHeight - 2 * s, h = Float(r1 - r0 + 1) * m.cellHeight + 4 * s
            sol_canvas_fill_rounded(c, x, y, right - x, h, 8 * s, accent, TerminalPalette.isDark ? 0.10 : 0.08)
            sol_canvas_stroke_rounded(c, x + 0.5, y + 0.5, right - x - 1, h - 1, 8 * s, accent, 0.45, 1)
        }
        return plain
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

    /// "Copy" at the top right of each box whose first line is on screen: above it, so it never covers a long first
    /// line, in the empty line Claude usually leaves or in a line of text that ends well short of it; on the box's first
    /// line only when neither has room.
    @discardableResult
    func drawButtons(hover hovered: Int?, copied copiedIndex: Int?) -> [(rect: UIRect, box: Int)] {
        var copyButtons: [(rect: UIRect, box: Int)] = []
        guard !boxes.isEmpty, !terminal.usingAlt else { return [] }
        let m = canvas.metrics, s = scale
        let edge = panelRight
        for (i, b) in boxes.enumerated() {
            let r = b.first - top
            guard r >= 0, r < terminal.rows else { continue }
            let copied = copiedIndex == i, hover = hovered == i
            let size = Self.pillSize(copied ? "Copied" : b.kind == .table ? "Copy table" : "Copy", copied: copied, canvas: canvas, scale: s)
            let roomAbove = b.kind != .table && r > 0 && (terminal.line(abs: b.first - 1).map { l in
                let lastText = l.cells.lastIndex { !ImageTokens.isSpace($0.ch) } ?? -1
                return ImageTokens.isBlank(l) || canvas.contentX + Float(lastText + 1) * m.cellWidth < edge - size.width - 12 * s
            } ?? false)
            let rowY = canvas.contentY + Float(r) * m.cellHeight
            // Above the box, 6 px clear of its top border (which is a pixel above its first row), in the empty line there.
            let y = roomAbove ? rowY - 1 - 6 * s - size.height : rowY + (m.cellHeight - size.height) / 2
            // Flush with the panel's right edge above it; a little in from it on the box's first line.
            let rect = Self.drawPill(copied ? "Copied" : b.kind == .table ? "Copy table" : "Copy", copied: copied, hover: hover,
                                     right: edge - (roomAbove ? 0 : 6) * scale, y: y, canvas: canvas, scale: s)
            copyButtons.append((rect, i))
        }
        return copyButtons
    }

    /// The text size of the Copy buttons: a little smaller than the terminal's.
    private static func pillPixels(_ s: Float) -> Float { max(10, Float(AppSettings.shared.fontSize) - 2.5) * s * 1.33 }

    static func pillSize(_ text: String, copied: Bool, canvas: Canvas, scale s: Float) -> (width: Float, height: Float) {
        let label = copied ? "\u{2713} " + text : text, units = Array(label.utf16), px = pillPixels(s)
        let tw = sol_canvas_measure_label(canvas.raw, units, Int32(units.count), px, 1).rounded(.up)
        return (tw + 16 * s + (copied ? 0 : px + 4 * s), (px * 1.25 + 4 * s).rounded())
    }

    /// A Copy button's pill, as the Mac draws them: "⧉ Copy", "✓ Copied" in green a moment after, or with another `icon`
    /// (Segoe Fluent Icons). Its right edge at `right`, its top at `y`. Returns where it went.
    @discardableResult
    static func drawPill(_ text: String, icon: UInt16 = 0xE8C8, copied: Bool, hover: Bool, right: Float, y: Float, canvas: Canvas, scale s: Float) -> UIRect {
        let c = canvas.raw, fg = TerminalPalette.foreground, px = pillPixels(s)
        let label = copied ? "\u{2713} " + text : text, units = Array(label.utf16)
        let tw = sol_canvas_measure_label(c, units, Int32(units.count), px, 1).rounded(.up)
        let size = pillSize(text, copied: copied, canvas: canvas, scale: s)
        let rect = UIRect(x: (right - size.width).rounded(), y: y.rounded(), width: size.width, height: size.height)
        let ink = copied ? TerminalPalette.ansi[2] : fg
        sol_canvas_fill_rounded(c, rect.x, rect.y, rect.width, rect.height, 5 * s, TerminalPalette.surface, 1)
        if hover || copied { sol_canvas_fill_rounded(c, rect.x, rect.y, rect.width, rect.height, 5 * s, fg, 0.08) }
        sol_canvas_stroke_rounded(c, rect.x + 0.5, rect.y + 0.5, rect.width - 1, rect.height - 1, 5 * s, fg, TerminalPalette.isDark ? 0.10 : 0.14, 1)
        var tx = rect.x + 8 * s
        if !copied {
            sol_canvas_draw_icon(c, tx, rect.y, px, rect.height, icon, px * 0.8, ink, hover ? 1 : 0.55)
            tx += px + 4 * s
        }
        sol_canvas_draw_label(c, tx, rect.y, tw + 2, rect.height, units, Int32(units.count), px, 1, ink, copied || hover ? 1 : 0.55)
        return rect
    }
}
