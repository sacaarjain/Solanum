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
    /// The prompt last sent, and the files changed since.
    private(set) var prompt: AgentPrompt?
    private(set) var files: [ChangedFile] = []
    /// The repository's top folder, when the pane's in one.
    private(set) var root: String?
    /// Whether `files` came from git (else from the agent's own edits, in the transcript).
    private(set) var fromGit = false
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
            prompt = nil
            files = []
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
                if let id = self.pendingSnapshot, id == self.prompt?.id { self.snapshot(id, root: top) }
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
        guard let latest = scan.latest else { return }
        if latest.id != before {
            prompt = latest
            files = []
            onChange?()
            // A prompt just sent: the working tree as it is now is what its changes are measured from. (One already
            // in the transcript when Solanum started watching is too late for that: its edits stand in.)
            if !first { if let root { snapshot(latest.id, root: root) } else { pendingSnapshot = latest.id } }
        }
        refresh()
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
                self?.snapshots[id] = tree
                self?.refresh()
            }
        }
    }

    /// Works out what's changed since the latest prompt (once at a time; asked again meanwhile, once more after).
    func refresh() {
        guard let p = prompt else { return }
        guard !refreshing else { refreshAgain = true; return }
        lastRefresh = Date()
        guard let root, let base = snapshots[p.id] else {
            let next = PromptChanges.files(from: scan.edits[p.id] ?? [], root: base).map { f in
                var f = f
                if f.path.hasPrefix("/") { f = ChangedFile(path: (f.path as NSString).abbreviatingWithTildeInPath, change: f.change, added: f.added, removed: f.removed, binary: f.binary) }
                return f
            }
            fromGit = false
            if next != files { files = next; onChange?() }
            return
        }
        refreshing = true
        queue.async { [weak self] in
            var next: [ChangedFile]?
            if let now = Self.tree(root) {
                let raw = LocalGit.runNow(root, ["diff-tree", "-r", "--no-renames", "-z", "--raw", base, now]).out
                let num = LocalGit.runNow(root, ["diff-tree", "-r", "--no-renames", "-z", "--numstat", base, now]).out
                next = PromptChanges.files(raw: raw, numstat: num)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshing = false
                if let next, self.prompt?.id == p.id {
                    self.fromGit = true
                    if next != self.files { self.files = next; self.onChange?() }
                }
                if self.refreshAgain { self.refreshAgain = false; self.refresh() }
            }
        }
    }

    /// The diff of one of `files` since the prompt was sent.
    func diff(_ path: String, done: @escaping (DiffFile?) -> Void) {
        guard let p = prompt else { return done(nil) }
        guard let root, let base = snapshots[p.id] else {
            let f = (scan.edits[p.id] ?? []).first { PromptChanges.relative($0.path, to: base) == path || ($0.path as NSString).abbreviatingWithTildeInPath == path }
            return done(f)
        }
        queue.async {
            var f: DiffFile?
            if let now = Self.tree(root) {
                f = DiffFile.parse(LocalGit.runNow(root, ["diff", "--no-renames", "--no-color", "--no-ext-diff", base, now, "--", path]).out).first
            }
            DispatchQueue.main.async { done(f) }
        }
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
        tracker.onChange = { [weak self] in self?.changed() }
        pillCard.isHidden = true
        panel.isHidden = true
        pillCard.body.addSubview(pill)
        pane.addSubview(pillCard)
        pane.addSubview(panel)
    }

    deinit { if let m = outsideClicks { NSEvent.removeMonitor(m) } }

    private func changed() {
        panel.canvas.forget(except: Set(tracker.files.map(\.path)), prompt: tracker.prompt?.id)
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

    /// Top right of the pane, under `top` (the find bar, when it's open).
    func layout(in bounds: NSRect, top: CGFloat) {
        let inset: CGFloat = 10
        let pw = min(pill.preferredWidth, bounds.width - inset * 2)
        pillCard.frame = NSRect(x: bounds.width - pw - inset, y: top + inset, width: pw, height: PromptChangesPill.height)
        pill.frame = pillCard.bounds
        let w = min(560, max(320, bounds.width * 0.5), bounds.width - inset * 2)
        let h = max(120, min(panel.contentHeight, bounds.height - top - inset * 2))
        let shown = NSRect(x: bounds.width - w - inset, y: top + inset, width: w, height: h)
        if !sliding { panel.frame = expanded ? shown : shown.offsetBy(dx: w + inset + 30, dy: 0) }
        targetFrame = shown
    }

    private var sliding = false
    private var targetFrame: NSRect = .zero

    func expand() {
        guard !expanded, let pane else { return }
        expanded = true
        pillCard.isHidden = true
        panel.isHidden = false
        panel.refit()
        pane.layoutSubtreeIfNeeded()
        let shown = targetFrame
        panel.frame = shown.offsetBy(dx: shown.width + 40, dy: 0)
        panel.alphaValue = 0
        sliding = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.panel.animator().frame = self.targetFrame
                self.panel.animator().alphaValue = 1
            }, completionHandler: { [weak self] in self?.sliding = false; self?.pane?.needsLayout = true })
        }
        pane.window?.makeFirstResponder(panel.canvas)
        watchOutsideClicks(true)
    }

    func collapse(animated: Bool = true) {
        guard expanded else { return }
        expanded = false
        watchOutsideClicks(false)
        let away = targetFrame.offsetBy(dx: targetFrame.width + 40, dy: 0)
        let done = { [weak self] in
            guard let self, !self.expanded else { return }
            self.sliding = false
            self.panel.isHidden = true
            self.pillCard.isHidden = !(self.active && !self.tracker.files.isEmpty)
            self.pane?.needsLayout = true
        }
        if let pane, pane.window?.firstResponder === panel.canvas { pane.window?.makeFirstResponder(pane) }
        guard animated else { panel.frame = away; return done() }
        sliding = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().frame = away
            panel.animator().alphaValue = 0
        }, completionHandler: done)
    }

    /// A click anywhere in the window but the panel folds it back (the click still does what it does there).
    private func watchOutsideClicks(_ on: Bool) {
        if let m = outsideClicks { NSEvent.removeMonitor(m); outsideClicks = nil }
        guard on else { return }
        outsideClicks = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
            guard let self, let pane = self.pane, e.window === pane.window else { return e }
            if !self.panel.frame.contains(pane.convert(e.locationInWindow, from: nil)) { self.collapse() }
            return e
        }
    }

    /// Opens a changed file above the pane's terminal.
    func open(_ path: String) {
        guard let pane else { return }
        collapse()
        pane.tab?.openFile(LocalFileSystem.shared, tracker.absolute(path))
    }

    // Dev aids (DevTools).
    var devPill: PageCanvas { pill }
    var devCanvas: PageCanvas { panel.canvas }
    var devPanelFrame: NSRect { panel.frame }
}

/// The pill: "3 files changed +42 −7".
final class PromptChangesPill: PageCanvas {
    weak var controller: PromptChangesController?
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
        let ty = (r.height - Self.font.boundingRectForFont.height) / 2 + 1
        text(label, Self.font, th.foreground, x: x, y: ty, width: r.width - x)
        x += PageCanvas.textWidth(label, Self.font) + 10
        let c = counts
        text(c.0, Self.countFont, th.green, x: x, y: ty + 0.5, width: 60)
        x += PageCanvas.textWidth(c.0, Self.countFont) + 6
        text(c.1, Self.countFont, th.red, x: x, y: ty + 0.5, width: 60)
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
    /// Unfolded files, and their diffs once loaded.
    private var open: Set<String> = []
    private var diffs: [String: DiffFile] = [:]
    private var loading: Set<String> = []
    private var forPrompt: String?

    /// Drops what's unfolded for files no longer changed, and everything when a new prompt's been sent. Loaded diffs are
    /// fetched again (the files may have changed since).
    func forget(except paths: Set<String>, prompt: String?) {
        if prompt != forPrompt { open = []; forPrompt = prompt }
        open = open.intersection(paths)
        diffs = [:]
        for p in open { load(p) }
        needsDisplay = true
    }

    private func load(_ path: String) {
        guard let t = controller?.tracker, !loading.contains(path) else { return }
        loading.insert(path)
        t.diff(path) { [weak self] f in
            guard let self else { return }
            self.loading.remove(path)
            if let f { self.diffs[path] = f }
            self.refit()
        }
    }

    private func refit() {
        controller?.update()
        needsDisplay = true
    }

    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { controller?.collapse(); return }
        super.keyDown(with: e)
    }

    override func render() -> CGFloat {
        guard let c = controller else { return 0 }
        let t = c.tracker
        let pad: CGFloat = 16
        let w = bounds.width - pad * 2
        var y: CGFloat = 12
        // Title, ✕.
        text("Files changed this prompt", .systemFont(ofSize: 13.5, weight: .bold), th.foreground, x: pad, y: y + 3, width: w - 40)
        button("", id: "close", x: bounds.width - pad + 6, y: y - 2, height: 26, symbol: "xmark", style: .plain, rightAligned: true) { [weak c] in c?.collapse() }
        y += 28
        if let p = t.prompt {
            y += paragraph("“" + p.text.replacingOccurrences(of: "\n", with: " ") + "”", .systemFont(ofSize: 12), th.dimText, x: pad, y: y, width: w, maxLines: 2) + 8
        }
        let added = t.files.map(\.added).reduce(0, +), removed = t.files.map(\.removed).reduce(0, +)
        let summary = "\(t.files.count) file\(t.files.count == 1 ? "" : "s") · +\(added) −\(removed)" + (t.fromGit ? "" : " · from Claude's edits")
        text(summary, .systemFont(ofSize: 11.5, weight: .medium), th.dimText, x: pad, y: y, width: w)
        y += 22
        for f in t.files {
            let unfolded = open.contains(f.path)
            let r = NSRect(x: pad, y: y, width: w, height: 32)
            let id = "file." + f.path
            fill(r, hover == id ? th.foreground.withAlphaComponent(0.08) : th.surface.withAlphaComponent(0.6), radius: PageCanvas.radius)
            symbol(unfolded ? "chevron.down" : "chevron.right", NSRect(x: r.minX + 8, y: r.minY, width: 12, height: r.height), th.dimText, size: 9, weight: .bold)
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
            let right = r.maxX - sw - 12 - (hover == id ? 30 : 0)
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
            hit(r, id) { [weak self] in
                guard let self else { return }
                if unfolded { self.open.remove(f.path) } else { self.open.insert(f.path); if self.diffs[f.path] == nil { self.load(f.path) } }
                self.refit()
            }
            // Open the file, on the row while the pointer's on it.
            if hover == id || hover == "openfile." + f.path, f.change != .deleted {
                let o = NSRect(x: r.maxX - sw - 40, y: r.minY + 3, width: 26, height: 26)
                if hover == "openfile." + f.path { fill(o, th.foreground.withAlphaComponent(0.1), radius: PageCanvas.radius) }
                symbol("arrow.up.right.square", o, th.accent, size: 11)
                hit(o, "openfile." + f.path) { [weak c] in c?.open(f.path) }
            }
            y += 36
            guard unfolded else { continue }
            if let d = diffs[f.path], !d.isBinary {
                y = diffLines(d, x: pad, y: y, width: w) + 10
            } else {
                y += paragraph(loading.contains(f.path) ? "Loading…" : f.binary ? "Binary file." : "No changes to show.",
                               .systemFont(ofSize: 12), th.dimText, x: pad + 26, y: y, width: w - 26) + 10
            }
        }
        return y + 6
    }
}
