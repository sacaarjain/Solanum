import CCanvas
import Foundation

/// A question asked over the window, as Windows 11 asks them (its ContentDialog): the window dims, and a card in the middle
/// has a title, a message, and buttons along a darker strip at the bottom, the main one in the accent color. Enter picks
/// it and Esc cancels. Drawn by Solanum, like its menus, in the theme's colors.
struct DialogModel {
    let title: String
    let message: String
    let primary: String
    let cancel: String
    let run: () -> Void
    /// A second choice between the main one and Cancel ("Don't Save").
    let other: (title: String, run: () -> Void)?
    var hovered: Int?
    var pressed: Int?

    init(title: String, message: String, primary: String, cancel: String = "Cancel", other: (title: String, run: () -> Void)? = nil,
         run: @escaping () -> Void) {
        self.title = title
        self.message = message
        self.primary = primary
        self.cancel = cancel
        self.other = other
        self.run = run
    }

    /// The buttons' titles, the main one first and Cancel last, as Windows lays them out.
    var titles: [String] { [primary] + (other.map { [$0.title] } ?? []) + [cancel] }
}

struct DialogLayout {
    let card: UIRect, footer: UIRect, buttons: [UIRect], messageHeight: Float

    /// Where the card and its buttons go in a window of that size; the message's height measured on `canvas`.
    init(_ dialog: DialogModel, width: Float, height: Float, scale s: Float, canvas: Canvas) {
        let w = min((448 * s).rounded(), width - 32 * s), pad = (24 * s).rounded()
        let units = Array(dialog.message.utf16)
        messageHeight = sol_canvas_paragraph(canvas.raw, 0, 0, w - pad * 2, units, Int32(units.count), 14 * s, 0, 0, 0, 1).rounded(.up)
        let footerHeight = (80 * s).rounded()
        let h = pad + (28 * s).rounded() + (12 * s).rounded() + messageHeight + pad + footerHeight
        card = UIRect(x: ((width - w) / 2).rounded(), y: ((height - h) / 2).rounded(), width: w, height: h)
        footer = UIRect(x: card.x, y: card.maxY - footerHeight, width: w, height: footerHeight)
        // The buttons sharing the strip equally, the main one first, as Windows lays them out.
        let n = Float(dialog.titles.count), gap = (8 * s).rounded(), bh = (32 * s).rounded()
        let bw = ((w - pad * 2 - gap * (n - 1)) / n).rounded()
        let y = (footer.y + (footerHeight - bh) / 2).rounded()
        let left = card.x + pad
        buttons = (0..<dialog.titles.count).map { UIRect(x: left + Float($0) * (bw + gap), y: y, width: bw, height: bh) }
    }

    func button(atX x: Float, y: Float) -> Int? { buttons.firstIndex { $0.contains(x, y) } }
}

struct DialogView {
    let canvas: Canvas
    let dialog: DialogModel
    let width: Float, height: Float, scale: Float

    func draw() {
        let c = canvas.raw, s = scale, fg = TerminalPalette.foreground
        let l = DialogLayout(dialog, width: width, height: height, scale: s, canvas: canvas)
        // The window behind dims.
        sol_canvas_fill_rect(c, 0, 0, width, height, 0x000000, TerminalPalette.isDark ? 0.45 : 0.3)
        let r = l.card, radius = 8 * s
        let body = TerminalPalette.mix(fg, TerminalPalette.background, TerminalPalette.isDark ? 0.07 : 0.0)
        let strip = TerminalPalette.mix(0x000000, body, TerminalPalette.isDark ? 0.18 : 0.04)
        for k in 1...3 {
            let k = Float(k)
            sol_canvas_fill_rounded(c, r.x - k * 2 * s, r.y - k * s + 6 * s, r.width + k * 4 * s, r.height + k * 4 * s, radius + k * 2 * s, 0x000000, 0.08)
        }
        sol_canvas_fill_rounded(c, r.x, r.y, r.width, r.height, radius, body, 1)
        sol_canvas_push_clip(c, l.footer.x, l.footer.y, l.footer.width, l.footer.height)
        sol_canvas_fill_rounded(c, r.x, r.y, r.width, r.height, radius, strip, 1)
        sol_canvas_pop_clip(c)
        sol_canvas_fill_rect(c, l.footer.x, l.footer.y, l.footer.width, 1, fg, 0.08)
        sol_canvas_stroke_rounded(c, r.x + 0.5, r.y + 0.5, r.width - 1, r.height - 1, radius, fg, 0.12, 1)

        let pad = (24 * s).rounded()
        let title = Array(dialog.title.utf16)
        sol_canvas_draw_label(c, r.x + pad, r.y + pad, r.width - pad * 2, 28 * s, title, Int32(title.count), 20 * s, 1, fg, 1)
        let message = Array(dialog.message.utf16)
        _ = sol_canvas_paragraph(c, r.x + pad, r.y + pad + 40 * s, r.width - pad * 2, message, Int32(message.count), 14 * s, 0, fg, 0.85, 0)

        for (i, b) in l.buttons.enumerated() {
            let primary = i == 0, hovered = dialog.hovered == i, pressed = dialog.pressed == i
            let fill = primary ? TerminalPalette.accent : TerminalPalette.mix(fg, body, 0.08)
            sol_canvas_fill_rounded(c, b.x, b.y, b.width, b.height, 4 * s, fill, pressed ? 0.75 : hovered ? 0.9 : 1)
            if !primary { sol_canvas_stroke_rounded(c, b.x + 0.5, b.y + 0.5, b.width - 1, b.height - 1, 4 * s, fg, 0.12, 1) }
            let text = dialog.titles[i]
            let units = Array(text.utf16)
            let tw = sol_canvas_measure_label(c, units, Int32(units.count), 14 * s, 0)
            let ink: UInt32 = primary ? (HexColor(rgb: TerminalPalette.accent).luminance > 0.55 ? 0x000000 : 0xFFFFFF) : fg
            sol_canvas_draw_label(c, b.x + (b.width - tw) / 2, b.y, tw + 2, b.height, units, Int32(units.count), 14 * s, 0, ink, 1)
        }
    }
}
