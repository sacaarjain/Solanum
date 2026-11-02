import CCanvas
import Foundation
import WinSDK

/// The buttons along the top of a sidebar, in order. Each has its icon and what it says when hovered.
enum SidebarButton: Int, CaseIterable {
    case pin, parent, refresh, more

    var glyph: UInt16 {
        switch self {
        case .pin: return 0xE718
        case .parent: return 0xE74A
        case .refresh: return 0xE72C
        case .more: return 0xE712
        }
    }
}

/// What a tab remembers about the left sidebar, as on the Mac: a pin in one tab says nothing about the others.
struct SidebarPlace {
    var tree = FileTree.Place()
    var pinned: String?
    var followed: String?
}

/// A file sidebar: one tree, and where it is. There are two, on the left and right of a window.
final class FileSidebar {
    let tree = FileTree()
    var isVisible: Bool
    var width: Float
    /// The folder it stays on, instead of following the terminal.
    var pinned: String?
    /// The terminal folder last followed. It only moves when that changes, so browsing elsewhere stays put until then.
    var followed: String?
    var isFocused = false
    var hoveredRow: Int?
    var hoveredButton: SidebarButton?

    /// How much of it is showing, from 0 to 1, while it slides in or out.
    var shown: Float

    init(visible: Bool, width: Float) {
        isVisible = visible
        self.width = width
        shown = visible ? 1 : 0
    }

    /// Lists a folder off the message loop, since a slow or disconnected drive can take a long time to answer.
    static func list(_ folder: String) -> [FileEntry]? {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: folder) else { return nil }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey]
        return names.compactMap { name in
            let path = WindowsPath.join(folder, name)
            let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: Set(keys))
            return FileEntry(name: name, path: path, isDirectory: values?.isDirectory ?? false,
                             isHidden: (values?.isHidden ?? false) || name.hasPrefix("."))
        }
    }
}

struct SidebarView {
    let canvas: Canvas
    let sidebar: FileSidebar
    let layout: SidebarLayout
    /// The terminal's folder, whose row is picked out.
    var terminalFolder: String?
    var home: String?
    /// The ssh host it's showing, if it isn't this machine.
    var host: String?
    /// What it's waiting for, or why it can't show anything, instead of the list.
    var status: String?

    private var scale: Float { layout.scale }
    private var fg: UInt32 { TerminalPalette.foreground }

    private func label(_ text: String, _ r: UIRect, pixels: Float, semibold: Bool = false, alpha: Float = 1) {
        let units = Array(text.utf16)
        sol_canvas_draw_label(canvas.raw, r.x, r.y, r.width, r.height, units, Int32(units.count), pixels, semibold ? 1 : 0, fg, alpha)
    }

    private func icon(_ glyph: UInt16, _ r: UIRect, pixels: Float, color: UInt32? = nil, alpha: Float = 1) {
        sol_canvas_draw_icon(canvas.raw, r.x, r.y, r.width, r.height, glyph, pixels, color ?? fg, alpha)
    }

    func draw() {
        let a = layout.area, tree = sidebar.tree
        sol_canvas_fill_rect(canvas.raw, a.x, a.y, a.width, a.height, TerminalPalette.chrome, 1)
        sol_canvas_push_clip(canvas.raw, a.x, a.y, a.width, a.height)
        defer { sol_canvas_pop_clip(canvas.raw) }

        let folder = tree.root
        let crumbs = folder.map { WindowText.crumbs($0, home: home) } ?? []
        label(crumbs.last ?? "Files", layout.title, pixels: 13.5 * scale, semibold: true, alpha: 0.95)
        for button in SidebarButton.allCases {
            let r = layout.button(button.rawValue)
            let on = button == .pin && sidebar.pinned != nil
            if sidebar.hoveredButton == button { sol_canvas_fill_rounded(canvas.raw, r.x, r.y, r.width, r.height, 4 * scale, fg, 0.10) }
            icon(button.glyph, r, pixels: 12 * scale, color: on ? TerminalPalette.accent : nil, alpha: on ? 1 : 0.7)
        }
        let path = folder.map { AnyPath.isUnix($0) ? (crumbs.first == "~" ? "~/" + crumbs.dropFirst().joined(separator: "/") : $0) : crumbs.joined(separator: "\\") } ?? ""
        label((sidebar.pinned != nil ? "Pinned · " : "") + (host.map { $0 + ":" } ?? "") + path, layout.subtitle, pixels: 11 * scale, alpha: 0.5)

        let list = layout.list
        sol_canvas_push_clip(canvas.raw, list.x, list.y, list.width, list.height)
        defer { sol_canvas_pop_clip(canvas.raw) }
        if let status {
            label(status, UIRect(x: a.x + 12 * scale, y: list.y + 4 * scale, width: a.width - 24 * scale, height: 22 * scale), pixels: 12.5 * scale, alpha: 0.5)
            return
        }
        if tree.rootFailed {
            label("Can't read this folder", UIRect(x: a.x + 12 * scale, y: list.y + 4 * scale, width: a.width - 24 * scale, height: 22 * scale), pixels: 12.5 * scale, alpha: 0.5)
            return
        }
        if tree.rows.isEmpty && !tree.isLoadingRoot {
            label("Empty folder", UIRect(x: a.x + 12 * scale, y: list.y + 4 * scale, width: a.width - 24 * scale, height: 22 * scale), pixels: 12.5 * scale, alpha: 0.5)
            return
        }
        let showing = layout.rowsShowing + 1
        for visible in 0..<showing where tree.scrollTop + visible < tree.rows.count {
            drawRow(tree.rows[tree.scrollTop + visible], in: layout.row(visible), visible: visible)
        }
        if tree.rows.count > layout.rowsShowing, layout.rowsShowing > 0 {
            let total = Float(tree.rows.count), thumb = max(list.height * Float(layout.rowsShowing) / total, 16 * scale)
            let position = Float(tree.scrollTop) / max(total - Float(layout.rowsShowing), 1)
            sol_canvas_fill_rounded(canvas.raw, a.maxX - 6 * scale, list.y + (list.height - thumb) * position, 3 * scale, thumb, 1.5 * scale, fg, 0.25)
        }
    }

    private func drawRow(_ row: FileTree.Row, in r: UIRect, visible: Int) {
        let tree = sidebar.tree, entry = row.entry
        let inset = 4 * scale
        if tree.selection == entry.path {
            sol_canvas_fill_rounded(canvas.raw, r.x + inset, r.y + scale / 2, r.width - inset * 2, r.height - scale, 5 * scale, TerminalPalette.accent, sidebar.isFocused ? 0.26 : 0.14)
        } else if sidebar.hoveredRow == visible {
            sol_canvas_fill_rounded(canvas.raw, r.x + inset, r.y + scale / 2, r.width - inset * 2, r.height - scale, 5 * scale, fg, 0.06)
        } else if entry.path.lowercased() == terminalFolder?.lowercased() {
            sol_canvas_fill_rounded(canvas.raw, r.x + inset, r.y + scale / 2, r.width - inset * 2, r.height - scale, 5 * scale, TerminalPalette.accent, 0.08)
        }
        let chevron = layout.chevron(depth: row.depth, row: r)
        if entry.isDirectory {
            icon(tree.isExpanded(entry.path) ? 0xE70D : 0xE76C, chevron, pixels: 8 * scale, alpha: 0.7)
        }
        let iconRect = UIRect(x: chevron.maxX + 3 * scale, y: r.y, width: 16 * scale, height: r.height)
        icon(entry.isDirectory ? 0xE8B7 : 0xE7C3, iconRect, pixels: 13 * scale, color: entry.isDirectory ? TerminalPalette.accent : nil, alpha: entry.isDirectory ? 0.85 : 0.65)
        let textX = iconRect.maxX + 6 * scale
        label(entry.name, UIRect(x: textX, y: r.y, width: max(r.maxX - textX - 8 * scale, 0), height: r.height), pixels: 12.5 * scale, alpha: entry.isHidden ? 0.5 : 0.9)
    }
}
