import CCanvas
import Foundation
import WinSDK

/// The buttons along the top of a sidebar, in order. Each has its icon and what it says when hovered.
enum SidebarButton: Int, CaseIterable {
    case pin, parent, newFile, newFolder, refresh, more

    var glyph: UInt16 {
        switch self {
        case .pin: return 0xE718
        case .parent: return 0xE74A
        case .newFile: return 0xE8A5
        case .newFolder: return 0xE8B7
        case .refresh: return 0xE72C
        case .more: return 0xE712
        }
    }

    /// New File and New Folder carry a plus, as the Mac's doc.badge.plus and folder.badge.plus do.
    var hasPlus: Bool { self == .newFile || self == .newFolder }
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
    /// A file transfer under way (uploading, downloading), said in place of the path.
    var transfer: String?
    /// Where something dragged over it would go: a folder in it, or its root.
    var dropFolder: String?

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
        sol_canvas_backdrop_rect(canvas.raw, a.x, a.y, a.width, a.height, TerminalPalette.chrome)
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
            if button.hasPlus {
                // The badge: a small plus at the bottom right, cut out of what's behind it.
                let b = UIRect(x: r.x + r.width / 2 + 1 * scale, y: r.y + r.height / 2 + 0.5 * scale, width: 9 * scale, height: 9 * scale)
                sol_canvas_fill_ellipse(canvas.raw, b.x + b.width / 2, b.y + b.height / 2, 4.8 * scale, 4.8 * scale, TerminalPalette.chrome, 1)
                icon(0xE710, b, pixels: 7 * scale, alpha: 0.85)
            }
        }
        let path = folder.map { AnyPath.isUnix($0) ? (crumbs.first == "~" ? "~/" + crumbs.dropFirst().joined(separator: "/") : $0) : crumbs.joined(separator: "\\") } ?? ""
        if let transfer = sidebar.transfer {
            label(transfer, layout.subtitle, pixels: 11 * scale, alpha: 0.8)
        } else {
            label((sidebar.pinned != nil ? "Pinned · " : "") + (host.map { $0 + ":" } ?? "") + path, layout.subtitle, pixels: 11 * scale, alpha: 0.5)
        }

        let list = layout.list
        sol_canvas_push_clip(canvas.raw, list.x, list.y, list.width, list.height)
        defer { sol_canvas_pop_clip(canvas.raw) }
        if let status {
            for (i, line) in status.split(separator: "\n").prefix(4).enumerated() {
                label(String(line), UIRect(x: a.x + 12 * scale, y: list.y + (4 + 20 * Float(i)) * scale, width: a.width - 24 * scale, height: 20 * scale),
                      pixels: (i == 0 ? 12.5 : 11.5) * scale, alpha: i == 0 ? 0.5 : 0.4)
            }
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
        // Something dragged over its root: the whole list is where it goes.
        if let drop = sidebar.dropFolder, drop == tree.root {
            sol_canvas_stroke_rounded(canvas.raw, list.x + 3 * scale, list.y + scale, list.width - 6 * scale, list.height - 4 * scale, 6 * scale, TerminalPalette.accent, 0.8, 1.5 * scale)
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
        if sidebar.dropFolder == entry.path && entry.isDirectory {
            sol_canvas_fill_rounded(canvas.raw, r.x + inset, r.y + scale / 2, r.width - inset * 2, r.height - scale, 5 * scale, TerminalPalette.accent, 0.32)
        } else if tree.selection == entry.path {
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
        // The icon pack's icon (see IconPacks), else Solanum's own.
        let side = (16 * scale).rounded()
        if !FileIcons.draw(name: entry.name, directory: entry.isDirectory, expanded: entry.isDirectory && tree.isExpanded(entry.path),
                           x: iconRect.x, y: (r.midY - side / 2).rounded(), size: side, on: canvas) {
            icon(entry.isDirectory ? 0xE8B7 : FileKind(name: entry.name).glyph, iconRect, pixels: 13 * scale, color: entry.isDirectory ? TerminalPalette.accent : nil, alpha: entry.isDirectory ? 0.85 : 0.65)
        }
        let textX = iconRect.maxX + 6 * scale
        // A name being typed: a field in the row, with its caret.
        if let editing = tree.editing, tree.editingRow == tree.rows.firstIndex(of: row) {
            let box = UIRect(x: textX - 4 * scale, y: r.y + 2 * scale, width: max(r.maxX - textX - 4 * scale, 40 * scale), height: r.height - 4 * scale)
            sol_canvas_fill_rounded(canvas.raw, box.x, box.y, box.width, box.height, 4 * scale, TerminalPalette.background, 1)
            sol_canvas_stroke_rounded(canvas.raw, box.x + 0.5, box.y + 0.5, box.width - 1, box.height - 1, 4 * scale, TerminalPalette.accent, 0.9, 1)
            let pixels = 12.5 * scale
            label(editing.field.text, UIRect(x: textX, y: r.y, width: box.width - 8 * scale, height: r.height), pixels: pixels)
            let before = Array(editing.field.beforeCaret.utf16)
            let caretX = textX + sol_canvas_measure_label(canvas.raw, before, Int32(before.count), pixels, 0)
            sol_canvas_fill_rect(canvas.raw, caretX.rounded(), box.y + 3 * scale, max(scale.rounded(), 1), box.height - 6 * scale, TerminalPalette.accent, 1)
            return
        }
        let dim: Float = tree.cutPaths.contains(entry.path) ? 0.45 : entry.isHidden ? 0.5 : 0.9
        label(entry.name, UIRect(x: textX, y: r.y, width: max(r.maxX - textX - 8 * scale, 0), height: r.height), pixels: 12.5 * scale, alpha: dim)
    }
}
