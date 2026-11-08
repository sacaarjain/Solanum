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
    var detached = false
    var changes = 0
    /// What git's doing ("Pulling…"), in place of the sync counts.
    var busy: String?

    init(_ info: GitInfo, busy: String?) {
        branch = info.branch
        ahead = info.ahead
        behind = info.behind
        upstream = info.upstream != nil
        detached = info.detached
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
    /// What each tab shows before its title, as on the Mac: an agent's mark and status, a file tab's icon, else the prompt.
    var tabIcons: [TabIcon] = []
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
    /// The theme's planet beside its name, as on the Mac; nil shows Solanum's flower (for Solanum Default).
    var themePlanet: PlanetArt.Planet?
    /// The Quantum Moon, wandered off from beside the theme name (see QuantumMoon): into the flower's corner, or by the
    /// folder path, where it can be clicked.
    var moonInCorner = false
    var moonByFolders = false
    var moonHovered = false
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
    /// While a tab or group is dragged: where it would land, as a bar in that color.
    var dropMarker: (x: Float, color: UInt32)?
    /// The column the marker is in, when it isn't where something in the bar is being dragged (a file, or a tab over the
    /// other column's strip).
    var dropMarkerColumn: Int?
    /// The dragged tab has left its strip, following the pointer: its place shows empty.
    var draggedTabLifted = false
    /// A group's chip a dragged tab is over, which it would join (by the chip's first tab).
    var dropChip: Int?
    /// A group dragged by its chip: its tabs, and how far it's been moved.
    var liftedGroup: (first: Int, last: Int, dx: Float)?
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
        sol_canvas_backdrop_rect(canvas.raw, bar.x, bar.y, bar.width, bar.height, TerminalPalette.chrome)
        sol_canvas_fill_rect(canvas.raw, 0, bar.maxY - 1, bar.width, 1, fg, 0.10)
        for column in layout.isSplit ? [0, 1] : [0] {
            let v = layout.tabViewport(column: column), range = layout.tabRange(column: column)
            sol_canvas_push_clip(canvas.raw, v.x, v.y, v.width, v.height)
            for i in range where i != draggedTab && !isLifted(i) && layout.tab(i).width > 0 && layout.tab(i).maxX > v.x && layout.tab(i).x < v.maxX { drawTab(i) }
            drawSeparators(range)
            drawGroups(range, lifted: false)
            // What's being dragged is a little see-through, as on the Mac, so what's behind it shows.
            if let draggedTab, range.contains(draggedTab), !draggedTabLifted {
                sol_canvas_push_opacity(canvas.raw, 0.8)
                drawTab(draggedTab)
                sol_canvas_pop_opacity(canvas.raw)
            }
            if let g = liftedGroup, range.contains(g.first) {
                // The group being moved, chip and tabs, over the rest.
                sol_canvas_push_opacity(canvas.raw, 0.8)
                drawGroups(range, lifted: true)
                for i in g.first...g.last where layout.tab(i).width > 0 { drawTab(i) }
                sol_canvas_pop_opacity(canvas.raw)
            }
            let markerHere = dropMarkerColumn.map { $0 == column } ?? range.contains(draggedTab ?? liftedGroup?.first ?? -1)
            if let marker = dropMarker, v.x - 4 * scale <= marker.x, marker.x <= v.maxX + 4 * scale, markerHere {
                let w = (3 * scale).rounded(), top = (7 * scale).rounded()
                sol_canvas_fill_rounded(canvas.raw, (marker.x - w / 2).rounded(), top, w, layout.tabBarHeight - top - (4 * scale).rounded(), w / 2, marker.color, 1)
            }
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
        let corner = UIRect(x: layout.flower.x + ((layout.flower.width - flower) / 2).rounded(), y: ((layout.tabBarHeight - flower) / 2).rounded(),
                            width: flower, height: flower)
        if moonInCorner {
            canvas.drawPlanet(.quantumMoon, UIRect(x: corner.x + 2 * scale, y: corner.y + 2 * scale, width: corner.width - 4 * scale, height: corner.height - 4 * scale))
        } else {
            canvas.drawArt("flower", corner, scale: scale)
        }
        drawCaptionButtons()
    }

    private func isLifted(_ i: Int) -> Bool { liftedGroup.map { $0.first <= i && i <= $0.last } ?? false }
    private func liftOffset(_ i: Int) -> Float { isLifted(i) ? liftedGroup!.dx : 0 }

    /// Each group's chip, and a line in its color over its tabs: those at rest, or the one being dragged.
    private func drawGroups(_ range: Range<Int>, lifted: Bool) {
        for (first, group) in chips where range.contains(first) && isLifted(first) == lifted {
            guard var r = layout.chip(first) else { continue }
            r.x += liftOffset(first)
            let end = group.collapsed ? r.maxX : layout.tab(group.last).maxX + liftOffset(first)
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
                if dropChip == first {
                    sol_canvas_stroke_rounded(canvas.raw, r.x, r.y, r.width, r.height, 6 * scale, fg, 0.9, 1.5 * scale)
                }
                if hover { sol_canvas_fill_rounded(canvas.raw, r.x, r.y, r.width, r.height, 6 * scale, fg, 0.12) }
                continue
            }
            sol_canvas_fill_rounded(canvas.raw, r.x, r.y, r.width, r.height, 6 * scale, group.color, hover || dropChip == first ? 1 : 0.88)
            if dropChip == first {
                // A dragged tab over it would join it.
                sol_canvas_stroke_rounded(canvas.raw, r.x - 1.5 * scale, r.y - 1.5 * scale, r.width + 3 * scale, r.height + 3 * scale, 7 * scale, fg, 0.9, 1.5 * scale)
            }
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
        r.x += liftOffset(i)
        return r
    }

    private func closeRect(_ i: Int) -> UIRect {
        var c = layout.tabClose(i)
        if i == draggedTab { c.x += draggedX - layout.tab(i).x }
        c.x += liftOffset(i)
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
            sol_canvas_backdrop_rounded(canvas.raw, r.x, r.y, r.width, r.height + radius * 2, radius, TerminalPalette.background)
            sol_canvas_stroke_rounded(canvas.raw, r.x + 0.5, r.y + 0.5, r.width - 1, r.height + radius * 2, radius, fg, 0.10, 1)
            sol_canvas_pop_clip(canvas.raw)
        } else if isLifted(i) || i == draggedTab {
            // Carried along with its group: raised, as a dragged tab is.
            let inset = 2 * scale
            sol_canvas_fill_rounded(canvas.raw, r.x + inset, r.y + inset, r.width - inset * 2, r.height - inset * 3, radius - 2, TerminalPalette.surface, 0.9)
        } else if hover || picked.contains(i) {
            let inset = 2 * scale
            sol_canvas_fill_rounded(canvas.raw, r.x + inset, r.y + inset, r.width - inset * 2, r.height - inset * 3, radius - 2,
                                    TerminalPalette.surface, 0.55)
        }

        let textAlpha: Float = active ? 1 : 0.55
        let promptX = r.x + 12 * scale
        var titleX = promptX + 22 * scale
        switch tabIcons.indices.contains(i) ? tabIcons[i] : .prompt {
        case .agent(let agent):
            // The agent's mark, then its status's dot; the title after both, as on the Mac.
            Self.drawAgent(agent, on: canvas, atX: promptX, midY: r.midY, scale: scale)
            titleX = promptX + (AgentMarks.side + 3 + 6 + 7) * scale
        case .file(let glyph, let name):
            // In the prompt's place, so the title starts where a terminal tab's does: the icon pack's, else Solanum's own.
            let side = (14 * scale).rounded()
            if !(name.map { FileIcons.draw(name: $0, directory: false, x: promptX, y: (r.midY - side / 2).rounded(), size: side, on: canvas, alpha: active ? 1 : 0.65) } ?? false) {
                sol_canvas_draw_icon(canvas.raw, promptX, r.y, (15 * scale).rounded(), r.height, glyph, 11 * scale, fg, active ? 1 : 0.65)
            }
        case .prompt:
            drawPrompt(atX: promptX, midY: r.midY, active: active)
        }
        let closes = (active || hover) && r.width >= 60 * scale && draggedTab == nil && liftedGroup == nil
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

    /// An agent's mark and its status's dot from `x`, as the Mac's tabs show them (AgentInfo.draw there).
    static func drawAgent(_ agent: AgentInfo, on canvas: Canvas, atX x: Float, midY: Float, scale: Float) {
        let side = (AgentMarks.side * scale).rounded()
        AgentMarks.draw(agent.kind, on: canvas, in: UIRect(x: x, y: (midY - side / 2).rounded(), width: side, height: side), scale: scale)
        let d = 6 * scale
        sol_canvas_fill_ellipse(canvas.raw, x + side + 3 * scale + d / 2, midY, d / 2, d / 2, agent.status.rgb, 1)
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
    /// Where a column's half of the status bar puts things, as on the Mac: the ssh host, git's parts and a divider after
    /// them, then the folder. While split, the right half runs the other way: the folder, then git and the host against
    /// its right end.
    private struct Half {
        var hostX: Float?
        var git: [(part: GitPart, rect: UIRect)] = []
        var dividerX: Float?
        /// Where the folder starts (its icon, then its parts), and where it has to stop.
        var folderX: Float
        var limit: Float
        var mirrored = false
    }

    private func gitWidths(_ g: GitBadge?) -> [(GitPart, Float)] {
        guard let g else { return [] }
        let pixels = 12 * scale
        var out: [(GitPart, Float)] = [(.branch, 22 * scale + min(width(of: g.branch, pixels: pixels), 200 * scale) + 8 * scale)]
        if let busy = g.busy { out.append((.sync, 22 * scale + width(of: busy, pixels: pixels) + 6 * scale)) }
        else if g.upstream { out.append((.sync, 22 * scale + (syncCounts(g).isEmpty ? 0 : width(of: syncCounts(g), pixels: pixels) + 6 * scale))) }
        else if !g.detached { out.append((.sync, 22 * scale)) }
        if g.changes > 0 { out.append((.changes, 22 * scale + width(of: "\(g.changes)", pixels: pixels) + 6 * scale)) }
        return out
    }

    private func syncCounts(_ g: GitBadge) -> String {
        [g.behind > 0 ? "\(g.behind)↓" : nil, g.ahead > 0 ? "\(g.ahead)↑" : nil].compactMap { $0 }.joined(separator: " ")
    }

    private func half(_ column: Int) -> Half {
        let bar = layout.statusBar, pixels = 12 * scale
        let host = column == 0 ? sshHost : rightSSHHost, g = column == 0 ? git : rightGit
        let hostW: Float = host.map { (14 * scale).rounded() + 5 * scale + min(width(of: $0, pixels: pixels), 200 * scale) + 10 * scale } ?? 0
        let parts = gitWidths(g)
        func spot(_ x: Float, _ w: Float) -> UIRect { UIRect(x: x, y: bar.y + 3 * scale, width: w, height: bar.height - 6 * scale) }
        if column == 0 {
            var x = layout.hostsButton.maxX + 6 * scale
            var h = Half(folderX: 0, limit: !layout.isSplit ? themeX - 34 * scale : layout.divider - 10 * scale)
            if host != nil { h.hostX = x + 4 * scale; x += 4 * scale + hostW }
            for (part, w) in parts { h.git.append((part, spot(x, w))); x += w + 2 * scale }
            if g != nil { h.dividerX = x + 3 * scale; x += 9 * scale }
            h.folderX = x
            return h
        }
        let infoW = hostW + parts.reduce(0) { $0 + $1.1 + 2 * scale } + (g != nil ? 9 * scale : 0)
        var x = layout.toggleRight.x - 8 * scale - infoW
        var h = Half(folderX: layout.rightColumnX + 4 * scale, limit: x - 8 * scale, mirrored: true)
        if g != nil { h.dividerX = x + 3 * scale; x += 9 * scale }
        for (part, w) in parts { h.git.append((part, spot(x, w))); x += w + 2 * scale }
        if host != nil { h.hostX = x + 4 * scale }
        return h
    }

    /// Where a column's git parts go: the branch, its sync, and how many files have changed.
    func gitSpots(column: Int = 0) -> [(part: GitPart, rect: UIRect)] { half(column).git }

    private func drawGit(_ column: Int) {
        guard let g = column == 0 ? git : rightGit else { return }
        let h = half(column), pixels = 12 * scale, dim: Float = 0.6
        for (part, r) in h.git {
            let hovered = hoveredGit.map { $0.column == column && $0.part == part } ?? false
            if hovered { sol_canvas_fill_rounded(canvas.raw, r.x, r.y, r.width, r.height, 4 * scale, fg, 0.10) }
            let iconRect = UIRect(x: r.x + 3 * scale, y: r.y, width: 16 * scale, height: r.height)
            let text = UIRect(x: r.x + 21 * scale, y: r.y, width: max(r.width - 23 * scale, 0), height: r.height)
            switch part {
            case .branch:
                drawBranchIcon(x: r.x + 8 * scale, midY: r.midY)
                label(g.branch, text, pixels: pixels, alpha: 0.85)
            case .sync:
                if let busy = g.busy {
                    icon(0xE72C, iconRect, pixels: 10 * scale, alpha: dim)
                    label(busy, text, pixels: pixels, alpha: dim)
                } else if g.upstream {
                    let counts = syncCounts(g)
                    icon(0xE72C, iconRect, pixels: 10 * scale, color: counts.isEmpty ? nil : TerminalPalette.accent, alpha: counts.isEmpty ? dim : 1)
                    if !counts.isEmpty { label(counts, text, pixels: pixels, alpha: 0.85) }
                } else {
                    // Not on a remote yet: the cloud publishes it.
                    icon(0xE753, iconRect, pixels: 11 * scale, alpha: dim)
                }
            case .changes:
                icon(0xE70F, iconRect, pixels: 10 * scale, alpha: dim)
                label("\(g.changes)", text, pixels: pixels, alpha: dim)
            }
        }
        if let d = h.dividerX, (column == 0 ? folder : rightFolder) != nil || !h.mirrored {
            sol_canvas_fill_rect(canvas.raw, d.rounded(), layout.statusBar.y + 6 * scale, 1, layout.statusBar.height - 12 * scale, fg, 0.14)
        }
    }

    /// Git's branch mark: two commits on a line, and a branch off it, in the accent colour as on the Mac.
    private func drawBranchIcon(x: Float, midY: Float) {
        let t = 1.3 * scale, top = midY - 5 * scale, bottom = midY + 5 * scale, side = x + 7 * scale, c = TerminalPalette.accent
        sol_canvas_line(canvas.raw, x, top, x, bottom, c, 0.9, t)
        sol_canvas_line(canvas.raw, side, top + 2 * scale, x + 1 * scale, midY + 2 * scale, c, 0.9, t)
        for (cx, cy) in [(x, top), (x, bottom), (side, top + 1 * scale)] {
            sol_canvas_fill_ellipse(canvas.raw, cx, cy, 2 * scale, 2 * scale, c, 1)
        }
    }

    /// The left column's (or the only one's); `column: 1`, the right column's half while split.
    func crumbSpots(column: Int = 0) -> [(label: String, path: String, rect: UIRect, hit: UIRect)] {
        crumbSpots(column: column, themeX: themeX)
    }

    /// Where the theme's name starts, which the folder's parts stop short of.
    private var themeX: Float {
        let themeWidth = width(of: themeName, pixels: 10.5 * scale, semibold: true)
        return (layout.showsRightToggle ? layout.toggleRight.x - 8 * scale : layout.statusBar.maxX - 10 * scale) - themeWidth
    }

    private func crumbSpots(column: Int, themeX: Float) -> [(label: String, path: String, rect: UIRect, hit: UIRect)] {
        let folder = column == 0 ? self.folder : rightFolder, sshHost = column == 0 ? self.sshHost : rightSSHHost
        guard let folder else { return [] }
        let h = half(column), bar = layout.statusBar, pixels = 12 * scale, limit = h.limit
        // After the folder icon; over ssh there's none, as the host's name says where it is.
        let iconX = h.folderX
        var x = h.folderX + (sshHost == nil ? 23 : 4) * scale
        var out: [(label: String, path: String, rect: UIRect, hit: UIRect)] = []
        // The whole path, never shortened to ~, so that every folder above is a click away. When it doesn't fit, folders
        // drop off the front one at a time, ".." standing for them (it opens the nearest of them), down to ".. › Folder".
        let all = WindowText.crumbPaths(folder, home: nil), gap = 13 * scale
        let widths = all.map { width(of: $0.label, pixels: pixels) }
        let dotsWidth = width(of: "..", pixels: pixels)
        func total(from first: Int) -> Float {
            widths[first...].reduce(0, +) + gap * Float(all.count - first - 1) + (first > 0 ? dotsWidth + gap : 0)
        }
        var first = 0
        while first < all.count - 1 && total(from: first) > limit - x { first += 1 }
        var shown = Array(all[first...])
        if first > 0 { shown.insert(("..", all[first - 1].path), at: 0) }
        for (i, crumb) in shown.enumerated() {
            let w = min(width(of: crumb.label, pixels: pixels), max(limit - x, 0))
            // The first takes in the folder icon, and each a little either side, so that a short one like ~ is easy to hit.
            let start = i == 0 && sshHost == nil ? iconX : x - 4 * scale
            let hit = UIRect(x: start, y: bar.y, width: x + w + 4 * scale - start, height: bar.height)
            out.append((crumb.label, crumb.path, UIRect(x: x, y: bar.y, width: w, height: bar.height), hit))
            x += w + 13 * scale
        }
        // The right half's folder ends against its git and host, as on the Mac.
        if h.mirrored, let last = out.last {
            let shift = max(limit - last.rect.maxX, 0)
            out = out.map { ($0.label, $0.path, UIRect(x: $0.rect.x + shift, y: $0.rect.y, width: $0.rect.width, height: $0.rect.height),
                             UIRect(x: $0.hit.x + shift, y: $0.hit.y, width: $0.hit.width, height: $0.hit.height)) }
        }
        return out
    }

    /// The Quantum Moon by the folder path, where it's clicked: in the left half's folder icon's place.
    func moonRect() -> UIRect? {
        guard moonByFolders else { return nil }
        let bar = layout.statusBar, x = folderIconX(0) ?? half(0).folderX + 2 * scale
        return UIRect(x: x - 3 * scale, y: bar.y + 2 * scale, width: 22 * scale, height: bar.height - 4 * scale)
    }

    /// Where the folder icon goes: before the first part.
    private func folderIconX(_ column: Int) -> Float? {
        guard (column == 0 ? sshHost : rightSSHHost) == nil else { return nil }
        let spots = crumbSpots(column: column)
        return spots.first.map { $0.rect.x - 21 * scale } ?? half(column).folderX + 2 * scale
    }

    private func drawStatusBar() {
        let bar = layout.statusBar
        sol_canvas_backdrop_rect(canvas.raw, bar.x, bar.y, bar.width, bar.height, TerminalPalette.chrome)
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
            if showsThemeIcon, let planet = themePlanet {
                let side = (18 * scale).rounded()
                canvas.drawPlanet(planet, UIRect(x: themeX - side - 4 * scale, y: (bar.midY - side / 2).rounded(), width: side, height: side))
            } else if showsThemeIcon {
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

        // Each column's half: over ssh the host, git, then the folder's parts, each of which opens a menu of what's in it.
        // `hoveredCrumb` counts the left half's parts first, then the right's.
        var offset = 0
        for column in layout.isSplit ? [0, 1] : [0] {
            let host = column == 0 ? sshHost : rightSSHHost, h = half(column)
            if let host, let x = h.hostX {
                let art = (14 * scale).rounded()
                canvas.drawArt("network", UIRect(x: x, y: (bar.midY - art / 2).rounded(), width: art, height: art), scale: scale)
                label(host, UIRect(x: x + art + 5 * scale, y: bar.y, width: min(width(of: host, pixels: pixels), 200 * scale) + 1, height: bar.height),
                      pixels: pixels, color: TerminalPalette.accent)
            }
            drawGit(column)
            let spots = crumbSpots(column: column, themeX: themeX)
            for (i, spot) in spots.enumerated() {
                let last = i == spots.count - 1, hover = hoveredCrumb == offset + i
                if hover { sol_canvas_fill_rounded(canvas.raw, spot.hit.x, spot.hit.y + 3 * scale, spot.hit.width, spot.hit.height - 6 * scale, 4 * scale, fg, 0.10) }
                label(spot.label, UIRect(x: spot.rect.x, y: bar.y, width: spot.rect.width + 1, height: bar.height), pixels: pixels, alpha: last || hover ? 0.85 : 0.55)
                if !last { label("›", UIRect(x: spot.rect.maxX + 3 * scale, y: bar.y, width: 8 * scale, height: bar.height), pixels: pixels, alpha: 0.4) }
            }
            if column == 0, let moon = moonRect() {
                // The moon, in the folder's place.
                if moonHovered { sol_canvas_fill_rounded(canvas.raw, moon.x, moon.y, moon.width, moon.height, 4 * scale, fg, 0.10) }
                let side = (18 * scale).rounded()
                canvas.drawPlanet(.quantumMoon, UIRect(x: (moon.x + (moon.width - side) / 2).rounded(), y: (moon.y + (moon.height - side) / 2).rounded(), width: side, height: side))
            } else if let x = folderIconX(column) {
                icon(Icon.folder, UIRect(x: x, y: bar.y, width: 16 * scale, height: bar.height), pixels: 12 * scale, alpha: 0.75)
            }
            offset += spots.count
        }
    }
}
