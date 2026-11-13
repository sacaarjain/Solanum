import CCanvas
import Foundation
import WinSDK

/// What's shown over a column's terminal instead of it: Git Changes or Git Graph, as on the Mac. Esc closes it.
protocol ColumnPanel: AnyObject {
    func draw(on canvas: Canvas, in area: UIRect, scale: Float)
    /// True if it dealt with the mouse.
    func mouse(_ message: UINT, x: Float, y: Float, in area: UIRect, scale: Float) -> Bool
    /// Scrolls by lines, up for positive: 3 a wheel notch, and one at a time under a finger.
    func scroll(lines: Int, x: Float, y: Float, in area: UIRect, scale: Float)
    /// True if it dealt with the key. Characters come through `typed`.
    func key(_ key: Int32, shift: Bool, ctrl: Bool) -> Bool
    func typed(_ text: String)
    /// Looks again (the files, the history), as Refresh does.
    func reload()
    /// The pointer has gone somewhere else: nothing stays hovered.
    func mouseLeft()
    /// About ten times a second, while it's in a tab: for work on a timer (a file followed as it changes).
    func tick()
    /// Edits not yet saved, which closing it would lose.
    var hasUnsavedChanges: Bool { get }
    /// Saves them; `done` with whether it worked.
    func save(_ done: @escaping (Bool) -> Void)
}

extension ColumnPanel {
    func mouseLeft() {}
    func tick() {}
    var hasUnsavedChanges: Bool { false }
    func save(_ done: @escaping (Bool) -> Void) { done(true) }
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

    /// A background of the window's own, as see-through as the window is (see `sol_canvas_backdrop_rect`).
    func backdrop(_ r: UIRect, _ color: UInt32) {
        sol_canvas_backdrop_rect(canvas.raw, r.x, r.y, r.width, r.height, color)
    }

    func fill(_ r: UIRect, _ color: UInt32, _ alpha: Float, radius: Float = 0) {
        if radius > 0 { sol_canvas_fill_rounded(canvas.raw, r.x, r.y, r.width, r.height, radius * scale, color, alpha) }
        else { sol_canvas_fill_rect(canvas.raw, r.x, r.y, r.width, r.height, color, alpha) }
    }

    /// A line of text in the terminal's font, one cell a character, cut at `maxCells`.
    func mono(_ text: String, x: Float, y: Float, maxCells: Int, color: UInt32, bold: Bool = false) {
        var scalars = Array(text.replacingOccurrences(of: "\t", with: "    ").unicodeScalars.prefix(max(maxCells, 0)).map(\.value))
        guard !scalars.isEmpty else { return }
        var widths = [UInt8](repeating: 1, count: scalars.count)
        sol_canvas_draw_cells(canvas.raw, x, y, &scalars, &widths, Int32(scalars.count), color, bold ? Int32(SOL_STYLE_BOLD) : 0)
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
    /// As the Mac's (and VS Code's) Source Control: what's staged, changes to tracked files, and files git doesn't track.
    enum Section: Equatable { case staged, changes, untracked }
    enum Row: Equatable {
        case header(Section, count: Int)
        case file(GitChange, staged: Bool)
    }
    enum Action: Equatable { case stage, unstage, discard, stageAll, unstageAll, stageTracked, stageUntracked, discardAll }

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
        let tracked = changes.filter { $0.unstaged != "." && $0.unstaged != "?" }
        let untracked = changes.filter { $0.unstaged == "?" }
        rows = []
        if !staged.isEmpty { rows += [.header(.staged, count: staged.count)] + staged.map { .file($0, staged: true) } }
        if !tracked.isEmpty || untracked.isEmpty { rows += [.header(.changes, count: tracked.count)] + tracked.map { .file($0, staged: false) } }
        if !untracked.isEmpty { rows += [.header(.untracked, count: untracked.count)] + untracked.map { .file($0, staged: false) } }
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
        // As the Mac's section links: Changes' Stage All is the tracked files, Untracked's the rest.
        case .stageTracked: perform("Staging…", "git add -u")
        case .stageUntracked: perform("Staging…", "git ls-files -z -o --exclude-standard | xargs -0 git add --")
        case .discardAll:
            let n = info?.changes.filter { $0.unstaged != "." && $0.unstaged != "?" }.count ?? 0
            confirm("Discard all \(n) change\(n == 1 ? "" : "s")? Untracked files stay. This can't be undone.", "Discard All") { [weak self] in
                self?.perform("Discarding…", "git restore -- . 2>/dev/null || git checkout -- .")
            }
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
        case .header(let section, let count):
            guard count > 0 else { return [] }
            switch section {
            case .staged: return [(.unstageAll, at(0))]
            case .changes: return [(.stageTracked, at(0)), (.discardAll, at(1))]
            case .untracked: return [(.stageUntracked, at(0))]
            }
        case .file(_, let staged): return staged ? [(.unstage, at(0))] : [(.stage, at(0)), (.discard, at(1))]
        }
    }
    private func glyph(_ a: Action) -> UInt16 {
        switch a {
        case .stage, .stageAll, .stageTracked, .stageUntracked: return 0xE710  // +
        case .unstage, .unstageAll: return 0xE738                              // −
        case .discard, .discardAll: return 0xE7A7                              // undo
        }
    }

    func draw(on canvas: Canvas, in a: UIRect, scale s: Float) {
        let p = PanelPaint(canvas: canvas, scale: s), fg = p.fg
        p.backdrop(a, TerminalPalette.page)
        sol_canvas_push_clip(canvas.raw, a.x, a.y, a.width, a.height)
        defer { sol_canvas_pop_clip(canvas.raw) }
        // The bar: what this is, the message, Commit.
        let h = header(a, s)
        // On the page's own surface, as the Mac's: set off from what's under it by a hairline inset from the page's
        // rounded edges, so the active sub-tab above runs straight into it.
        p.fill(UIRect(x: a.x + 12 * s, y: h.maxY - 1, width: max(a.width - 24 * s, 0), height: 1), fg, 0.10)
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
            case .header(let section, let count):
                let title = section == .staged ? "STAGED CHANGES" : section == .changes ? "CHANGES" : "UNTRACKED"
                p.label(title + "  \(count)", UIRect(x: r.x + 14 * s, y: r.y + 4 * s, width: r.width - 60 * s, height: r.height - 4 * s),
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
            // A header's Stage All or Unstage All always shows; a file's buttons, when it's hovered or selected.
            var isHeader = false
            if case .header = rows[i] { isHeader = true }
            if isHeader || hoveredRow == i || (selected == i && rows.indices.contains(i)) {
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

    func scroll(lines: Int, x: Float, y: Float, in a: UIRect, scale s: Float) {
        if diffArea(a, s).contains(x, y) {
            diffScroll = min(max(diffScroll - lines, 0), max(diff.count - 5, 0))
        } else {
            listScroll = min(max(listScroll - lines, 0), max(rows.count - 3, 0))
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

