import CCanvas
import Foundation

/// Icons from the system icon font.
private enum Icon {
    static let minimize: UInt16 = 0xE921, maximize: UInt16 = 0xE922, restore: UInt16 = 0xE923, close: UInt16 = 0xE8BB
    static let add: UInt16 = 0xE710, folder: UInt16 = 0xE8B7
    static let chevronLeft: UInt16 = 0xE76B, chevronRight: UInt16 = 0xE76C
    static let dockLeft: UInt16 = 0xE90C, dockRight: UInt16 = 0xE90D
}

/// Git's marks in the status bar, drawn as the Mac's are (its arrow.triangle.branch, arrow.triangle.2.circlepath,
/// icloud.and.arrow.up and square.and.pencil): Solanum's own drawings of the same shapes, as paths on a 16-point square.
enum GitIcons {
    enum Kind { case branch, sync, publish, changes }

    /// Lines, and shapes filled (arrowheads), for each.
    private static func paths(_ kind: Kind) -> (lines: [String], fills: [String]) {
        switch kind {
        case .branch:
            // A Y: a stem up from the bottom, splitting into two arms that curve out to the upper left and right, a
            // triangle at the end of each.
            return (["M8 14.6 V10.2", "M8 10.2 C8 8.2 6.8 6.9 5.4 5.5", "M8 10.2 C8 8.2 9.2 6.9 10.6 5.5"],
                    ["M3.2 3.4 L6.53 4.25 L4.19 6.69 Z", "M12.8 3.4 L9.47 4.25 L11.81 6.69 Z"])
        case .sync:
            // Two arcs of one circle chasing each other clockwise, as the Mac's arrow.triangle.2.circlepath: over the top
            // from the left to the upper right, a triangle there pointing on round; under the bottom from the right to the
            // lower left, the same. A clear gap between each arrowhead and the next arc's tail.
            return (["M2.98 6.65 A5.2 5.2 0 0 1 12.26 5.02", "M13.02 9.35 A5.2 5.2 0 0 1 3.74 10.98"],
                    ["M13.81 7.23 L13.98 3.81 L10.54 6.22 Z", "M2.19 8.77 L2.02 12.19 L5.46 9.78 Z"])
        case .publish:
            // A cloud, an arrow up out of it.
            return (["M4.6 12.6 H11.6 A3 3 0 0 0 12.1 6.7 A4.2 4.2 0 0 0 4.2 7.5 A2.6 2.6 0 0 0 4.6 12.6 Z",
                     "M8.1 11.2 V7.4 M6.6 8.9 L8.1 7.4 L9.6 8.9"], [])
        case .changes:
            // A square open at its top right, a pencil writing across it.
            return (["M7.6 3.4 H4.6 A1.6 1.6 0 0 0 3 5 V11.9 A1.6 1.6 0 0 0 4.6 13.5 H11.5 A1.6 1.6 0 0 0 13.1 11.9 V8.9",
                     "M6.4 10.1 L6.8 8.1 L11.9 3 A0.95 0.95 0 0 1 13.3 4.4 L8.2 9.5 Z"], [])
        }
    }

    /// The mark centered in `r`, 14 points across.
    static func draw(_ kind: Kind, in r: UIRect, on canvas: Canvas, scale: Float, color: UInt32, alpha: Float) {
        let k = scale * 14 / 16, side = 16 * k
        let x = (r.x + (r.width - side) / 2).rounded(), y = (r.y + (r.height - side) / 2).rounded()
        let shape = paths(kind)
        for d in shape.lines { sol_canvas_stroke_svg_path(canvas.raw, d, x, y, k, color, alpha, 1.35) }
        for d in shape.fills { sol_canvas_fill_svg_path(canvas.raw, d, x, y, k, color, alpha) }
    }
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
    /// The active tab's shell, for the status bar's shell button (see Shells).
    var shell: ShellOption?
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
    /// The theme's icon beside its name (see ThemeIcon): its planet, the flower, a picture of your own, or none.
    var themeIcon: ThemeIcon?
    var showsThemeIcon: Bool { themeIcon != nil }
    /// The clock a GIF icon's frames go by.
    var iconTime: Double = 0
    /// The pointer's on the Extensions button.
    var extensionsHovered = false
    /// The theme's own name, as typed (the status bar shows it in capitals), for the card hovering it.
    var themeTitle = ThemeSpecs.defaultName
    /// The Quantum Moon, wandered off from beside the theme name (see QuantumMoon): into the flower's corner, or by the
    /// folder path, where it can be clicked.
    var moonInCorner = false
    var moonByFolders = false
    var moonHovered = false
    var themeHovered = false
    /// Keep Awake's time left ("7h 59m"), shown over its cup; nil while off.
    var keepAwakeLeft: String?
    /// Where the cup's steam is in its rise (seconds, any origin) while Keep Awake is on and animating; nil draws it still.
    var steamTime: Double?
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
    /// What's held over the strip where the tabs have parted for it (`layout.dropGap`): shown there as the tab it'll be.
    var dropGhost: (title: String, glyph: UInt16?)?
    /// The column the marker is in, when it isn't where something in the bar is being dragged (a file, or a tab over the
    /// other column's strip).
    var dropMarkerColumn: Int?
    /// The dragged tab has left its strip, following the pointer: its place shows empty.
    var draggedTabLifted = false
    /// A group's chip a dragged tab is over, which it would join (by the chip's first tab).
    var dropChip: Int?
    /// The tab the Send to Chat menu's highlighted chat is in, marked as a drop target is, as on the Mac: tinted and
    /// outlined in its group's color (the accent outside one), or its chip ringed while its group is collapsed.
    var sendTarget: Int?
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
            if let ghost = dropGhost, let gap = layout.dropGapRect, layout.dropGap?.column == column {
                let inset = 2 * scale, r = gap, radius = 8 * scale
                sol_canvas_fill_rounded(canvas.raw, r.x + inset, r.y + inset, r.width - inset * 2, r.height - inset * 3, radius - 2, TerminalPalette.surface, 0.9)
                sol_canvas_stroke_rounded(canvas.raw, r.x + inset + 0.5, r.y + inset + 0.5, r.width - inset * 2 - 1, r.height - inset * 3 - 1, radius - 2,
                                          TerminalPalette.accent, 0.8, max(scale, 1))
                var tx = r.x + 12 * scale
                if let glyph = ghost.glyph {
                    sol_canvas_draw_icon(canvas.raw, tx, r.y, 15 * scale, r.height - inset, glyph, 11 * scale, TerminalPalette.accent, 0.9)
                    tx += 22 * scale
                }
                label(ghost.title, UIRect(x: tx, y: r.y, width: max(r.maxX - tx - 10 * scale, 0), height: r.height - inset), pixels: 12.5 * scale, alpha: 0.85)
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
            let ringed = dropChip == first || (group.collapsed && sendTarget.map { first <= $0 && $0 <= group.last } == true)
            if group.label.isEmpty {
                sol_canvas_fill_ellipse(canvas.raw, r.x + r.width / 2, r.midY, 6 * scale, 6 * scale, group.color, 1)
                if ringed {
                    sol_canvas_stroke_rounded(canvas.raw, r.x, r.y, r.width, r.height, 6 * scale, fg, 0.9, 1.5 * scale)
                }
                if hover { sol_canvas_fill_rounded(canvas.raw, r.x, r.y, r.width, r.height, 6 * scale, fg, 0.12) }
                continue
            }
            sol_canvas_fill_rounded(canvas.raw, r.x, r.y, r.width, r.height, 6 * scale, group.color, hover || ringed ? 1 : 0.88)
            if ringed {
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

        if i == sendTarget, r.width > 2 * scale {
            let color = chips.first { $0.key <= i && i <= $0.value.last }?.value.color ?? TerminalPalette.accent
            let inset = 2 * scale
            sol_canvas_fill_rounded(canvas.raw, r.x + inset, r.y + inset, r.width - inset * 2, r.height - inset * 3, radius - 2, color, 0.18)
            sol_canvas_stroke_rounded(canvas.raw, r.x + inset, r.y + inset, r.width - inset * 2, r.height - inset * 3, radius - 2, color, 1, 1.5 * scale)
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
        case .dot(let running):
            // Green while a command runs, red when the last one failed: not the accent, which can be orange or red.
            let d = 6 * scale
            sol_canvas_fill_ellipse(canvas.raw, promptX + 7 * scale, r.midY, d / 2, d / 2, TerminalPalette.ansi[running ? 2 : 1], 1)
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

    /// A teacup on its saucer, on a 24-unit square, as classic clip art draws one: a wide cup narrowing to its foot, a
    /// round handle, and a saucer under it. The cup's body is one path, filled lightly and outlined.
    private static let cupBody = "M3.2 9.6H17.4L16.7 14.2C16.3 16.8 14.4 18.6 11.9 18.6H8.7C6.2 18.6 4.3 16.8 3.9 14.2Z"
    private static let cupHandle = "M17.2 10.9C19.4 10.3 21.1 11.3 21 13C20.9 14.7 19 15.8 16.7 15.2"
    private static let saucer = "M1.6 19.9H19C18.6 21.1 17.4 21.8 15.9 21.8H4.7C3.2 21.8 2 21.1 1.6 19.9Z"

    /// Keep Awake's cup, centered in `r`, with three wisps of steam over it: waving as they rise while it's on (`steam`,
    /// in seconds, moves them), still otherwise (nil).
    static func drawCup(on canvas: Canvas, in r: UIRect, scale: Float, color: UInt32, alpha: Float, steam: Double?) {
        // 24 units across 17 pixels at 100%.
        let unit = 17 * scale / 24, side = 24 * unit
        let x = (r.x + (r.width - side) / 2).rounded(), y = (r.y + (r.height - side) / 2).rounded()
        sol_canvas_fill_svg_path(canvas.raw, cupBody, x, y, unit, color, alpha * 0.3)
        sol_canvas_fill_svg_path(canvas.raw, saucer, x, y, unit, color, alpha * 0.3)
        // Outlines in a solid color, so where the handle and saucer meet the cup doesn't show darker, dimmed or not.
        let ink = alpha < 1 ? TerminalPalette.mix(color, TerminalPalette.chrome, alpha) : color
        for path in [cupBody, cupHandle, saucer] { sol_canvas_stroke_svg_path(canvas.raw, path, x, y, unit, ink, 1, 1.6) }
        // Three S-shaped wisps side by side, as in the picture; moving, each wave travels up them.
        let phase = Float((steam ?? 0).truncatingRemainder(dividingBy: 1000)) * 4
        for base in [Float(7.3), 10.3, 13.3] {
            var points: [Float] = []
            let bottom: Float = 8, top: Float = 1.6, steps = 14
            for i in 0...steps {
                let yy = bottom - (bottom - top) * Float(i) / Float(steps)
                points += [x + (base + 0.75 * sin(yy * 1.0 + phase)) * unit, y + yy * unit]
            }
            points.withUnsafeBufferPointer { p in
                sol_canvas_stroke_polyline(canvas.raw, p.baseAddress, Int32(steps + 1), 0, color, alpha * 0.7, 1.15 * unit)
            }
        }
    }

    /// What the pointer over Keep Awake's cup shows: whether it's on, and for how much longer.
    var keepAwakeTip: String {
        keepAwakeLeft.map { "Keeping this PC awake \u{00B7} \($0) left" } ?? "Caffeinate is off \u{00B7} click to start it for \(KeepAwake.shortDuration(AppSettings.shared.keepAwakeSeconds))"
    }

    /// The tip over Keep Awake's cup, above the status bar, while the pointer's on it. Drawn over everything else.
    func drawKeepAwakeTip() {
        guard hovered == .keepAwake else { return }
        let r = layout.keepAwakeButton, text = keepAwakeTip, px = 12 * scale
        let w = width(of: text, pixels: px, semibold: false) + 18 * scale, h = (24 * scale).rounded()
        let box = UIRect(x: max(r.x + r.width / 2 - w / 2, 6 * scale).rounded(), y: (layout.statusBar.y - h - 6 * scale).rounded(), width: w, height: h)
        sol_canvas_fill_rounded(canvas.raw, box.x, box.y + 2 * scale, box.width, box.height, 6 * scale, 0x000000, 0.25)
        sol_canvas_fill_rounded(canvas.raw, box.x, box.y, box.width, box.height, 6 * scale, TerminalPalette.mix(fg, TerminalPalette.chrome, 0.12), 1)
        sol_canvas_stroke_rounded(canvas.raw, box.x + 0.5, box.y + 0.5, box.width - 1, box.height - 1, 6 * scale, fg, 0.18, 1)
        label(text, UIRect(x: box.x + 9 * scale, y: box.y, width: box.width - 18 * scale + 1, height: box.height), pixels: px)
    }

    /// Where the card hovering the theme's name goes: just above it, lined up with its right end.
    func themeHoverCard() -> UIRect? {
        guard themeHovered, !layout.isSplit else { return nil }
        let s = scale, spot = themeSpot()
        let nameWidth = min(220 * s, width(of: themeTitle, pixels: 11.5 * s, semibold: true))
        let w = max(44 * s + 2 * 12 * s + 16 * s, nameWidth + 2 * 12 * s).rounded(), h = (12 + 44 + 8 + 15 + 12 - 2) * s
        let x = min(spot.maxX - w, layout.statusBar.maxX - w - 6 * s)
        return UIRect(x: max(x, 6 * s).rounded(), y: (layout.statusBar.y - h - 6 * s).rounded(), width: w, height: h.rounded())
    }

    /// Hovering the theme's name shows its icon, bigger, with the name below, as on the Mac. The Quantum Moon, while it's
    /// wandered off the status bar, isn't given away (`themeIcon` is nil then). Drawn over everything else.
    func drawThemeHoverCard() {
        guard let box = themeHoverCard() else { return }
        let s = scale, c = canvas.raw, radius = 10 * s
        sol_canvas_fill_rounded(c, box.x, box.y + 3 * s, box.width, box.height, radius, 0x000000, 0.28)
        sol_canvas_fill_rounded(c, box.x, box.y, box.width, box.height, radius, TerminalPalette.mix(TerminalPalette.isDark ? 0xFFFFFF : 0x000000, TerminalPalette.surface, 0.04), 1)
        sol_canvas_stroke_rounded(c, box.x + 0.5, box.y + 0.5, box.width - 1, box.height - 1, radius, fg, TerminalPalette.isDark ? 0.16 : 0.18, 1)
        let side = (44 * s).rounded()
        let r = UIRect(x: (box.x + (box.width - side) / 2).rounded(), y: box.y + 12 * s, width: side, height: side)
        if let themeIcon {
            canvas.drawThemeIcon(themeIcon, r, scale: scale, time: iconTime)
        } else {
            // No icon of its own: a palette.
            sol_canvas_draw_icon(c, r.x, r.y, r.width, r.height, 0xE790, 26 * s, fg, 0.55)
        }
        let px = 11.5 * s, nameWidth = min(width(of: themeTitle, pixels: px, semibold: true), box.width - 16 * s)
        label(themeTitle, UIRect(x: (box.x + (box.width - nameWidth) / 2).rounded(), y: r.maxY + 8 * s, width: nameWidth + 1, height: 16 * s), pixels: px, semibold: true, alpha: 0.95)
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

    /// The Extensions button, just left of the theme's name, as on the Mac. Not while split, as the theme isn't.
    func extensionsSpot() -> UIRect {
        guard !layout.isSplit else { return UIRect(x: 0, y: 0, width: 0, height: 0) }
        let spot = themeSpot(), side = layout.keepAwakeButton.width
        return UIRect(x: (spot.x - 2 * scale - side).rounded(), y: layout.keepAwakeButton.y, width: side, height: layout.keepAwakeButton.height)
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
        var out: [(GitPart, Float)] = [(.branch, 22 * scale + min(width(of: g.branch, pixels: pixels, semibold: true), 200 * scale) + 8 * scale)]
        if let busy = g.busy { out.append((.sync, 22 * scale + width(of: busy, pixels: pixels, semibold: true) + 6 * scale)) }
        else if g.upstream { out.append((.sync, 22 * scale + (syncCounts(g).isEmpty ? 0 : width(of: syncCounts(g), pixels: pixels, semibold: true) + 6 * scale))) }
        else if !g.detached { out.append((.sync, 22 * scale)) }
        if g.changes > 0 { out.append((.changes, 22 * scale + width(of: "\(g.changes)", pixels: pixels, semibold: true) + 6 * scale)) }
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
            var x = layout.keepAwakeButton.maxX + 6 * scale
            var h = Half(folderX: 0, limit: !layout.isSplit ? extensionsSpot().x - 8 * scale : layout.divider - 10 * scale)
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
                // The branch's mark two pixels higher than the others and its name one, where they sit best on the bar.
                GitIcons.draw(.branch, in: UIRect(x: iconRect.x, y: iconRect.y - 2, width: iconRect.width, height: iconRect.height),
                              on: canvas, scale: scale, color: TerminalPalette.accent, alpha: 1)
                label(g.branch, UIRect(x: text.x, y: text.y - 1, width: text.width, height: text.height), pixels: pixels, semibold: true, alpha: 0.85)
            case .sync:
                if let busy = g.busy {
                    GitIcons.draw(.sync, in: iconRect, on: canvas, scale: scale, color: fg, alpha: dim)
                    label(busy, text, pixels: pixels, semibold: true, alpha: dim)
                } else if g.upstream {
                    let counts = syncCounts(g)
                    GitIcons.draw(.sync, in: iconRect, on: canvas, scale: scale, color: counts.isEmpty ? fg : TerminalPalette.accent, alpha: counts.isEmpty ? dim : 1)
                    if !counts.isEmpty { label(counts, text, pixels: pixels, semibold: true, alpha: 0.85) }
                } else {
                    // Not on a remote yet: the cloud publishes it.
                    GitIcons.draw(.publish, in: iconRect, on: canvas, scale: scale, color: fg, alpha: dim)
                }
            case .changes:
                GitIcons.draw(.changes, in: iconRect, on: canvas, scale: scale, color: fg, alpha: dim)
                label("\(g.changes)", text, pixels: pixels, semibold: true, alpha: dim)
            }
        }
        if let d = h.dividerX, (column == 0 ? folder : rightFolder) != nil || !h.mirrored {
            sol_canvas_fill_rect(canvas.raw, d.rounded(), layout.statusBar.y + 6 * scale, 1, layout.statusBar.height - 12 * scale, fg, 0.14)
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
            // Extensions, a puzzle piece, just left of it.
            let ext = extensionsSpot()
            if extensionsHovered { sol_canvas_fill_rounded(canvas.raw, ext.x, ext.y, ext.width, ext.height, 4 * scale, fg, 0.10) }
            icon(0xEA86, ext, pixels: 12 * scale, color: extensionsHovered ? TerminalPalette.accent : nil, alpha: extensionsHovered ? 1 : 0.75)
            if let themeIcon {
                // The flower is drawn a touch smaller, as its outline fills its square.
                let flower = themeIcon == .flower
                let side = ((flower ? 16 : 18) * scale).rounded()
                canvas.drawThemeIcon(themeIcon, UIRect(x: themeX - side - (flower ? 5 : 4) * scale, y: (bar.midY - side / 2).rounded(), width: side, height: side),
                                     scale: scale, time: iconTime, outline: true)
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
        // In the theme's text color, full strength (the picture's own lines are partly see-through, so less looks grey).
        canvas.drawArt("serverRack", UIRect(x: hosts.x + ((hosts.width - art) / 2).rounded(), y: (hosts.midY - art / 2 - 0.5 * scale).rounded() + 1, width: art, height: art),
                       scale: scale, alpha: 1, tint: fg)
        if layout.hasShellButton {
            // The shells: a terminal in outline, drawn as the icons beside it are (and as the Mac's console button).
            let b = layout.shellButton
            if hovered == .shell { sol_canvas_fill_rounded(canvas.raw, b.x, b.y, b.width, b.height, 4 * scale, fg, 0.10) }
            EditorStrip.drawTerminalSymbol(on: canvas, centerX: b.x + b.width / 2, centerY: b.midY, scale: scale, color: fg, alpha: 0.75, thin: true)
        }
        // Keep Awake's cup: in the accent color while it's on, grey while it's off.
        let cup = layout.keepAwakeButton
        if hovered == .keepAwake { sol_canvas_fill_rounded(canvas.raw, cup.x, cup.y, cup.width, cup.height, 4 * scale, fg, 0.10) }
        let on = keepAwakeLeft != nil
        Self.drawCup(on: canvas, in: cup, scale: scale, color: on ? TerminalPalette.accent : fg,
                     alpha: on ? 1 : hovered == .keepAwake ? 0.7 : 0.45, steam: on ? (steamTime ?? 0) : nil)

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
