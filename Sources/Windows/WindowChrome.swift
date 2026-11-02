import CCanvas
import Foundation

/// Icons from the system icon font.
private enum Icon {
    static let minimize: UInt16 = 0xE921, maximize: UInt16 = 0xE922, restore: UInt16 = 0xE923, close: UInt16 = 0xE8BB
    static let add: UInt16 = 0xE710, folder: UInt16 = 0xE8B7
}

/// The tab bar and status bar. One function for the window and for snapshots.
struct WindowChrome {
    let canvas: Canvas
    let layout: WindowLayout
    var tabs: [String]
    var activeTab: Int
    var hovered: WindowPart?
    var pressed: WindowPart?
    var maximized = false
    var focused = true
    var folder: String?
    var home: String?
    var themeName = "SOLANUM DEFAULT"

    private var scale: Float { layout.scale }
    private var fg: UInt32 { TerminalPalette.foreground }

    /// Text in the interface font. The rectangle's height centers it.
    private func label(_ text: String, _ r: UIRect, pixels: Float, semibold: Bool = false, color: UInt32? = nil, alpha: Float = 1) {
        let units = Array(text.utf16)
        sol_canvas_draw_label(canvas.raw, r.x, r.y, r.width, r.height, units, Int32(units.count), pixels, semibold ? 1 : 0, color ?? fg, alpha)
    }

    private func width(of text: String, pixels: Float, semibold: Bool = false) -> Float {
        let units = Array(text.utf16)
        return sol_canvas_measure_label(canvas.raw, units, Int32(units.count), pixels, semibold ? 1 : 0).rounded(.up)
    }

    private func icon(_ glyph: UInt16, _ r: UIRect, pixels: Float, color: UInt32? = nil, alpha: Float = 1) {
        sol_canvas_draw_icon(canvas.raw, r.x, r.y, r.width, r.height, glyph, pixels, color ?? fg, alpha)
    }

    func draw() {
        sol_canvas_fill_gradient(canvas.raw, 0, 0, layout.width, layout.height, TerminalPalette.background, TerminalPalette.backgroundBottom)
        drawTabBar()
        drawStatusBar()
    }

    private func drawTabBar() {
        let bar = UIRect(x: 0, y: 0, width: layout.width, height: layout.tabBarHeight)
        sol_canvas_fill_rect(canvas.raw, bar.x, bar.y, bar.width, bar.height, TerminalPalette.chrome, 1)
        sol_canvas_fill_rect(canvas.raw, 0, bar.maxY - 1, bar.width, 1, fg, 0.10)
        for i in tabs.indices { drawTab(i) }
        drawNewTabButton()
        drawFlower(in: layout.flower)
        drawCaptionButtons()
    }

    private func drawTab(_ i: Int) {
        let r = layout.tab(i), active = i == activeTab
        let hover = hovered == .tab(i) || hovered == .tabClose(i)
        let radius = 8 * scale
        if active {
            // Runs down past the tab bar and into the terminal below it, which has the same color: the tab and its
            // contents read as one piece. The clip keeps the extra height out of the terminal.
            sol_canvas_push_clip(canvas.raw, r.x, r.y, r.width, r.height)
            sol_canvas_fill_rounded(canvas.raw, r.x, r.y, r.width, r.height + radius * 2, radius, TerminalPalette.background, 1)
            sol_canvas_stroke_rounded(canvas.raw, r.x + 0.5, r.y + 0.5, r.width - 1, r.height + radius * 2, radius, fg, 0.10, 1)
            sol_canvas_pop_clip(canvas.raw)
        } else if hover {
            let inset = 2 * scale
            sol_canvas_fill_rounded(canvas.raw, r.x + inset, r.y + inset, r.width - inset * 2, r.height - inset * 3, radius - 2,
                                    TerminalPalette.surface, 0.55)
        } else if i + 1 != activeTab, i + 1 < tabs.count {
            // A divider between two tabs at rest.
            sol_canvas_fill_rect(canvas.raw, r.maxX - 1, r.y + 7 * scale, 1, r.height - 14 * scale, fg, 0.14)
        }

        let textAlpha: Float = active ? 1 : 0.55
        let promptX = r.x + 12 * scale
        drawPrompt(atX: promptX, midY: r.midY, alpha: active ? 1 : 0.65)
        let titleX = promptX + 26 * scale
        let closes = (active || hover) && r.width >= 60 * scale
        let room = layout.tabClose(i).x - titleX - 4 * scale
        label(tabs[i], UIRect(x: titleX, y: r.y, width: max(room, 0), height: r.height), pixels: 12.5 * scale, color: fg, alpha: textAlpha)
        if closes {
            let c = layout.tabClose(i)
            if hovered == .tabClose(i) { sol_canvas_fill_rounded(canvas.raw, c.x, c.y, c.width, c.height, 4 * scale, fg, 0.12) }
            let inset = 5.5 * scale, thick = 1.3 * scale
            sol_canvas_line(canvas.raw, c.x + inset, c.y + inset, c.maxX - inset, c.maxY - inset, fg, 0.6, thick)
            sol_canvas_line(canvas.raw, c.maxX - inset, c.y + inset, c.x + inset, c.maxY - inset, fg, 0.6, thick)
        }
    }

    /// The prompt a terminal's tab shows: a chevron in the petals' pale purple, and an underscore in the title's color.
    private func drawPrompt(atX x: Float, midY: Float, alpha: Float) {
        let h = 5 * scale, w = 6 * scale, thick = 1.6 * scale
        sol_canvas_line(canvas.raw, x, midY - h, x + w, midY, TerminalPalette.accent, alpha, thick)
        sol_canvas_line(canvas.raw, x + w, midY, x, midY + h, TerminalPalette.accent, alpha, thick)
        sol_canvas_line(canvas.raw, x + w + 3 * scale, midY + h, x + w + 10 * scale, midY + h, fg, alpha, thick)
    }

    private func drawNewTabButton() {
        let r = layout.newTab
        if hovered == .newTab { sol_canvas_fill_rounded(canvas.raw, r.x, r.y, r.width, r.height, 5 * scale, fg, 0.10) }
        icon(Icon.add, r, pixels: 12 * scale, alpha: 0.75)
    }

    /// Solanum's flower: five petals around a yellow center.
    private func drawFlower(in r: UIRect, side: Float? = nil) {
        let cx = r.x + r.width / 2, cy = r.midY, reach = (side ?? 16 * scale) * 0.30, petal = (side ?? 16 * scale) * 0.27
        for k in 0..<5 {
            let angle = -Float.pi / 2 + Float(k) * 2 * Float.pi / 5
            sol_canvas_fill_ellipse(canvas.raw, cx + reach * cos(angle), cy + reach * sin(angle), petal, petal, 0xD8C8F4, hovered == .flower ? 1 : 0.9)
        }
        sol_canvas_fill_ellipse(canvas.raw, cx, cy, petal * 0.62, petal * 0.62, 0xE9B54D, 1)
    }

    private func drawCaptionButtons() {
        let alpha: Float = focused ? 1 : 0.5
        for (part, r, glyph) in [(WindowPart.minimize, layout.minimize, Icon.minimize),
                                 (.maximize, layout.maximize, maximized ? Icon.restore : Icon.maximize),
                                 (.close, layout.close, Icon.close)] {
            let on = hovered == part
            if on && part == .close {
                sol_canvas_fill_rect(canvas.raw, r.x, r.y, r.width, r.height, 0xC42B1C, pressed == part ? 0.85 : 1)
            } else if on {
                sol_canvas_fill_rect(canvas.raw, r.x, r.y, r.width, r.height, fg, pressed == part ? 0.06 : 0.10)
            }
            icon(glyph, r, pixels: 10 * scale, color: on && part == .close ? 0xFFFFFF : fg, alpha: on ? 1 : alpha)
        }
    }

    private func drawStatusBar() {
        let bar = layout.statusBar
        sol_canvas_fill_rect(canvas.raw, bar.x, bar.y, bar.width, bar.height, TerminalPalette.chrome, 1)
        sol_canvas_fill_rect(canvas.raw, bar.x, bar.y, bar.width, 1, fg, 0.10)
        let pixels = 12 * scale

        // The theme's name on the right, with its flower.
        let themePixels = 10.5 * scale
        let themeWidth = width(of: themeName, pixels: themePixels, semibold: true)
        let themeX = bar.maxX - 10 * scale - themeWidth
        label(themeName, UIRect(x: themeX, y: bar.y, width: themeWidth + 2, height: bar.height), pixels: themePixels, semibold: true, alpha: 0.55)
        drawFlower(in: UIRect(x: themeX - 22 * scale, y: bar.y, width: 18 * scale, height: bar.height), side: 13 * scale)

        // The folder on the left.
        var x = 12 * scale
        icon(Icon.folder, UIRect(x: x, y: bar.y, width: 16 * scale, height: bar.height), pixels: 12 * scale, alpha: 0.75)
        x += 21 * scale
        guard let folder else { return }
        let limit = themeX - 34 * scale
        let crumbs = WindowText.crumbs(folder, home: home)
        for (i, crumb) in crumbs.enumerated() {
            let last = i == crumbs.count - 1
            let w = min(width(of: crumb, pixels: pixels), max(limit - x, 0))
            label(crumb, UIRect(x: x, y: bar.y, width: w + 1, height: bar.height), pixels: pixels, alpha: last ? 0.85 : 0.55)
            x += w
            if !last {
                label("›", UIRect(x: x + 3 * scale, y: bar.y, width: 8 * scale, height: bar.height), pixels: pixels, alpha: 0.4)
                x += 13 * scale
            }
        }
    }
}
