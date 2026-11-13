import CCanvas
import Foundation
import WinSDK

/// One commit, as the Mac's Git page shows it (GitStatusView.swift there): its subject, hash, author and age, and the size
/// of the change on top; then its files, each unfolding to show its changes right there with both line numbers. Expand
/// All unfolds them all.
final class GitCommitPanel: ColumnPanel {
    private enum Row {
        case top, clean, section(Int), file(GitCommitReport.Entry), diff(GitPageLine), loading, gap
    }

    let place: GitPlace
    let hash: String
    private(set) var report: GitCommitReport?
    private(set) var failed = false
    private var rows: [Row] = []
    /// Where each row starts, and the end of the last, at the width they were laid out for.
    private var offsets: [Float] = [0]
    private var builtFor: (width: Float, scale: Float) = (0, 0)
    private(set) var unfolded = Set<String>()
    private var diffs: [String: [GitPageLine]] = [:]
    private var scrollY: Float = 0
    private var hovered: Int?
    private var hoveredToggle = false
    private var toggleAllRect: UIRect?
    private var lastArea = UIRect(x: 0, y: 0, width: 0, height: 0)
    var invalidate: () -> Void = {}
    var close: () -> Void = {}
    var copy: (String) -> Void = { _ in }
    var post: (@escaping () -> Void) -> Void = { $0() }
    var cellSize: (width: Float, height: Float) = (8, 16)

    init(place: GitPlace, hash: String) {
        self.place = place
        self.hash = hash
    }

    func reload() {
        place.run(GitCommitReport.script(commit: hash), timeout: 30) { [weak self] status, out, _ in
            let report = status == 0 ? GitCommitReport(output: out) : nil
            self?.post {
                guard let self else { return }
                self.report = report
                self.failed = report == nil
                self.rebuild()
                self.invalidate()
            }
        }
    }

    private var entries: [GitCommitReport.Entry] { report?.files.filter { !$0.path.hasSuffix("/") } ?? [] }

    private func rebuild() {
        rows = []
        hovered = nil
        if let r = report {
            rows.append(.top)
            if r.files.isEmpty { rows.append(.clean) }
            if !r.files.isEmpty {
                rows.append(.section(r.files.count))
                for e in r.files {
                    rows.append(.file(e))
                    guard unfolded.contains(e.path) else { continue }
                    if let lines = diffs[e.path] {
                        rows += lines.isEmpty ? [.diff(GitPageLine(kind: .note, text: "No text changes to show."))] : lines.map { .diff($0) }
                    } else {
                        rows.append(.loading)
                    }
                }
                rows.append(.gap)
            }
        }
        builtFor = (0, 0)
    }

    // MARK: Unfolding

    private func setUnfolded(_ on: Bool, _ e: GitCommitReport.Entry) {
        if on {
            unfolded.insert(e.path)
            load(e)
        } else {
            unfolded.remove(e.path)
        }
        rebuild()
        invalidate()
    }

    private func load(_ e: GitCommitReport.Entry) {
        guard let r = report, diffs[e.path] == nil else { return }
        place.run("cd -- \"$(git rev-parse --show-toplevel)\" && " + GitPageLine.script(for: e, hash: r.hash, base: r.base), timeout: 30) { [weak self] _, out, _ in
            let lines = GitPageLine.parse(out)
            self?.post {
                guard let self, self.unfolded.contains(e.path) else { return }
                self.diffs[e.path] = lines
                self.rebuild()
                self.invalidate()
            }
        }
    }

    /// Expand All when anything is folded, otherwise Collapse All.
    func toggleAll() {
        if entries.allSatisfy({ unfolded.contains($0.path) }) {
            unfolded.removeAll()
        } else {
            for e in entries where !unfolded.contains(e.path) {
                unfolded.insert(e.path)
                load(e)
            }
        }
        rebuild()
        invalidate()
    }

    // MARK: Layout

    private func left(_ s: Float) -> Float { (24 * s).rounded() }
    private func lineHeight(_ s: Float) -> Float { max(cellSize.height, (17 * s).rounded()) }
    private func gutter(_ s: Float) -> Float { (92 * s).rounded() }
    /// How many characters of a diff line fit across, before it wraps.
    private func cellsAcross(_ a: UIRect, _ s: Float) -> Int { max(Int((a.width - left(s) * 2 - gutter(s) - 8 * s) / max(cellSize.width, 1)), 8) }

    private func shown(_ text: String) -> String { text.replacingOccurrences(of: "\t", with: "    ") }

    private func titleHeight(_ p: PanelPaint, _ a: UIRect, _ s: Float) -> Float {
        guard let r = report else { return 20 * s }
        let units = Array(r.subject.utf16)
        return sol_canvas_paragraph(p.canvas.raw, 0, 0, max(a.width - left(s) * 2 - 24 * s, 60 * s), units, Int32(units.count), 15 * s, 1, 0, 0, 1).rounded(.up)
    }

    private func height(of row: Row, _ p: PanelPaint, _ a: UIRect, _ s: Float) -> Float {
        switch row {
        case .top: return 18 * s + titleHeight(p, a, s) + 6 * s + 18 * s + 18 * s
        case .clean: return 150 * s
        case .section: return 30 * s
        case .file: return 28 * s
        case .gap: return 14 * s
        case .loading: return lineHeight(s) + 6 * s
        case .diff(let line):
            let n = shown(line.text).count
            return lineHeight(s) * Float(max((n + cellsAcross(a, s) - 1) / cellsAcross(a, s), 1))
        }
    }

    private func layoutRows(_ p: PanelPaint, _ a: UIRect, _ s: Float) {
        guard builtFor.width != a.width || builtFor.scale != s || offsets.count != rows.count + 1 else { return }
        builtFor = (a.width, s)
        var y: Float = 0
        offsets = [0]
        offsets.reserveCapacity(rows.count + 1)
        for r in rows {
            y += height(of: r, p, a, s)
            offsets.append(y)
        }
    }

    private var contentHeight: Float { (offsets.last ?? 0) + 12 }

    private func clampScroll(_ a: UIRect) { scrollY = min(max(scrollY, 0), max(contentHeight - a.height, 0)) }

    private func rect(ofRow i: Int, _ a: UIRect) -> UIRect {
        UIRect(x: a.x, y: a.y + offsets[i] - scrollY, width: a.width, height: offsets[i + 1] - offsets[i])
    }

    /// The row at a point: the last one starting at or above it.
    private func row(atY y: Float, _ a: UIRect) -> Int? {
        let at = y - a.y + scrollY
        guard !rows.isEmpty, offsets.count == rows.count + 1, at >= 0, at < offsets[rows.count] else { return nil }
        var lo = 0, hi = rows.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if offsets[mid] <= at { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    // MARK: Drawing

    func draw(on canvas: Canvas, in a: UIRect, scale s: Float) {
        lastArea = a
        let p = PanelPaint(canvas: canvas, scale: s)
        p.backdrop(a, TerminalPalette.page)
        sol_canvas_push_clip(canvas.raw, a.x, a.y, a.width, a.height)
        defer { sol_canvas_pop_clip(canvas.raw) }
        guard report != nil else {
            p.label(failed ? "Couldn't read this commit." : "Loading…", UIRect(x: a.x + left(s), y: a.y + 18 * s, width: a.width - left(s) * 2, height: 22 * s), alpha: 0.55)
            return
        }
        layoutRows(p, a, s)
        clampScroll(a)
        toggleAllRect = nil
        guard let first = row(atY: a.y, a) else { return }
        var i = first
        while i < rows.count, a.y + offsets[i] - scrollY < a.maxY {
            let r = rect(ofRow: i, a)
            switch rows[i] {
            case .top: drawTop(r, p, s)
            case .clean:
                p.icon(0xE73E, UIRect(x: r.x, y: r.y + 30 * s, width: r.width, height: 40 * s), pixels: 28, color: 0x72BD78)
                let text = "This commit doesn't change any files."
                let w = p.width(text, pixels: 13, semibold: true)
                p.label(text, UIRect(x: r.x + (r.width - w) / 2, y: r.y + 80 * s, width: w + 2, height: 20 * s), pixels: 13, semibold: true, alpha: 0.55)
            case .section(let count):
                let title = "FILES"
                let w = p.width(title, pixels: 11, semibold: true)
                p.label(title, UIRect(x: r.x + left(s), y: r.y + 6 * s, width: w + 2, height: 20 * s), pixels: 11, semibold: true, alpha: 0.55)
                p.label("\(count)", UIRect(x: r.x + left(s) + w + 8 * s, y: r.y + 6 * s, width: 60 * s, height: 20 * s), pixels: 11, alpha: 0.4)
            case .file(let e): drawFile(e, r, hovered: hovered == i, p, s)
            case .diff(let line): drawDiff(line, r, a, p, s)
            case .loading: p.label("Loading…", UIRect(x: r.x + left(s) + 14 * s, y: r.y, width: 200 * s, height: r.height), pixels: 11.5, alpha: 0.55)
            case .gap: break
            }
            i += 1
        }
    }

    /// The subject, wrapped; its hash, author and age; the size of the change and Expand All.
    private func drawTop(_ rect: UIRect, _ p: PanelPaint, _ s: Float) {
        guard let c = report else { return }
        let l = left(s), right = rect.maxX - l, top = rect.y + 18 * s
        p.icon(EditorItem.Glyph.commit, UIRect(x: rect.x + l, y: top, width: 16 * s, height: 20 * s), pixels: 13, color: TerminalPalette.accent)
        let units = Array(c.subject.utf16), titleW = max(rect.width - l * 2 - 24 * s, 60 * s)
        let h = sol_canvas_paragraph(p.canvas.raw, rect.x + l + 24 * s, top, titleW, units, Int32(units.count), 15 * s, 1, p.fg, 1, 0).rounded(.up)
        let line = top + h + 6 * s
        // From the right: Expand All, then the size of the change; the rest of the line is the byline's.
        var x = right
        if !entries.isEmpty {
            let title = entries.allSatisfy({ unfolded.contains($0.path) }) ? "Collapse All" : "Expand All"
            let w = p.width(title, pixels: 12, semibold: true)
            x -= w
            let r = UIRect(x: x - 4 * s, y: line - 3 * s, width: w + 8 * s, height: 22 * s)
            toggleAllRect = r
            if hoveredToggle { p.fill(r, TerminalPalette.accent, 0.12, radius: 4) }
            p.label(title, UIRect(x: x, y: line, width: w + 2, height: 16 * s), pixels: 12, semibold: true, color: TerminalPalette.accent)
            x -= 16 * s
        }
        var parts: [(String, UInt32?, Float)] = [("\(c.files.count) file\(c.files.count == 1 ? "" : "s")", nil, 0.55)]
        if c.added > 0 { parts.append(("+\(c.added)", 0x72BD78, 1)) }
        if c.removed > 0 { parts.append(("−\(c.removed)", 0xE06B6B, 1)) }
        for (text, color, alpha) in parts.reversed() {
            let w = p.width(text, pixels: 12, semibold: true)
            x -= w
            p.label(text, UIRect(x: x, y: line, width: w + 2, height: 16 * s), pixels: 12, semibold: true, color: color, alpha: alpha)
            x -= 10 * s
        }
        let byline = "\(c.short)  ·  \(c.author)  ·  \(c.date)"
        p.label(byline, UIRect(x: rect.x + l + 24 * s, y: line, width: max(x - rect.x - l - 30 * s, 0), height: 16 * s), pixels: 12, alpha: 0.55)
        p.fill(UIRect(x: rect.x + l, y: rect.maxY - 8 * s, width: right - rect.x - l, height: 1), p.fg, 0.10)
    }

    /// Its status letter, icon and name, the folder it's in, and how many lines changed.
    private func drawFile(_ e: GitCommitReport.Entry, _ rect: UIRect, hovered: Bool, _ p: PanelPaint, _ s: Float) {
        let l = left(s)
        if hovered { p.fill(UIRect(x: rect.x + 12 * s, y: rect.y + 1, width: rect.width - 24 * s, height: rect.height - 2), p.fg, 0.07, radius: 6) }
        let isFolder = e.path.hasSuffix("/")
        if !isFolder {
            p.icon(unfolded.contains(e.path) ? 0xE70D : 0xE76C, UIRect(x: rect.x + l - 4 * s, y: rect.y, width: 12 * s, height: rect.height), pixels: 8, alpha: 0.6)
        }
        let b = GitLook.badge(e.code)
        p.label(b.letter, UIRect(x: rect.x + l + 14 * s, y: rect.y, width: 14 * s, height: rect.height), pixels: 11.5, semibold: true, color: b.color)
        let clean = isFolder ? String(e.path.dropLast()) : e.path
        let name = clean.split(separator: "/").last.map(String.init) ?? clean
        var x = rect.x + l + 36 * s
        let side = (15 * s).rounded()
        if !FileIcons.draw(name: name, directory: isFolder, x: x, y: (rect.midY - side / 2).rounded(), size: side, on: p.canvas) {
            p.icon(isFolder ? 0xE8B7 : FileKind(name: name).glyph, UIRect(x: x, y: rect.y, width: 16 * s, height: rect.height), pixels: 12,
                   color: isFolder ? TerminalPalette.accent : nil, alpha: isFolder ? 0.85 : 0.6)
        }
        x += 22 * s
        // The line counts on the right first, then the name, then as much of the folder as fits.
        var r = rect.maxX - l - 8 * s
        func count(_ text: String, _ color: UInt32?, _ alpha: Float = 1) {
            let w = p.width(text, pixels: 11.5, semibold: true)
            r -= w
            p.label(text, UIRect(x: r, y: rect.y, width: w + 2, height: rect.height), pixels: 11.5, semibold: true, color: color, alpha: alpha)
            r -= 8 * s
        }
        if let v = e.removed, v > 0 { count("−\(v)", 0xE06B6B) }
        if let v = e.added, v > 0 { count("+\(v)", 0x72BD78) }
        if e.added == nil, e.removed == nil, !isFolder { count("binary", nil, 0.5) }
        let limit = r - 8 * s
        let nameW = min(p.width(name, semibold: true), max(limit - x, 30 * s))
        p.label(name, UIRect(x: x, y: rect.y, width: nameW + 2, height: rect.height), semibold: true, alpha: e.code == "D" ? 0.6 : 0.92)
        x += nameW + 8 * s
        var dir = clean.contains("/") ? String(clean[..<clean.lastIndex(of: "/")!]) : ""
        if let old = e.oldPath { dir = "from \(old)" }
        if !dir.isEmpty, limit - x > 24 * s {
            p.label(dir, UIRect(x: x, y: rect.y, width: limit - x, height: rect.height), pixels: 11.5, alpha: 0.5)
        }
    }

    /// One line of a file's changes: both line numbers, a sign, and the text, wrapped if it's long.
    private func drawDiff(_ line: GitPageLine, _ rect: UIRect, _ a: UIRect, _ p: PanelPaint, _ s: Float) {
        let l = left(s)
        let block = UIRect(x: rect.x + l, y: rect.y, width: rect.width - l * 2, height: rect.height)
        let green: UInt32 = 0x72BD78, red: UInt32 = 0xE06B6B
        var color = p.fg, alpha: Float = 1
        switch line.kind {
        case .added: p.fill(block, green, 0.14)
        case .removed: p.fill(block, red, 0.14)
        case .hunk: p.fill(block, TerminalPalette.accent, 0.10); alpha = 0.55
        case .note: alpha = 0.55
        case .context: alpha = 0.8
        }
        if alpha < 1 { color = TerminalPalette.mix(p.fg, TerminalPalette.background, alpha) }
        let lh = lineHeight(s)
        func gutter(_ n: Int?, right: Float) {
            guard let n else { return }
            let text = "\(n)", w = p.width(text, pixels: 10.5)
            p.label(text, UIRect(x: right - w, y: rect.y, width: w + 2, height: lh), pixels: 10.5, alpha: 0.4)
        }
        gutter(line.old, right: block.x + 36 * s)
        gutter(line.new, right: block.x + 72 * s)
        if line.kind == .added || line.kind == .removed {
            p.label(line.kind == .added ? "+" : "−", UIRect(x: block.x + 78 * s, y: rect.y, width: 12 * s, height: lh), pixels: 12, semibold: true,
                    color: line.kind == .added ? green : red)
        }
        let across = cellsAcross(a, s), chars = Array(shown(line.text))
        let textY = (lh - cellSize.height) / 2
        var start = 0, row = 0
        repeat {
            let piece = String(chars[start..<min(start + across, chars.count)])
            p.mono(piece, x: block.x + self.gutter(s), y: rect.y + Float(row) * lh + textY, maxCells: across, color: color)
            start += across
            row += 1
        } while start < chars.count
    }

    // MARK: Mouse and keys

    func mouse(_ message: UINT, x: Float, y: Float, in a: UIRect, scale s: Float) -> Bool {
        let before = (hovered, hoveredToggle)
        hoveredToggle = toggleAllRect?.contains(x, y) ?? false
        hovered = nil
        if !hoveredToggle, let i = row(atY: y, a), case .file = rows[i] { hovered = i }
        if message == Win.WM_LBUTTONUP {
            if hoveredToggle {
                toggleAll()
            } else if let i = hovered, case .file(let e) = rows[i], !e.path.hasSuffix("/") {
                setUnfolded(!unfolded.contains(e.path), e)
            }
        }
        if before.0 != hovered || before.1 != hoveredToggle { invalidate() }
        return true
    }

    func mouseLeft() {
        guard hovered != nil || hoveredToggle else { return }
        hovered = nil
        hoveredToggle = false
        invalidate()
    }

    func scroll(lines: Int, x: Float, y: Float, in a: UIRect, scale s: Float) {
        scrollY -= Float(lines) * lineHeight(s)
        clampScroll(a)
        invalidate()
    }

    func key(_ key: Int32, shift: Bool, ctrl: Bool) -> Bool {
        let a = lastArea, step = cellSize.height * 3
        switch key {
        case Win.VK_ESCAPE: close()
        case Win.VK_UP: scrollY -= step
        case Win.VK_DOWN: scrollY += step
        case Win.VK_PRIOR: scrollY -= a.height * 0.9
        case Win.VK_NEXT, Win.VK_SPACE: scrollY += a.height * 0.9
        case Win.VK_HOME: scrollY = 0
        case Win.VK_END: scrollY = contentHeight
        case 0x43 where ctrl: copy(hash)
        default: return ctrl
        }
        clampScroll(a)
        invalidate()
        return true
    }

    func typed(_ text: String) {}

    // For tests
    var filePaths: [String] { report?.files.map(\.path) ?? [] }
    func unfold(_ path: String) { if let e = report?.files.first(where: { $0.path == path }) { setUnfolded(true, e) } }
    func diffLines(_ path: String) -> [GitPageLine]? { diffs[path] }
}
