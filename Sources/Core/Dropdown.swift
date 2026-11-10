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
    /// Picking it puts text in the search box instead of running anything ("New Connection…" puts "ssh ").
    var fillsSearch: Bool { get }
}

extension DropdownRow {
    var fillsSearch: Bool { false }
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

    /// What a search box with `typed` in it shows: the rows and the one highlighted. `prefix` ("ssh ") is left out of
    /// the search; `made` are rows made from what's typed (connecting to a host that isn't listed), and `separator` a
    /// line to put under them.
    /// - Nothing typed: everything, under any made rows.
    /// - Only the prefix: the same, less the rows that fill the search box, with nothing highlighted, so Enter doesn't
    ///   pick the first host by surprise.
    /// - Otherwise: the matching items (none that fill the search), then the made rows.
    static func shown<Row: DropdownRow>(_ all: [Row], typed: String, prefix: String? = nil, made: [Row] = [], separator: Row) -> (rows: [Row], highlight: Int?) {
        var q = typed.trimmingCharacters(in: .whitespaces).lowercased()
        if let p = prefix?.lowercased() {
            let bare = p.trimmingCharacters(in: .whitespaces)
            if q == bare { q = "" } else if q.hasPrefix(p) { q = q.dropFirst(p.count).trimmingCharacters(in: .whitespaces) }
        }
        let onlyPrefix = q.isEmpty && !typed.trimmingCharacters(in: .whitespaces).isEmpty
        let rows: [Row]
        if q.isEmpty {
            let rest = onlyPrefix ? Array(all.drop { $0.fillsSearch || $0.dropdownKind == .separator }) : all
            rows = made + (made.isEmpty ? [] : [separator]) + rest
        } else {
            rows = filter(all.filter { !$0.fillsSearch }, query: q) + made
        }
        return (rows, onlyPrefix && made.isEmpty ? nil : firstPickable(rows, from: 0, by: 1))
    }

    /// The arrow keys: the next pickable row that way, staying put at either end, as a Mac menu does. With nothing
    /// highlighted yet, down starts at the top and up at the bottom.
    static func step<Row: DropdownRow>(_ rows: [Row], from highlighted: Int?, by d: Int) -> Int? {
        let start = (highlighted ?? (d > 0 ? -1 : rows.count)) + d
        return firstPickable(rows, from: start, by: d) ?? highlighted
    }
}

enum SSHTarget {
    /// What follows `ssh` in what was typed into the hosts dropdown, when it names a host to connect to: anything after
    /// "ssh ", or a bare "user@host". Nil for a search (a plain word) or for something that isn't an ssh argument list
    /// (it's run in a shell, so no ; | & $ ` < > or quotes).
    static func newTarget(_ typed: String) -> String? {
        var t = typed.trimmingCharacters(in: .whitespaces)
        let ssh = t.lowercased().hasPrefix("ssh ")
        if ssh { t = String(t.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
        guard !t.isEmpty, ssh || (t.contains("@") && !t.contains(" ")),
              !t.contains(where: { ";|&$`<>\\\"'\n(){}*?!#~".contains($0) }) else { return nil }
        // A host after the options: the last word, not an option or something like "user@".
        guard let host = t.split(separator: " ").last, !host.hasPrefix("-"), !host.hasSuffix("@"), !host.hasPrefix("@") else { return nil }
        return t
    }
}
