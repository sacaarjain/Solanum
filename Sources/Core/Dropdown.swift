import Foundation

// How a dropdown behaves, whatever draws it: the Mac's ThemedDropdown and the Windows build's menus both go through
// here, so typing narrows the same way, the same row starts highlighted, and the arrows step the same way on both.

/// A row of a dropdown, as far as its behavior goes.
protocol DropdownRow {
    var dropdownKind: DropdownRowKind { get }
    var title: String { get }
    /// Dim text after the title ("as sjain"); typing matches it too.
    var detail: String? { get }
    var isChecked: Bool { get }
    /// Shown but not pickable (dimmed).
    var isEnabled: Bool { get }
}

enum DropdownRowKind { case item, header, separator }

enum Dropdown {
    /// What's left showing for `query`: everything while it's empty; otherwise just the items whose title or detail
    /// holds it, ignoring case, with no headers or lines between (they only grouped the full list).
    static func filter<Row: DropdownRow>(_ rows: [Row], query: String) -> [Row] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return rows }
        return rows.filter { $0.dropdownKind == .item && ($0.title.lowercased().contains(q) || ($0.detail?.lowercased().contains(q) ?? false)) }
    }

    static func isPickable<Row: DropdownRow>(_ row: Row) -> Bool { row.dropdownKind == .item && row.isEnabled }

    /// The first pickable row from `start` going `by` (+1 down, -1 up), or nil past the end.
    static func firstPickable<Row: DropdownRow>(_ rows: [Row], from start: Int, by d: Int) -> Int? {
        var i = start
        while rows.indices.contains(i) {
            if isPickable(rows[i]) { return i }
            i += d
        }
        return nil
    }

    /// Where the highlight starts as it opens: on what's checked (what's set now), else the first pickable row.
    static func initialHighlight<Row: DropdownRow>(_ rows: [Row]) -> Int? {
        rows.indices.first { isPickable(rows[$0]) && rows[$0].isChecked } ?? firstPickable(rows, from: 0, by: 1)
    }

    /// The arrow keys: the next pickable row that way, staying put at either end, as a Mac menu does. With nothing
    /// highlighted yet, down starts at the top and up at the bottom.
    static func step<Row: DropdownRow>(_ rows: [Row], from highlighted: Int?, by d: Int) -> Int? {
        let start = (highlighted ?? (d > 0 ? -1 : rows.count)) + d
        return firstPickable(rows, from: start, by: d) ?? highlighted
    }
}
