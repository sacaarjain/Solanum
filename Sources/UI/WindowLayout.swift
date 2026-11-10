import Foundation

/// A rectangle in pixels, with the origin at the top left.
struct UIRect: Equatable {
    var x: Float, y: Float, width: Float, height: Float
    var maxX: Float { x + width }
    var maxY: Float { y + height }
    var midY: Float { y + height / 2 }

    func contains(_ px: Float, _ py: Float) -> Bool { px >= x && px < maxX && py >= y && py < maxY }
}

/// What's at a point of the window.
enum WindowPart: Equatable {
    case tab(Int), tabClose(Int), newTab, flower, scrollLeft, scrollRight
    /// A group's chip, by the index of its first tab.
    case chip(Int)
    case minimize, maximize, close
    /// The empty part of the tab bar, which drags the window.
    case titleBar
    case statusBar, terminal
    case leftSidebar, rightSidebar, leftEdge, rightEdge, toggleLeft, toggleRight, hosts, shell, keepAwake
    /// The band between the two columns, which drags to resize them.
    case columnDivider
    /// While split: the right column's new tab button and scroll arrows, and the button that closes the split.
    case newTabRight, rightScrollLeft, rightScrollRight, closeSplit
}

/// Where everything in a window goes: the tab bar along the top, with the window's buttons at its right end as Windows
/// has them, the status bar along the bottom, and the terminal between. Split, there are two columns side by side, each
/// with its own strip of tabs above it, as on the Mac. Plain arithmetic, shared and testable.
struct WindowLayout {
    let width: Float, height: Float, scale: Float, tabCount: Int
    /// How far the tabs are scrolled, when they don't all fit (the left column's, when split).
    var tabScroll: Float = 0
    /// Group chips' widths, each by the index of the tab it comes before.
    var chips: [Int: Float] = [:]
    /// Tabs in collapsed groups, which take no room.
    var hiddenTabs: Set<Int> = []
    /// Tabs of a group opening or closing: how much of each shows (0 to 1), over what `hiddenTabs` says. They slide
    /// out of, or back into, the group's chip.
    var tabShown: [Int: Float] = [:]
    /// How wide the sidebars are, 0 when hidden.
    var leftWidth: Float = 0
    var rightWidth: Float = 0
    /// The right sidebar belongs to a split window, as on the Mac: there's nothing to switch without one.
    var showsRightToggle = false
    /// Split in two columns: how many of the tabs are the left column's. The rest are the right one's.
    var splitCount: Int?
    /// How far the right column's tabs are scrolled.
    var rightTabScroll: Float = 0
    /// The left column's share of the room, while split; dragging the band between them changes it, as on the Mac.
    var splitFraction: Float = 0.5

    var isSplit: Bool { splitCount != nil }
    var tabBarHeight: Float { (38 * scale).rounded() }
    var statusBarHeight: Float { (26 * scale).rounded() }
    private var captionWidth: Float { (46 * scale).rounded() }

    var close: UIRect { UIRect(x: width - captionWidth, y: 0, width: captionWidth, height: tabBarHeight) }
    var maximize: UIRect { UIRect(x: width - captionWidth * 2, y: 0, width: captionWidth, height: tabBarHeight) }
    var minimize: UIRect { UIRect(x: width - captionWidth * 3, y: 0, width: captionWidth, height: tabBarHeight) }
    /// The Settings flower, at the left end of the bar: over the sidebar when it's open, where nothing else is.
    var flower: UIRect {
        let side = (36 * scale).rounded()
        return UIRect(x: (4 * scale).rounded(), y: 0, width: side, height: tabBarHeight)
    }
    /// The band between the columns (and between a tab's pages and its terminal), with a grip, as on the Mac.
    var bandWidth: Float { (6 * scale).rounded() }
    /// Where the left column ends and the band between the columns starts: halfway across the room the sidebars leave,
    /// unless the band has been dragged.
    var divider: Float {
        let room = width - leftWidth - rightWidth - (isSplit ? bandWidth : 0)
        return leftWidth + (room * min(max(splitFraction, 0.2), 0.8)).rounded()
    }
    /// Where the right column starts, past the band.
    var rightColumnX: Float { divider + (isSplit ? bandWidth : 0) }
    /// The fraction that puts the band's middle at `x`.
    func splitFraction(atX x: Float) -> Float {
        let room = max(width - leftWidth - rightWidth - bandWidth, 1)
        return min(max((x - bandWidth / 2 - leftWidth) / room, 0.2), 0.8)
    }
    /// While split, the button that closes it, just before the window's buttons.
    var closeSplit: UIRect {
        let side = (24 * scale).rounded()
        return UIRect(x: minimize.x - side - (6 * scale).rounded(), y: (tabTop + (tabBarHeight - tabTop - side) / 2).rounded(), width: side, height: side)
    }

    private var newTabSide: Float { (28 * scale).rounded() }
    private var tabTop: Float { (5 * scale).rounded() }
    /// Tabs start where the terminal does, so the active one opens onto it, its outline on the sidebar's edge line (the
    /// last pixel of the sidebar); past the flower when the sidebar's closed.
    private var tabsStart: Float { max(flower.maxX + (4 * scale).rounded(), leftWidth - 1) }
    private var minTabWidth: Float { (120 * scale).rounded() }
    private var chipGap: Float { (6 * scale).rounded() }
    private var arrowWidth: Float { (22 * scale).rounded() }

    // MARK: Strips of tabs

    /// One column's tabs: which they are, where they may go, and their scroll.
    private struct Strip {
        let range: Range<Int>, start: Float, newTabLimit: Float, scroll: Float
    }

    private func strip(_ column: Int) -> Strip {
        guard let n = splitCount.map({ min(max($0, 0), tabCount) }) else {
            return Strip(range: 0..<tabCount, start: tabsStart, newTabLimit: minimize.x - newTabSide - (8 * scale).rounded(), scroll: tabScroll)
        }
        if column == 0 {
            return Strip(range: 0..<n, start: tabsStart, newTabLimit: divider - newTabSide - (6 * scale).rounded(), scroll: tabScroll)
        }
        // On the band's right-hand line (its last pixel), as the left column's tabs are on the sidebar's edge.
        return Strip(range: n..<tabCount, start: rightColumnX - 1, newTabLimit: closeSplit.x - newTabSide - (4 * scale).rounded(),
                     scroll: rightTabScroll)
    }

    /// Which column a tab is in: 0 unless it's split and the tab is the right one's.
    func column(ofTab i: Int) -> Int { splitCount.map { i >= $0 ? 1 : 0 } ?? 0 }

    /// How much of a tab shows: none in a collapsed group, all otherwise, or part of it while its group opens or closes.
    private func shown(_ i: Int) -> Float { tabShown[i] ?? (hiddenTabs.contains(i) ? 0 : 1) }
    /// How many tabs' worth show, counting part of one while it opens or closes.
    private func visibleCount(_ s: Strip) -> Float { s.range.reduce(0) { $0 + shown($1) } }
    /// A chip has a gap on both sides: from the tab before it, and to its own first tab.
    private func chipSpace(_ s: Strip) -> Float { chips.filter { s.range.contains($0.key) }.values.reduce(0) { $0 + $1 + chipGap * 2 } }
    private func fittingTabWidth(_ s: Strip) -> Float {
        (s.newTabLimit - (6 * scale).rounded() - s.start - chipSpace(s)) / max(visibleCount(s), 1)
    }
    private func overflows(_ s: Strip) -> Bool {
        guard !s.range.isEmpty else { return false }
        return visibleCount(s) > 0 ? fittingTabWidth(s) < minTabWidth : chipSpace(s) > s.newTabLimit - s.start
    }
    private func tabWidth(_ s: Strip) -> Float {
        guard !s.range.isEmpty else { return 0 }
        return overflows(s) ? minTabWidth : min(fittingTabWidth(s), 230 * scale).rounded()
    }
    /// Everything in the strip end to end: tabs and chips.
    private func contentWidth(_ s: Strip) -> Float { visibleCount(s) * tabWidth(s) + chipSpace(s) }
    private func scrollLeft(_ s: Strip) -> UIRect { UIRect(x: s.start, y: tabTop, width: arrowWidth, height: tabBarHeight - tabTop) }
    private func scrollRight(_ s: Strip) -> UIRect {
        UIRect(x: s.newTabLimit - (6 * scale).rounded() - arrowWidth, y: tabTop, width: arrowWidth, height: tabBarHeight - tabTop)
    }
    private func viewport(_ s: Strip) -> UIRect {
        guard overflows(s) else { return UIRect(x: s.start, y: 0, width: max(s.newTabLimit - s.start, 0), height: tabBarHeight) }
        let x = scrollLeft(s).maxX + (2 * scale).rounded()
        return UIRect(x: x, y: 0, width: max(scrollRight(s).x - (2 * scale).rounded() - x, 0), height: tabBarHeight)
    }
    private func maxScroll(_ s: Strip) -> Float { overflows(s) ? max(contentWidth(s) - viewport(s).width, 0) : 0 }
    private func newTab(_ s: Strip) -> UIRect {
        let x = overflows(s) ? s.newTabLimit : s.start + contentWidth(s) + (6 * scale).rounded()
        return UIRect(x: x, y: (tabTop + (tabBarHeight - tabTop - newTabSide) / 2).rounded(), width: newTabSide, height: newTabSide)
    }

    /// Right after the last tab, or pinned at the end of the strip when the tabs have to scroll.
    var newTab: UIRect { newTab(strip(0)) }
    var overflows: Bool { overflows(strip(0)) }
    var tabWidth: Float { tabWidth(strip(0)) }
    var scrollLeft: UIRect { scrollLeft(strip(0)) }
    var scrollRight: UIRect { scrollRight(strip(0)) }
    /// The stretch of the bar tabs are drawn in, and can be clicked in.
    var tabViewport: UIRect { viewport(strip(0)) }
    var maxTabScroll: Float { maxScroll(strip(0)) }

    func newTab(column: Int) -> UIRect { newTab(strip(column)) }
    func overflows(column: Int) -> Bool { overflows(strip(column)) }
    func tabWidth(column: Int) -> Float { tabWidth(strip(column)) }
    func scrollLeft(column: Int) -> UIRect { scrollLeft(strip(column)) }
    func scrollRight(column: Int) -> UIRect { scrollRight(strip(column)) }
    func tabViewport(column: Int) -> UIRect { viewport(strip(column)) }
    func maxTabScroll(column: Int) -> Float { maxScroll(strip(column)) }
    /// The tabs of a column.
    func tabRange(column: Int) -> Range<Int> { strip(column).range }

    /// Where tab `i` starts: past the tabs and chips before it in its strip, and its own chip.
    private func start(of i: Int) -> Float {
        let s = strip(column(ofTab: i)), w = tabWidth(s)
        var x = overflows(s) ? viewport(s).x - s.scroll : s.start
        for k in s.range.lowerBound..<max(i, s.range.lowerBound) {
            if let chip = chips[k] { x += chipGap + chip + chipGap }
            x += w * shown(k)
        }
        if let chip = chips[i] { x += chipGap + chip + chipGap }
        return x
    }

    /// A tab, or an empty rectangle where a collapsed one would be.
    func tab(_ i: Int) -> UIRect {
        UIRect(x: start(of: i), y: tabTop, width: (tabWidth(strip(column(ofTab: i))) * shown(i)).rounded(), height: tabBarHeight - tabTop)
    }

    /// The chip of the group starting at tab `i`.
    func chip(_ i: Int) -> UIRect? {
        guard let width = chips[i] else { return nil }
        let height = (20 * scale).rounded(), mid = tabTop + (tabBarHeight - tabTop) / 2
        return UIRect(x: start(of: i) - width - chipGap, y: (mid - height / 2).rounded(), width: width, height: height)
    }

    func tabClose(_ i: Int) -> UIRect {
        let r = tab(i), side = (18 * scale).rounded()
        return UIRect(x: r.maxX - side - (6 * scale).rounded(), y: (r.midY - side / 2).rounded(), width: side, height: side)
    }

    /// The scroll of tab `i`'s strip that brings it fully into view, moving as little as possible.
    func scroll(showing i: Int) -> Float {
        let s = strip(column(ofTab: i)), r = tab(i), v = viewport(s)
        var target = s.scroll
        if r.x < v.x { target += r.x - v.x } else if r.maxX > v.maxX { target += r.maxX - v.maxX }
        return min(max(target, 0), maxScroll(s))
    }

    var statusBar: UIRect { UIRect(x: 0, y: height - statusBarHeight, width: width, height: statusBarHeight) }
    /// The terminal, or the left column's when split.
    var terminal: UIRect {
        let right = isSplit ? divider : width - rightWidth
        return UIRect(x: leftWidth, y: tabBarHeight, width: max(right - leftWidth, 0), height: max(height - tabBarHeight - statusBarHeight, 0))
    }
    /// The right column's terminal, while split.
    var rightTerminal: UIRect {
        UIRect(x: rightColumnX, y: tabBarHeight, width: max(width - rightWidth - rightColumnX, 0), height: terminal.height)
    }
    /// The band between the columns, while split.
    var columnBand: UIRect? { isSplit ? UIRect(x: divider, y: tabBarHeight, width: bandWidth, height: terminal.height) : nil }
    var leftSidebar: UIRect { UIRect(x: 0, y: tabBarHeight, width: leftWidth, height: terminal.height) }
    var rightSidebar: UIRect { UIRect(x: width - rightWidth, y: tabBarHeight, width: rightWidth, height: terminal.height) }
    private var toggleSide: Float { (22 * scale).rounded() }
    var toggleLeft: UIRect { UIRect(x: (8 * scale).rounded(), y: statusBar.y + 2 * scale, width: toggleSide, height: statusBarHeight - 4 * scale) }
    /// The ssh hosts button, beside the left sidebar's switch, as on the Mac.
    var hostsButton: UIRect { UIRect(x: toggleLeft.maxX + (2 * scale).rounded(), y: toggleLeft.y, width: toggleSide, height: toggleLeft.height) }
    /// Windows only: the tab's shell, beside the ssh hosts button (see Shells). Zero wide where there's none.
    var hasShellButton = false
    var shellButton: UIRect {
        UIRect(x: hostsButton.maxX + (2 * scale).rounded(), y: toggleLeft.y, width: hasShellButton ? toggleSide : 0, height: toggleLeft.height)
    }
    /// Windows only: Keep Awake's cup, after the shell's button (the hosts button's, where there's none).
    var keepAwakeButton: UIRect {
        let b = hasShellButton ? shellButton : hostsButton
        return UIRect(x: b.maxX + (2 * scale).rounded(), y: toggleLeft.y, width: toggleSide, height: toggleLeft.height)
    }
    var toggleRight: UIRect { UIRect(x: width - toggleSide - (8 * scale).rounded(), y: statusBar.y + 2 * scale, width: toggleSide, height: statusBarHeight - 4 * scale) }

    func part(atX x: Float, y: Float) -> WindowPart {
        if statusBar.contains(x, y) {
            if toggleLeft.contains(x, y) { return .toggleLeft }
            if hostsButton.contains(x, y) { return .hosts }
            if hasShellButton && shellButton.contains(x, y) { return .shell }
            if keepAwakeButton.contains(x, y) { return .keepAwake }
            if showsRightToggle && toggleRight.contains(x, y) { return .toggleRight }
            return .statusBar
        }
        guard y < tabBarHeight else {
            // A few pixels either side of each sidebar's border drag it.
            let grab = 3 * scale
            if let band = columnBand, x >= band.x - grab, x < band.maxX + grab { return .columnDivider }
            if leftWidth > 0 && abs(x - leftWidth) <= grab { return .leftEdge }
            if rightWidth > 0 && abs(x - (width - rightWidth)) <= grab { return .rightEdge }
            if leftWidth > 0 && x < leftWidth { return .leftSidebar }
            if rightWidth > 0 && x >= width - rightWidth { return .rightSidebar }
            return .terminal
        }
        if close.contains(x, y) { return .close }
        if maximize.contains(x, y) { return .maximize }
        if minimize.contains(x, y) { return .minimize }
        if flower.contains(x, y) { return .flower }
        if isSplit {
            if closeSplit.contains(x, y) { return .closeSplit }
            if newTab(column: 1).contains(x, y) { return .newTabRight }
            if overflows(column: 1) {
                if scrollLeft(column: 1).contains(x, y) { return .rightScrollLeft }
                if scrollRight(column: 1).contains(x, y) { return .rightScrollRight }
            }
            if let hit = tabPart(column: 1, x, y) { return hit }
        }
        if newTab.contains(x, y) { return .newTab }
        if overflows {
            if scrollLeft.contains(x, y) { return .scrollLeft }
            if scrollRight.contains(x, y) { return .scrollRight }
        }
        return tabPart(column: 0, x, y) ?? .titleBar
    }

    private func tabPart(column: Int, _ x: Float, _ y: Float) -> WindowPart? {
        let s = strip(column)
        guard viewport(s).contains(x, y) else { return nil }
        for i in chips.keys.sorted() where s.range.contains(i) && chip(i)?.contains(x, y) == true { return .chip(i) }
        for i in s.range where tab(i).contains(x, y) {
            return tabClose(i).contains(x, y) ? .tabClose(i) : .tab(i)
        }
        return nil
    }
}

enum WindowText {
    /// A folder as the status bar shows it: home as ~, and its parts for the breadcrumbs.
    static func crumbs(_ path: String, home: String?) -> [String] {
        var rest = path
        var parts: [String] = []
        let unix = AnyPath.isUnix(path)
        let separator = unix ? "/" : "\\"
        // Unix paths are case-sensitive; Windows ones aren't.
        let (r, h) = unix ? (rest, home ?? "") : (rest.lowercased(), home?.lowercased() ?? "")
        if !h.isEmpty, r == h || r.hasPrefix(h + separator) {
            parts.append("~")
            rest = String(rest.dropFirst(h.count))
        } else if unix {
            parts.append("/")
        }
        parts += rest.split(whereSeparator: { $0 == "\\" || $0 == "/" }).map(String.init)
        return parts
    }

    /// The same parts, each with the folder it stands for, for going to them.
    static func crumbPaths(_ path: String, home: String?) -> [(label: String, path: String)] {
        var out: [(label: String, path: String)] = []
        let labels = crumbs(path, home: home)
        var current = ""
        for (i, label) in labels.enumerated() {
            if i == 0 && label == "~", let home {
                current = home
            } else if i == 0 && label == "/" {
                current = "/"
            } else if i == 0 && label.hasSuffix(":") {
                current = label + "\\"
            } else {
                current = current.isEmpty ? label : AnyPath.join(current, label)
            }
            out.append((label, current))
        }
        return out
    }

    /// What a tab is called: the program's title, unless that's just the path of the shell itself, which is what
    /// consoles set by default. Then the folder it's in.
    static func tabTitle(title: String?, folder: String?, home: String?) -> String {
        if let title, !title.isEmpty, !isExecutablePath(title) { return title }
        guard let folder else { return "Terminal" }
        return crumbs(folder, home: home).last ?? folder
    }

    private static func isExecutablePath(_ title: String) -> Bool {
        let t = title.lowercased()
        let name = t.hasPrefix("administrator: ") ? String(t.dropFirst("administrator: ".count)) : t
        return name.hasSuffix(".exe") && (name.contains("\\") || name.contains("/"))
    }
}
