import Foundation

/// One row of the command palette.
struct PaletteItem {
    let title: String
    /// What it belongs to, shown dim on the right.
    var category = ""
    var shortcut = ""
    var isHeader = false
    var run: () -> Void = {}

    static func header(_ title: String) -> PaletteItem { PaletteItem(title: title, isHeader: true) }

    /// Tells a command from others of the same name, for remembering what was run.
    var recentKey: String { category + " › " + title }
}

/// What the palette knows, with nothing about drawing: the commands, what's typed, and what that leaves.
final class PaletteModel {
    static let maxRows = 10
    static let maxRecents = 5

    let items: [PaletteItem]
    private(set) var recents: [String]
    private(set) var query = ""
    /// In characters.
    private(set) var caret = 0
    private(set) var rows: [PaletteItem] = []
    private(set) var selected = 0
    private(set) var scrollTop = 0

    init(items: [PaletteItem], recents: [String] = []) {
        self.items = items
        self.recents = recents
        refilter()
    }

    var selectedItem: PaletteItem? { rows.indices.contains(selected) && !rows[selected].isHeader ? rows[selected] : nil }
    var visibleRowCount: Int { min(rows.count, Self.maxRows) }

    // MARK: Typing

    func insert(_ text: String) {
        let clean = text.filter { !$0.isNewline }
        var chars = Array(query)
        chars.insert(contentsOf: clean, at: caret)
        query = String(chars)
        caret += clean.count
        refilter()
    }

    func deleteBackward(word: Bool = false) {
        guard caret > 0 else { return }
        var chars = Array(query)
        var start = caret - 1
        if word {
            while start > 0, chars[start] == " " { start -= 1 }
            while start > 0, chars[start - 1] != " " { start -= 1 }
        }
        chars.removeSubrange(start..<caret)
        query = String(chars)
        caret = start
        refilter()
    }

    func deleteForward() {
        guard caret < query.count else { return }
        var chars = Array(query)
        chars.remove(at: caret)
        query = String(chars)
        refilter()
    }

    func moveCaret(by delta: Int) { caret = min(max(caret + delta, 0), query.count) }
    func moveCaret(to position: Int) { caret = min(max(position, 0), query.count) }
    var textBeforeCaret: String { String(query.prefix(caret)) }

    // MARK: Moving through the list

    /// Steps over headers, and stays put past either end.
    func moveSelection(by delta: Int) {
        var next = selected + delta
        let step = delta < 0 ? -1 : 1
        while rows.indices.contains(next), rows[next].isHeader { next += step }
        guard rows.indices.contains(next) else {
            // A page past the end lands on the last or first row there is, rather than nowhere.
            if abs(delta) > 1 { select(delta < 0 ? firstSelectable : lastSelectable) }
            return
        }
        select(next)
    }

    func select(_ row: Int) {
        guard rows.indices.contains(row), !rows[row].isHeader else { return }
        selected = row
        if selected < scrollTop { scrollTop = selected }
        if selected >= scrollTop + Self.maxRows { scrollTop = selected - Self.maxRows + 1 }
        // A header just above the first row is worth showing with it.
        if scrollTop > 0, selected == scrollTop, rows[scrollTop - 1].isHeader { scrollTop -= 1 }
    }

    func scroll(by delta: Int) {
        scrollTop = min(max(scrollTop + delta, 0), max(rows.count - Self.maxRows, 0))
    }

    private var firstSelectable: Int { rows.firstIndex { !$0.isHeader } ?? 0 }
    private var lastSelectable: Int { rows.lastIndex { !$0.isHeader } ?? 0 }

    /// Records the selected command as the most recent. The list to keep is `recents`.
    func noteRun(_ item: PaletteItem) {
        recents.removeAll { $0 == item.recentKey }
        recents.insert(item.recentKey, at: 0)
        if recents.count > Self.maxRecents { recents.removeLast(recents.count - Self.maxRecents) }
    }

    // MARK: Filtering

    private func refilter() {
        let needle = Array(query.lowercased().filter { $0 != " " })
        if needle.isEmpty {
            // The last few run go on top, then everything.
            let known = recents.compactMap { key in items.first { $0.recentKey == key } }
            rows = known.isEmpty ? items : [.header("Recently used")] + known + [.header("All commands")] + items
        } else {
            let scored = items.enumerated().compactMap { index, item -> (item: PaletteItem, score: Int, index: Int)? in
                let inTitle = Self.score(needle, item.title)
                let inBoth = Self.score(needle, item.category + " " + item.title)
                guard let best = [inTitle.map { $0 + 8 }, inBoth].compactMap({ $0 }).max() else { return nil }
                return (item, best, index)
            }
            rows = scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }.map(\.item)
        }
        scrollTop = 0
        selected = firstSelectable
        select(selected)
    }

    /// Fuzzy matching, as on the Mac: the query's characters in order, with points for runs of them and for word starts.
    static func score(_ query: [Character], _ text: String) -> Int? {
        let t = Array(text.lowercased())
        var ti = 0, total = 0, prev = -2
        for qc in query {
            var found = false
            while ti < t.count {
                if t[ti] == qc {
                    var s = 1
                    if ti == prev + 1 { s += 6 }
                    if ti == 0 || " ›:-/".contains(t[ti - 1]) { s += 8 }
                    total += s
                    prev = ti
                    ti += 1
                    found = true
                    break
                }
                ti += 1
            }
            if !found { return nil }
        }
        return total * 4 - t.count
    }
}

/// Where the palette goes in a window: centered at its full height, and staying there as it shrinks while typing, so the
/// field doesn't move.
struct PaletteLayout {
    let windowWidth: Float, windowHeight: Float, scale: Float, rowCount: Int

    var rowHeight: Float { (34 * scale).rounded() }
    private var fieldHeight: Float { (52 * scale).rounded() }
    private var bottom: Float { (12 * scale).rounded() }

    var panel: UIRect {
        let width = min((620 * scale).rounded(), windowWidth - 24 * scale)
        let full = fieldHeight + Float(PaletteModel.maxRows) * rowHeight + bottom
        let top = max(12 * scale, ((windowHeight - full) / 2).rounded())
        let height = fieldHeight + Float(min(max(rowCount, 1), PaletteModel.maxRows)) * rowHeight + bottom
        return UIRect(x: ((windowWidth - width) / 2).rounded(), y: top, width: width, height: height)
    }

    var field: UIRect {
        let p = panel, inset = (42 * scale).rounded()
        return UIRect(x: p.x + inset, y: p.y, width: p.width - inset - 16 * scale, height: fieldHeight)
    }
    var icon: UIRect { UIRect(x: panel.x + 14 * scale, y: panel.y, width: 20 * scale, height: fieldHeight) }
    var dividerY: Float { panel.y + fieldHeight - 1 }

    /// A row on screen, counted from the first one showing.
    func row(_ visible: Int) -> UIRect {
        let inset = (6 * scale).rounded()
        return UIRect(x: panel.x + inset, y: panel.y + fieldHeight + (4 * scale).rounded() + Float(visible) * rowHeight,
                      width: panel.width - inset * 2, height: rowHeight)
    }

    /// The row at a point, counted from the first one showing.
    func visibleRow(atX x: Float, y: Float) -> Int? {
        for i in 0..<min(rowCount, PaletteModel.maxRows) where row(i).contains(x, y) { return i }
        return nil
    }
}
