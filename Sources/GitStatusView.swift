import AppKit

// Git Changes (⌃⌘S, or the status bar's list of changes): the repository's state as a page in a tab above the
// terminal, like the Git Graph. The branch and how it stands against its upstream on top, then the changed files
// grouped as git groups them. Clicking a file unfolds its changes right there; a button opens them side by side in
// a sub-tab. It keeps itself current while it's showing. The same page shows one commit from the Git Graph.

/// `git status`, parsed: each file once per place it has changes (a file can be both staged and changed again).
struct GitStatusReport: Equatable {
    struct Entry: Equatable {
        let path: String
        /// What a renamed or copied file was called.
        var oldPath: String?
        /// M, A, D, R, C, T, U (conflict) or ? (untracked).
        let code: Character
        /// Lines added and removed; nil when git doesn't count them (binary files, untracked files).
        var added: Int?
        var removed: Int?
    }

    var root = ""
    var branch = ""
    var detached = false
    var upstream: String?
    var ahead = 0
    var behind = 0
    var lastCommit: String?
    var lastCommitDate: String?
    var conflicts: [Entry] = []
    var staged: [Entry] = []
    var changed: [Entry] = []
    var untracked: [Entry] = []

    /// Set when this is one commit's files (in `changed`) rather than the working tree.
    struct Commit: Equatable {
        let hash: String
        let short: String
        let author: String
        let date: String
        let subject: String
        /// What it's compared with: its first parent, or the empty tree for a repository's first commit.
        let base: String
    }
    var commit: Commit?

    var isClean: Bool { conflicts.isEmpty && staged.isEmpty && changed.isEmpty && untracked.isEmpty }

    /// The top folder; status; staged and unstaged line counts; the last commit, split by the record separator.
    static let script = """
    git rev-parse --show-toplevel && git status --porcelain=v2 --branch -z && printf '\\036' && git diff --cached --numstat -z \
    && printf '\\036' && git diff --numstat -z && printf '\\036' && { git log -1 --format='%s%x00%cr' 2>/dev/null; true; }
    """

    /// The top folder, the commit and what it's compared with; the files changed; their line counts.
    static func script(commit hash: String) -> String {
        """
        h=\(shellQuote(hash)); base=$(git rev-parse -q --verify "$h^" || git hash-object -t tree /dev/null)
        git rev-parse --show-toplevel && git log -1 --format='%H%x1f%h%x1f%an%x1f%ar%x1f%s' "$h" && printf '%s\\036' "$base" \
        && git diff --name-status -M -z "$base" "$h" && printf '\\036' && git diff --numstat -M -z "$base" "$h"
        """
    }

    init?(commitOutput: Data) {
        let parts = String(decoding: commitOutput, as: UTF8.self).components(separatedBy: "\u{1E}")
        guard parts.count == 3 else { return nil }
        let head = parts[0].components(separatedBy: "\n")
        guard head.count == 3, head[0].hasPrefix("/") else { return nil }
        let f = head[1].components(separatedBy: "\u{1F}")
        guard f.count == 5 else { return nil }
        root = head[0]
        commit = Commit(hash: f[0], short: f[1], author: f[2], date: f[3], subject: f[4], base: head[2])
        let lines = Self.lineCounts(parts[2])
        // "M<NUL>path<NUL>", or for a rename or copy "R100<NUL>old<NUL>new<NUL>".
        let names = parts[1].split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i + 1 < names.count {
            guard let code = names[i].first else { break }
            let moved = code == "R" || code == "C"
            guard !moved || i + 2 < names.count else { break }
            let path = moved ? names[i + 2] : names[i + 1]
            changed.append(Entry(path: path, oldPath: moved ? names[i + 1] : nil, code: code, added: lines[path]?.0, removed: lines[path]?.1))
            i += moved ? 3 : 2
        }
    }

    init?(output: Data) {
        let parts = String(decoding: output, as: UTF8.self).components(separatedBy: "\u{1E}")
        guard parts.count == 4, let nl = parts[0].firstIndex(of: "\n") else { return nil }
        root = String(parts[0][..<nl])
        guard root.hasPrefix("/") else { return nil }
        let stagedLines = Self.lineCounts(parts[1]), changedLines = Self.lineCounts(parts[2])
        var oid = ""
        let fields = parts[0][parts[0].index(after: nl)...].split(separator: "\0", omittingEmptySubsequences: false)
        var i = 0
        func entry(_ path: String, old: String? = nil, code: Character, lines: [String: (Int?, Int?)]) -> Entry {
            Entry(path: path, oldPath: old, code: code, added: lines[path]?.0, removed: lines[path]?.1)
        }
        while i < fields.count {
            let f = fields[i]
            i += 1
            if f.hasPrefix("# branch.oid ") {
                oid = String(f.dropFirst(13))
            } else if f.hasPrefix("# branch.head ") {
                branch = String(f.dropFirst(14))
            } else if f.hasPrefix("# branch.upstream ") {
                upstream = String(f.dropFirst(18))
            } else if f.hasPrefix("# branch.ab ") {
                let ab = f.dropFirst(12).split(separator: " ")
                if ab.count == 2 {
                    ahead = Int(ab[0].dropFirst()) ?? 0
                    behind = Int(ab[1].dropFirst()) ?? 0
                }
            } else if let kind = f.first, "12u".contains(kind), f.dropFirst().first == " " {
                // Fields before the path: 8 for ordinary entries, 9 for renames/copies, 10 for conflicts.
                let n = kind == "1" ? 8 : kind == "2" ? 9 : 10
                let p = f.split(separator: " ", maxSplits: n, omittingEmptySubsequences: false)
                var old: String?
                if kind == "2", i < fields.count { old = String(fields[i]); i += 1 }
                guard p.count == n + 1, p[1].count == 2 else { continue }
                let path = String(p[n])
                if kind == "u" {
                    conflicts.append(entry(path, code: "U", lines: [:]))
                    continue
                }
                let x = p[1].first!, y = p[1].last!
                if x != "." { staged.append(entry(path, old: old, code: x, lines: stagedLines)) }
                if y != "." { changed.append(entry(path, code: y, lines: changedLines)) }
            } else if f.hasPrefix("? ") {
                untracked.append(entry(String(f.dropFirst(2)), code: "?", lines: [:]))
            }
        }
        if branch == "(detached)" {
            detached = true
            branch = String(oid.prefix(7))
        }
        let log = parts[3].trimmingCharacters(in: .newlines).components(separatedBy: "\0")
        if log.count == 2, !log[0].isEmpty {
            lastCommit = log[0]
            lastCommitDate = log[1]
        }
    }

    /// `git diff --numstat -z`: "added<TAB>removed<TAB>path", or for a rename an empty path and then both names.
    private static func lineCounts(_ s: String) -> [String: (Int?, Int?)] {
        var out: [String: (Int?, Int?)] = [:]
        let f = s.split(separator: "\0", omittingEmptySubsequences: false)
        var i = 0
        while i < f.count {
            let p = f[i].split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            i += 1
            guard p.count == 3 else { continue }
            var path = String(p[2])
            if path.isEmpty, i + 1 < f.count {
                path = String(f[i + 1])
                i += 2
            }
            out[path] = (Int(p[0]), Int(p[1]))
        }
        return out
    }
}

/// One line of a file's changes, as unfolded under its row.
struct GitDiffLine: Equatable {
    enum Kind { case hunk, added, removed, context, note }
    let kind: Kind
    var old: Int?
    var new: Int?
    let text: String

    /// Lines shown per file; past that, opening it in a tab shows them all.
    static let limit = 3000

    /// `git diff` output: what's in its hunks, without the file headers. A conflict's combined diff has a column
    /// per side and "@@@" hunks, so its lines have no single old and new number.
    static func parse(_ output: Data) -> [GitDiffLine] {
        var out: [GitDiffLine] = []
        var old = 0, new = 0, columns = 1, inHunk = false
        for raw in String(decoding: output, as: UTF8.self).components(separatedBy: "\n") {
            if raw.hasPrefix("Binary files ") || raw.hasPrefix("GIT binary patch") {
                return [GitDiffLine(kind: .note, text: "Binary file: no text changes to show.")]
            }
            if raw.hasPrefix("@@") {
                inHunk = true
                columns = raw.hasPrefix("@@@") ? 2 : 1
                if columns == 1 {
                    // "@@ -12,3 +14,5 @@ the function it's in"
                    let f = raw.split(separator: " ")
                    if f.count > 2 {
                        old = Int(f[1].dropFirst().split(separator: ",").first ?? "") ?? 0
                        new = Int(f[2].dropFirst().split(separator: ",").first ?? "") ?? 0
                    }
                }
                out.append(GitDiffLine(kind: .hunk, text: raw))
                continue
            }
            guard inHunk, !raw.isEmpty, !raw.hasPrefix("\\") else { continue }
            let prefix = raw.prefix(columns), text = String(raw.dropFirst(columns))
            if out.count >= limit {
                out.append(GitDiffLine(kind: .note, text: "Showing the first \(limit) lines. Open it in a tab to see them all."))
                break
            }
            if columns > 1 {
                out.append(GitDiffLine(kind: prefix.contains("+") ? .added : prefix.contains("-") ? .removed : .context, text: text))
            } else if prefix == "+" {
                out.append(GitDiffLine(kind: .added, new: new, text: text))
                new += 1
            } else if prefix == "-" {
                out.append(GitDiffLine(kind: .removed, old: old, text: text))
                old += 1
            } else {
                out.append(GitDiffLine(kind: .context, old: old, new: new, text: text))
                old += 1
                new += 1
            }
        }
        return out
    }

    /// The command for one file: what's staged, what isn't, (for an untracked file) all of it as new, or what a
    /// commit changed against `base`.
    static func script(for e: GitStatusReport.Entry, mode: EditorMode, base: String?) -> String {
        let quoted = shellQuote(":(literal)" + e.path)
        let diff = "git diff --no-color --no-ext-diff"
        let staged = mode == .stagedDiff
        let command: String
        if case .commitDiff(let hash) = mode, let base {
            command = "\(diff) -M \(shellQuote(base)) \(shellQuote(hash)) -- \(quoted)" + (e.oldPath.map { " " + shellQuote(":(literal)" + $0) } ?? "")
        } else if e.code == "?" {
            command = "\(diff) --no-index -- /dev/null \(shellQuote(e.path))"
        } else if staged {
            // Both names, or a rename would look like a whole new file.
            command = "\(diff) --cached -M -- \(quoted)" + (e.oldPath.map { " " + shellQuote(":(literal)" + $0) } ?? "")
        } else {
            command = "\(diff) -- \(quoted)"
        }
        return command + " | head -n \(limit + 20)"
    }
}

/// The page itself, scrolling.
final class GitStatusView: NSView {
    private let scroll = NSScrollView()
    private let rowsView: GitStatusRowsView
    /// Asks for a fresh report; every few seconds while it's showing.
    var onRefresh: (() -> Void)?
    private var timer: Timer?

    /// A file's full path was clicked (or chosen from its menu) to be shown this way.
    var onOpen: ((String, EditorMode) -> Void)? {
        get { rowsView.onOpen }
        set { rowsView.onOpen = newValue }
    }

    init(runner: GitRunner) {
        rowsView = GitStatusRowsView(runner: runner)
        super.init(frame: .zero)
        scroll.documentView = rowsView
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { timer?.invalidate() }

    override var isFlipped: Bool { true }
    /// Takes focus so ⌘W and the other editor commands reach the editor around it.
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        // Catches changes the sidebar wouldn't report (it may be hidden, or on another folder).
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            if NSApp.isActive { self?.onRefresh?() }
        }
    }

    func show(_ report: GitStatusReport) {
        rowsView.report = report
        rowsView.fitSize()
    }

    func applyTheme() { rowsView.needsDisplay = true }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        rowsView.fitSize()
    }

    /// Dev aids (DevTools status-click, status-open, status-all).
    func devClick(_ path: String) { rowsView.devToggle(path) }
    func devOpen(_ path: String) { rowsView.devOpen(path) }
    func devToggleAll() { rowsView.toggleAll() }
}

final class GitStatusRowsView: NSView {
    private enum Row {
        case top
        case clean
        case section(String, Int)
        case file(GitStatusReport.Entry, EditorMode)
        case diff(GitDiffLine)
        case loading
        case gap
    }

    /// A file's place on the page: the same file can be both staged and changed.
    private struct Key: Hashable {
        let path: String
        let staged: Bool
    }

    private let runner: GitRunner
    var report: GitStatusReport? {
        didSet {
            refreshUnfolded()
            guard report != oldValue else { return }
            rebuild()
        }
    }
    var onOpen: ((String, EditorMode) -> Void)?
    private var rows: [Row] = []
    /// Where each row starts, and the end of the last.
    private var offsets: [CGFloat] = [0]
    private var unfolded = Set<Key>()
    private var diffs: [Key: [GitDiffLine]] = [:]
    private var hovered: Int? {
        didSet {
            guard hovered != oldValue else { return }
            for r in [oldValue, hovered].compactMap({ $0 }) where r < rows.count { setNeedsDisplay(rect(ofRow: r)) }
        }
    }
    private var toggleAllRect = NSRect.zero
    private var builtWidth: CGFloat = 0
    private static let left: CGFloat = 24
    private static let lineHeight: CGFloat = 18

    init(runner: GitRunner) {
        self.runner = runner
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func key(_ e: GitStatusReport.Entry, _ mode: EditorMode) -> Key { Key(path: e.path, staged: mode == .stagedDiff) }
    /// What a file's row opens: a commit's files are compared within the commit.
    private var changedMode: EditorMode { report?.commit.map { .commitDiff($0.hash) } ?? .diff }
    private func canUnfold(_ e: GitStatusReport.Entry) -> Bool { !e.path.hasSuffix("/") }
    private var allEntries: [(GitStatusReport.Entry, EditorMode)] {
        rows.compactMap { if case .file(let e, let m) = $0, canUnfold(e) { return (e, m) } else { return nil } }
    }

    private func rebuild() {
        rows = []
        hovered = nil
        if let r = report {
            rows.append(.top)
            if r.isClean { rows.append(.clean) }
            // Staged files show what the next commit would change; the rest, what isn't staged yet.
            for (title, list, mode) in [("Conflicts", r.conflicts, EditorMode.diff), ("Staged", r.staged, .stagedDiff),
                                        (r.commit == nil ? "Changes" : "Files", r.changed, changedMode), ("Untracked", r.untracked, .diff)] where !list.isEmpty {
                rows.append(.section(title, list.count))
                for e in list {
                    rows.append(.file(e, mode))
                    let k = key(e, mode)
                    guard unfolded.contains(k) else { continue }
                    if let lines = diffs[k] {
                        rows += lines.isEmpty ? [.diff(GitDiffLine(kind: .note, text: "No text changes to show."))] : lines.map { .diff($0) }
                    } else {
                        rows.append(.loading)
                    }
                }
                rows.append(.gap)
            }
            // Folded files that have gone stop being remembered.
            let present = Set(allEntries.map { key($0.0, $0.1) })
            unfolded.formIntersection(present)
        }
        layoutRows()
    }

    private func layoutRows() {
        builtWidth = bounds.width
        var y: CGFloat = 0
        offsets = [0]
        offsets.reserveCapacity(rows.count + 1)
        for r in rows {
            y += height(of: r)
            offsets.append(y)
        }
        fitSize()
        needsDisplay = true
    }

    func fitSize() {
        let width = enclosingScrollView?.contentSize.width ?? 0
        let h = (offsets.last ?? 0) + 12
        let size = NSSize(width: width, height: max(h, enclosingScrollView?.contentSize.height ?? 0))
        if size != frame.size { setFrameSize(size) }
        // Long lines wrap, so a new width means new heights.
        if width != builtWidth, width > 0 { layoutRows() }
    }

    private func rect(ofRow i: Int) -> NSRect { NSRect(x: 0, y: offsets[i], width: bounds.width, height: offsets[i + 1] - offsets[i]) }

    // MARK: Unfolding

    private func setUnfolded(_ on: Bool, _ e: GitStatusReport.Entry, _ mode: EditorMode) {
        let k = key(e, mode)
        if on {
            unfolded.insert(k)
            load(e, mode)
        } else {
            unfolded.remove(k)
        }
        rebuild()
    }

    private func load(_ e: GitStatusReport.Entry, _ mode: EditorMode) {
        let k = key(e, mode)
        runner.run(GitDiffLine.script(for: e, mode: mode, base: report?.commit?.base), timeout: 20) { [weak self] _, out, _ in
            guard let self, self.unfolded.contains(k) else { return }
            let lines = GitDiffLine.parse(out)
            guard self.diffs[k] != lines else { return }
            self.diffs[k] = lines
            self.rebuild()
        }
    }

    /// Unfolded files can change without the report changing (the same number of lines, different text).
    private func refreshUnfolded() {
        guard report?.commit == nil else { return }
        for (e, m) in allEntries where unfolded.contains(key(e, m)) { load(e, m) }
    }

    /// Expand All when anything is folded, otherwise Collapse All.
    func toggleAll() {
        let entries = allEntries
        if entries.allSatisfy({ unfolded.contains(key($0.0, $0.1)) }) {
            unfolded.removeAll()
        } else {
            for (e, m) in entries where !unfolded.contains(key(e, m)) {
                unfolded.insert(key(e, m))
                load(e, m)
            }
        }
        rebuild()
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    private func fileRow(at e: NSEvent) -> Int? {
        let at = convert(e.locationInWindow, from: nil).y
        // The last row starting at or above the point.
        var lo = 0, hi = rows.count - 1
        guard hi >= 0, at >= 0, at < offsets[rows.count] else { return nil }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if offsets[mid] <= at { lo = mid } else { hi = mid - 1 }
        }
        if case .file = rows[lo] { return lo }
        return nil
    }

    private func entry(_ i: Int?) -> (GitStatusReport.Entry, EditorMode)? {
        guard let i, rows.indices.contains(i), case .file(let e, let m) = rows[i] else { return nil }
        return (e, m)
    }

    private func full(_ e: GitStatusReport.Entry) -> String { FilePaths.join(report?.root ?? "", e.path) }

    /// The hovered row's button that opens the changes side by side in a sub-tab.
    private func openButton(_ row: NSRect) -> NSRect {
        NSRect(x: bounds.width - Self.left - 20, y: row.midY - 11, width: 22, height: 22)
    }

    override func mouseMoved(with e: NSEvent) { hovered = fileRow(at: e) }
    override func mouseExited(with e: NSEvent) { hovered = nil }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(superview?.superview?.superview)
        let p = convert(e.locationInWindow, from: nil)
        if toggleAllRect.contains(p) { return toggleAll() }
        guard let i = fileRow(at: e), let (entry, mode) = entry(i), canUnfold(entry) else { return }
        if openButton(rect(ofRow: i)).contains(p) { onOpen?(full(entry), mode); return }
        setUnfolded(!unfolded.contains(key(entry, mode)), entry, mode)
    }

    /// Right-click: the changes in a tab, the file itself, and where it is.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let (entry, mode) = entry(fileRow(at: event)) else { return nil }
        let path = full(entry)
        let menu = NSMenu()
        if canUnfold(entry) {
            let title = report?.commit != nil ? "Open Side by Side" : mode == .stagedDiff ? "Open Staged Changes" : "Open Working Tree"
            menu.addItem(ActionMenuItem(title) { [weak self] in self?.onOpen?(path, mode) })
            // A commit's file may not be there any more, or be different now.
            if entry.code != "D", report?.commit == nil { menu.addItem(ActionMenuItem("Open File") { [weak self] in self?.onOpen?(path, .file) }) }
            menu.addItem(.separator())
        }
        menu.addItem(ActionMenuItem("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        })
        return menu
    }

    func devToggle(_ path: String) {
        guard let (e, m) = allEntries.first(where: { $0.0.path == path }) else { return }
        setUnfolded(!unfolded.contains(key(e, m)), e, m)
    }

    func devOpen(_ path: String) {
        if let (e, m) = allEntries.first(where: { $0.0.path == path }) { onOpen?(full(e), m) }
    }

    // MARK: Drawing

    private var diffFont: NSFont { NSFont(descriptor: (FontSet.current.regular as NSFont).fontDescriptor, size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .regular) }
    private static let gutter: CGFloat = 92
    private var diffTextWidth: CGFloat { max(40, bounds.width - Self.left * 2 - Self.gutter - 8) }

    private func shown(_ s: String) -> String { s.replacingOccurrences(of: "\t", with: "    ") }

    private func height(of row: Row) -> CGFloat {
        switch row {
        case .top:
            guard let c = report?.commit else { return 82 }
            return 18 + commitTitleHeight(c.subject) + 6 + 18 + 18
        case .clean: return 150
        case .section: return 30
        case .file: return 28
        case .gap: return 14
        case .loading: return Self.lineHeight + 6
        case .diff(let line):
            let text = shown(line.text)
            guard !text.isEmpty else { return Self.lineHeight }
            let font = diffFont
            // Short plain text is one line without measuring (a page can have thousands); the rest is measured.
            let cell = ("M" as NSString).size(withAttributes: [.font: font]).width
            if text.utf8.count == text.utf16.count, CGFloat(text.utf8.count) * cell <= diffTextWidth { return Self.lineHeight }
            let h = (text as NSString).boundingRect(with: NSSize(width: diffTextWidth, height: 100_000), options: [.usesLineFragmentOrigin],
                                                    attributes: [.font: font, .paragraphStyle: Self.diffParagraph]).height
            return max(Self.lineHeight, ceil(h / Self.lineHeight) * Self.lineHeight)
        }
    }

    private static let diffParagraph: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byCharWrapping
        p.minimumLineHeight = lineHeight
        p.maximumLineHeight = lineHeight
        return p
    }()

    override func draw(_ dirtyRect: NSRect) {
        let th = Config.shared.theme
        guard offsets.count == rows.count + 1 else { return }
        // Only what's on screen: a page of unfolded files can be thousands of rows.
        var lo = 0, hi = rows.count - 1
        guard hi >= 0 else { return }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if offsets[mid] <= dirtyRect.minY { lo = mid } else { hi = mid - 1 }
        }
        var i = lo
        while i < rows.count, offsets[i] < dirtyRect.maxY {
            let rect = rect(ofRow: i)
            switch rows[i] {
            case .top: drawTop(rect, th)
            case .clean: drawClean(rect, th)
            case .section(let title, let n): drawSection(title, n, rect, th)
            case .file(let e, let m): drawFile(e, m, rect, hovered: hovered == i, th)
            case .diff(let line): drawDiff(line, rect, th)
            case .loading:
                ("Loading…" as NSString).draw(at: NSPoint(x: Self.left + 14, y: rect.minY + 3),
                                              withAttributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: th.dimText])
            case .gap: break
            }
            i += 1
        }
    }

    /// One line of a file's changes: both line numbers, a sign, and the text, wrapped if it's long.
    private func drawDiff(_ line: GitDiffLine, _ rect: NSRect, _ th: Theme) {
        let block = NSRect(x: Self.left, y: rect.minY, width: bounds.width - Self.left * 2, height: rect.height)
        let green = GitTreeStatus.badge("A").color, red = GitTreeStatus.badge("D").color
        let wash: NSColor?, sign: String, color: NSColor
        switch line.kind {
        case .added: (wash, sign, color) = (green.withAlphaComponent(th.isDark ? 0.14 : 0.18), "+", th.foreground)
        case .removed: (wash, sign, color) = (red.withAlphaComponent(th.isDark ? 0.14 : 0.16), "−", th.foreground)
        case .hunk: (wash, sign, color) = (th.accent.withAlphaComponent(0.1), "", th.dimText)
        case .note: (wash, sign, color) = (nil, "", th.dimText)
        case .context: (wash, sign, color) = (nil, "", th.foreground.withAlphaComponent(0.8))
        }
        if let wash {
            wash.setFill()
            block.fill()
        }
        let font = diffFont
        let number: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular), .foregroundColor: th.dimText.withAlphaComponent(0.7)]
        func gutter(_ n: Int?, right: CGFloat) {
            guard let n else { return }
            let s = "\(n)"
            (s as NSString).draw(at: NSPoint(x: right - width(s, number), y: rect.minY + 2), withAttributes: number)
        }
        gutter(line.old, right: block.minX + 36)
        gutter(line.new, right: block.minX + 72)
        let signColor = line.kind == .added ? green : red
        (sign as NSString).draw(at: NSPoint(x: block.minX + 78, y: rect.minY), withAttributes: [.font: font, .foregroundColor: signColor])
        (shown(line.text) as NSString).draw(with: NSRect(x: block.minX + Self.gutter, y: rect.minY, width: diffTextWidth, height: rect.height),
                                            options: [.usesLineFragmentOrigin],
                                            attributes: [.font: font, .foregroundColor: color, .paragraphStyle: Self.diffParagraph])
    }

    private func symbol(_ name: String, _ color: NSColor, _ size: CGFloat, _ weight: NSFont.Weight = .medium) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight).applying(.init(paletteColors: [color])))
    }

    private func width(_ s: String, _ attrs: [NSAttributedString.Key: Any]) -> CGFloat { ceil((s as NSString).size(withAttributes: attrs).width) }

    private func truncating(_ mode: NSLineBreakMode) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = mode
        return p
    }

    private static let commitTitleFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
    private var commitTitleWidth: CGFloat { max(60, bounds.width - Self.left * 2 - 24) }

    private func commitTitleHeight(_ subject: String) -> CGFloat {
        ceil((subject as NSString).boundingRect(with: NSSize(width: commitTitleWidth, height: 1000), options: [.usesLineFragmentOrigin],
                                                attributes: [.font: Self.commitTitleFont]).height)
    }

    /// The commit's subject, wrapped; its hash, author and age; the size of the change.
    private func drawCommitTop(_ c: GitStatusReport.Commit, _ r: GitStatusReport, _ rect: NSRect, _ th: Theme) {
        let right = bounds.width - Self.left
        let top = rect.minY + 18
        if let img = symbol("smallcircle.filled.circle", th.accent, 14, .semibold) {
            img.draw(in: NSRect(x: Self.left, y: top + 2, width: img.size.width, height: img.size.height))
        }
        let h = commitTitleHeight(c.subject)
        (c.subject as NSString).draw(with: NSRect(x: Self.left + 24, y: top, width: commitTitleWidth, height: h), options: [.usesLineFragmentOrigin],
                                     attributes: [.font: Self.commitTitleFont, .foregroundColor: th.foreground])
        let line = top + h + 6
        // From the right: Expand All, then the size of the change; the rest of the line is the byline's.
        var x = right
        toggleAllRect = .zero
        let entries = allEntries
        if !entries.isEmpty {
            let title = entries.allSatisfy({ unfolded.contains(key($0.0, $0.1)) }) ? "Collapse All" : "Expand All"
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: th.accent]
            x -= width(title, attrs)
            toggleAllRect = NSRect(x: x - 4, y: line - 4, width: right - x + 8, height: 22)
            (title as NSString).draw(at: NSPoint(x: x, y: line), withAttributes: attrs)
            x -= 16
        }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        var parts: [(String, NSColor)] = [("\(r.changed.count) file\(r.changed.count == 1 ? "" : "s")", th.dimText)]
        let added = r.changed.compactMap(\.added).reduce(0, +), removed = r.changed.compactMap(\.removed).reduce(0, +)
        if added > 0 { parts.append(("+\(added)", GitTreeStatus.badge("A").color)) }
        if removed > 0 { parts.append(("−\(removed)", GitTreeStatus.badge("D").color)) }
        for (s, color) in parts.reversed() {
            x -= width(s, [.font: font])
            (s as NSString).draw(at: NSPoint(x: x, y: line), withAttributes: [.font: font, .foregroundColor: color])
            x -= 10
        }
        let byline = "\(c.short)  ·  \(c.author)  ·  \(c.date)"
        (byline as NSString).draw(in: NSRect(x: Self.left + 24, y: line, width: max(0, x - Self.left - 30), height: 16),
                                  withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: th.dimText, .paragraphStyle: truncating(.byTruncatingTail)])
        th.border.setFill()
        NSRect(x: Self.left, y: rect.maxY - 8, width: right - Self.left, height: 1).fill()
    }

    /// The branch, how it stands against its upstream, and the last commit; the size of the changes on the right.
    private func drawTop(_ rect: NSRect, _ th: Theme) {
        guard let r = report else { return }
        if let c = r.commit { return drawCommitTop(c, r, rect, th) }
        let right = bounds.width - Self.left
        var x = Self.left
        let line1 = rect.minY + 18
        if let img = symbol(r.detached ? "circle.dotted" : "arrow.triangle.branch", th.accent, 15, .semibold) {
            img.draw(in: NSRect(x: x, y: line1 + (22 - img.size.height) / 2, width: img.size.width, height: img.size.height))
            x += img.size.width + 8
        }
        // What's on the right is laid out first, so the branch gives way to it.
        var summary: [(String, NSColor)] = []
        let files = Set((r.conflicts + r.staged + r.changed + r.untracked).map(\.path)).count
        if files > 0 { summary.append(("\(files) file\(files == 1 ? "" : "s")", th.dimText)) }
        let added = (r.staged + r.changed).compactMap(\.added).reduce(0, +), removed = (r.staged + r.changed).compactMap(\.removed).reduce(0, +)
        if added > 0 { summary.append(("+\(added)", GitTreeStatus.badge("A").color)) }
        if removed > 0 { summary.append(("−\(removed)", GitTreeStatus.badge("D").color)) }
        let summaryFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let summaryW = summary.reduce(CGFloat(0)) { $0 + width($1.0, [.font: summaryFont]) + 10 }
        var sx = right - summaryW + 10
        for (s, c) in summary {
            (s as NSString).draw(at: NSPoint(x: sx, y: line1 + 3), withAttributes: [.font: summaryFont, .foregroundColor: c])
            sx += width(s, [.font: summaryFont]) + 10
        }
        let limit = right - summaryW - 16
        let nameAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: th.foreground,
                                                        .paragraphStyle: truncating(.byTruncatingMiddle)]
        let nameW = min(width(r.branch, nameAttrs), max(40, limit - x))
        (r.branch as NSString).draw(in: NSRect(x: x, y: line1, width: nameW, height: 22), withAttributes: nameAttrs)
        x += nameW + 10
        // Against its upstream: a pill for each way it differs, or "up to date".
        let pillFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        var pills: [(String, NSColor)] = []
        if r.ahead > 0 { pills.append(("↑ \(r.ahead)", th.accent)) }
        if r.behind > 0 { pills.append(("↓ \(r.behind)", GitTreeStatus.badge("M").color)) }
        for (s, c) in pills {
            let w = width(s, [.font: pillFont]) + 14
            guard x + w < limit else { break }
            let pill = NSRect(x: x, y: line1 + 2, width: w, height: 18)
            c.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 9, yRadius: 9).fill()
            (s as NSString).draw(at: NSPoint(x: x + 7, y: line1 + 4), withAttributes: [.font: pillFont, .foregroundColor: c])
            x += w + 6
        }
        let upstream = r.detached ? "detached HEAD" : r.upstream.map { pills.isEmpty ? "up to date with \($0)" : $0 } ?? "not pushed yet"
        let dim: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: th.dimText, .paragraphStyle: truncating(.byTruncatingTail)]
        if limit - x > 40 { (upstream as NSString).draw(in: NSRect(x: x + 2, y: line1 + 4, width: limit - x - 2, height: 16), withAttributes: dim) }
        // The last commit, then a line under it all.
        if let c = r.lastCommit {
            let text = c + (r.lastCommitDate.map { " · \($0)" } ?? "")
            (text as NSString).draw(in: NSRect(x: Self.left, y: line1 + 28, width: right - Self.left - 110, height: 16), withAttributes: dim)
        }
        toggleAllRect = .zero
        let entries = allEntries
        if !entries.isEmpty {
            let title = entries.allSatisfy({ unfolded.contains(key($0.0, $0.1)) }) ? "Collapse All" : "Expand All"
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: th.accent]
            let w = width(title, attrs)
            toggleAllRect = NSRect(x: right - w - 4, y: line1 + 24, width: w + 8, height: 22)
            (title as NSString).draw(at: NSPoint(x: right - w, y: line1 + 28), withAttributes: attrs)
        }
        th.border.setFill()
        NSRect(x: Self.left, y: rect.maxY - 8, width: right - Self.left, height: 1).fill()
    }

    private func drawClean(_ rect: NSRect, _ th: Theme) {
        let green = GitTreeStatus.badge("A").color
        if let img = symbol("checkmark.circle", green, 30, .regular) {
            img.draw(in: NSRect(x: bounds.midX - img.size.width / 2, y: rect.minY + 38, width: img.size.width, height: img.size.height))
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: th.dimText]
        let s = report?.commit != nil ? "This commit doesn't change any files." : "Nothing to commit. The working tree is clean."
        (s as NSString).draw(at: NSPoint(x: bounds.midX - width(s, attrs) / 2, y: rect.minY + 84), withAttributes: attrs)
    }

    private func drawSection(_ title: String, _ count: Int, _ rect: NSRect, _ th: Theme) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: th.dimText, .kern: 0.8]
        let t = title.uppercased()
        (t as NSString).draw(at: NSPoint(x: Self.left, y: rect.minY + 9), withAttributes: attrs)
        let countAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: th.dimText.withAlphaComponent(0.7)]
        ("\(count)" as NSString).draw(at: NSPoint(x: Self.left + width(t, attrs) + 8, y: rect.minY + 9), withAttributes: countAttrs)
    }

    /// Its status letter, icon and name, the folder it's in, and how many lines changed.
    private func drawFile(_ e: GitStatusReport.Entry, _ mode: EditorMode, _ rect: NSRect, hovered: Bool, _ th: Theme) {
        if hovered {
            th.foreground.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 12, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        let b = GitTreeStatus.badge(e.code)
        let textY = rect.minY + 6
        if canUnfold(e), let img = symbol(unfolded.contains(key(e, mode)) ? "chevron.down" : "chevron.right", th.dimText, 9, .semibold) {
            img.draw(in: NSRect(x: Self.left + 4 - img.size.width / 2, y: rect.midY - img.size.height / 2, width: img.size.width, height: img.size.height))
        }
        let letter: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: b.color]
        (b.letter as NSString).draw(at: NSPoint(x: Self.left + 16, y: textY + 1), withAttributes: letter)
        let isFolder = e.path.hasSuffix("/")
        let clean = isFolder ? String(e.path.dropLast()) : e.path
        let name = (clean as NSString).lastPathComponent
        var x = Self.left + 36
        let icon = IconPacks.current?.icon(forName: name, directory: isFolder, light: !th.isDark)
            ?? symbol(isFolder ? "folder.fill" : FileSidebarView.symbol(for: name), isFolder ? th.accent.withAlphaComponent(0.85) : th.dimText, 11, .regular)
        if let icon {
            let side = min(16, max(icon.size.width, icon.size.height))
            icon.draw(in: NSRect(x: x + (16 - side) / 2, y: rect.midY - side / 2, width: side, height: side))
        }
        x += 22
        // The line counts on the right first, then the name, then as much of the folder as fits.
        let right = bounds.width - Self.left
        var r = right - 26
        if hovered, canUnfold(e), let img = symbol("arrow.up.forward.square", th.foreground.withAlphaComponent(0.7), 12) {
            let box = openButton(rect)
            img.draw(in: NSRect(x: box.midX - img.size.width / 2, y: box.midY - img.size.height / 2, width: img.size.width, height: img.size.height))
        }
        let stats = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        if let v = e.removed, v > 0 {
            let s = "−\(v)"
            r -= width(s, [.font: stats])
            (s as NSString).draw(at: NSPoint(x: r, y: textY + 1), withAttributes: [.font: stats, .foregroundColor: GitTreeStatus.badge("D").color])
            r -= 8
        }
        if let v = e.added, v > 0 {
            let s = "+\(v)"
            r -= width(s, [.font: stats])
            (s as NSString).draw(at: NSPoint(x: r, y: textY + 1), withAttributes: [.font: stats, .foregroundColor: GitTreeStatus.badge("A").color])
            r -= 8
        }
        if e.added == nil, e.removed == nil, e.code != "?", !isFolder, e.code != "U" {
            let s = "binary"
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: th.dimText.withAlphaComponent(0.7)]
            r -= width(s, a)
            (s as NSString).draw(at: NSPoint(x: r, y: textY + 1), withAttributes: a)
            r -= 8
        }
        let limit = r - 8
        let nameAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12.5, weight: .medium), .paragraphStyle: truncating(.byTruncatingMiddle),
                                                        .foregroundColor: e.code == "D" ? th.foreground.withAlphaComponent(0.6) : th.foreground.withAlphaComponent(0.92)]
        let nameW = min(width(name, nameAttrs), max(30, limit - x))
        (name as NSString).draw(in: NSRect(x: x, y: textY, width: nameW, height: 17), withAttributes: nameAttrs)
        x += nameW + 8
        var dir = (clean as NSString).deletingLastPathComponent
        if let old = e.oldPath { dir = "from \(old)" }
        if !dir.isEmpty, limit - x > 24 {
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: th.dimText, .paragraphStyle: truncating(.byTruncatingHead)]
            (dir as NSString).draw(in: NSRect(x: x, y: textY + 1, width: limit - x, height: 16), withAttributes: a)
        }
    }
}
