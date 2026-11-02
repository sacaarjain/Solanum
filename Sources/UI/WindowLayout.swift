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
    case tab(Int), tabClose(Int), newTab, flower
    case minimize, maximize, close
    /// The empty part of the tab bar, which drags the window.
    case titleBar
    case statusBar, terminal
}

/// Where everything in a window goes: the tab bar along the top, with the window's buttons at its right end as Windows
/// has them, the status bar along the bottom, and the terminal between. Plain arithmetic, shared and testable.
struct WindowLayout {
    let width: Float, height: Float, scale: Float, tabCount: Int

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
    var newTab: UIRect {
        let side = (28 * scale).rounded()
        return UIRect(x: flower.x - side - (2 * scale).rounded(), y: ((tabBarHeight - side) / 2).rounded(), width: side, height: side)
    }

    /// Tabs share what's left, between these widths: past the narrowest, they stop fitting.
    var tabWidth: Float {
        guard tabCount > 0 else { return 0 }
        let room = newTab.x - (6 * scale).rounded() - tabsStart
        return max(min(room / Float(tabCount), 240 * scale), 72 * scale).rounded()
    }
    private var tabsStart: Float { (8 * scale).rounded() }

    func tab(_ i: Int) -> UIRect {
        let top = (5 * scale).rounded()
        return UIRect(x: tabsStart + Float(i) * tabWidth, y: top, width: tabWidth, height: tabBarHeight - top)
    }

    func tabClose(_ i: Int) -> UIRect {
        let r = tab(i), side = (18 * scale).rounded()
        return UIRect(x: r.maxX - side - (6 * scale).rounded(), y: (r.midY - side / 2).rounded(), width: side, height: side)
    }

    var statusBar: UIRect { UIRect(x: 0, y: height - statusBarHeight, width: width, height: statusBarHeight) }
    var terminal: UIRect { UIRect(x: 0, y: tabBarHeight, width: width, height: max(height - tabBarHeight - statusBarHeight, 0)) }

    func part(atX x: Float, y: Float) -> WindowPart {
        if statusBar.contains(x, y) { return .statusBar }
        guard y < tabBarHeight else { return .terminal }
        if close.contains(x, y) { return .close }
        if maximize.contains(x, y) { return .maximize }
        if minimize.contains(x, y) { return .minimize }
        if flower.contains(x, y) { return .flower }
        if newTab.contains(x, y) { return .newTab }
        for i in 0..<tabCount where tab(i).contains(x, y) {
            return tabClose(i).contains(x, y) ? .tabClose(i) : .tab(i)
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
