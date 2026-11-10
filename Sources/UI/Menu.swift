import Foundation

/// A row of a dropdown: a command, a heading over the ones after it, or a line between groups of them. Everything
/// but the title is optional, and every dropdown in the app draws the same way (MenuView).
struct MenuItem {
    var title = ""
    var isChecked = false
    var isEnabled = true
    var isSeparator = false
    /// A colored dot before the title, for a group's color (ringed when checked).
    var swatch: UInt32?
    /// A glyph (Segoe Fluent Icons) before the title, where a check would go.
    var icon: UInt16?
    /// A coding agent's mark there instead, as the Send to Chat menu shows.
    var agentMark: AgentKind?
    /// A tab group's chip before the title: its name on its color, as in the tab strip.
    var chip: (label: String, color: UInt32)?
    /// A small heading over the items after it ("ACTIVE CHATS").
    var isHeader = false
    /// Dim text after the title ("origin"); typing in the search box matches it too.
    var detail: String?
    /// A glyph at the right end.
    var trailingIcon: UInt16?
    /// Picking it puts this in the search box instead of running anything ("New Connection…" puts "ssh ").
    var fill: String?
    /// The keys that do the same, dim at the right, as the Mac's menus show them.
    var shortcut = ""
    var run: () -> Void = {}
    /// What it becomes while Alt is held, as the Mac's menus do with Option: another title and command.
    var alternate: (title: String, run: () -> Void)?

    static var separator: MenuItem { MenuItem(isEnabled: false, isSeparator: true) }
    static func header(_ title: String) -> MenuItem { MenuItem(title: title, isEnabled: false, isHeader: true) }
}

/// Filtering, the highlight and the arrows are Core's (Dropdown), shared with the Mac's ThemedDropdown.
extension MenuItem: DropdownRow {
    var dropdownKind: DropdownRowKind { isSeparator ? .separator : isHeader ? .header : .item }
    var fillsSearch: Bool { fill != nil }
}

/// A dropdown: what's in it, where it goes, what's highlighted, and (optionally) a search box at the top that narrows
/// it as you type. Solanum draws its own (MenuView), in the theme's colors.
final class MenuModel {
    /// Everything it was opened with; `items` is what the search leaves.
    let all: [MenuItem]
    private(set) var items: [MenuItem]
    private(set) var highlighted: Int?
    /// Alt is held: items with an alternate show and run that instead.
    var showsAlternates = false
    private(set) var scroll: Float = 0
    private(set) var frame: UIRect
    let scale: Float
    /// The search box's text and caret; nil for a dropdown without one.
    private(set) var search: TextFieldState?
    let placeholder: String
    /// Told which item is highlighted (nil for none), whenever that changes and when the menu closes: the Send to Chat
    /// menu marks the tab the highlighted chat is in.
    var onHighlight: ((Int?) -> Void)?
    /// Told when it closes, picked from or not (a button it opened from stops showing pressed).
    var onClose: (() -> Void)?
    /// Typed before what's searched for, and left out of the search ("ssh " in the hosts dropdown).
    var prefix: String?
    /// Rows made from what's typed, above the matches (connecting to a host that isn't listed).
    var extra: ((String) -> [MenuItem])?
    /// Opened upward: as the search narrows it, it keeps its bottom edge.
    private let above: Bool
    /// The tallest it may grow where it is.
    private let tallest: Float

    var rowHeight: Float { (28 * scale).rounded() }
    var headerHeight: Float { (26 * scale).rounded() }
    var separatorHeight: Float { (11 * scale).rounded() }
    var padding: Float { (6 * scale).rounded() }
    /// The search box's band at the top.
    var searchHeight: Float { search == nil ? 0 : (38 * scale).rounded() }
    /// Where the rows start, below the search box.
    var top: Float { searchHeight + padding }
    var searchBox: UIRect { UIRect(x: frame.x + 8 * scale, y: frame.y + 8 * scale, width: frame.width - 16 * scale, height: (28 * scale).rounded()) }

    /// Opens at `anchor`, downward or, for `above`, upward from it, kept inside the window, and scrolling if it's too
    /// tall. `searchPlaceholder`: a search box at the top that narrows it, saying that while empty; nil for none.
    init(items: [MenuItem], anchorX: Float, anchorY: Float, above: Bool, width: Float, window: UIRect, scale: Float,
         searchPlaceholder: String? = nil) {
        all = items
        self.items = items
        self.scale = scale
        self.above = above
        placeholder = searchPlaceholder ?? ""
        search = searchPlaceholder.map { _ in TextFieldState("") }
        let margin = 8 * scale
        let room = above ? anchorY - window.y - margin : window.maxY - anchorY - margin
        let w = min(width, window.width - margin * 2)
        let x = min(max(anchorX, window.x + margin), window.maxX - w - margin)
        frame = UIRect(x: x, y: anchorY, width: w, height: 0)
        tallest = max(room, (28 * scale).rounded() * 3)
        fit(anchorY: anchorY)
        // A dropdown to pick from opens on what's set now, as on the Mac.
        if search != nil, let i = Dropdown.initialHighlight(items) {
            highlighted = i
            reveal(i)
        }
    }

    /// The frame's height for what's showing, from `anchorY` down (or up).
    private func fit(anchorY: Float) {
        let h = min(top + contentHeight + padding, tallest)
        frame = UIRect(x: frame.x, y: above ? anchorY - h : anchorY, width: frame.width, height: h)
    }

    private func height(_ item: MenuItem) -> Float { item.isSeparator ? separatorHeight : item.isHeader ? headerHeight : rowHeight }

    /// With nothing left after searching, one row's room for "No matches".
    private var contentHeight: Float { items.isEmpty ? rowHeight : items.reduce(0) { $0 + height($1) } }
    var maxScroll: Float { max(contentHeight - (frame.height - top - padding), 0) }
    var scrolls: Bool { maxScroll > 0 }

    /// A row's rectangle, in the window, wherever the scroll has put it.
    func rect(_ i: Int) -> UIRect {
        var y = frame.y + top - scroll
        for k in 0..<min(i, items.count) { y += height(items[k]) }
        return UIRect(x: frame.x + padding, y: y, width: frame.width - padding * 2, height: items.indices.contains(i) ? height(items[i]) : rowHeight)
    }

    /// The item (not a heading or a line) at a point.
    func item(atX x: Float, y: Float) -> Int? {
        guard frame.contains(x, y), y >= frame.y + top else { return nil }
        return items.indices.first { items[$0].dropdownKind == .item && rect($0).contains(x, y) }
    }

    func title(_ i: Int) -> String { showsAlternates ? items[i].alternate?.title ?? items[i].title : items[i].title }
    func action(_ i: Int) -> () -> Void { showsAlternates ? items[i].alternate?.run ?? items[i].run : items[i].run }

    func highlight(_ i: Int?) {
        let next = i.flatMap { items.indices.contains($0) && Dropdown.isPickable(items[$0]) ? $0 : nil }
        guard next != highlighted else { return }
        highlighted = next
        onHighlight?(next)
    }

    /// The arrow keys: over headings, lines and what's off, stopping at either end.
    func moveHighlight(by delta: Int) {
        guard let next = Dropdown.step(items, from: highlighted, by: delta) else { return }
        if next != highlighted {
            highlighted = next
            onHighlight?(next)
        }
        reveal(next)
    }

    private func reveal(_ i: Int) {
        let r = rect(i), bottom = frame.maxY - padding
        if r.y < frame.y + top { scrollBy(r.y - frame.y - top) }
        if r.maxY > bottom { scrollBy(r.maxY - bottom) }
    }

    func scrollBy(_ delta: Float) { scroll = min(max(scroll + delta, 0), maxScroll) }

    // MARK: The search box

    /// Typed into the search box: the rows narrow to what matches, the first one highlighted.
    func type(_ text: String) { editSearch { $0.insert(text) } }
    func deleteBackward(word: Bool = false) { editSearch { $0.deleteBackward(word: word) } }
    func moveCaret(by delta: Int) { editSearch { $0.move(by: delta) } }
    /// A row that fills the search box was picked: its text goes there, caret at the end, and the list follows.
    func fillSearch(_ text: String) { editSearch { $0 = TextFieldState(text) } }

    private func editSearch(_ edit: (inout TextFieldState) -> Void) {
        guard var field = search else { return }
        let before = field.text
        edit(&field)
        search = field
        guard field.text != before else { return }
        let anchorY = above ? frame.maxY : frame.y
        // What's left and what's highlighted are Core's, as on the Mac.
        let shown = Dropdown.shown(all, typed: field.text, prefix: prefix, made: extra?(field.text) ?? [], separator: .separator)
        items = shown.rows
        scroll = 0
        fit(anchorY: anchorY)
        if shown.highlight != highlighted {
            highlighted = shown.highlight
            onHighlight?(shown.highlight)
        }
    }
}
