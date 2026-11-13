import CCanvas
import Foundation
import WinSDK

/// The Extensions page (Ctrl+Shift+X, or the puzzle piece left of the theme name), in a sub-tab of its own as on the Mac:
/// what's installed, and the marketplace. Nothing's offered on Windows yet, so both lists say so.
final class ExtensionsPanel: ColumnPanel {
    var invalidate: () -> Void = {}

    func draw(on canvas: Canvas, in a: UIRect, scale s: Float) {
        let p = PanelPaint(canvas: canvas, scale: s)
        p.backdrop(a, TerminalPalette.background)
        sol_canvas_push_clip(canvas.raw, a.x, a.y, a.width, a.height)
        defer { sol_canvas_pop_clip(canvas.raw) }
        let pad = 24 * s, width = min(a.width - pad * 2, 720 * s)
        var y = a.y + 22 * s
        p.label("Extensions", UIRect(x: a.x + pad, y: y, width: width, height: 30 * s), pixels: 22, semibold: true)
        y += 34 * s
        let about = Array("Add features to Solanum. An extension can bring its own page, beside your terminal like Git Graph, and give Claude Code new tools through an MCP server that Solanum runs itself.".utf16)
        y += sol_canvas_paragraph(canvas.raw, a.x + pad, y, width, about, Int32(about.count), 12.5 * s, 0, TerminalPalette.foreground, 0.55, 0) + 22 * s
        for (title, empty) in [("Installed", "Nothing installed yet."), ("Marketplace", "Nothing here yet. Extensions you can add will show up here.")] {
            p.label(title.uppercased(), UIRect(x: a.x + pad, y: y, width: width, height: 16 * s), pixels: 10.5, semibold: true, alpha: 0.5)
            let zero = "0", zw = p.width(zero, pixels: 10.5)
            p.label(zero, UIRect(x: a.x + pad + min(width, 320 * s) - zw, y: y, width: zw + 1, height: 16 * s), pixels: 10.5, alpha: 0.35)
            y += 22 * s
            // An empty card where the extensions would be listed.
            let card = UIRect(x: a.x + pad, y: y, width: min(width, 320 * s), height: 56 * s)
            sol_canvas_fill_rounded(canvas.raw, card.x, card.y, card.width, card.height, 10 * s, TerminalPalette.foreground, 0.04)
            sol_canvas_stroke_rounded(canvas.raw, card.x + 0.5, card.y + 0.5, card.width - 1, card.height - 1, 10 * s, TerminalPalette.foreground, 0.08, 1)
            p.icon(0xEA86, UIRect(x: card.x + 12 * s, y: card.y, width: 24 * s, height: card.height), pixels: 14, alpha: 0.35)
            let text = Array(empty.utf16)
            _ = sol_canvas_paragraph(canvas.raw, card.x + 44 * s, card.y + (title == "Installed" ? 19 : 11) * s, card.width - 56 * s, text, Int32(text.count), 12 * s, 0,
                                     TerminalPalette.foreground, 0.55, 0)
            y += card.height + 22 * s
        }
    }

    func mouse(_ message: UINT, x: Float, y: Float, in area: UIRect, scale: Float) -> Bool { false }
    func scroll(lines: Int, x: Float, y: Float, in area: UIRect, scale: Float) {}
    func key(_ key: Int32, shift: Bool, ctrl: Bool) -> Bool { false }
    func typed(_ text: String) {}
    func reload() { invalidate() }
}
