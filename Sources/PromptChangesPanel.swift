import AppKit

// "Files changed this prompt", over a pane running Claude Code on this Mac: a small frosted pill in the pane's top
// right once the prompt you last sent has changed a file, and clicking it opens a frosted panel there listing the files,
// each unfolding to show its diff. A click outside the panel, Esc or ✕ folds it back to the pill. What changed comes
// from git when the pane's in a repository, else from the transcript's record of the agent's edits (see
// Core/PromptChanges.swift).

/// Follows one pane's Claude Code session: its prompts, a snapshot of the working tree as each was sent, and what's
/// changed since the latest one.
final class PromptChangesTracker {
    var onChange: (() -> Void)?

    /// What one prompt changed: from git between the working tree as it was sent and as the next was (or now, for the
    /// latest), or from the transcript's record of the agent's edits for one sent before Solanum was watching.
    struct Entry: Equatable {
        let prompt: AgentPrompt
        var files: [ChangedFile]
        var fromGit: Bool
    }

    /// Every prompt of the session Solanum knows of, oldest first, with what it changed.
    private(set) var entries: [Entry] = []
    /// Everything changed in the chat: from git since the first prompt Solanum saw sent, else the edits added up.
    private(set) var chatFiles: [ChangedFile] = []
    private(set) var chatFromGit = false
    /// The chat's changes since the first prompt Solanum saw sent, from git (the rest of `chatFiles` is the edits of
    /// the prompts before it).
    private var gitChat: [ChangedFile] = []

    /// The prompts before the first one with a snapshot: what they changed is only known from their edits.
    private var beforeWatching: [Entry] {
        let first = entries.firstIndex { snapshots[$0.prompt.id] != nil } ?? entries.count
        return Array(entries.prefix(first))
    }

    /// The whole chat: the edits of the prompts from before Solanum was watching, and git's changes since, a file once.
    private func updateChat() {
        let next = Self.addedUp(beforeWatching.map(\.files) + [gitChat])
        let git = beforeWatching.allSatisfy { $0.files.isEmpty } && !gitChat.isEmpty
        if next != chatFiles || git != chatFromGit { chatFiles = next; chatFromGit = git; onChange?() }
    }

    /// What the pill speaks for: the latest prompt, or, when that's changed nothing (yet), the last one that did.
    var pillEntry: Entry? { entries.last { !$0.files.isEmpty } }
    var prompt: AgentPrompt? { pillEntry?.prompt }
    var files: [ChangedFile] { pillEntry?.files ?? [] }
    var fromGit: Bool { pillEntry?.fromGit ?? false }
    /// The repository's top folder, when the pane's in one.
    private(set) var root: String?
    /// The tree each finished prompt left (the next one's snapshot), worked out once.
    private var finished: Set<String> = []
    /// The pane's folder: outside a repository, files are shown from here.
    private var cwd: String?
    /// What `files`' paths are relative to.
    private var base: String? { root ?? cwd }

    private var session: String?
    private var transcript: String?
    private var offset: UInt64 = 0
    private var partial = Data()
    private var scan = PromptChanges.Scan()
    /// The working tree as each prompt was sent: a tree object, by prompt.
    private var snapshots: [String: String] = [:]
    private var reading = false
    /// A prompt sent before the repository's folder was known: snapshotted once it is.
    private var pendingSnapshot: String?
    private var refreshing = false
    private var refreshAgain = false
    private var lastLookForTranscript = Date.distantPast
    private var lastRefresh = Date.distantPast
    private let queue = DispatchQueue(label: "solanum.prompt-changes", qos: .utility)

    /// Called every second while Claude Code runs in the pane: `session` is its session (a new one after /clear),
    /// `cwd` the pane's folder, `working` whether it's busy (what's changed is looked at again while it is).
    func tick(session id: String?, cwd: String?, working: Bool) {
        if let cwd { self.cwd = cwd }
        if id != session {
            session = id
            transcript = nil
            offset = 0
            partial = Data()
            scan = PromptChanges.Scan()
            entries = []
            chatFiles = []
            gitChat = []
            snapshots = [:]
            finished = []
            onChange?()
        }
        if root == nil, let cwd { findRoot(cwd) }
        if transcript == nil, let id, Date().timeIntervalSince(lastLookForTranscript) > 3 {
            lastLookForTranscript = Date()
            transcript = ClaudeSessions.transcript(id)
        }
        read()
        // While it works, looked at again every few seconds (and as soon as the transcript grows, in `take`); while it's
        // idle, now and then, for changes made by hand.
        if Date().timeIntervalSince(lastRefresh) > (working ? 3 : 30) { refresh() }
    }

    /// For tests (DevTools): follows this transcript, as if its session were running here.
    func follow(transcript path: String, cwd: String?) {
        session = "dev"
        transcript = path
        self.cwd = cwd
        if let cwd { findRoot(cwd) }
        read()
    }

    private func findRoot(_ cwd: String) {
        queue.async { [weak self] in
            let o = LocalGit.runNow(cwd, ["rev-parse", "--show-toplevel"])
            let top = o.ok ? o.out.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            DispatchQueue.main.async {
                guard let self, let top, self.root == nil else { return }
                self.root = top
                if let id = self.pendingSnapshot, id == self.entries.last?.prompt.id { self.snapshot(id, root: top) }
                self.pendingSnapshot = nil
            }
        }
    }

    /// Reads what's been added to the transcript: at first just its end (where the latest prompt is), then what's new.
    private func read() {
        guard !reading, let path = transcript else { return }
        reading = true
        let from = offset
        queue.async { [weak self] in
            guard let h = FileHandle(forReadingAtPath: path) else { DispatchQueue.main.async { self?.reading = false }; return }
            defer { try? h.close() }
            let size = h.seekToEndOfFile()
            var data = Data()
            var first = false
            if from == 0 || size < from {
                first = true
                data = ClaudeTranscript.tail(of: path, bytes: 4 << 20) ?? Data()
            } else if size > from {
                h.seek(toFileOffset: from)
                data = h.readData(ofLength: Int(min(size - from, 64 << 20)))
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.reading = false
                guard self.transcript == path else { return }
                self.offset = size
                self.take(data, first: first)
            }
        }
    }

    private func take(_ data: Data, first: Bool) {
        var bytes = first ? data : partial + data
        // A line still being written waits for the rest.
        if let nl = bytes.lastIndex(of: UInt8(ascii: "\n")) {
            partial = bytes.subdata(in: bytes.index(after: nl)..<bytes.endIndex)
            bytes = bytes.subdata(in: bytes.startIndex..<bytes.index(after: nl))
        } else {
            partial = bytes
            return
        }
        let before = scan.latest?.id
        PromptChanges.scan(bytes, into: &scan)
        rebuildEntries()
        updateChat()
        guard let latest = scan.latest else { return }
        if latest.id != before {
            onChange?()
            // A prompt just sent: the working tree as it is now is what its changes are measured from, and where the one
            // before it ended. (One already in the transcript when Solanum started watching is too late for that: its
            // edits stand in.)
            if !first { if let root { snapshot(latest.id, root: root) } else { pendingSnapshot = latest.id } }
        }
        refresh()
    }

    /// The entries for the prompts read so far: git's files kept where they've been worked out, the transcript's edits
    /// for the rest.
    private func rebuildEntries() {
        let known = Dictionary(entries.map { ($0.prompt.id, $0) }, uniquingKeysWith: { a, _ in a })
        entries = scan.prompts.map { p in
            if let e = known[p.id], e.fromGit { return e }
            return Entry(prompt: p, files: editedFiles(p.id), fromGit: false)
        }
    }

    /// The latest prompt whose text is what's on a prompt's box in the terminal ("❯ fix the …", wrapped over lines,
    /// maybe cut short): compared by their start, spaces aside.
    func entry(matching typed: String) -> Entry? {
        func squeeze(_ s: String) -> String {
            var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("❯") { t.removeFirst() }
            return t.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).joined(separator: " ")
        }
        let shown = squeeze(typed)
        guard shown.count >= 2 else { return nil }
        return entries.last { e in
            let full = squeeze(e.prompt.text)
            let n = min(40, shown.count, full.count)
            return n > 0 && full.prefix(n) == shown.prefix(n)
        }
    }

    /// A prompt's files from the transcript's record of its edits.
    private func editedFiles(_ id: String) -> [ChangedFile] {
        PromptChanges.files(from: scan.edits[id] ?? [], root: base).map { f in
            guard f.path.hasPrefix("/") else { return f }
            return ChangedFile(path: (f.path as NSString).abbreviatingWithTildeInPath, change: f.change, added: f.added, removed: f.removed, binary: f.binary)
        }
    }

    // MARK: Git

    /// The working tree now, as a tree object: all its files (untracked ones too, ignored ones not), through a scratch
    /// index so the repository's own index, and everything else in it, stays as it was.
    static func tree(_ root: String) -> String? {
        let fm = FileManager.default
        let scratch = NSTemporaryDirectory() + "solanum-prompt-index-" + UUID().uuidString
        // Starting from the real index, git only reads the files that changed since it was written.
        let real = LocalGit.runNow(root, ["rev-parse", "--path-format=absolute", "--git-path", "index"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
        try? fm.removeItem(atPath: scratch)
        if !real.isEmpty { try? fm.copyItem(atPath: real, toPath: scratch) }
        defer { try? fm.removeItem(atPath: scratch) }
        let env = ["GIT_INDEX_FILE": scratch]
        guard LocalGit.runNow(root, ["add", "-A"], env: env).ok else { return nil }
        let t = LocalGit.runNow(root, ["write-tree"], env: env)
        return t.ok ? t.out.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    private func snapshot(_ id: String, root: String) {
        queue.async { [weak self] in
            guard let tree = Self.tree(root) else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.snapshots[id] = tree
                self.finishBefore(id, root: root)
                self.refresh()
            }
        }
    }

    /// The prompt before `id` is over: what it changed is fixed now, from its snapshot to `id`'s.
    private func finishBefore(_ id: String, root: String) {
        guard let i = entries.firstIndex(where: { $0.prompt.id == id }), i > 0 else { return }
        let prev = entries[i - 1].prompt.id
        guard let from = snapshots[prev], let to = snapshots[id], !finished.contains(prev) else { return }
        finished.insert(prev)
        queue.async { [weak self] in
            let files = Self.changes(root, from, to)
            DispatchQueue.main.async {
                guard let self, let files, let j = self.entries.firstIndex(where: { $0.prompt.id == prev }) else { return }
                self.entries[j].files = files
                self.entries[j].fromGit = true
                self.onChange?()
            }
        }
    }

    /// The files changed between two trees, with git's counts.
    static func changes(_ root: String, _ from: String, _ to: String) -> [ChangedFile]? {
        let raw = LocalGit.runNow(root, ["diff-tree", "-r", "--no-renames", "-z", "--raw", from, to])
        guard raw.ok else { return nil }
        let num = LocalGit.runNow(root, ["diff-tree", "-r", "--no-renames", "-z", "--numstat", from, to]).out
        return PromptChanges.files(raw: raw.out, numstat: num)
    }

    /// The trees a diff is between: for an entry, its snapshot and the next prompt's (or the working tree now, for the
    /// latest); for the whole chat (`id` nil), the first snapshot and now. Nil when there's no snapshot to start from.
    private func span(_ id: String?) -> (from: String, to: String?)? {
        let withTrees = entries.filter { snapshots[$0.prompt.id] != nil }
        guard let id else { return withTrees.first.flatMap { snapshots[$0.prompt.id] }.map { ($0, nil) } }
        guard let i = entries.firstIndex(where: { $0.prompt.id == id }), let from = snapshots[id] else { return nil }
        let next = entries.dropFirst(i + 1).first.flatMap { snapshots[$0.prompt.id] }
        return (from, next)
    }

    /// Works out what the latest prompt has changed so far, and the whole chat (once at a time; asked again meanwhile,
    /// once more after).
    func refresh() {
        guard let latest = entries.last else { return }
        guard !refreshing else { refreshAgain = true; return }
        lastRefresh = Date()
        let id = latest.prompt.id
        let base = snapshots[id]
        let start = span(nil)?.from
        guard let root, base != nil || start != nil else {
            // No snapshot at all: the transcript's edits, for the chat too.
            gitChat = []
            updateChat()
            return
        }
        refreshing = true
        queue.async { [weak self] in
            let now = Self.tree(root)
            let latestFiles = now.flatMap { n in base.flatMap { Self.changes(root, $0, n) } }
            let chat = now.flatMap { n in start.flatMap { Self.changes(root, $0, n) } }
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshing = false
                var changed = false
                if let latestFiles, let i = self.entries.firstIndex(where: { $0.prompt.id == id }), !self.finished.contains(id),
                   self.entries[i].files != latestFiles || !self.entries[i].fromGit {
                    self.entries[i].files = latestFiles
                    self.entries[i].fromGit = true
                    changed = true
                }
                if let chat { self.gitChat = chat }
                if changed { self.onChange?() }
                self.updateChat()
                if self.refreshAgain { self.refreshAgain = false; self.refresh() }
            }
        }
    }

    /// Files from several prompts as one list: a file once, its counts added up.
    static func addedUp(_ lists: [[ChangedFile]]) -> [ChangedFile] {
        var out: [ChangedFile] = []
        for f in lists.joined() {
            if let i = out.firstIndex(where: { $0.path == f.path }) {
                out[i].added += f.added
                out[i].removed += f.removed
            } else {
                out.append(f)
            }
        }
        return out
    }

    /// Every changed file's diff for the prompt `id` (or the whole chat, for nil), by path: one snapshot and one diff.
    func diffs(prompt id: String?, done: @escaping ([String: DiffFile]) -> Void) {
        // The whole chat: the files only the edits know of, from them, the others from git.
        if id == nil, let root, let span = span(nil) {
            let gitPaths = Set(gitChat.map(\.path))
            var out: [String: DiffFile] = [:]
            for f in chatFiles where !gitPaths.contains(f.path) { if let d = editDiff(f.path, ids: beforeWatching.map(\.prompt.id)) { out[f.path] = d } }
            return queue.async {
                if let to = span.to ?? Self.tree(root) {
                    for f in DiffFile.parse(LocalGit.runNow(root, ["diff", "--no-renames", "--no-color", "--no-ext-diff", span.from, to]).out) { out[f.path] = f }
                }
                DispatchQueue.main.async { done(out) }
            }
        }
        guard let root, let span = span(id) else {
            let paths = id.map { pid in entries.first { $0.prompt.id == pid }?.files ?? [] } ?? chatFiles
            var out: [String: DiffFile] = [:]
            let group = DispatchGroup()
            for f in paths { group.enter(); diff(f.path, prompt: id) { d in out[f.path] = d; group.leave() } }
            return group.notify(queue: .main) { done(out) }
        }
        queue.async {
            var out: [String: DiffFile] = [:]
            if let to = span.to ?? Self.tree(root) {
                for f in DiffFile.parse(LocalGit.runNow(root, ["diff", "--no-renames", "--no-color", "--no-ext-diff", span.from, to]).out) { out[f.path] = f }
            }
            DispatchQueue.main.async { done(out) }
        }
    }

    /// The diff of a changed file for the prompt `id` (or the whole chat, for nil).
    func diff(_ path: String, prompt id: String?, done: @escaping (DiffFile?) -> Void) {
        // The whole chat, for a file git hasn't seen change since it started watching: from the edits before then.
        if id == nil, !gitChat.contains(where: { $0.path == path }) {
            return done(editDiff(path, ids: entries.map(\.prompt.id)))
        }
        guard let root, let span = span(id) else {
            // From the transcript's edits: the prompt's own, or every prompt's for the file.
            return done(editDiff(path, ids: id.map { [$0] } ?? entries.map(\.prompt.id)))
        }
        queue.async {
            var f: DiffFile?
            if let to = span.to ?? Self.tree(root) {
                f = DiffFile.parse(LocalGit.runNow(root, ["diff", "--no-renames", "--no-color", "--no-ext-diff", span.from, to, "--", path]).out).first
            }
            DispatchQueue.main.async { done(f) }
        }
    }

    /// A file's diff from the transcript's edits by the prompts `ids`, one after another.
    private func editDiff(_ path: String, ids: [String]) -> DiffFile? {
        let edits = ids.flatMap { scan.edits[$0] ?? [] }.filter {
            PromptChanges.relative($0.path, to: base) == path || ($0.path as NSString).abbreviatingWithTildeInPath == path
        }
        guard var f = edits.first else { return nil }
        for more in edits.dropFirst() { f.lines += more.lines }
        return f
    }

    /// Where `path` (one of `files`) is on disk.
    func absolute(_ path: String) -> String {
        if path.hasPrefix("/") || path.hasPrefix("~") { return (path as NSString).expandingTildeInPath }
        return (base.map { $0 + "/" } ?? "") + path
    }
}

// MARK: - The pill and the panel

/// The pill and the panel for one pane: made by the pane once Claude Code runs there, laid out by it.
final class PromptChangesController {
    let tracker = PromptChangesTracker()
    private weak var pane: TerminalView?
    private let pill = PromptChangesPill()
    private let pillCard = FrostedCard()
    private let panel = PromptChangesPanelView()
    private(set) var expanded = false
    private var outsideClicks: Any?
    /// The pane's agent is running (else nothing shows).
    var active = false { didSet { if active != oldValue { update() } } }

    init(pane: TerminalView) {
        self.pane = pane
        pill.controller = self
        panel.controller = self
        pill.usesCursorRects = true
        panel.canvas.usesCursorRects = true
        tracker.onChange = { [weak self] in self?.changed() }
        pillCard.isHidden = true
        panel.isHidden = true
        pillCard.body.addSubview(pill)
        pane.addSubview(pillCard)
        pane.addSubview(panel)
    }

    deinit { if let m = outsideClicks { NSEvent.removeMonitor(m) } }

    /// What the panel shows: the pill's prompt (following it as prompts come), an earlier prompt, or the whole chat.
    enum Showing: Equatable { case following, prompt(String), chat }
    private(set) var showing: Showing = .following

    struct Shown {
        let title: String
        let prompt: AgentPrompt?
        let files: [ChangedFile]
        let fromGit: Bool
        /// Which list this is, for what's unfolded in it.
        let key: String
        /// The prompt the diffs are for; nil for the whole chat.
        let promptID: String?
        /// Its place among the prompts that changed something (1-based), and how many there are.
        let step: (Int, Int)?
        /// How "Ask" names it.
        let scope: String
    }

    /// The prompts that changed something, oldest first: what ‹ › step through.
    private var steps: [PromptChangesTracker.Entry] { tracker.entries.filter { !$0.files.isEmpty } }

    var shown: Shown {
        let t = tracker
        if showing == .chat {
            return Shown(title: "This whole chat", prompt: nil, files: t.chatFiles, fromGit: t.chatFromGit, key: "chat", promptID: nil,
                         step: nil, scope: "in this chat")
        }
        var entry = t.pillEntry
        if case .prompt(let id) = showing, let e = t.entries.first(where: { $0.prompt.id == id }) { entry = e }
        guard let e = entry else {
            return Shown(title: "This prompt", prompt: nil, files: [], fromGit: false, key: "-", promptID: nil, step: nil, scope: "for my last prompt")
        }
        let ago = (t.entries.count - 1) - (t.entries.firstIndex(of: e) ?? (t.entries.count - 1))
        let title = ago == 0 ? "This prompt" : ago == 1 ? "The prompt before" : "\(ago) prompts ago"
        let place = steps.firstIndex(of: e).map { ($0 + 1, steps.count) }
        let words = e.prompt.text.replacingOccurrences(of: "\n", with: " ")
        let scope = ago == 0 ? "for my last prompt" : "for my prompt “\(words.count > 50 ? String(words.prefix(48)) + "…" : words)”"
        return Shown(title: title, prompt: e.prompt, files: e.files, fromGit: e.fromGit, key: "p:" + e.prompt.id, promptID: e.prompt.id,
                     step: place, scope: scope)
    }

    /// Opens the panel at a prompt's changes (from the chip on its box in the terminal).
    func show(prompt id: String) {
        showing = id == tracker.pillEntry?.prompt.id ? .following : .prompt(id)
        if expanded { changed() } else { expand(keeping: true) }
    }

    /// ‹ › : the prompt that changed something before (or after) the one shown; past the newest, back to following.
    func step(_ by: Int) {
        let list = steps
        guard showing != .chat, let p = shown.promptID, let i = list.firstIndex(where: { $0.prompt.id == p }) else { return }
        let j = i + by
        guard list.indices.contains(j) else { return }
        showing = j == list.count - 1 ? .following : .prompt(list[j].prompt.id)
        changed()
    }

    /// The whole chat, or back to the prompt.
    func toggleChat() {
        showing = showing == .chat ? .following : .chat
        changed()
    }

    private func changed() {
        let s = shown
        panel.canvas.forget(except: Set(s.files.map(\.path)), prompt: s.key)
        update()
    }

    func update() {
        let show = active && !tracker.files.isEmpty
        if !show, expanded { collapse(animated: false) }
        pillCard.isHidden = !show || expanded
        pillCard.refreshCard()
        pill.needsDisplay = true
        panel.refit()
        pane?.needsLayout = true
    }

    /// A new theme (or other settings): the cards' tint and edge, and what's drawn on them.
    func applyTheme() {
        pillCard.refreshCard()
        pill.needsDisplay = true
        panel.refit()
        panel.canvas.needsDisplay = true
    }

    /// Top right of the pane, under `top` (the find bar, when it's open).
    func layout(in bounds: NSRect, top: CGFloat) {
        // Right of it, the scrollbar's strip: the pill ends where prompts' boxes and outlines do.
        let inset: CGFloat = 10, right = TerminalView.scrollbarStrip
        let pw = min(pill.preferredWidth, bounds.width - inset - right)
        pillCard.frame = NSRect(x: bounds.width - pw - right, y: top + inset, width: pw, height: PromptChangesPill.height)
        pill.frame = pillCard.bounds
        let w = min(560, max(320, bounds.width * 0.5), bounds.width - inset - right)
        let h = max(120, min(panel.contentHeight, bounds.height - top - inset * 2))
        let shown = NSRect(x: bounds.width - w - right, y: top + inset, width: w, height: h)
        if expanded && !morphing { panel.frame = shown }
        targetFrame = shown
    }

    /// Growing out of the pill or shrinking back into it.
    private var morphing = false
    private var targetFrame: NSRect = .zero

    /// A stand-in for the panel while it grows or shrinks: one picture of the whole panel (its card and what's in it)
    /// on one layer with nothing under it, so animating its frame scales the picture itself.
    private var ghost: PromptChangesGhost?

    /// The panel as it looks now, card and contents, at the screen's scale.
    private func picture() -> NSImage? {
        panel.layoutSubtreeIfNeeded()
        let size = panel.bounds.size
        let b = panel.body
        guard size.width > 0, size.height > 0, let rep = b.bitmapImageRepForCachingDisplay(in: b.bounds) else { return nil }
        b.cacheDisplay(in: b.bounds, to: rep)
        let contents = NSImage(size: b.bounds.size)
        contents.addRepresentation(rep)
        let th = Config.shared.theme
        return NSImage(size: size, flipped: false) { r in
            // The card as the frosted one reads (its tint over the blur, near enough opaque here), its edge, then the list.
            let card = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: FrostedCard.radius, yRadius: FrostedCard.radius)
            th.background.mix(th.surface, 0.5).withAlphaComponent(0.96).setFill()
            card.fill()
            th.foreground.withAlphaComponent(th.isDark ? 0.12 : 0.1).setStroke()
            card.lineWidth = 1
            card.stroke()
            contents.draw(in: r)
            return true
        }
    }

    private func makeGhost(at frame: NSRect, picture: NSImage?) -> PromptChangesGhost {
        let g = PromptChangesGhost(frame: frame, picture: picture)
        ghost?.removeFromSuperview()
        ghost = g
        pane?.addSubview(g, positioned: .above, relativeTo: panel)
        return g
    }

    /// The pill grows into the panel: a picture of the panel, the pill's size and place, grows to the panel's (fading
    /// in over the pill as it starts); then the panel itself is there.
    func expand(keeping: Bool = false) {
        guard !expanded, let pane else { return }
        expanded = true
        if !keeping, showing != .following { showing = .following }
        changed()
        panel.refit()
        pane.needsLayout = true
        pane.layoutSubtreeIfNeeded()
        let from = pillCard.frame, to = targetFrame
        panel.frame = to
        panel.isHidden = false
        panel.alphaValue = 0
        let g = makeGhost(at: from, picture: picture())
        g.alphaValue = 0
        morphing = true
        // Once it's on screen at the pill's place (in the same pass, it would grow from wherever it was drawn).
        DispatchQueue.main.async { [weak self] in
            guard let self, self.expanded else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.85, 0.25, 1)
                g.animator().frame = to
            }, completionHandler: { [weak self] in
                guard let self, self.expanded else { return }
                self.morphing = false
                self.panel.alphaValue = 1
                g.removeFromSuperview()
                if self.ghost === g { self.ghost = nil }
                self.pillCard.isHidden = true
                self.pillCard.alphaValue = 1
                self.pane?.needsLayout = true
                // The panel's come up under a pointer that hasn't moved: its cursor rects at its real size, then hover,
                // the hand and tips from where the pointer is.
                self.panel.canvas.display()
                self.pane?.window?.invalidateCursorRects(for: self.panel.canvas)
                self.panel.canvas.refreshPointer()
            })
            // The pill becomes the picture in the first moments.
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.1
                g.animator().alphaValue = 1
                self.pillCard.animator().alphaValue = 0
            }
        }
        pane.window?.makeFirstResponder(panel.canvas)
        watchOutsideClicks(true)
    }

    /// The panel shrinks back into the pill.
    func collapse(animated: Bool = true) {
        guard expanded else { return }
        expanded = false
        watchOutsideClicks(false)
        if let pane, pane.window?.firstResponder === panel.canvas { pane.window?.makeFirstResponder(pane) }
        let showPill = { [weak self] in
            guard let self, !self.expanded else { return }
            self.morphing = false
            self.ghost?.removeFromSuperview()
            self.ghost = nil
            self.panel.isHidden = true
            self.panel.alphaValue = 1
            let show = self.active && !self.tracker.files.isEmpty
            self.pillCard.isHidden = !show
            if show { self.pill.refreshPointer() }
            self.pane?.needsLayout = true
        }
        guard animated, !panel.isHidden else { self.pillCard.alphaValue = 1; return showPill() }
        morphing = true
        let g = makeGhost(at: panel.frame, picture: picture())
        panel.alphaValue = 0
        let into = pillCard.frame
        pillCard.isHidden = !(active && !tracker.files.isEmpty)
        pillCard.alphaValue = 0
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.9, 0.6)
                g.animator().frame = into
            }, completionHandler: showPill)
            // And becomes the pill again in its last moments.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) { [weak self] in
                guard let self, !self.expanded else { return }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.09
                    g.animator().alphaValue = 0
                    self.pillCard.animator().alphaValue = 1
                }
            }
        }
    }

    /// A click anywhere in the window but the panel folds it back (the click still does what it does there).
    private func watchOutsideClicks(_ on: Bool) {
        if let m = outsideClicks { NSEvent.removeMonitor(m); outsideClicks = nil }
        guard on else { return }
        // Moves come only to windows that ask for them.
        pane?.window?.acceptsMouseMovedEvents = true
        outsideClicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .mouseMoved]) { [weak self] e in
            guard let self, let pane = self.pane, e.window === pane.window else { return e }
            if e.type == .mouseMoved {
                // Hover, the hand and tips from the first move, whether or not the list's own tracking has caught up.
                if !self.morphing { self.panel.canvas.pointerMoved(to: e.locationInWindow) }
                return e
            }
            if !self.panel.frame.contains(pane.convert(e.locationInWindow, from: nil)) { self.collapse() }
            return e
        }
    }

    /// The agent running in the pane, by name ("Claude Code", "Codex"); "the agent" when it can't be told.
    var agentName: String { pane?.agent?.kind.name ?? "the agent" }

    /// Starts a question about the changes to `paths` (all of them, by default) in the agent's input box in this pane: a
    /// line saying which files and where (see PromptChanges.ask), for you to finish; not sent. When it can't take a paste
    /// now (asking you something), the line goes on the clipboard.
    func ask(about paths: [String]? = nil) {
        guard let pane else { return }
        let s = shown
        let files = s.files.filter { paths?.contains($0.path) ?? true }
        guard !files.isEmpty else { return }
        var diffs: [String: DiffFile] = [:]
        let group = DispatchGroup()
        for f in files where !f.binary {
            group.enter()
            tracker.diff(f.path, prompt: s.promptID) { d in
                if let d { diffs[f.path] = d }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self, weak pane] in
            guard let self, let pane else { return }
            let text = PromptChanges.ask(about: files.map { ($0, diffs[$0.path]) }, scope: s.scope)
            self.collapse()
            if pane.devPromptChanges { FileHandle.standardError.write("prompt-changes: ask\n\(text)".data(using: .utf8)!) }
            guard pane.terminal.bracketedPaste, pane.agent?.status != .waiting else { return pane.chatPasteFailed(text) }
            pane.sendPaste(text)
            pane.window?.makeFirstResponder(pane)
        }
    }

    /// Opens a changed file above the pane's terminal.
    func open(_ path: String) {
        guard let pane else { return }
        collapse()
        pane.tab?.openFile(LocalFileSystem.shared, tracker.absolute(path))
    }

    // Dev aids (DevTools).
    func devSavePicture(_ path: String) {
        guard let tiff = picture()?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    var devPill: PageCanvas { pill }
    var devCanvas: PageCanvas { panel.canvas }
    var devPanelFrame: NSRect { panel.frame }
    var devShown: String {
        let sh = shown
        let list = tracker.entries.map { "\($0.prompt.id):\($0.fromGit ? "git" : "edits"):\($0.files.map { "\($0.path)+\($0.added)-\($0.removed)" }.joined(separator: ","))" }
        return "showing=\(sh.title) step=\(sh.step.map { "\($0.0)/\($0.1)" } ?? "-") files=\(sh.files.map(\.path)) git=\(sh.fromGit) | entries=\(list) | chat=\(tracker.chatFiles.map(\.path))"
    }
    var devGhost: String { ghost?.devState ?? "no ghost" }
    var devMorph: String {
        let g: NSView = ghost ?? panel
        let now = g.layer?.presentation()?.frame ?? g.frame
        return "now=\(Int(now.minX)),\(Int(now.minY)) \(Int(now.width))x\(Int(now.height)) to=\(Int(targetFrame.minX)),\(Int(targetFrame.minY)) \(Int(targetFrame.width))x\(Int(targetFrame.height)) pillAt=\(Int(pillCard.frame.minX)),\(Int(pillCard.frame.minY))" + " pill=\(Int(pillCard.frame.width))x\(Int(pillCard.frame.height)) pillAlpha=\(String(format: "%.2f", pillCard.alphaValue)) pillHidden=\(pillCard.isHidden)" }
}

/// The panel's stand-in while it grows from the pill or shrinks into it: its picture as the layer's contents, stretched
/// to whatever size the layer is, so the animated frame scales it.
final class PromptChangesGhost: NSView {
    private let picture: NSImage?

    init(frame: NSRect, picture: NSImage?) {
        self.picture = picture
        super.init(frame: frame)
        wantsLayer = true
        // Its picture is set once and stretched as it resizes, never drawn again.
        layerContentsRedrawPolicy = .never
        layer?.contentsGravity = .resize
        layer?.cornerRadius = FrostedCard.radius
        layer?.masksToBounds = true
        needsDisplay = true
    }

    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.contents = picture }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Dev aid: whether it has its picture, and how big its layer is drawn now.
    var devState: String {
        let b = layer?.presentation()?.bounds ?? bounds
        return "ghost picture=\(layer?.contents != nil) subviews=\(subviews.count) drawn=\(Int(b.width))x\(Int(b.height))"
    }
}

/// The pill: "3 files changed +42 −7".
final class PromptChangesPill: PageCanvas {
    weak var controller: PromptChangesController?

    override func tip(for id: String) -> String? { "Files your prompts changed: click to see them, and step back through earlier prompts" }
    static let height: CGFloat = 30
    private static let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private static let countFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)

    private var label: String {
        let n = controller?.tracker.files.count ?? 0
        return n == 1 ? "1 file changed" : "\(n) files changed"
    }
    private var counts: (String, String) {
        let f = controller?.tracker.files ?? []
        return ("+\(f.map(\.added).reduce(0, +))", "−\(f.map(\.removed).reduce(0, +))")
    }

    var preferredWidth: CGFloat {
        let c = counts
        return 34 + PageCanvas.textWidth(label, Self.font) + 10 + PageCanvas.textWidth(c.0, Self.countFont) + 6 + PageCanvas.textWidth(c.1, Self.countFont) + 14
    }

    override func render() -> CGFloat {
        let r = bounds
        // On its frosted card (the controller's): lit up under the pointer.
        if hover == "pill" { fill(r, th.foreground.withAlphaComponent(0.08), radius: PageCanvas.radius) }
        symbol("doc.text.magnifyingglass", NSRect(x: 10, y: 0, width: 16, height: r.height), th.accent, size: 11, weight: .semibold)
        var x: CGFloat = 32
        // Centered on the pill, the counts on the label's baseline.
        let ty = AtlassianHeader.textY(Self.font, in: r)
        let cy = ty + (Self.font.ascender - Self.countFont.ascender)
        text(label, Self.font, th.foreground, x: x, y: ty, width: r.width - x)
        x += PageCanvas.textWidth(label, Self.font) + 10
        let c = counts
        text(c.0, Self.countFont, th.green, x: x, y: cy, width: 60)
        x += PageCanvas.textWidth(c.0, Self.countFont) + 6
        text(c.1, Self.countFont, th.red, x: x, y: cy, width: 60)
        hit(r, "pill") { [weak self] in self?.controller?.expand() }
        return r.height
    }
}

/// The panel: a frosted card with the list of files.
final class PromptChangesPanelView: FrostedCard {
    weak var controller: PromptChangesController? { didSet { canvas.controller = controller } }
    let canvas = PromptChangesCanvas()
    private let scroll: CanvasScroll

    override init(frame: NSRect) {
        scroll = CanvasScroll(canvas)
        super.init(frame: frame)
        body.addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// How tall the panel would be to show everything.
    var contentHeight: CGFloat {
        canvas.frame.size.width = max(canvas.frame.width, 300)
        return canvas.measure() + 12
    }

    override func layout() {
        super.layout()
        scroll.frame = body.bounds.insetBy(dx: 0, dy: 6)
        scroll.refit()
    }

    func refit() {
        refreshCard()
        scroll.refit()
        canvas.needsDisplay = true
    }
}

final class PromptChangesCanvas: PageCanvas {
    weak var controller: PromptChangesController?

    override func tip(for id: String) -> String? {
        let agent = controller?.agentName ?? "the agent"
        let name = { (prefix: String) in (String(id.dropFirst(prefix.count)) as NSString).lastPathComponent }
        if id == "close" { return "Close (Esc)" }
        if id == "prev" { return "An earlier prompt's changes (←)" }
        if id == "next" { return "A later prompt's changes (→)" }
        if id == "chat" { return controller?.showing == .chat ? "Back to the prompt's changes" : "Everything changed in this chat" }
        if id == "askall" { return "Start a question to \(agent) about these changes" }
        if id.hasPrefix("askfile.") { return "Ask \(agent) about the change to \(name("askfile."))" }
        if id.hasPrefix("openfile.") { return "Open \(name("openfile.")) above the terminal" }
        if id.hasPrefix("file.") { return open.contains(String(id.dropFirst(5))) ? "Hide the changes" : "Show the changes" }
        return nil
    }
    /// Unfolded files, and their diffs once loaded.
    private var open: Set<String> = []
    private var diffs: [String: DiffFile] = [:]
    private var loading: Set<String> = []
    private var forPrompt: String?

    /// Drops what's unfolded for files no longer changed, and everything when a new prompt's been sent. Loaded diffs are
    /// fetched again (the files may have changed since).
    func forget(except paths: Set<String>, prompt: String?) {
        if prompt != forPrompt { open = []; forPrompt = prompt; anchor = nil; focus = nil; moving = [:]; openOnLoad = [] }
        open = open.intersection(paths)
        // Diffs shown stay until their fresh copies come (cleared, an open file shut and reopened at each refresh).
        diffs = diffs.filter { paths.contains($0.key) }
        prefetch()
        needsDisplay = true
    }

    // MARK: Folding and unfolding

    /// Files folding or unfolding: from how open, to how open, since when.
    private var moving: [String: (from: CGFloat, to: CGFloat, start: CFTimeInterval)] = [:]
    /// Unfolded while its diff was still on its way: it opens once it's here.
    private var openOnLoad: Set<String> = []
    private var ticker: Timer?
    private static let foldTime: CFTimeInterval = 0.22

    /// How far open a file is: 0 folded, 1 unfolded, part way while it moves (eased out).
    private func openness(_ path: String) -> CGFloat {
        guard let m = moving[path] else { return open.contains(path) && diffs[path] != nil ? 1 : 0 }
        let t = min(1, max(0, (CACurrentMediaTime() - m.start) / Self.foldTime))
        let eased = 1 - pow(1 - t, 3)
        return m.from + (m.to - m.from) * CGFloat(eased)
    }

    /// Unfolds (or folds) a file, moving there.
    private func setOpen(_ path: String, _ on: Bool) {
        let from = openness(path)
        if on {
            open.insert(path)
            guard diffs[path] != nil else {
                openOnLoad.insert(path)
                load(path)
                return refit()
            }
        } else {
            open.remove(path)
            openOnLoad.remove(path)
        }
        move(path, from: from, to: on ? 1 : 0)
    }

    private func move(_ path: String, from: CGFloat, to: CGFloat) {
        moving[path] = (from, to, CACurrentMediaTime())
        guard ticker == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            let now = CACurrentMediaTime()
            self.moving = self.moving.filter { now - $0.value.start < Self.foldTime }
            self.refit()
            if self.moving.isEmpty { timer.invalidate(); self.ticker = nil }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
        refit()
    }

    /// Every shown file's diff, fetched together ahead of any unfolding, so one opens as soon as it's clicked.
    private var prefetching = false
    func prefetch() {
        // Only while the panel's open (it's asked at every refresh of what's changed).
        guard let c = controller, c.expanded, !prefetching else { return }
        prefetching = true
        let key = c.shown.key
        c.tracker.diffs(prompt: c.shown.promptID) { [weak self] all in
            guard let self else { return }
            self.prefetching = false
            guard self.controller?.shown.key == key else { return }
            for (path, d) in all { self.diffs[path] = d }
            for path in self.openOnLoad where all[path] != nil && self.open.contains(path) { self.move(path, from: 0, to: 1) }
            self.openOnLoad.subtract(all.keys)
            self.refit()
        }
    }

    private func load(_ path: String) {
        guard let t = controller?.tracker, !loading.contains(path) else { return }
        loading.insert(path)
        t.diff(path, prompt: controller?.shown.promptID) { [weak self] f in
            guard let self else { return }
            self.loading.remove(path)
            if let f { self.diffs[path] = f }
            if self.openOnLoad.remove(path) != nil, f != nil, self.open.contains(path) { self.move(path, from: 0, to: 1) }
            self.refit()
        }
    }

    private func refit() {
        controller?.update()
        needsDisplay = true
    }

    override func keyDown(with e: NSEvent) {
        if e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "c" { return copy(nil) }
        if e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "a" { return selectAll(nil) }
        switch e.keyCode {
        case 53: if ordered != nil { anchor = nil; focus = nil; needsDisplay = true } else { controller?.collapse() }
        case 123: controller?.step(-1)
        case 124: controller?.step(1)
        default: super.keyDown(with: e)
        }
    }

    override func render() -> CGFloat {
        guard let c = controller else { return 0 }
        if !measuring { rows = [] }
        let t = c.shown
        let pad: CGFloat = 16
        let w = bounds.width - pad * 2
        var y: CGFloat = 12
        // Title; ‹ › through the prompts that changed something; ✕.
        var right = bounds.width - pad + 6
        right -= button("", id: "close", x: right, y: y - 2, height: 26, symbol: "xmark", style: .plain, rightAligned: true) { [weak c] in c?.collapse() } + 2
        if let (i, n) = t.step, n > 1 {
            right -= button("", id: "next", x: right, y: y - 2, height: 26, symbol: "chevron.right", style: .plain, rightAligned: true, enabled: i < n) { [weak c] in
                c?.step(1)
            }
            right -= button("", id: "prev", x: right, y: y - 2, height: 26, symbol: "chevron.left", style: .plain, rightAligned: true, enabled: i > 1) { [weak c] in
                c?.step(-1)
            }
            // Which of the prompts that changed something this is.
            let place = "\(i)/\(n)", pf = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
            right -= PageCanvas.textWidth(place, pf) + 6
            text(place, pf, th.dimText, x: right, y: y + 4, width: 60)
        }
        text(t.title, .systemFont(ofSize: 13.5, weight: .bold), th.foreground, x: pad, y: y + 3, width: right - pad - 4)
        y += 28
        if let p = t.prompt {
            y += paragraph("“" + p.text.replacingOccurrences(of: "\n", with: " ") + "”", .systemFont(ofSize: 12), th.dimText, x: pad, y: y, width: w, maxLines: 2) + 8
        }
        let added = t.files.map(\.added).reduce(0, +), removed = t.files.map(\.removed).reduce(0, +)
        // A prompt from before Solanum was watching says where its files come from (the whole chat mixes both).
        let summary = "\(t.files.count) file\(t.files.count == 1 ? "" : "s") · +\(added) −\(removed)" + (t.fromGit || t.promptID == nil ? "" : " · from Claude's edits")
        // The totals; the whole chat (or back), and asking the agent about what's shown, on their right.
        let askW = button(bounds.width < 400 ? "Ask" : "Ask " + c.agentName, id: "askall", x: bounds.width - pad, y: y - 4, height: 26, symbol: "sparkles", style: .secondary,
                          rightAligned: true, enabled: !t.files.isEmpty) { [weak c] in c?.ask() }
        let chatW = button(c.showing == .chat ? "This prompt" : "Whole chat", id: "chat", x: bounds.width - pad - askW - 6, y: y - 4, height: 26,
                           symbol: c.showing == .chat ? "arrow.uturn.backward" : "rectangle.stack", style: .plain, rightAligned: true) { [weak c] in c?.toggleChat() }
        text(summary, .systemFont(ofSize: 11.5, weight: .medium), th.dimText, x: pad, y: y + 1, width: w - askW - chatW - 14)
        y += 30
        if t.files.isEmpty {
            y += paragraph("Nothing changed.", .systemFont(ofSize: 12), th.dimText, x: pad, y: y, width: w) + 10
        }
        for f in t.files {
            let unfolded = open.contains(f.path)
            // How far open it is (0 to 1): part way while it folds or unfolds.
            let shown = openness(f.path)
            let r = NSRect(x: pad, y: y, width: w, height: 32)
            let id = "file." + f.path
            fill(r, hover == id ? th.foreground.withAlphaComponent(0.08) : th.surface.withAlphaComponent(0.6), radius: PageCanvas.radius)
            // The chevron turns from › to ⌄ as it opens.
            let chev = NSRect(x: r.minX + 8, y: r.minY, width: 12, height: r.height)
            if visible(chev), let ctx = NSGraphicsContext.current?.cgContext {
                ctx.saveGState()
                ctx.translateBy(x: chev.midX, y: chev.midY)
                ctx.rotate(by: .pi / 2 * shown)
                ctx.translateBy(x: -chev.midX, y: -chev.midY)
                symbol("chevron.right", chev, th.dimText, size: 9, weight: .bold)
                ctx.restoreGState()
            }
            let name = (f.path as NSString).lastPathComponent
            let dir = (f.path as NSString).deletingLastPathComponent
            let nf = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
            let stat = f.binary ? "binary" : "+\(f.added) −\(f.removed)"
            let sf = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
            let sw = PageCanvas.textWidth(stat, sf)
            var x = r.minX + 26
            // The kind of change, for a file that's new or gone.
            if f.change != .modified {
                x += pill(f.change == .added ? "new" : "deleted", x: x, y: r.minY + 7, height: 18, color: f.change == .added ? th.green : th.red,
                          font: .systemFont(ofSize: 10, weight: .bold)) + 6
            }
            let right = r.maxX - sw - 12 - (hover == id || hover == "openfile." + f.path || hover == "askfile." + f.path ? 60 : 0)
            let nw = min(PageCanvas.textWidth(name, nf) + 2, right - x - 8)
            text(name, nf, f.change == .deleted ? th.dimText : th.foreground, x: x, y: r.minY + 8, width: nw)
            if !dir.isEmpty, nw + 30 < right - x { text(dir, .systemFont(ofSize: 11.5), th.dimText, x: x + nw + 6, y: r.minY + 9, width: right - x - nw - 6) }
            if f.binary {
                text(stat, sf, th.dimText, x: r.maxX - sw - 12, y: r.minY + 9, width: sw)
            } else {
                let a = "+\(f.added)", d = "−\(f.removed)"
                text(a, sf, th.green, x: r.maxX - sw - 12, y: r.minY + 9, width: sw)
                text(d, sf, th.red, x: r.maxX - 12 - PageCanvas.textWidth(d, sf), y: r.minY + 9, width: sw)
            }
            hit(r, id) { [weak self] in self?.setOpen(f.path, !unfolded) }
            // On the row while the pointer's on it: ask the agent about this change, and open the file.
            let rowHot = hover == id || hover == "openfile." + f.path || hover == "askfile." + f.path
            if rowHot {
                var bx = r.maxX - sw - 40
                if f.change != .deleted {
                    let o = NSRect(x: bx, y: r.minY + 3, width: 26, height: 26)
                    if hover == "openfile." + f.path { fill(o, th.foreground.withAlphaComponent(0.1), radius: PageCanvas.radius) }
                    symbol("arrow.up.right.square", o, th.accent, size: 11)
                    hit(o, "openfile." + f.path) { [weak c] in c?.open(f.path) }
                    bx -= 28
                }
                let a = NSRect(x: bx, y: r.minY + 3, width: 26, height: 26)
                if hover == "askfile." + f.path { fill(a, th.foreground.withAlphaComponent(0.1), radius: PageCanvas.radius) }
                symbol("sparkles", a, th.accent, size: 11)
                hit(a, "askfile." + f.path) { [weak c] in c?.ask(about: [f.path]) }
            }
            y += 36
            guard shown > 0 else { continue }
            if let d = diffs[f.path], !d.isBinary {
                // Its whole height, and as much of it as shows: it unfolds from the top, under its row (or folds up).
                let full = CGFloat(d.lines.count) * PageCanvas.diffLineH + 10
                let part = (full * shown).rounded()
                let clip = NSRect(x: pad, y: y, width: w, height: part)
                if !measuring, visible(clip), let ctx = NSGraphicsContext.current?.cgContext {
                    ctx.saveGState()
                    ctx.clip(to: clip)
                    var n = 0
                    _ = diffLines(d, x: pad, y: y, width: w) { [unowned self] l, bottom, textX in
                        // Its lines take a selection once it's all the way open.
                        if l.kind != .hunk, shown >= 1 {
                            self.rows.append(Row(key: "\(f.path)#\(n)", rect: NSRect(x: pad, y: bottom - PageCanvas.diffLineH, width: w, height: PageCanvas.diffLineH),
                                                 textX: textX, text: l.text.replacingOccurrences(of: "\t", with: "    ")))
                        }
                        n += 1
                        return bottom
                    }
                    ctx.restoreGState()
                }
                y += part
            } else if unfolded {
                y += paragraph(loading.contains(f.path) ? "Loading…" : f.binary ? "Binary file." : "No changes to show.",
                               .systemFont(ofSize: 12), th.dimText, x: pad + 26, y: y, width: w - 26) + 10
            }
        }
        drawSelection()
        return y + 6
    }

    // MARK: Selecting text in the diffs

    /// A diff line as drawn: where it is, where its text starts, and its text (tabs as four spaces, as drawn).
    private struct Row {
        let key: String
        let rect: NSRect
        let textX: CGFloat
        let text: String
    }
    private var rows: [Row] = []
    /// Where a drag began and where it's got to: a row (by its key) and a column.
    private var anchor: (key: String, col: Int)?
    private var focus: (key: String, col: Int)?
    private var selecting = false
    /// The diff font is fixed-width: a column is this wide.
    private static let charW = ("0000000000" as NSString).size(withAttributes: [.font: PageCanvas.diffFont]).width / 10

    /// The row and column under `p`; with `clamp`, the nearest row above or below when it's between or past them.
    private func position(at p: NSPoint, clamp: Bool = false) -> (key: String, col: Int)? {
        var row = rows.first { $0.rect.minY <= p.y && p.y < $0.rect.maxY && (clamp || $0.rect.minX <= p.x && p.x <= $0.rect.maxX) }
        if row == nil, clamp, !rows.isEmpty {
            row = p.y < rows[0].rect.minY ? rows.first : rows.last { $0.rect.minY <= p.y } ?? rows.last
        }
        guard let r = row else { return nil }
        let col = Int(((p.x - r.textX) / Self.charW).rounded())
        return (r.key, max(0, min(r.text.count, col)))
    }

    /// The selection, as rows (by index) and columns, start before end.
    private var ordered: (start: (row: Int, col: Int), end: (row: Int, col: Int))? {
        guard let a = anchor, let f = focus, let ai = rows.firstIndex(where: { $0.key == a.key }),
              let fi = rows.firstIndex(where: { $0.key == f.key }) else { return nil }
        let x = (ai, a.col), y = (fi, f.col)
        let first = x.0 < y.0 || (x.0 == y.0 && x.1 <= y.1)
        let s = first ? x : y, e = first ? y : x
        guard s != e else { return nil }
        return ((s.0, s.1), (e.0, e.1))
    }

    private func selectedCols(_ i: Int) -> (Int, Int)? {
        guard let o = ordered, i >= o.start.row, i <= o.end.row else { return nil }
        let lo = i == o.start.row ? o.start.col : 0
        let hi = i == o.end.row ? o.end.col : rows[i].text.count + 1
        return (lo, hi)
    }

    private func drawSelection() {
        guard !measuring, ordered != nil else { return }
        for (i, r) in rows.enumerated() {
            guard let (lo, hi) = selectedCols(i), hi > lo else { continue }
            let x0 = r.textX + CGFloat(lo) * Self.charW, x1 = min(r.rect.maxX, r.textX + CGFloat(hi) * Self.charW)
            fill(NSRect(x: x0, y: r.rect.minY, width: max(2, x1 - x0), height: r.rect.height), th.accent.withAlphaComponent(0.32))
        }
    }

    /// What's selected, line by line.
    var selectedText: String? {
        guard ordered != nil else { return nil }
        var lines: [String] = []
        for (i, r) in rows.enumerated() {
            guard let (lo, hi) = selectedCols(i) else { continue }
            let chars = Array(r.text)
            lines.append(String(chars[min(lo, chars.count)..<min(hi, chars.count)]))
        }
        return lines.joined(separator: "\n")
    }

    /// Dev aid: a drag from row `r0`, column `c0` to row `r1`, column `c1` of the unfolded diffs, by mouse events; what's
    /// selected after it.
    func devDrag(_ r0: Int, _ c0: Int, _ r1: Int, _ c1: Int) -> String {
        display()
        guard let w = window, rows.indices.contains(r0), rows.indices.contains(r1) else { return "no rows (\(rows.count))" }
        func event(_ type: NSEvent.EventType, _ r: Int, _ c: Int) -> NSEvent? {
            let row = rows[r]
            let p = convert(NSPoint(x: row.textX + (CGFloat(c) + 0.1) * Self.charW, y: row.rect.midY), to: nil)
            return NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber, context: nil,
                                      eventNumber: 0, clickCount: 1, pressure: 1)
        }
        if let e = event(.leftMouseDown, r0, c0) { mouseDown(with: e) }
        if let e = event(.leftMouseDragged, r1, c1) { mouseDragged(with: e) }
        if let e = event(.leftMouseUp, r1, c1) { mouseUp(with: e) }
        display()
        return "rows=\(rows.map(\.text)) selected=\(String(reflecting: selectedText ?? "-"))"
    }

    /// ⌘A: every unfolded diff's lines.
    override func selectAll(_ sender: Any?) {
        guard let first = rows.first, let last = rows.last else { return }
        anchor = (first.key, 0)
        focus = (last.key, last.text.count)
        needsDisplay = true
    }

    @objc func copy(_ sender: Any?) {
        guard let t = selectedText, !t.isEmpty else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t, forType: .string)
    }

    override func cursor(at p: NSPoint) -> NSCursor? {
        rows.contains { $0.rect.minY <= p.y && p.y < $0.rect.maxY && p.x >= $0.textX - 4 } ? .iBeam : nil
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let shown = visibleRect
        for r in rows {
            let t = NSRect(x: r.textX - 4, y: r.rect.minY, width: r.rect.maxX - r.textX + 4, height: r.rect.height).intersection(shown)
            if !t.isEmpty { addCursorRect(t, cursor: .iBeam) }
        }
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        // On a diff's text: a selection starts (a click without a drag clears it).
        if !hits.contains(where: { $0.rect.contains(p) }), let at = position(at: p) {
            window?.makeFirstResponder(self)
            anchor = at
            focus = at
            selecting = true
            needsDisplay = true
            return
        }
        anchor = nil
        focus = nil
        needsDisplay = true
        super.mouseDown(with: e)
    }

    override func mouseDragged(with e: NSEvent) {
        guard selecting else { return super.mouseDragged(with: e) }
        if let at = position(at: convert(e.locationInWindow, from: nil), clamp: true) { focus = at }
        autoscroll(with: e)
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        guard selecting else { return super.mouseUp(with: e) }
        selecting = false
        if ordered == nil { anchor = nil; focus = nil }
        needsDisplay = true
    }
}
