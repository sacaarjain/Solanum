import Foundation

struct FileEntry: Equatable {
    let name: String
    let path: String
    let isDirectory: Bool
    /// Hidden by the file system, or named with a leading dot.
    let isHidden: Bool
}

enum WindowsPath {
    static func join(_ folder: String, _ name: String) -> String {
        folder.hasSuffix("\\") ? folder + name : folder + "\\" + name
    }

    /// The folder holding this one, or nil at the top of a drive.
    static func parent(_ path: String) -> String? {
        let trimmed = path.count > 3 && path.hasSuffix("\\") ? String(path.dropLast()) : path
        guard let slash = trimmed.lastIndex(of: "\\") else { return nil }
        let up = String(trimmed[..<slash])
        if up.isEmpty { return nil }
        if up.hasSuffix(":") { return trimmed.count > up.count + 1 ? up + "\\" : nil }
        return up
    }

    static func name(_ path: String) -> String {
        let trimmed = path.count > 3 && path.hasSuffix("\\") ? String(path.dropLast()) : path
        return trimmed.split(separator: "\\").last.map(String.init) ?? path
    }
}

/// What a file tree shows, with nothing about drawing or the disk: which folders are open and what's in them. Whoever
/// owns it lists a folder when `onNeedsListing` asks and hands back the result with `receive`.
final class FileTree {
    struct Row: Equatable {
        let entry: FileEntry
        let depth: Int
    }

    private(set) var root: String?
    private(set) var expanded: Set<String> = []
    private var listings: [String: [FileEntry]] = [:]
    private(set) var failed: Set<String> = []
    private(set) var rows: [Row] = []
    var showHidden = false { didSet { rebuild() } }
    var selection: String?
    var scrollTop = 0
    var onNeedsListing: ((String) -> Void)?

    var isLoadingRoot: Bool { root.map { listings[$0] == nil && !failed.contains($0) } ?? false }
    var rootFailed: Bool { root.map { failed.contains($0) } ?? false }
    /// Every folder on show, for looking again at what's changed.
    var listedFolders: [String] { (root.map { [$0] } ?? []) + expanded.sorted().filter { listings[$0] != nil } }

    func setRoot(_ path: String) {
        guard path != root else { return }
        root = path
        scrollTop = 0
        selection = nil
        rebuild()
        onNeedsListing?(path)
        for folder in expanded where isUnder(folder, path) { onNeedsListing?(folder) }
    }

    private func isUnder(_ path: String, _ folder: String) -> Bool {
        path.lowercased().hasPrefix((folder.hasSuffix("\\") ? folder : folder + "\\").lowercased())
    }

    /// Where a tree is, which each tab keeps for itself: the folder shown, what's open in it and what's selected.
    struct Place {
        var root: String?
        var expanded: Set<String> = []
        var selection: String?
        var scrollTop = 0
    }

    var place: Place { Place(root: root, expanded: expanded, selection: selection, scrollTop: scrollTop) }

    func restore(_ place: Place) {
        expanded = place.expanded
        if let folder = place.root, folder != root {
            root = folder
            rebuild()
            onNeedsListing?(folder)
        } else {
            rebuild()
        }
        for folder in expanded where listings[folder] == nil { onNeedsListing?(folder) }
        selection = place.selection
        scrollTop = place.scrollTop
    }

    /// True if what's listed has changed.
    @discardableResult
    func receive(_ path: String, _ entries: [FileEntry]?) -> Bool {
        if let entries {
            let sorted = Self.sortedForDisplay(entries)
            let wasFailed = failed.remove(path) != nil
            if !wasFailed && listings[path] == sorted { return false }
            listings[path] = sorted
        } else {
            let known = listings.removeValue(forKey: path) != nil
            if failed.insert(path).inserted == false && !known { return false }
        }
        rebuild()
        return true
    }

    func isExpanded(_ path: String) -> Bool { expanded.contains(path) }

    func toggle(_ path: String) {
        if expanded.remove(path) == nil {
            expanded.insert(path)
            if listings[path] == nil { onNeedsListing?(path) }
        }
        rebuild()
    }

    func collapseAll() {
        expanded = []
        rebuild()
    }

    func refresh() { listedFolders.forEach { onNeedsListing?($0) } }

    /// Folders first, then a name's dot doesn't count against it until last, in the order people read numbers.
    static func sortedForDisplay(_ items: [FileEntry]) -> [FileEntry] {
        items.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            let dotA = $0.name.hasPrefix("."), dotB = $1.name.hasPrefix(".")
            if dotA != dotB { return dotB }
            return $0.name.compare($1.name, options: [.caseInsensitive, .numeric]) == .orderedAscending
        }
    }

    private func rebuild() {
        rows = []
        guard let root else { return }
        func add(_ folder: String, depth: Int) {
            for entry in listings[folder] ?? [] where showHidden || !entry.isHidden {
                rows.append(Row(entry: entry, depth: depth))
                if entry.isDirectory && expanded.contains(entry.path) { add(entry.path, depth: depth + 1) }
            }
        }
        add(root, depth: 0)
        scrollTop = min(scrollTop, max(rows.count - 1, 0))
    }

    // MARK: Keyboard

    var selectedIndex: Int? { selection.flatMap { s in rows.firstIndex { $0.entry.path == s } } }

    func moveSelection(by delta: Int) {
        guard !rows.isEmpty else { return }
        let next = selectedIndex.map { $0 + delta } ?? (delta > 0 ? 0 : rows.count - 1)
        selection = rows[min(max(next, 0), rows.count - 1)].entry.path
    }

    /// Right opens a folder, or else steps into it.
    func stepIn() {
        guard let i = selectedIndex, rows[i].entry.isDirectory else { return }
        if !expanded.contains(rows[i].entry.path) { toggle(rows[i].entry.path) } else { moveSelection(by: 1) }
    }

    /// Left closes a folder, or else steps out to the one holding it.
    func stepOut() {
        guard let i = selectedIndex else { return }
        let entry = rows[i].entry
        if entry.isDirectory && expanded.contains(entry.path) {
            toggle(entry.path)
        } else if let parent = WindowsPath.parent(entry.path), rows.contains(where: { $0.entry.path == parent }) {
            selection = parent
        }
    }

    /// Scrolls just enough to show the selected row.
    func keepSelectionVisible(rowsShowing: Int) {
        guard let i = selectedIndex, rowsShowing > 0 else { return }
        if i < scrollTop { scrollTop = i }
        if i >= scrollTop + rowsShowing { scrollTop = i - rowsShowing + 1 }
    }

    func scroll(by delta: Int, rowsShowing: Int) {
        scrollTop = min(max(scrollTop + delta, 0), max(rows.count - rowsShowing, 0))
    }
}

/// Where a sidebar's parts go inside its area.
struct SidebarLayout {
    let area: UIRect, scale: Float

    var title: UIRect { UIRect(x: area.x + 12 * scale, y: area.y + 6 * scale, width: area.width - 24 * scale, height: 22 * scale) }
    var buttonsY: Float { title.maxY + 2 * scale }
    private var buttonSide: Float { (24 * scale).rounded() }
    func button(_ i: Int) -> UIRect { UIRect(x: area.x + 8 * scale + Float(i) * (buttonSide + 2 * scale), y: buttonsY, width: buttonSide, height: buttonSide) }
    var subtitle: UIRect { UIRect(x: area.x + 12 * scale, y: buttonsY + buttonSide + 2 * scale, width: area.width - 24 * scale, height: 18 * scale) }
    var list: UIRect {
        let top = subtitle.maxY + 2 * scale
        return UIRect(x: area.x, y: top, width: area.width, height: max(area.maxY - top, 0))
    }
    var rowHeight: Float { (22 * scale).rounded() }
    var rowsShowing: Int { Int(list.height / rowHeight) }
    func row(_ visible: Int) -> UIRect { UIRect(x: list.x, y: list.y + Float(visible) * rowHeight, width: list.width, height: rowHeight) }
    func visibleRow(atY y: Float) -> Int? {
        guard y >= list.y, y < list.maxY else { return nil }
        return Int((y - list.y) / rowHeight)
    }
    func indent(_ depth: Int) -> Float { (8 + Float(depth) * 14) * scale }
    func chevron(depth: Int, row: UIRect) -> UIRect { UIRect(x: row.x + indent(depth), y: row.y, width: 16 * scale, height: row.height) }
}
