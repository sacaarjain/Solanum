import CCanvas
import Foundation

/// A finished command's badge and buttons drawn over a terminal, as on the Mac: "✓ 1.2s" or "✕ exit 1 · 3s" at the
/// right of its first line while it's picked or under the pointer (always, for one that failed), and "Send to chat" and
/// "Copy output" before it while it's under the pointer, in the code boxes' Copy button's look. What each says and when
/// is Core's (BlockActions). And the bar over several picked commands. TerminalPane draws them, and so does a test run.
struct BlockButtonsView {
    let canvas: Canvas
    let terminal: Terminal
    let scale: Float
    /// The row a line is on, nil when it's hidden.
    let row: (Int) -> Int?
    var picked: Set<Int> = []
    var outlined: Int?
    var hovered: Int?
    var hoveredButton: String?
    var copied: Int?

    /// Draws them; returns where each button went, with what it is ("copy", "send") and its command's id.
    func draw() -> [(rect: UIRect, part: String, block: Int)] {
        var out: [(rect: UIRect, part: String, block: Int)] = []
        guard !terminal.usingAlt else { return out }
        let m = canvas.metrics, s = scale
        let right = canvas.contentX + Float(terminal.cols) * m.cellWidth - 4 * s
        for b in terminal.blocks where b.state != .prompt {
            guard let r = row(b.promptLine), r >= 0, r < terminal.rows else { continue }
            let shown = picked.contains(b.id) || outlined == b.id || hovered == b.id
            var edge = right
            if let badge = BlockActions.badge(b, shown: shown) {
                let units = Array(badge.text.utf16), px = max(10 * s, m.cellHeight * 0.62)
                let tw = sol_canvas_measure_label(canvas.raw, units, Int32(units.count), px, 1).rounded(.up)
                let color: UInt32 = badge.kind == .failed ? TerminalPalette.ansi[1] : badge.kind == .succeeded ? TerminalPalette.ansi[2]
                    : badge.kind == .running ? TerminalPalette.accent : TerminalPalette.mix(TerminalPalette.foreground, TerminalPalette.background, 0.55)
                let y = canvas.contentY + Float(r) * m.cellHeight
                sol_canvas_fill_rect(canvas.raw, edge - tw - 8 * s, y, tw + 8 * s, m.cellHeight, TerminalPalette.background, 0.85)
                sol_canvas_draw_label(canvas.raw, edge - tw - 2 * s, y, tw + 2, m.cellHeight, units, Int32(units.count), px, 1, color, 1)
                edge -= tw + 12 * s
            }
            guard hovered == b.id || copied == b.id, BlockActions.offersButtons(b) else { continue }
            let isCopied = copied == b.id
            let h = CodeBoxView.pillSize("Copy output", copied: isCopied, canvas: canvas, scale: s).height
            let y = canvas.contentY + Float(r) * m.cellHeight + (m.cellHeight - h) / 2
            let copy = CodeBoxView.drawPill(isCopied ? "Copied" : "Copy output", copied: isCopied, hover: hoveredButton == "\(b.id):copy",
                                            right: edge, y: y, canvas: canvas, scale: s)
            out.append((copy, "copy", b.id))
            let send = CodeBoxView.drawPill("Send to chat", icon: 0xE72D, copied: false, hover: hoveredButton == "\(b.id):send",
                                            right: copy.x - 6 * s, y: y, canvas: canvas, scale: s)
            out.append((send, "send", b.id))
        }
        return out
    }

    /// "N commands selected", Copy All, Send to Chat and Clear, at the bottom right of `area`, as the Mac's bar.
    static func drawSelectionBar(count: Int, hovered: String?, canvas: Canvas, area: UIRect, scale s: Float) -> [(rect: UIRect, part: String, block: Int)] {
        let c = canvas.raw, fg = TerminalPalette.foreground
        let label = BlockActions.selectionLabel(count), px = 12 * s
        func width(_ t: String) -> Float {
            let u = Array(t.utf16)
            return sol_canvas_measure_label(c, u, Int32(u.count), px, 1).rounded(.up)
        }
        let parts = [("all-copy", "Copy All"), ("all-send", "Send to Chat"), ("all-clear", "Clear")]
        let h = (32 * s).rounded()
        let w = 14 * s + width(label) + parts.reduce(0) { $0 + 16 * s + width($1.1) } + 14 * s
        let box = UIRect(x: (area.maxX - w - 12 * s).rounded(), y: (area.maxY - h - 12 * s).rounded(), width: w, height: h)
        sol_canvas_fill_rounded(c, box.x, box.y + 2 * s, box.width, box.height, 8 * s, 0x000000, 0.25)
        sol_canvas_fill_rounded(c, box.x, box.y, box.width, box.height, 8 * s, TerminalPalette.surface, 1)
        sol_canvas_stroke_rounded(c, box.x + 0.5, box.y + 0.5, box.width - 1, box.height - 1, 8 * s, TerminalPalette.accent, 0.6, 1)
        let lu = Array(label.utf16)
        sol_canvas_draw_label(c, box.x + 14 * s, box.y, width(label) + 2, h, lu, Int32(lu.count), px, 1, fg, 1)
        var out: [(rect: UIRect, part: String, block: Int)] = []
        var x = box.x + 14 * s + width(label) + 16 * s
        for (part, title) in parts {
            let tw = width(title), u = Array(title.utf16)
            let r = UIRect(x: x - 4 * s, y: box.y + 4 * s, width: tw + 8 * s, height: h - 8 * s)
            if hovered == "0:" + part { sol_canvas_fill_rounded(c, r.x, r.y, r.width, r.height, 4 * s, fg, 0.08) }
            sol_canvas_draw_label(c, x, box.y, tw + 2, h, u, Int32(u.count), px, 1, TerminalPalette.accent, 1)
            out.append((r, part, 0))
            x += tw + 16 * s
        }
        return out
    }
}
