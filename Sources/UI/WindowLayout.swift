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
    case minimize, maximize, close
    /// The empty part of the tab bar, which drags the window.
    case titleBar
    case statusBar, terminal
    case leftSidebar, rightSidebar, leftEdge, rightEdge, toggleLeft, toggleRight
}

/// Where everything in a window goes: the tab bar along the top, with the window's buttons at its right end as Windows
/// has them, the status bar along the bottom, and the terminal between. Plain arithmetic, shared and testable.
struct WindowLayout {
    let width: Float, height: Float, scale: Float, tabCount: Int
    /// How far the tabs are scrolled, when they don't all fit.
    var tabScroll: Float = 0
    /// How wide the sidebars are, 0 when hidden.
    var leftWidth: Float = 0
    var rightWidth: Float = 0
    /// The right sidebar belongs to a split window, as on the Mac: there's nothing to switch without one.
    var showsRightToggle = false

    var tabBarHeight: Float { (38 * scale).rounded() }
    var statusBarHeight: Float { (26 * scale).rounded() }
    private var captionWidth: Float { (46 * scale).rounded() }

    var close: UIRect { UIRect(x: width - captionWidth, y: 0, width: captionWidth, height: tabBarHeight) }
    var maximize: UIRect { UIRect(x: width - captionWidth * 2, y: 0, width: captionWidth, height: tabBarHeight) }
    var minimize: UIRect { UIRect(x: width - captionWidth * 3, y: 0, width: captionWidth, height: tabBarHeight) }
    var flower: UIRect {
        let side = (36 * scale).rounded()
        return UIRect(x: minimize.x - side, y: 0, width: side, height: tabBarHeight)
    }
    /// Right after the last tab, or pinned beside the flower when the tabs have to scroll.
    var newTab: UIRect {
        let x = overflows ? newTabLimit : tabsStart + Float(tabCount) * tabWidth + (6 * scale).rounded()
        return UIRect(x: x, y: (tabTop + (tabBarHeight - tabTop - newTabSide) / 2).rounded(), width: newTabSide, height: newTabSide)
    }
    private var newTabSide: Float { (28 * scale).rounded() }
    private var newTabLimit: Float { flower.x - newTabSide - (2 * scale).rounded() }
    private var tabTop: Float { (5 * scale).rounded() }
    /// Tabs start where the terminal does, so the active one opens onto it.
    private var tabsStart: Float { max((8 * scale).rounded(), leftWidth) }
    private var minTabWidth: Float { (120 * scale).rounded() }
    private var fittingTabWidth: Float { (newTabLimit - (6 * scale).rounded() - tabsStart) / Float(max(tabCount, 1)) }

    /// More tabs than fit at their narrowest: they scroll between two arrows, as on the Mac.
    var overflows: Bool { tabCount > 0 && fittingTabWidth < minTabWidth }

    var tabWidth: Float {
        guard tabCount > 0 else { return 0 }
        return overflows ? minTabWidth : min(fittingTabWidth, 230 * scale).rounded()
    }

    private var arrowWidth: Float { (22 * scale).rounded() }
    var scrollLeft: UIRect { UIRect(x: tabsStart, y: tabTop, width: arrowWidth, height: tabBarHeight - tabTop) }
    var scrollRight: UIRect { UIRect(x: newTabLimit - (6 * scale).rounded() - arrowWidth, y: tabTop, width: arrowWidth, height: tabBarHeight - tabTop) }

    /// The stretch of the bar tabs are drawn in, and can be clicked in.
    var tabViewport: UIRect {
        guard overflows else { return UIRect(x: tabsStart, y: 0, width: newTabLimit - tabsStart, height: tabBarHeight) }
        let x = scrollLeft.maxX + (2 * scale).rounded()
        return UIRect(x: x, y: 0, width: max(scrollRight.x - (2 * scale).rounded() - x, 0), height: tabBarHeight)
    }

    var maxTabScroll: Float { overflows ? max(Float(tabCount) * tabWidth - tabViewport.width, 0) : 0 }

    func tab(_ i: Int) -> UIRect {
        let start = overflows ? tabViewport.x - tabScroll : tabsStart
        return UIRect(x: start + Float(i) * tabWidth, y: tabTop, width: tabWidth, height: tabBarHeight - tabTop)
    }

    func tabClose(_ i: Int) -> UIRect {
        let r = tab(i), side = (18 * scale).rounded()
        return UIRect(x: r.maxX - side - (6 * scale).rounded(), y: (r.midY - side / 2).rounded(), width: side, height: side)
    }

    /// The scroll that brings a tab fully into view, moving as little as possible.
    func scroll(showing i: Int) -> Float {
        let r = tab(i), v = tabViewport
        var target = tabScroll
        if r.x < v.x { target += r.x - v.x } else if r.maxX > v.maxX { target += r.maxX - v.maxX }
        return min(max(target, 0), maxTabScroll)
    }

    var statusBar: UIRect { UIRect(x: 0, y: height - statusBarHeight, width: width, height: statusBarHeight) }
    var terminal: UIRect {
        UIRect(x: leftWidth, y: tabBarHeight, width: max(width - leftWidth - rightWidth, 0), height: max(height - tabBarHeight - statusBarHeight, 0))
    }
    var leftSidebar: UIRect { UIRect(x: 0, y: tabBarHeight, width: leftWidth, height: terminal.height) }
    var rightSidebar: UIRect { UIRect(x: width - rightWidth, y: tabBarHeight, width: rightWidth, height: terminal.height) }
    private var toggleSide: Float { (22 * scale).rounded() }
    var toggleLeft: UIRect { UIRect(x: (8 * scale).rounded(), y: statusBar.y + 2 * scale, width: toggleSide, height: statusBarHeight - 4 * scale) }
    var toggleRight: UIRect { UIRect(x: width - toggleSide - (8 * scale).rounded(), y: statusBar.y + 2 * scale, width: toggleSide, height: statusBarHeight - 4 * scale) }

    func part(atX x: Float, y: Float) -> WindowPart {
        if statusBar.contains(x, y) {
            if toggleLeft.contains(x, y) { return .toggleLeft }
            if showsRightToggle && toggleRight.contains(x, y) { return .toggleRight }
            return .statusBar
        }
        guard y < tabBarHeight else {
            // A few pixels either side of each sidebar's border drag it.
            let grab = 3 * scale
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
        if newTab.contains(x, y) { return .newTab }
        if overflows {
            if scrollLeft.contains(x, y) { return .scrollLeft }
            if scrollRight.contains(x, y) { return .scrollRight }
        }
        if tabViewport.contains(x, y) {
            for i in 0..<tabCount where tab(i).contains(x, y) {
                return tabClose(i).contains(x, y) ? .tabClose(i) : .tab(i)
            }
        }
        return .titleBar
    }
}

enum WindowText {
    /// A folder as the status bar shows it: home as ~, and its parts for the breadcrumbs.
    static func crumbs(_ path: String, home: String?) -> [String] {
        var rest = path
        var parts: [String] = []
        if let home, !home.isEmpty, rest.lowercased() == home.lowercased() || rest.lowercased().hasPrefix(home.lowercased() + "\\") {
            parts.append("~")
            rest = String(rest.dropFirst(home.count))
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
            } else if i == 0 && label.hasSuffix(":") {
                current = label + "\\"
            } else {
                current = current.isEmpty ? label : WindowsPath.join(current, label)
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
