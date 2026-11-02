import CCanvas
import Foundation

/// Icons from the system icon font.
private enum Icon {
    static let minimize: UInt16 = 0xE921, maximize: UInt16 = 0xE922, restore: UInt16 = 0xE923, close: UInt16 = 0xE8BB
    static let add: UInt16 = 0xE710, folder: UInt16 = 0xE8B7
    static let chevronLeft: UInt16 = 0xE76B, chevronRight: UInt16 = 0xE76C
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
        let v = layout.tabViewport
        sol_canvas_push_clip(canvas.raw, v.x, v.y, v.width, v.height)
        for i in tabs.indices where layout.tab(i).maxX > v.x && layout.tab(i).x < v.maxX { drawTab(i) }
        drawSeparators()
        sol_canvas_pop_clip(canvas.raw)
        drawScrollArrows()
        drawNewTabButton()
        let flower = (22 * scale).rounded()
        canvas.drawArt("flower", UIRect(x: layout.flower.x + ((layout.flower.width - flower) / 2).rounded(),
                                        y: ((layout.tabBarHeight - flower) / 2).rounded(), width: flower, height: flower), scale: scale)
        drawCaptionButtons()
    }

    /// Lines between tabs at rest, as on the Mac: one before the first, one between each two and one after the last, but
    /// none beside the active or hovered tab, which stand out by themselves.
    private func drawSeparators() {
        func quiet(_ i: Int) -> Bool { i == activeTab || hovered == .tab(i) || hovered == .tabClose(i) }
        func line(atX x: Float, midY: Float) {
            let height = (16 * scale).rounded(), width = max(scale.rounded(), 1)
            sol_canvas_fill_rect(canvas.raw, x.rounded(), (midY - height / 2).rounded(), width, height, fg, 0.18)
        }
        guard !tabs.isEmpty else { return }
        if !quiet(0) { line(atX: layout.tab(0).x, midY: layout.tab(0).midY) }
        for i in tabs.indices {
            let r = layout.tab(i)
            if i + 1 < tabs.count {
                if !quiet(i) && !quiet(i + 1) { line(atX: r.maxX, midY: r.midY) }
            } else if !quiet(i) {
                line(atX: r.maxX + 2 * scale, midY: r.midY)
            }
        }
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
        }

        let textAlpha: Float = active ? 1 : 0.55
        let promptX = r.x + 12 * scale
        drawPrompt(atX: promptX, midY: r.midY, active: active)
        let titleX = promptX + 22 * scale
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

    /// The prompt a terminal's tab shows: Solanum's two slim petals and an underscore.
    private func drawPrompt(atX x: Float, midY: Float, active: Bool) {
        let w = (15 * scale).rounded(), h = (13 * scale).rounded()
        canvas.drawArt(active ? "prompt" : "promptDim", UIRect(x: x, y: (midY - h / 2).rounded(), width: w, height: h), scale: scale)
    }

    /// At both ends of tabs that don't all fit, faint when there's nothing more that way.
    private func drawScrollArrows() {
        guard layout.overflows else { return }
        for (part, r, glyph, more) in [(WindowPart.scrollLeft, layout.scrollLeft, Icon.chevronLeft, layout.tabScroll > 0.5),
                                       (.scrollRight, layout.scrollRight, Icon.chevronRight, layout.tabScroll < layout.maxTabScroll - 0.5)] {
            let on = more && hovered == part
            if on { sol_canvas_fill_rounded(canvas.raw, r.x, r.y, r.width, r.height - 4 * scale, 6 * scale, TerminalPalette.surface, 0.7) }
            icon(glyph, UIRect(x: r.x, y: r.y, width: r.width, height: r.height - 4 * scale), pixels: 10 * scale, alpha: more ? (on ? 0.95 : 0.7) : 0.18)
        }
    }

    private func drawNewTabButton() {
        let r = layout.newTab
        if hovered == .newTab { sol_canvas_fill_rounded(canvas.raw, r.x, r.y, r.width, r.height, 5 * scale, fg, 0.10) }
        icon(Icon.add, r, pixels: 12 * scale, alpha: 0.75)
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
        let side = (16 * scale).rounded()
        canvas.drawArt("flowerOutline", UIRect(x: themeX - side - 5 * scale, y: (bar.midY - side / 2).rounded(), width: side, height: side), scale: scale)

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
