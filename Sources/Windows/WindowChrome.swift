import CCanvas
import Foundation

/// Icons from the system icon font.
private enum Icon {
    static let minimize: UInt16 = 0xE921, maximize: UInt16 = 0xE922, restore: UInt16 = 0xE923, close: UInt16 = 0xE8BB
    static let add: UInt16 = 0xE710, folder: UInt16 = 0xE8B7
    static let chevronLeft: UInt16 = 0xE76B, chevronRight: UInt16 = 0xE76C
    static let dockLeft: UInt16 = 0xE90C, dockRight: UInt16 = 0xE90D
}

/// A column's git state in the status bar: branch, sync, and how many files have changed.
struct GitBadge: Equatable {
    var branch: String
    var ahead = 0, behind = 0
    var upstream = false
    var changes = 0
    /// What git's doing ("Pulling…"), in place of the sync counts.
    var busy: String?

    init(_ info: GitInfo, busy: String?) {
        branch = info.branch
        ahead = info.ahead
        behind = info.behind
        upstream = info.upstream != nil
        changes = info.changes.count
        self.busy = busy
    }
}

enum GitPart: Equatable { case branch, sync, changes }

/// The tab bar and status bar. One function for the window and for snapshots.
struct WindowChrome {
    let canvas: Canvas
    let layout: WindowLayout
    var tabs: [String]
    var activeTab: Int
    /// While split, the other column's active tab, which shows as active in its own strip.
    var otherActiveTab: Int?
    var hovered: WindowPart?
    var pressed: WindowPart?
    var maximized = false
    var focused = true
    var folder: String?
    var home: String?
    var themeName = ThemeSpecs.defaultName.uppercased()
    var showsThemeIcon = true
    var themeHovered = false
    /// A tab being dragged, and where its left edge is.
    /// Each group's chip, by its first tab, and the run of tabs it spans.
    var chips: [Int: (label: String, color: UInt32, last: Int, collapsed: Bool)] = [:]
    /// Tabs picked with Ctrl or Shift.
    var picked: Set<Int> = []
    /// A tab's or a chip's name being typed, in its place.
    var editingTab: (index: Int, field: TextFieldState)?
    var editingChip: (index: Int, field: TextFieldState, placeholder: String)?
    var draggedTab: Int?
    var draggedX: Float = 0
    var hoveredCrumb: Int?
    /// The host the active tab is connected to over ssh.
    var sshHost: String?
    /// While split, the right column's folder, home and host, for its half of the status bar.
    var rightFolder: String?
    var rightHome: String?
    var rightSSHHost: String?
    /// Each column's repository, when its folder is in one.
    var git: GitBadge?
    var rightGit: GitBadge?
    var hoveredGit: (column: Int, part: GitPart)?

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
        for column in layout.isSplit ? [0, 1] : [0] {
            let v = layout.tabViewport(column: column), range = layout.tabRange(column: column)
            sol_canvas_push_clip(canvas.raw, v.x, v.y, v.width, v.height)
            for i in range where i != draggedTab && layout.tab(i).width > 0 && layout.tab(i).maxX > v.x && layout.tab(i).x < v.maxX { drawTab(i) }
            drawSeparators(range)
            drawGroups(range)
            if let draggedTab, range.contains(draggedTab) { drawTab(draggedTab) }
            sol_canvas_pop_clip(canvas.raw)
            drawScrollArrows(column)
            drawNewTabButton(column)
        }
        if layout.isSplit {
            // Where the columns meet, and the button that puts them back together.
            sol_canvas_fill_rect(canvas.raw, layout.divider, (8 * scale).rounded(), 1, bar.maxY - (8 * scale).rounded(), fg, 0.12)
            let c = layout.closeSplit
            if hovered == .closeSplit { sol_canvas_fill_rounded(canvas.raw, c.x, c.y, c.width, c.height, 5 * scale, fg, 0.10) }
            icon(0xE8BB, c, pixels: 9 * scale, alpha: hovered == .closeSplit ? 0.9 : 0.55)
        }
        if hovered == .flower {
            let side = (26 * scale).rounded(), f = layout.flower
            sol_canvas_fill_rounded(canvas.raw, f.x + ((f.width - side) / 2).rounded(), ((layout.tabBarHeight - side) / 2).rounded(), side, side, 6 * scale, TerminalPalette.surface, 0.7)
        }
        let flower = (22 * scale).rounded()
        canvas.drawArt("flower", UIRect(x: layout.flower.x + ((layout.flower.width - flower) / 2).rounded(),
                                        y: ((layout.tabBarHeight - flower) / 2).rounded(), width: flower, height: flower), scale: scale)
        drawCaptionButtons()
    }

    /// Each group's chip, and a line in its color over its tabs.
    private func drawGroups(_ range: Range<Int>) {
        for (first, group) in chips where range.contains(first) {
            guard let r = layout.chip(first) else { continue }
            let end = group.collapsed ? r.maxX : layout.tab(group.last).maxX
            sol_canvas_fill_rounded(canvas.raw, r.x, (2 * scale).rounded(), max(end - r.x, r.width), 2 * scale, scale, group.color, 0.85)
            let hover = hovered == .chip(first)
            if let editing = editingChip, editing.index == first {
                sol_canvas_fill_rounded(canvas.raw, r.x, r.y, r.width, r.height, 6 * scale, group.color, 1)
                let text = editing.field.text, pixels = 11.5 * scale, ink = HexColor(rgb: group.color).luminance > 0.6 ? UInt32(0x1A1A1A) : 0xFFFFFF
                let inner = UIRect(x: r.x + 8 * scale, y: r.y, width: r.width - 16 * scale, height: r.height)
                if text.isEmpty { label(editing.placeholder, inner, pixels: pixels, semibold: true, color: ink, alpha: 0.55) } else { label(text, inner, pixels: pixels, semibold: true, color: ink) }
                let caretX = inner.x + width(of: editing.field.beforeCaret, pixels: pixels, semibold: true)
                sol_canvas_fill_rect(canvas.raw, caretX.rounded(), r.y + 4 * scale, max(scale.rounded(), 1), r.height - 8 * scale, ink, 1)
                continue
            }
            if group.label.isEmpty {
                sol_canvas_fill_ellipse(canvas.raw, r.x + r.width / 2, r.midY, 6 * scale, 6 * scale, group.color, 1)
                if hover { sol_canvas_fill_rounded(canvas.raw, r.x, r.y, r.width, r.height, 6 * scale, fg, 0.12) }
                continue
            }
            sol_canvas_fill_rounded(canvas.raw, r.x, r.y, r.width, r.height, 6 * scale, group.color, hover ? 1 : 0.88)
            let ink: UInt32 = HexColor(rgb: group.color).luminance > 0.6 ? 0x1A1A1A : 0xFFFFFF
            let pixels = 11.5 * scale, textWidth = min(width(of: group.label, pixels: pixels, semibold: true), r.width - 12 * scale)
            label(group.label, UIRect(x: r.x + (r.width - textWidth) / 2, y: r.y, width: textWidth + 1, height: r.height), pixels: pixels, semibold: true, color: ink)
        }
    }

    /// Lines between tabs at rest, as on the Mac: one before the first, one between each two and one after the last, but
    /// none beside the active or hovered tab, which stand out by themselves.
    private func drawSeparators(_ range: Range<Int>) {
        func quiet(_ i: Int) -> Bool { i == activeTab || i == otherActiveTab || i == draggedTab || picked.contains(i) || hovered == .tab(i) || hovered == .tabClose(i) }
        func line(atX x: Float, midY: Float) {
            let height = (16 * scale).rounded(), width = max(scale.rounded(), 1)
            sol_canvas_fill_rect(canvas.raw, x.rounded(), (midY - height / 2).rounded(), width, height, fg, 0.18)
        }
        let shown = range.filter { layout.tab($0).width > 0 }
        guard let first = shown.first else { return }
        if !quiet(first) && chips[first] == nil { line(atX: layout.tab(first).x, midY: layout.tab(first).midY) }
        for (k, i) in shown.enumerated() {
            let r = layout.tab(i)
            if k + 1 < shown.count {
                let next = shown[k + 1]
                // None where a chip sits between them.
                if next == i + 1, chips[next] == nil, !quiet(i), !quiet(next) { line(atX: r.maxX, midY: r.midY) }
            } else if !quiet(i) {
                line(atX: r.maxX + 2 * scale, midY: r.midY)
            }
        }
    }

    /// Where a tab is drawn: its place, or under the pointer while it's being dragged.
    private func tabRect(_ i: Int) -> UIRect {
        var r = layout.tab(i)
        if i == draggedTab { r.x = draggedX }
        return r
    }

    private func closeRect(_ i: Int) -> UIRect {
        var c = layout.tabClose(i)
        if i == draggedTab { c.x += draggedX - layout.tab(i).x }
        return c
    }

    private func drawTab(_ i: Int) {
        let r = tabRect(i), active = i == activeTab || i == otherActiveTab
        let hover = hovered == .tab(i) || hovered == .tabClose(i)
        let radius = 8 * scale
        if active {
            // Runs down past the tab bar and into the terminal below it, which has the same color: the tab and its
            // contents read as one piece. The clip keeps the extra height out of the terminal.
            sol_canvas_push_clip(canvas.raw, r.x, r.y, r.width, r.height)
            sol_canvas_fill_rounded(canvas.raw, r.x, r.y, r.width, r.height + radius * 2, radius, TerminalPalette.background, 1)
            sol_canvas_stroke_rounded(canvas.raw, r.x + 0.5, r.y + 0.5, r.width - 1, r.height + radius * 2, radius, fg, 0.10, 1)
            sol_canvas_pop_clip(canvas.raw)
        } else if hover || picked.contains(i) {
            let inset = 2 * scale
            sol_canvas_fill_rounded(canvas.raw, r.x + inset, r.y + inset, r.width - inset * 2, r.height - inset * 3, radius - 2,
                                    TerminalPalette.surface, 0.55)
        }

        let textAlpha: Float = active ? 1 : 0.55
        let promptX = r.x + 12 * scale
        drawPrompt(atX: promptX, midY: r.midY, active: active)
        let titleX = promptX + 22 * scale
        let closes = (active || hover) && r.width >= 60 * scale && draggedTab == nil
        let room = closeRect(i).x - titleX - 4 * scale
        if let editing = editingTab, editing.index == i {
            let box = UIRect(x: titleX - 4 * scale, y: r.y + 6 * scale, width: max(room + 4 * scale, 60 * scale), height: r.height - 12 * scale)
            sol_canvas_fill_rounded(canvas.raw, box.x, box.y, box.width, box.height, 4 * scale, TerminalPalette.mix(0x000000, TerminalPalette.background, 0.3), 1)
            sol_canvas_stroke_rounded(canvas.raw, box.x + 0.5, box.y + 0.5, box.width - 1, box.height - 1, 4 * scale, TerminalPalette.accent, 0.9, 1)
            let text = editing.field.text
            let inner = UIRect(x: titleX, y: r.y, width: max(room - 4 * scale, 0), height: r.height)
            if text.isEmpty { label(tabs[i], inner, pixels: 12.5 * scale, alpha: 0.4) } else { label(text, inner, pixels: 12.5 * scale) }
            let caretX = titleX + width(of: editing.field.beforeCaret, pixels: 12.5 * scale)
            sol_canvas_fill_rect(canvas.raw, caretX.rounded(), box.y + 4 * scale, max(scale.rounded(), 1), box.height - 8 * scale, TerminalPalette.accent, 1)
        } else {
            label(tabs[i], UIRect(x: titleX, y: r.y, width: max(room, 0), height: r.height), pixels: 12.5 * scale, color: fg, alpha: textAlpha)
        }
        if closes {
            let c = closeRect(i)
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
    private func drawScrollArrows(_ column: Int) {
        guard layout.overflows(column: column) else { return }
        let scroll = column == 0 ? layout.tabScroll : layout.rightTabScroll, most = layout.maxTabScroll(column: column)
        let parts: (WindowPart, WindowPart) = column == 0 ? (.scrollLeft, .scrollRight) : (.rightScrollLeft, .rightScrollRight)
        for (part, r, glyph, more) in [(parts.0, layout.scrollLeft(column: column), Icon.chevronLeft, scroll > 0.5),
                                       (parts.1, layout.scrollRight(column: column), Icon.chevronRight, scroll < most - 0.5)] {
            let on = more && hovered == part
            if on { sol_canvas_fill_rounded(canvas.raw, r.x, r.y, r.width, r.height - 4 * scale, 6 * scale, TerminalPalette.surface, 0.7) }
            icon(glyph, UIRect(x: r.x, y: r.y, width: r.width, height: r.height - 4 * scale), pixels: 10 * scale, alpha: more ? (on ? 0.95 : 0.7) : 0.18)
        }
    }

    private func drawNewTabButton(_ column: Int) {
        let r = layout.newTab(column: column)
        if hovered == (column == 0 ? .newTab : .newTabRight) { sol_canvas_fill_rounded(canvas.raw, r.x, r.y, r.width, r.height, 5 * scale, fg, 0.10) }
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

    /// The theme's name and icon in the status bar, which open the theme menu.
    func themeSpot() -> UIRect {
        // Not while split, where the right column's folder goes, as on the Mac.
        guard !layout.isSplit else { return UIRect(x: 0, y: 0, width: 0, height: 0) }
        let themeWidth = width(of: themeName, pixels: 10.5 * scale, semibold: true)
        let right = layout.showsRightToggle ? layout.toggleRight.x - 8 * scale : layout.statusBar.maxX - 10 * scale
        let left = right - themeWidth - (showsThemeIcon ? 24 * scale : 4 * scale)
        return UIRect(x: left, y: layout.statusBar.y, width: right - left + 4 * scale, height: layout.statusBar.height)
    }

    /// Where the folder's parts go in the status bar, and what each stands for. For drawing them and for clicks.
    /// Where a column's git parts go, right to left from the end of its half: changes, sync, then the branch.
    func gitSpots(column: Int = 0) -> [(part: GitPart, rect: UIRect)] {
        guard let g = column == 0 ? git : rightGit else { return [] }
        let bar = layout.statusBar, pixels = 12 * scale
        var x = !layout.isSplit ? themeX - (showsThemeIcon ? 30 : 12) * scale : column == 0 ? layout.divider - 8 * scale : layout.toggleRight.x - 6 * scale
        var out: [(part: GitPart, rect: UIRect)] = []
        func add(_ part: GitPart, _ w: Float) {
            x -= w
            out.append((part, UIRect(x: x, y: bar.y + 3 * scale, width: w, height: bar.height - 6 * scale)))
            x -= 4 * scale
        }
        if g.changes > 0 { add(.changes, width(of: "● \(g.changes)", pixels: pixels) + 14 * scale) }
        add(.sync, width(of: syncText(g), pixels: pixels) + (g.busy == nil ? 30 : 14) * scale)
        add(.branch, min(width(of: g.branch, pixels: pixels), 170 * scale) + 34 * scale)
        return out
    }

    private func syncText(_ g: GitBadge) -> String {
        if let busy = g.busy { return busy }
        if !g.upstream { return "Publish" }
        return g.ahead == 0 && g.behind == 0 ? "" : "\(g.behind)↓ \(g.ahead)↑"
    }

    private func drawGit(_ column: Int) {
        guard let g = column == 0 ? git : rightGit else { return }
        let pixels = 12 * scale
        for (part, r) in gitSpots(column: column) {
            let hovered = hoveredGit.map { $0.column == column && $0.part == part } ?? false
            if hovered { sol_canvas_fill_rounded(canvas.raw, r.x, r.y, r.width, r.height, 4 * scale, fg, 0.10) }
            switch part {
            case .branch:
                drawBranchIcon(x: r.x + 9 * scale, midY: r.midY)
                label(g.branch, UIRect(x: r.x + 24 * scale, y: r.y, width: r.width - 28 * scale, height: r.height), pixels: pixels, alpha: 0.8)
            case .sync:
                if g.busy == nil { icon(0xE72C, UIRect(x: r.x + 4 * scale, y: r.y, width: 18 * scale, height: r.height), pixels: 10 * scale, alpha: 0.7) }
                label(syncText(g), UIRect(x: r.x + (g.busy == nil ? 24 : 7) * scale, y: r.y, width: r.width - 24 * scale, height: r.height), pixels: pixels, alpha: 0.75)
            case .changes:
                label("● \(g.changes)", UIRect(x: r.x + 7 * scale, y: r.y, width: r.width - 10 * scale, height: r.height), pixels: pixels, color: 0xE09C54, alpha: 0.95)
            }
        }
    }

    /// Git's branch mark: two commits on a line, and a branch off it.
    private func drawBranchIcon(x: Float, midY: Float) {
        let t = 1.3 * scale, top = midY - 5 * scale, bottom = midY + 5 * scale, side = x + 7 * scale
        sol_canvas_line(canvas.raw, x, top, x, bottom, fg, 0.7, t)
        sol_canvas_line(canvas.raw, side, top + 2 * scale, x + 1 * scale, midY + 2 * scale, fg, 0.7, t)
        for (cx, cy) in [(x, top), (x, bottom), (side, top + 1 * scale)] {
            sol_canvas_fill_ellipse(canvas.raw, cx, cy, 2 * scale, 2 * scale, fg, 0.85)
        }
    }

    /// The left column's (or the only one's); `column: 1`, the right column's half while split.
    func crumbSpots(column: Int = 0) -> [(label: String, path: String, rect: UIRect, hit: UIRect)] {
        crumbSpots(column: column, themeX: themeX)
    }

    /// Where the theme's name starts, which the folder's parts stop short of; while split, the middle or the right end.
    private var themeX: Float {
        let themeWidth = width(of: themeName, pixels: 10.5 * scale, semibold: true)
        return (layout.showsRightToggle ? layout.toggleRight.x - 8 * scale : layout.statusBar.maxX - 10 * scale) - themeWidth
    }

    /// Where a column's half of the status bar starts its folder: after the buttons on the left, or the middle.
    private func folderStart(_ column: Int) -> Float { column == 0 ? layout.hostsButton.maxX : layout.divider + 4 * scale }

    private func crumbSpots(column: Int, themeX: Float) -> [(label: String, path: String, rect: UIRect, hit: UIRect)] {
        let folder = column == 0 ? self.folder : rightFolder, sshHost = column == 0 ? self.sshHost : rightSSHHost
        guard let folder else { return [] }
        // Short of the theme's name, or while split, the middle and the right sidebar's switch; and of git's parts.
        var limit = !layout.isSplit ? themeX - 34 * scale : column == 0 ? layout.divider - 10 * scale : layout.toggleRight.x - 8 * scale
        if let first = gitSpots(column: column).last { limit = min(limit, first.rect.x - 14 * scale) }
        let bar = layout.statusBar, pixels = 12 * scale, base = folderStart(column)
        let iconX = base + 6 * scale
        var x = base + 8 * scale + 21 * scale
        // Over ssh, after the host's name.
        if let sshHost { x = base + 10 * scale + (14 * scale).rounded() + 5 * scale + width(of: sshHost, pixels: pixels) + 14 * scale }
        var out: [(label: String, path: String, rect: UIRect, hit: UIRect)] = []
        // The whole path, never shortened to ~, so that every folder above is a click away.
        for (i, crumb) in WindowText.crumbPaths(folder, home: nil).enumerated() {
            let w = min(width(of: crumb.label, pixels: pixels), max(limit - x, 0))
            // The first takes in the folder icon, and each a little either side, so that a short one like ~ is easy to hit.
            let start = i == 0 && sshHost == nil ? iconX : x - 4 * scale
            let hit = UIRect(x: start, y: bar.y, width: x + w + 4 * scale - start, height: bar.height)
            out.append((crumb.label, crumb.path, UIRect(x: x, y: bar.y, width: w, height: bar.height), hit))
            x += w + 13 * scale
        }
        return out
    }

    private func drawStatusBar() {
        let bar = layout.statusBar
        sol_canvas_fill_rect(canvas.raw, bar.x, bar.y, bar.width, bar.height, TerminalPalette.chrome, 1)
        sol_canvas_fill_rect(canvas.raw, bar.x, bar.y, bar.width, 1, fg, 0.10)
        let pixels = 12 * scale

        // The theme's name on the right, with its flower. While split, the right column's folder has that half.
        let themePixels = 10.5 * scale
        let themeWidth = width(of: themeName, pixels: themePixels, semibold: true)
        let themeX = self.themeX
        if layout.isSplit {
            sol_canvas_fill_rect(canvas.raw, layout.divider, bar.y + 5 * scale, 1, bar.height - 10 * scale, fg, 0.12)
        } else {
            let spot = themeSpot()
            if themeHovered { sol_canvas_fill_rounded(canvas.raw, spot.x, spot.y + 3 * scale, spot.width, spot.height - 6 * scale, 4 * scale, fg, 0.10) }
            label(themeName, UIRect(x: themeX, y: bar.y, width: themeWidth + 2, height: bar.height), pixels: themePixels, semibold: true, alpha: themeHovered ? 0.9 : 0.55)
            if showsThemeIcon {
                let side = (16 * scale).rounded()
                canvas.drawArt("flowerOutline", UIRect(x: themeX - side - 5 * scale, y: (bar.midY - side / 2).rounded(), width: side, height: side), scale: scale)
            }
        }

        // The sidebars' switches, at either end.
        var switches = [(WindowPart.toggleLeft, layout.toggleLeft, Icon.dockLeft, layout.leftWidth > 0)]
        if layout.showsRightToggle { switches.append((.toggleRight, layout.toggleRight, Icon.dockRight, layout.rightWidth > 0)) }
        for (part, r, glyph, on) in switches {
            if hovered == part { sol_canvas_fill_rounded(canvas.raw, r.x, r.y, r.width, r.height, 4 * scale, fg, 0.10) }
            icon(glyph, r, pixels: 12 * scale, color: on ? TerminalPalette.accent : nil, alpha: on ? 1 : 0.75)
        }
        let hosts = layout.hostsButton, art = (16 * scale).rounded()
        if hovered == .hosts { sol_canvas_fill_rounded(canvas.raw, hosts.x, hosts.y, hosts.width, hosts.height, 4 * scale, fg, 0.10) }
        canvas.drawArt("serverRack", UIRect(x: hosts.x + ((hosts.width - art) / 2).rounded(), y: (hosts.midY - art / 2).rounded(), width: art, height: art), scale: scale)

        // Each column's half: over ssh, the host first, then the folder's parts, each of which opens a menu of what's in it.
        // `hoveredCrumb` counts the left half's parts first, then the right's.
        var offset = 0
        for column in layout.isSplit ? [0, 1] : [0] {
            let host = column == 0 ? sshHost : rightSSHHost, base = folderStart(column)
            let end = !layout.isSplit ? themeX : column == 0 ? layout.divider : layout.toggleRight.x
            if let host {
                let x = base + 10 * scale, art = (14 * scale).rounded()
                canvas.drawArt("network", UIRect(x: x, y: (bar.midY - art / 2).rounded(), width: art, height: art), scale: scale)
                let w = min(width(of: host, pixels: pixels), max(end - x - 40 * scale, 0))
                label(host, UIRect(x: x + art + 5 * scale, y: bar.y, width: w + 1, height: bar.height), pixels: pixels, color: TerminalPalette.accent)
            }
            let spots = crumbSpots(column: column, themeX: themeX)
            for (i, spot) in spots.enumerated() {
                let last = i == spots.count - 1, hover = hoveredCrumb == offset + i
                if hover { sol_canvas_fill_rounded(canvas.raw, spot.hit.x, spot.hit.y + 3 * scale, spot.hit.width, spot.hit.height - 6 * scale, 4 * scale, fg, 0.10) }
                label(spot.label, UIRect(x: spot.rect.x, y: bar.y, width: spot.rect.width + 1, height: bar.height), pixels: pixels, alpha: last || hover ? 0.85 : 0.55)
                if !last { label("›", UIRect(x: spot.rect.maxX + 3 * scale, y: bar.y, width: 8 * scale, height: bar.height), pixels: pixels, alpha: 0.4) }
            }
            if host == nil {
                icon(Icon.folder, UIRect(x: base + 8 * scale, y: bar.y, width: 16 * scale, height: bar.height), pixels: 12 * scale, alpha: 0.75)
            }
            offset += spots.count
            drawGit(column)
        }
    }
}
