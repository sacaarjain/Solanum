import Foundation

/// A row of a pop-up menu: a command, or a line between groups of them.
struct MenuItem {
    var title = ""
    var isChecked = false
    var isEnabled = true
    var isSeparator = false
    /// A colored dot before the title, for a group's color.
    var swatch: UInt32?
    /// A glyph (Segoe Fluent Icons) before the title, where a check would go.
    var icon: UInt16?
    /// The keys that do the same, dim at the right, as the Mac's menus show them.
    var shortcut = ""
    var run: () -> Void = {}
    /// What it becomes while Alt is held, as the Mac's menus do with Option: another title and command.
    var alternate: (title: String, run: () -> Void)?

    static var separator: MenuItem { MenuItem(isEnabled: false, isSeparator: true) }
}

/// A pop-up menu: what's in it, where it goes, and what's highlighted. Solanum draws its own, in the theme's colors.
final class MenuModel {
    let items: [MenuItem]
    private(set) var highlighted: Int?
    /// Alt is held: items with an alternate show and run that instead.
    var showsAlternates = false
    private(set) var scroll: Float = 0
    let frame: UIRect
    let scale: Float

    var rowHeight: Float { (28 * scale).rounded() }
    var separatorHeight: Float { (9 * scale).rounded() }
    var padding: Float { (4 * scale).rounded() }

    /// Opens at `anchor`, downward or, for `above`, upward from it, kept inside the window, and scrolling if it's too tall.
    init(items: [MenuItem], anchorX: Float, anchorY: Float, above: Bool, width: Float, window: UIRect, scale: Float) {
        self.items = items
        self.scale = scale
        let rows = (28 * scale).rounded(), line = (9 * scale).rounded(), pad = (4 * scale).rounded()
        let full = items.reduce(pad * 2) { $0 + ($1.isSeparator ? line : rows) }
        let margin = 8 * scale
        let room = above ? anchorY - window.y - margin : window.maxY - anchorY - margin
        let height = min(full, max(room, rows * 3))
        let w = min(width, window.width - margin * 2)
        let x = min(max(anchorX, window.x + margin), window.maxX - w - margin)
        frame = UIRect(x: x, y: above ? anchorY - height : anchorY, width: w, height: height)
    }

    private var contentHeight: Float { items.reduce(padding * 2) { $0 + ($1.isSeparator ? separatorHeight : rowHeight) } }
    var maxScroll: Float { max(contentHeight - frame.height, 0) }
    var scrolls: Bool { maxScroll > 0 }

    /// A row's rectangle, in the window, wherever the scroll has put it.
    func rect(_ i: Int) -> UIRect {
        var y = frame.y + padding - scroll
        for k in 0..<i { y += items[k].isSeparator ? separatorHeight : rowHeight }
        return UIRect(x: frame.x + padding, y: y, width: frame.width - padding * 2, height: items[i].isSeparator ? separatorHeight : rowHeight)
    }

    func item(atX x: Float, y: Float) -> Int? {
        guard frame.contains(x, y) else { return nil }
        return items.indices.first { !items[$0].isSeparator && rect($0).contains(x, y) }
    }

    func title(_ i: Int) -> String { showsAlternates ? items[i].alternate?.title ?? items[i].title : items[i].title }
    func action(_ i: Int) -> () -> Void { showsAlternates ? items[i].alternate?.run ?? items[i].run : items[i].run }

    func highlight(_ i: Int?) { highlighted = i.flatMap { items.indices.contains($0) && items[$0].isEnabled ? $0 : nil } }

    /// Steps over separators and what's disabled, and stays put past either end.
    func moveHighlight(by delta: Int) {
        var next = highlighted.map { $0 + delta } ?? (delta > 0 ? 0 : items.count - 1)
        while items.indices.contains(next), !items[next].isEnabled { next += delta }
        guard items.indices.contains(next) else { return }
        highlighted = next
        let r = rect(next)
        if r.y < frame.y { scrollBy(r.y - frame.y - padding) }
        if r.maxY > frame.maxY { scrollBy(r.maxY - frame.maxY + padding) }
    }

    func scrollBy(_ delta: Float) { scroll = min(max(scroll + delta, 0), maxScroll) }
}
