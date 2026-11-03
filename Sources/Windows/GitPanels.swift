import CCanvas
import Foundation
import WinSDK

/// What's shown over a column's terminal instead of it: Git Changes or Git Graph, as on the Mac. Esc closes it.
protocol ColumnPanel: AnyObject {
    func draw(on canvas: Canvas, in area: UIRect, scale: Float)
    /// True if it dealt with the mouse.
    func mouse(_ message: UINT, x: Float, y: Float, in area: UIRect, scale: Float) -> Bool
    func wheel(notches: Int, x: Float, y: Float, in area: UIRect, scale: Float)
    /// True if it dealt with the key. Characters come through `typed`.
    func key(_ key: Int32, shift: Bool, ctrl: Bool) -> Bool
    func typed(_ text: String)
    /// Looks again (the files, the history), as Refresh does.
    func reload()
}

/// Drawing in the interface font and in the terminal's, for the panels.
struct PanelPaint {
    let canvas: Canvas, scale: Float
    var fg: UInt32 { TerminalPalette.foreground }

    func label(_ text: String, _ r: UIRect, pixels: Float = 12.5, semibold: Bool = false, color: UInt32? = nil, alpha: Float = 1) {
        let units = Array(text.utf16)
        sol_canvas_draw_label(canvas.raw, r.x, r.y, r.width, r.height, units, Int32(units.count), pixels * scale, semibold ? 1 : 0, color ?? fg, alpha)
    }

    func width(_ text: String, pixels: Float = 12.5, semibold: Bool = false) -> Float {
        let units = Array(text.utf16)
        return sol_canvas_measure_label(canvas.raw, units, Int32(units.count), pixels * scale, semibold ? 1 : 0).rounded(.up)
    }

    func icon(_ glyph: UInt16, _ r: UIRect, pixels: Float = 12, color: UInt32? = nil, alpha: Float = 1) {
        sol_canvas_draw_icon(canvas.raw, r.x, r.y, r.width, r.height, glyph, pixels * scale, color ?? fg, alpha)
    }

    func fill(_ r: UIRect, _ color: UInt32, _ alpha: Float, radius: Float = 0) {
        if radius > 0 { sol_canvas_fill_rounded(canvas.raw, r.x, r.y, r.width, r.height, radius * scale, color, alpha) }
        else { sol_canvas_fill_rect(canvas.raw, r.x, r.y, r.width, r.height, color, alpha) }
    }

    /// A line of text in the terminal's font, one cell a character, cut at `maxCells`.
    func mono(_ text: String, x: Float, y: Float, maxCells: Int, color: UInt32) {
        var scalars = Array(text.replacingOccurrences(of: "\t", with: "    ").unicodeScalars.prefix(max(maxCells, 0)).map(\.value))
        guard !scalars.isEmpty else { return }
        var widths = [UInt8](repeating: 1, count: scalars.count)
        sol_canvas_draw_cells(canvas.raw, x, y, &scalars, &widths, Int32(scalars.count), color, 0)
    }

    /// A button with an icon, highlighted under the pointer.
    func button(_ glyph: UInt16, _ r: UIRect, hovered: Bool, alpha: Float = 0.75) {
        if hovered { fill(r, fg, 0.10, radius: 4) }
        icon(glyph, r, pixels: 11, alpha: hovered ? 0.95 : alpha)
    }

    /// A pill with words in it.
    func textButton(_ text: String, _ r: UIRect, hovered: Bool, primary: Bool = false, enabled: Bool = true) {
        fill(r, primary ? TerminalPalette.accent : fg, primary ? (enabled ? (hovered ? 1 : 0.85) : 0.35) : (hovered ? 0.14 : 0.08), radius: 5)
        let w = width(text, pixels: 12, semibold: true)
        label(text, UIRect(x: r.x + (r.width - w) / 2, y: r.y, width: w + 2, height: r.height), pixels: 12, semibold: true,
              color: primary ? TerminalPalette.background : nil, alpha: enabled ? 1 : 0.5)
    }
}

/// A change's letter and colour, as the Mac shows them: green added, orange modified, red deleted or conflicted.
enum GitLook {
    static func badge(_ c: Character) -> (letter: String, color: UInt32) {
        switch c {
        case "?": return ("U", 0x72BD78)
        case "A", "C": return ("A", 0x72BD78)
        case "R": return ("R", 0x72BD78)
        case "M", "T": return ("M", 0xE09C54)
        case "D": return ("D", 0xE06B6B)
        case "U": return ("C", 0xE06B6B)
        default: return (String(c), 0xE09C54)
        }
    }

    static func diffColor(_ kind: GitDiffKind) -> UInt32 {
        switch kind {
        case .added: return 0x72BD78
        case .removed: return 0xE06B6B
        case .hunk: return TerminalPalette.accent
        case .header: return TerminalPalette.foreground
        case .context: return TerminalPalette.foreground
        }
    }

    /// "3 hours ago", from git's seconds.
    static func ago(_ date: Date) -> String {
        let s = max(Int(Date().timeIntervalSince(date)), 0)
        func n(_ v: Int, _ unit: String) -> String { "\(v) \(unit)\(v == 1 ? "" : "s") ago" }
        if s < 60 { return "just now" }
        if s < 3600 { return n(s / 60, "minute") }
        if s < 86400 { return n(s / 3600, "hour") }
        if s < 86400 * 30 { return n(s / 86400, "day") }
        if s < 86400 * 365 { return n(s / (86400 * 30), "month") }
        return n(s / (86400 * 365), "year")
    }
}

// MARK: - Git Changes

/// The repository's changes, staged and not, with the selected file's diff beside them and a message to commit with.
final class GitChangesPanel: ColumnPanel {
    enum Row: Equatable {
        case header(staged: Bool, count: Int)
        case file(GitChange, staged: Bool)
    }
    enum Action: Equatable { case stage, unstage, discard, stageAll, unstageAll }

    let place: GitPlace
    private(set) var info: GitInfo?
    private(set) var rows: [Row] = []
    var message = TextFieldState("")
    private(set) var selected: Int?
    private var listScroll = 0, diffScroll = 0
    private(set) var diff: [(kind: GitDiffKind, text: String)] = []
    private var hoveredRow: Int?
    private var hoveredPart: String?
    /// What it's doing ("Committing…"), or what went wrong, said in the bar.
    private(set) var note: String?
    private(set) var problem = false
    /// Draws again; tells the window the status bar's count may have changed; closes it; asks before throwing changes away.
    var invalidate: () -> Void = {}
    var statusChanged: () -> Void = {}
    var close: () -> Void = {}
    var confirm: (_ question: String, _ button: String, _ run: @escaping () -> Void) -> Void = { _, _, run in run() }
    /// Runs on the window's thread.
    var post: (@escaping () -> Void) -> Void = { $0() }
    var cellSize: (width: Float, height: Float) = (8, 16)

    init(place: GitPlace) { self.place = place }

    func reload() {
        place.run(GitInfo.statusScript, timeout: 20) { [weak self] status, out, _ in
            self?.post {
                guard let self else { return }
                self.info = status == 0 ? GitInfo(statusOutput: out) : nil
                self.rebuild()
                self.loadDiff()
                self.invalidate()
            }
        }
    }

    private func rebuild() {
        let before = selected.flatMap { rows.indices.contains($0) ? rows[$0] : nil }
        let changes = info?.changes ?? []
        let staged = changes.filter { $0.staged != "." && $0.staged != "?" }
        let unstaged = changes.filter { $0.unstaged != "." }
        rows = []
        if !staged.isEmpty { rows += [.header(staged: true, count: staged.count)] + staged.map { .file($0, staged: true) } }
        rows += [.header(staged: false, count: unstaged.count)] + unstaged.map { .file($0, staged: false) }
        // The same file stays selected, or the first there is.
        if let before, case .file(let c, let s) = before {
            selected = rows.firstIndex { if case .file(let d, let t) = $0 { return d.path == c.path && t == s }; return false }
        }
        if selected == nil || !(selected.map { rows.indices.contains($0) } ?? false) { selected = rows.firstIndex { if case .file = $0 { return true }; return false } }
    }

    private var selectedFile: (change: GitChange, staged: Bool)? {
        guard let i = selected, rows.indices.contains(i), case .file(let c, let s) = rows[i] else { return nil }
        return (c, s)
    }

    private func loadDiff() {
        diffScroll = 0
        guard let f = selectedFile else { diff = []; return }
        let p = RemoteConnection.quote(f.change.path)
        let script = f.staged ? "git diff --cached --no-color -- \(p)"
            : f.change.unstaged == "?" ? "git diff --no-color --no-index -- /dev/null \(p); true" : "git diff --no-color -- \(p)"
        // From the repository's top, which the paths are relative to.
        let top = "cd -- \"$(git rev-parse --show-toplevel)\" && "
        place.run(top + script, timeout: 20) { [weak self] _, out, _ in
            let text = String(decoding: out.prefix(2_000_000), as: UTF8.self)
            let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).prefix(20000)
            self?.post {
                guard let self, self.selectedFile?.change.path == f.change.path else { return }
                self.diff = lines.map { (GitDiffKind.of($0), String($0)) }
                if self.diff.allSatisfy({ $0.text.isEmpty }) { self.diff = [(.context, "No changes to show (a binary file, or only its mode changed).")] }
                self.invalidate()
            }
        }
    }

    /// Runs a git command, then looks again.
    private func perform(_ label: String, _ script: String) {
        note = label
        problem = false
        invalidate()
        place.run("cd -- \"$(git rev-parse --show-toplevel)\" && " + script, timeout: 120, errors: true) { [weak self] status, out, err in
            self?.post {
                guard let self else { return }
                if status == 0 {
                    self.note = nil
                } else {
                    let said = (err.isEmpty ? String(decoding: out, as: UTF8.self) : err).trimmingCharacters(in: .whitespacesAndNewlines)
                    self.note = said.split(whereSeparator: \.isNewline).last.map(String.init) ?? "That didn't work."
                    self.problem = true
                }
                self.reload()
                self.statusChanged()
            }
        }
    }

    func act(_ action: Action, on change: GitChange?) {
        let p = change.map { RemoteConnection.quote($0.path) } ?? ""
        switch action {
        case .stage: perform("Staging…", "git add -A -- \(p)")
        case .unstage: perform("Unstaging…", "git restore --staged -- \(p) 2>/dev/null || git rm -q --cached -- \(p)")
        case .stageAll: perform("Staging…", "git add -A")
        case .unstageAll: perform("Unstaging…", "git restore --staged -- . 2>/dev/null || git rm -rq --cached -- .")
        case .discard:
            guard let change else { return }
            let untracked = change.unstaged == "?"
            confirm(untracked ? "Delete “\(change.path)”? It isn't tracked, so it's gone for good." : "Throw away your changes to “\(change.path)”?",
                    untracked ? "Delete File" : "Discard Changes") { [weak self] in
                self?.perform("Discarding…", untracked ? "git clean -fdq -- \(p)" : "git restore -- \(p)")
            }
        }
    }

    /// Commits what's staged, or with nothing staged, everything.
    func commit() {
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { note = "Write a message to commit with."; problem = true; invalidate(); return }
        let stagedAny = rows.contains { if case .file(_, true) = $0 { return true }; return false }
        message = TextFieldState("")
        perform("Committing…", (stagedAny ? "" : "git add -A && ") + "git commit -q -m \(RemoteConnection.quote(text))")
    }

    // Layout

    private func header(_ a: UIRect, _ s: Float) -> UIRect { UIRect(x: a.x, y: a.y, width: a.width, height: (46 * s).rounded()) }
    private func list(_ a: UIRect, _ s: Float) -> UIRect {
        let h = header(a, s), w = min(max((a.width * 0.38).rounded(), 260 * s), a.width - 200 * s)
        return UIRect(x: a.x, y: h.maxY, width: max(w, 160 * s), height: max(a.maxY - h.maxY, 0))
    }
    private func diffArea(_ a: UIRect, _ s: Float) -> UIRect {
        let l = list(a, s)
        return UIRect(x: l.maxX + 1, y: l.y, width: max(a.maxX - l.maxX - 1, 0), height: l.height)
    }
    private func rowHeight(_ s: Float) -> Float { (26 * s).rounded() }
    private func row(_ i: Int, _ a: UIRect, _ s: Float) -> UIRect {
        let l = list(a, s)
        return UIRect(x: l.x, y: l.y + 4 * s + Float(i - listScroll) * rowHeight(s), width: l.width, height: rowHeight(s))
    }
    private func closeButton(_ a: UIRect, _ s: Float) -> UIRect { UIRect(x: a.maxX - 34 * s, y: a.y + 11 * s, width: 24 * s, height: 24 * s) }
    private func refreshButton(_ a: UIRect, _ s: Float) -> UIRect { UIRect(x: a.maxX - 62 * s, y: a.y + 11 * s, width: 24 * s, height: 24 * s) }
    private func commitButton(_ a: UIRect, _ s: Float) -> UIRect { UIRect(x: refreshButton(a, s).x - 96 * s, y: a.y + 10 * s, width: 84 * s, height: 26 * s) }
    private func field(_ a: UIRect, _ s: Float) -> UIRect {
        let start = a.x + 12 * s + titleWidth
        return UIRect(x: start, y: a.y + 9 * s, width: max(commitButton(a, s).x - 10 * s - start, 80 * s), height: 28 * s)
    }
    private var titleWidth: Float = 140
    /// The buttons on a row: on its right, while it's hovered.
    private func rowButtons(_ i: Int, _ a: UIRect, _ s: Float) -> [(Action, UIRect)] {
        let r = row(i, a, s), side = 22 * s
        func at(_ k: Int) -> UIRect { UIRect(x: r.maxX - 8 * s - side * Float(k + 1) - 2 * s * Float(k), y: r.y + (r.height - side) / 2, width: side, height: side) }
        switch rows[i] {
        case .header(let staged, let count): return count == 0 ? [] : [(staged ? .unstageAll : .stageAll, at(0))]
        case .file(_, let staged): return staged ? [(.unstage, at(0))] : [(.stage, at(0)), (.discard, at(1))]
        }
    }
    private func glyph(_ a: Action) -> UInt16 {
        switch a {
        case .stage, .stageAll: return 0xE710      // +
        case .unstage, .unstageAll: return 0xE738  // −
        case .discard: return 0xE7A7               // undo
        }
    }

    func draw(on canvas: Canvas, in a: UIRect, scale s: Float) {
        let p = PanelPaint(canvas: canvas, scale: s), fg = p.fg
        p.fill(a, TerminalPalette.background, 1)
        sol_canvas_push_clip(canvas.raw, a.x, a.y, a.width, a.height)
        defer { sol_canvas_pop_clip(canvas.raw) }
        // The bar: what this is, the message, Commit.
        let h = header(a, s)
        p.fill(h, TerminalPalette.chrome, 1)
        p.fill(UIRect(x: a.x, y: h.maxY - 1, width: a.width, height: 1), fg, 0.10)
        let title = "Git Changes" + (info.map { " · \($0.branch)" } ?? "")
        titleWidth = min(p.width(title, pixels: 13, semibold: true) + 20 * s, a.width * 0.3)
        p.label(title, UIRect(x: a.x + 12 * s, y: h.y, width: titleWidth - 16 * s, height: h.height), pixels: 13, semibold: true)
        let f = field(a, s)
        p.fill(f, TerminalPalette.background, 1, radius: 5)
        sol_canvas_stroke_rounded(canvas.raw, f.x + 0.5, f.y + 0.5, f.width - 1, f.height - 1, 5 * s, TerminalPalette.accent, 0.6, 1)
        let inner = UIRect(x: f.x + 8 * s, y: f.y, width: f.width - 16 * s, height: f.height)
        if message.text.isEmpty {
            p.label("Message (Ctrl+Enter commits)", inner, pixels: 12.5, alpha: 0.4)
        } else {
            p.label(message.text, inner, pixels: 12.5)
        }
        let caretX = inner.x + (message.beforeCaret.isEmpty ? 0 : p.width(message.beforeCaret, pixels: 12.5))
        p.fill(UIRect(x: min(caretX, inner.maxX).rounded(), y: f.y + 6 * s, width: max(s.rounded(), 1), height: f.height - 12 * s), TerminalPalette.accent, 1)
        p.textButton("Commit", commitButton(a, s), hovered: hoveredPart == "commit", primary: true, enabled: !(info?.changes.isEmpty ?? true))
        p.button(0xE72C, refreshButton(a, s), hovered: hoveredPart == "refresh")
        p.button(0xE8BB, closeButton(a, s), hovered: hoveredPart == "close")

        // The list.
        let l = list(a, s)
        p.fill(UIRect(x: l.maxX, y: l.y, width: 1, height: l.height), fg, 0.10)
        if info == nil {
            p.label("Not a git repository, or git isn't installed.", UIRect(x: l.x + 14 * s, y: l.y + 10 * s, width: l.width - 28 * s, height: 22 * s), alpha: 0.55)
        }
        for i in rows.indices where i >= listScroll {
            let r = row(i, a, s)
            guard r.y < l.maxY else { break }
            switch rows[i] {
            case .header(let staged, let count):
                p.label((staged ? "STAGED CHANGES" : "CHANGES") + "  \(count)", UIRect(x: r.x + 14 * s, y: r.y + 4 * s, width: r.width - 60 * s, height: r.height - 4 * s),
                        pixels: 11, semibold: true, alpha: 0.5)
            case .file(let c, let staged):
                if selected == i { p.fill(UIRect(x: r.x + 4 * s, y: r.y + 1, width: r.width - 8 * s, height: r.height - 2), TerminalPalette.accent, 0.22, radius: 5) }
                else if hoveredRow == i { p.fill(UIRect(x: r.x + 4 * s, y: r.y + 1, width: r.width - 8 * s, height: r.height - 2), fg, 0.06, radius: 5) }
                let badge = GitLook.badge(staged ? c.staged : (c.unstaged == "?" ? "?" : c.unstaged))
                p.label(badge.letter, UIRect(x: r.x + 14 * s, y: r.y, width: 14 * s, height: r.height), pixels: 12, semibold: true, color: badge.color)
                let name = AnyPath.name(c.path.replacingOccurrences(of: "\\", with: "/")), folder = c.path.contains("/") ? String(c.path[..<c.path.lastIndex(of: "/")!]) : ""
                let nameW = min(p.width(name), r.width - 100 * s)
                p.label(name, UIRect(x: r.x + 34 * s, y: r.y, width: nameW + 2, height: r.height), alpha: c.code == "D" ? 0.6 : 0.95)
                if !folder.isEmpty {
                    p.label(folder, UIRect(x: r.x + 40 * s + nameW, y: r.y, width: max(r.maxX - 70 * s - nameW - 40 * s, 0), height: r.height), pixels: 11.5, alpha: 0.45)
                }
            }
            if hoveredRow == i || (selected == i && rows.indices.contains(i)) {
                for (action, b) in rowButtons(i, a, s) { p.button(glyph(action), b, hovered: hoveredPart == "\(i):\(action)") }
            }
        }

        // The diff.
        let d = diffArea(a, s)
        sol_canvas_push_clip(canvas.raw, d.x, d.y, d.width, d.height)
        let cellsAcross = Int((d.width - 20 * s) / max(cellSize.width, 1))
        for (k, line) in diff.dropFirst(diffScroll).enumerated() {
            let y = d.y + 6 * s + Float(k) * cellSize.height
            guard y < d.maxY else { break }
            if line.kind == .added || line.kind == .removed {
                p.fill(UIRect(x: d.x, y: y, width: d.width, height: cellSize.height), GitLook.diffColor(line.kind), 0.10)
            }
            p.mono(line.text, x: d.x + 10 * s, y: y, maxCells: cellsAcross, color: GitLook.diffColor(line.kind))
        }
        sol_canvas_pop_clip(canvas.raw)
        // What it's doing, or what went wrong.
        if let note {
            let w = min(p.width(note) + 28 * s, a.width - 24 * s)
            let r = UIRect(x: a.x + (a.width - w) / 2, y: a.maxY - 42 * s, width: w, height: 30 * s)
            p.fill(r, problem ? 0x5A2424 : TerminalPalette.chrome, 0.96, radius: 6)
            p.label(note, UIRect(x: r.x + 14 * s, y: r.y, width: w - 28 * s, height: r.height), alpha: 0.95)
        }
    }

    func mouse(_ message: UINT, x: Float, y: Float, in a: UIRect, scale s: Float) -> Bool {
        let hoverBefore = (hoveredRow, hoveredPart)
        hoveredPart = nil
        hoveredRow = nil
        if closeButton(a, s).contains(x, y) { hoveredPart = "close" }
        else if refreshButton(a, s).contains(x, y) { hoveredPart = "refresh" }
        else if commitButton(a, s).contains(x, y) { hoveredPart = "commit" }
        else if list(a, s).contains(x, y) {
            hoveredRow = rows.indices.first { $0 >= listScroll && row($0, a, s).contains(x, y) }
            if let i = hoveredRow, let hit = rowButtons(i, a, s).first(where: { $0.1.contains(x, y) }) { hoveredPart = "\(i):\(hit.0)" }
        }
        if message == Win.WM_LBUTTONUP {
            switch hoveredPart {
            case "close": close()
            case "refresh": reload()
            case "commit": commit()
            default:
                if let i = hoveredRow {
                    if let hit = rowButtons(i, a, s).first(where: { $0.1.contains(x, y) }) {
                        if case .file(let c, _) = rows[i] { act(hit.0, on: c) } else { act(hit.0, on: nil) }
                    } else if case .file = rows[i] {
                        selected = i
                        loadDiff()
                    }
                }
            }
        }
        if hoverBefore.0 != hoveredRow || hoverBefore.1 != hoveredPart || message != Win.WM_MOUSEMOVE { invalidate() }
        return true
    }

    func wheel(notches: Int, x: Float, y: Float, in a: UIRect, scale s: Float) {
        if diffArea(a, s).contains(x, y) {
            diffScroll = min(max(diffScroll - notches * 3, 0), max(diff.count - 5, 0))
        } else {
            listScroll = min(max(listScroll - notches * 2, 0), max(rows.count - 3, 0))
        }
        invalidate()
    }

    func key(_ key: Int32, shift: Bool, ctrl: Bool) -> Bool {
        switch key {
        case Win.VK_ESCAPE: close()
        case Win.VK_RETURN: if ctrl || !message.text.isEmpty { commit() }
        case Win.VK_UP, Win.VK_DOWN:
            let files = rows.indices.filter { if case .file = rows[$0] { return true }; return false }
            guard !files.isEmpty else { return true }
            let at = selected.flatMap { files.firstIndex(of: $0) } ?? -1
            selected = files[min(max(at + (key == Win.VK_UP ? -1 : 1), 0), files.count - 1)]
            loadDiff()
        case Win.VK_BACK: message.deleteBackward(word: ctrl)
        case Win.VK_DELETE: message.deleteForward()
        case Win.VK_LEFT: message.move(by: -1)
        case Win.VK_RIGHT: message.move(by: 1)
        case Win.VK_HOME: message.move(to: 0)
        case Win.VK_END: message.move(to: message.text.count)
        default: return ctrl
        }
        invalidate()
        return true
    }

    func typed(_ text: String) {
        message.insert(text.filter { !$0.isNewline })
        invalidate()
    }

    // For tests
    var fileRows: [(path: String, staged: Bool)] { rows.compactMap { if case .file(let c, let s) = $0 { return (c.path, s) }; return nil } }
    func select(path: String, staged: Bool) {
        selected = rows.firstIndex { if case .file(let c, let s) = $0 { return c.path == path && s == staged }; return false }
        loadDiff()
    }
}

// MARK: - Git Graph

/// Every branch's history, as VS Code's Git Graph draws it: a lane for each line of development, with branch and tag
/// labels. Clicking a commit shows its details below.
final class GitGraphPanel: ColumnPanel {
    let place: GitPlace
    private(set) var head = ""
    private(set) var rows: [GraphRow] = []
    private(set) var loaded = false
    private(set) var selected: Int?
    private var scroll = 0
    private var hoveredRow: Int?
    private var hoveredPart: String?
    private(set) var details: [String] = []
    var invalidate: () -> Void = {}
    var close: () -> Void = {}
    var copy: (String) -> Void = { _ in }
    var post: (@escaping () -> Void) -> Void = { $0() }

    init(place: GitPlace) { self.place = place }

    static let laneColors: [UInt32] = [0x4FA3F7, 0xE5A445, 0x6CC97A, 0xD46FC9, 0xE06B6B, 0x5FC9C2, 0xA98BF2, 0xC9B55F]

    func reload() {
        place.run(GraphCommit.script, timeout: 60) { [weak self] status, out, _ in
            let parsed = status == 0 ? GraphCommit.parse(out) : ("", [])
            let rows = GraphLayout.rows(parsed.commits)
            self?.post {
                guard let self else { return }
                self.head = parsed.0
                self.rows = rows
                self.loaded = true
                if let s = self.selected, !rows.indices.contains(s) { self.selected = nil }
                self.invalidate()
            }
        }
    }

    private func loadDetails() {
        guard let i = selected, rows.indices.contains(i) else { details = []; return }
        let hash = rows[i].commit.hash
        details = ["Loading…"]
        place.run("git show --stat --format='%H%n%an <%ae>%n%ad%n%n%B' --date=format:'%a %d %b %Y %H:%M' --no-color \(hash) | head -n 60", timeout: 20) { [weak self] _, out, _ in
            let lines = String(decoding: out, as: UTF8.self).split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
            self?.post {
                guard let self, self.selected.map({ self.rows.indices.contains($0) && self.rows[$0].commit.hash == hash }) == true else { return }
                self.details = lines
                self.invalidate()
            }
        }
    }

    private func header(_ a: UIRect, _ s: Float) -> UIRect { UIRect(x: a.x, y: a.y, width: a.width, height: (40 * s).rounded()) }
    private func closeButton(_ a: UIRect, _ s: Float) -> UIRect { UIRect(x: a.maxX - 34 * s, y: a.y + 8 * s, width: 24 * s, height: 24 * s) }
    private func refreshButton(_ a: UIRect, _ s: Float) -> UIRect { UIRect(x: a.maxX - 62 * s, y: a.y + 8 * s, width: 24 * s, height: 24 * s) }
    private func copyButton(_ a: UIRect, _ s: Float) -> UIRect { UIRect(x: refreshButton(a, s).x - 100 * s, y: a.y + 8 * s, width: 90 * s, height: 24 * s) }
    private func detailsArea(_ a: UIRect, _ s: Float) -> UIRect? {
        guard selected != nil else { return nil }
        let h = min((220 * s).rounded(), a.height * 0.45)
        return UIRect(x: a.x, y: a.maxY - h, width: a.width, height: h)
    }
    private func listArea(_ a: UIRect, _ s: Float) -> UIRect {
        let h = header(a, s), bottom = detailsArea(a, s)?.y ?? a.maxY
        return UIRect(x: a.x, y: h.maxY, width: a.width, height: max(bottom - h.maxY, 0))
    }
    private func rowHeight(_ s: Float) -> Float { (24 * s).rounded() }
    private func laneWidth(_ s: Float) -> Float { (14 * s).rounded() }
    private func rowRect(_ i: Int, _ a: UIRect, _ s: Float) -> UIRect {
        let l = listArea(a, s)
        return UIRect(x: l.x, y: l.y + Float(i - scroll) * rowHeight(s), width: l.width, height: rowHeight(s))
    }
    private var visibleRows: Int = 20

    func draw(on canvas: Canvas, in a: UIRect, scale s: Float) {
        let p = PanelPaint(canvas: canvas, scale: s), fg = p.fg
        p.fill(a, TerminalPalette.background, 1)
        sol_canvas_push_clip(canvas.raw, a.x, a.y, a.width, a.height)
        defer { sol_canvas_pop_clip(canvas.raw) }
        let h = header(a, s)
        p.fill(h, TerminalPalette.chrome, 1)
        p.fill(UIRect(x: a.x, y: h.maxY - 1, width: a.width, height: 1), fg, 0.10)
        p.label("Git Graph" + (rows.isEmpty ? "" : " · \(rows.count) commit\(rows.count == 1 ? "" : "s")"), UIRect(x: a.x + 12 * s, y: h.y, width: a.width * 0.5, height: h.height),
                pixels: 13, semibold: true)
        if selected != nil { p.textButton("Copy Hash", copyButton(a, s), hovered: hoveredPart == "copy") }
        p.button(0xE72C, refreshButton(a, s), hovered: hoveredPart == "refresh")
        p.button(0xE8BB, closeButton(a, s), hovered: hoveredPart == "close")

        let l = listArea(a, s), rh = rowHeight(s), lw = laneWidth(s)
        visibleRows = max(Int(l.height / rh), 1)
        if loaded && rows.isEmpty {
            p.label("No commits here, or not a git repository.", UIRect(x: l.x + 14 * s, y: l.y + 10 * s, width: l.width - 28 * s, height: 22 * s), alpha: 0.55)
        }
        sol_canvas_push_clip(canvas.raw, l.x, l.y, l.width, l.height)
        func laneX(_ lane: Int) -> Float { l.x + 14 * s + Float(lane) * lw }
        func color(_ c: Int) -> UInt32 { Self.laneColors[c % Self.laneColors.count] }
        for i in rows.indices where i >= scroll && i < scroll + visibleRows + 1 {
            let r = rowRect(i, a, s), row = rows[i], mid = r.midY, thick = 1.6 * s
            if selected == i { p.fill(r, TerminalPalette.accent, 0.20) } else if hoveredRow == i { p.fill(r, fg, 0.05) }
            for (segment, c) in row.segments {
                switch segment {
                case .through(let lane): sol_canvas_line(canvas.raw, laneX(lane), r.y, laneX(lane), r.maxY, color(c), 0.9, thick)
                case .top(let from, let to): sol_canvas_line(canvas.raw, laneX(from), r.y, laneX(to), mid, color(c), 0.9, thick)
                case .bottom(let from, let to): sol_canvas_line(canvas.raw, laneX(from), mid, laneX(to), r.maxY, color(c), 0.9, thick)
                }
            }
            let isHead = row.commit.hash == head
            sol_canvas_fill_ellipse(canvas.raw, laneX(row.lane), mid, 4.5 * s, 4.5 * s, color(row.color), 1)
            if isHead { sol_canvas_fill_ellipse(canvas.raw, laneX(row.lane), mid, 2 * s, 2 * s, TerminalPalette.background, 1) }
            var x = laneX(row.width) + 6 * s
            for label in GraphLabel.labels(row.commit.refs).prefix(4) {
                let text = label.kind == .tag ? "◆ " + label.name : label.name + (label.onRemote ? " ☁" : "")
                let w = min(p.width(text, pixels: 11, semibold: true) + 12 * s, 180 * s)
                let pill = UIRect(x: x, y: mid - 9 * s, width: w, height: 18 * s)
                p.fill(pill, label.kind == .tag ? 0xE5A445 : color(row.color), label.current ? 0.95 : 0.35, radius: 9)
                p.label(text, UIRect(x: pill.x + 6 * s, y: pill.y, width: w - 12 * s, height: pill.height), pixels: 11, semibold: true,
                        color: label.current ? TerminalPalette.background : nil)
                x += w + 4 * s
            }
            let meta = row.commit.author + "  ·  " + GitLook.ago(row.commit.date) + "  ·  " + String(row.commit.hash.prefix(7))
            let metaW = min(p.width(meta, pixels: 11.5), r.width * 0.4)
            p.label(row.commit.subject, UIRect(x: x + 2 * s, y: r.y, width: max(r.maxX - metaW - 24 * s - x, 0), height: r.height), alpha: 0.92)
            p.label(meta, UIRect(x: r.maxX - metaW - 12 * s, y: r.y, width: metaW + 2, height: r.height), pixels: 11.5, alpha: 0.45)
        }
        sol_canvas_pop_clip(canvas.raw)
        if let d = detailsArea(a, s) {
            p.fill(d, TerminalPalette.chrome, 1)
            p.fill(UIRect(x: d.x, y: d.y, width: d.width, height: 1), fg, 0.12)
            sol_canvas_push_clip(canvas.raw, d.x, d.y, d.width, d.height)
            for (k, line) in details.enumerated() {
                let y = d.y + 10 * s + Float(k) * 18 * s
                guard y < d.maxY else { break }
                let kind: GitDiffKind = line.contains("|") && (line.contains("+") || line.contains("-")) ? .context : k == 0 ? .hunk : .context
                p.label(line, UIRect(x: d.x + 14 * s, y: y, width: d.width - 28 * s, height: 18 * s), pixels: k == 0 ? 11.5 : 12, semibold: k == 4,
                        color: kind == .hunk ? TerminalPalette.accent : nil, alpha: k == 1 || k == 2 ? 0.6 : 0.9)
            }
            sol_canvas_pop_clip(canvas.raw)
        }
    }

    func mouse(_ message: UINT, x: Float, y: Float, in a: UIRect, scale s: Float) -> Bool {
        let before = (hoveredRow, hoveredPart)
        hoveredPart = closeButton(a, s).contains(x, y) ? "close" : refreshButton(a, s).contains(x, y) ? "refresh"
            : selected != nil && copyButton(a, s).contains(x, y) ? "copy" : nil
        hoveredRow = listArea(a, s).contains(x, y) ? rows.indices.first { $0 >= scroll && rowRect($0, a, s).contains(x, y) } : nil
        if message == Win.WM_LBUTTONUP {
            switch hoveredPart {
            case "close": close()
            case "refresh": reload()
            case "copy": if let i = selected { copy(rows[i].commit.hash) }
            default:
                if let i = hoveredRow {
                    selected = selected == i ? nil : i
                    loadDetails()
                }
            }
        }
        if before.0 != hoveredRow || before.1 != hoveredPart || message != Win.WM_MOUSEMOVE { invalidate() }
        return true
    }

    func wheel(notches: Int, x: Float, y: Float, in a: UIRect, scale s: Float) {
        scroll = min(max(scroll - notches * 3, 0), max(rows.count - 3, 0))
        invalidate()
    }

    func key(_ key: Int32, shift: Bool, ctrl: Bool) -> Bool {
        switch key {
        case Win.VK_ESCAPE:
            if selected != nil { selected = nil; details = [] } else { close() }
        case Win.VK_UP, Win.VK_DOWN:
            guard !rows.isEmpty else { return true }
            selected = min(max((selected ?? -1) + (key == Win.VK_UP ? -1 : 1), 0), rows.count - 1)
            if let i = selected {
                if i < scroll { scroll = i }
                if i >= scroll + visibleRows { scroll = i - visibleRows + 1 }
            }
            loadDetails()
        case Win.VK_PRIOR: scroll = max(scroll - visibleRows, 0)
        case Win.VK_NEXT: scroll = min(scroll + visibleRows, max(rows.count - 3, 0))
        case 0x43 where ctrl: if let i = selected { copy(rows[i].commit.hash) }
        default: return ctrl
        }
        invalidate()
        return true
    }

    func typed(_ text: String) {}

    // For tests
    func selectRow(_ i: Int) { selected = i; loadDetails() }
}
