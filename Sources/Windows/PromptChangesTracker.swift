import Foundation
import WinSDK

// "Files changed this prompt", as on the Mac (PromptChangesPanel.swift there): over a tab running Claude Code on this
// PC, a frosted pill once the prompt you last sent has changed a file, opening a panel of the files and their diffs.
// This is what follows one tab's session; the pill and panel are PromptChangesPanel. What changed comes from git when
// the tab's in a repository (a snapshot of the working tree as each prompt is sent, through a scratch index, so
// nothing in the repository changes), else from the transcript's record of Claude's edits (Core's PromptChanges).

/// git, run straight (no shell), off the window's thread.
enum LocalGit {
    /// Git for Windows' git.exe, from the PATH or beside its sh.exe.
    static let exe: String? = {
        var path = [UInt16](repeating: 0, count: Int(MAX_PATH))
        if SearchPathW(nil, wide("git.exe"), nil, DWORD(path.count), &path, nil) > 0 { return String(decodingCString: path, as: UTF16.self) }
        guard let sh = GitShell.sh, let bin = WindowsPath.parent(sh), let root = WindowsPath.parent(bin) else { return nil }
        let candidate = WindowsPath.join(WindowsPath.join(root, "cmd"), "git.exe")
        return FileManager.default.fileExists(atPath: candidate) ? candidate : nil
    }()

    /// Runs git in `dir` and waits: whether it exited 0, its status and what it printed.
    static func runNow(_ dir: String, _ args: [String], env: [String: String] = [:], timeout: TimeInterval = 60) -> (ok: Bool, status: Int32, out: String) {
        guard let exe else { return (false, 127, "") }
        var environment = env
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        guard let child = HiddenProcess(executable: exe, arguments: ["-C", dir, "-c", "core.quotepath=off"] + args, extraEnvironment: environment) else {
            return (false, 127, "")
        }
        let lock = NSLock(), done = DispatchSemaphore(value: 0)
        var out = Data(), status: Int32 = -1
        child.onOutput = { d in lock.lock(); out.append(d); lock.unlock() }
        child.onExit = { code in status = code; done.signal() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            child.terminate()
            _ = done.wait(timeout: .now() + 2)
            return (false, 124, "")
        }
        lock.lock()
        defer { lock.unlock() }
        return (status == 0, status, String(decoding: out, as: UTF8.self))
    }
}

/// Follows one tab's Claude Code session: its prompts, a snapshot of the working tree as each was sent, and what's
/// changed since.
final class PromptChangesTracker {
    var onChange: (() -> Void)?
    /// Runs work on the window's thread.
    var post: (@escaping () -> Void) -> Void = { $0() }

    /// What one prompt changed: from git between the working tree as it was sent and as the next was (or now, for the
    /// latest), or from the transcript's record of Claude's edits for one sent before Solanum was watching.
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
    private var gitChat: [ChangedFile] = []

    private var beforeWatching: [Entry] {
        let first = entries.firstIndex { snapshots[$0.prompt.id] != nil } ?? entries.count
        return Array(entries.prefix(first))
    }

    private func updateChat() {
        let next = Self.addedUp(beforeWatching.map(\.files) + [gitChat])
        let git = beforeWatching.allSatisfy { $0.files.isEmpty } && !gitChat.isEmpty
        if next != chatFiles || git != chatFromGit { chatFiles = next; chatFromGit = git; onChange?() }
    }

    /// What the pill speaks for: the latest prompt, or, when that's changed nothing (yet), the last one that did.
    var pillEntry: Entry? { entries.last { !$0.files.isEmpty } }
    var files: [ChangedFile] { pillEntry?.files ?? [] }
    /// The repository's top folder (as git writes it, C:/a/b), when the tab's in one.
    private(set) var root: String?
    private var finished: Set<String> = []
    private var cwd: String?
    private var base: String? { root ?? cwd }

    private(set) var session: String?
    private var transcript: String?
    private var offset: UInt64 = 0
    private var partial = Data()
    private var scan = PromptChanges.Scan()
    private var snapshots: [String: Snapshot] = [:]
    private var reading = false
    private var pendingSnapshot: String?
    private var refreshing = false
    private var refreshAgain = false
    private var lastLookForTranscript = Date.distantPast
    private var lastRefresh = Date.distantPast
    private var lookingForRoot = false
    private let queue = DispatchQueue(label: "solanum.prompt-changes", qos: .utility)

    /// Called every second while Claude Code runs in the tab: `session` its session (a new one after /clear), `cwd` the
    /// tab's folder, `working` whether it's busy (what's changed is looked at again while it is).
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
            transcript = Self.transcript(id)
        }
        read()
        if Date().timeIntervalSince(lastRefresh) > (working ? 3 : 30) { refresh() }
    }

    /// For tests: follows this transcript, as if its session were running here.
    func follow(transcript path: String, cwd: String?) {
        session = "test"
        transcript = path
        self.cwd = cwd
        if let cwd { findRoot(cwd) }
        read()
    }

    /// Claude Code's transcript of a session: %USERPROFILE%\.claude\projects\<the folder>\<session>.jsonl.
    static func transcript(_ id: String) -> String? {
        let fm = FileManager.default
        let projects = WindowsPath.join(WindowsPath.join(ProcessInfo.processInfo.environment["USERPROFILE"] ?? "", ".claude"), "projects")
        return ((try? fm.contentsOfDirectory(atPath: projects)) ?? []).lazy
            .map { WindowsPath.join(WindowsPath.join(projects, $0), id + ".jsonl") }
            .first { fm.fileExists(atPath: $0) }
    }

    private func findRoot(_ cwd: String) {
        guard !lookingForRoot else { return }
        lookingForRoot = true
        queue.async { [weak self] in
            let o = LocalGit.runNow(cwd, ["rev-parse", "--show-toplevel"])
            let top = o.ok ? o.out.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            self?.post {
                guard let self else { return }
                self.lookingForRoot = false
                guard let top, !top.isEmpty, self.root == nil else { return }
                self.root = top
                if let id = self.pendingSnapshot, id == self.entries.last?.prompt.id { self.snapshot(id, root: top) }
                self.pendingSnapshot = nil
            }
        }
    }

    private func read() {
        guard !reading, let path = transcript else { return }
        reading = true
        let from = offset
        queue.async { [weak self] in
            guard let h = FileHandle(forReadingAtPath: path) else { self?.post { self?.reading = false }; return }
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
            self?.post {
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
            // before it ended. (One already there when Solanum started watching is too late for that: its edits stand in.)
            if !first { if let root { snapshot(latest.id, root: root) } else { pendingSnapshot = latest.id } }
        }
        refresh()
    }

    private func rebuildEntries() {
        let known = Dictionary(entries.map { ($0.prompt.id, $0) }, uniquingKeysWith: { a, _ in a })
        entries = scan.prompts.map { p in
            if let e = known[p.id], e.fromGit { return e }
            return Entry(prompt: p, files: editedFiles(p.id), fromGit: false)
        }
    }

    /// The latest prompt whose text is what's on a prompt's box in the terminal ("> fix the …", maybe cut short):
    /// compared by their start, spaces aside.
    func entry(matching typed: String) -> Entry? {
        func squeeze(_ s: String) -> String {
            var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("❯") || t.hasPrefix(">") { t.removeFirst() }
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

    /// A path as the panel shows it: relative to the repository (or folder) with forward slashes, as git writes them.
    static func display(_ path: String, base: String?) -> String {
        let p = path.replacingOccurrences(of: "\\", with: "/")
        guard let base, !base.isEmpty else { return p }
        let b = base.replacingOccurrences(of: "\\", with: "/")
        let r = b.hasSuffix("/") ? b : b + "/"
        return p.lowercased().hasPrefix(r.lowercased()) ? String(p.dropFirst(r.count)) : p
    }

    private func editedFiles(_ id: String) -> [ChangedFile] {
        (scan.edits[id] ?? []).map { f in
            ChangedFile(path: Self.display(f.path, base: base), change: f.oldPath == nil ? .added : .modified, added: f.added, removed: f.removed)
        }
    }

    // MARK: Git

    struct Snapshot: Equatable {
        let tree: String
        let head: String?
        let time: Date
    }

    static func snapshot(_ root: String) -> Snapshot? {
        let time = Date()
        let head = LocalGit.runNow(root, ["rev-parse", "--verify", "-q", "HEAD"])
        guard let tree = tree(root) else { return nil }
        let h = head.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return Snapshot(tree: tree, head: head.ok && !h.isEmpty ? h : nil, time: time)
    }

    private static var rebased: [String: String] = [:]

    /// The tree to compare `to` with for what changed since `from`: `from`'s own, or once another commit is checked out
    /// (a branch switched, a pull, a rebase or reset), `from`'s changes moved onto that commit (a three-way merge in
    /// memory), so the difference between the two commits isn't taken for changes made. Commits made on top of `from`'s
    /// since it was taken (the agent committing its work) are changes made, and are kept.
    static func base(_ root: String, _ from: Snapshot, _ to: Snapshot) -> String {
        guard let old = from.head, let new = to.head, old != new else { return from.tree }
        let key = "\(from.tree) \(old) \(new)"
        if let t = rebased[key] { return t }
        var t = from.tree
        let ancestor = LocalGit.runNow(root, ["merge-base", "--is-ancestor", old, new]).ok
        let times = ancestor ? LocalGit.runNow(root, ["log", "--format=%ct", "\(old)..\(new)"]) : nil
        let since = from.time.timeIntervalSince1970 - 1
        let committedOnTop = times.map { o in o.ok && o.out.split(separator: "\n").allSatisfy { (Double($0) ?? 0) >= since } } ?? false
        if !committedOnTop {
            // Exit 1 is a conflict: the tree (its first line) still has every file, the conflicted ones with markers.
            let m = LocalGit.runNow(root, ["merge-tree", "--write-tree", "--merge-base=\(old)", new, from.tree])
            let first = m.out.split(separator: "\n").first.map { String($0) } ?? ""
            if m.status == 0 || m.status == 1, first.count >= 40, first.allSatisfy(\.isHexDigit) { t = first }
        }
        rebased[key] = t
        return t
    }

    /// The working tree now, every file (untracked too, ignored not), as a tree object, through a scratch index.
    static func tree(_ root: String) -> String? {
        let fm = FileManager.default
        let scratch = WindowsPath.join(NSTemporaryDirectory(), "solanum-prompt-index-" + UUID().uuidString)
        let real = LocalGit.runNow(root, ["rev-parse", "--path-format=absolute", "--git-path", "index"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
        try? fm.removeItem(atPath: scratch)
        if !real.isEmpty { try? fm.copyItem(atPath: real.replacingOccurrences(of: "/", with: "\\"), toPath: scratch) }
        defer { try? fm.removeItem(atPath: scratch) }
        let env = ["GIT_INDEX_FILE": scratch]
        guard LocalGit.runNow(root, ["add", "-A"], env: env, timeout: 120).ok else { return nil }
        let t = LocalGit.runNow(root, ["write-tree"], env: env)
        return t.ok ? t.out.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    private func snapshot(_ id: String, root: String) {
        queue.async { [weak self] in
            guard let snap = Self.snapshot(root) else { return }
            self?.post {
                guard let self else { return }
                self.snapshots[id] = snap
                self.finishBefore(id, root: root)
                self.refresh()
            }
        }
    }

    private func finishBefore(_ id: String, root: String) {
        guard let i = entries.firstIndex(where: { $0.prompt.id == id }), i > 0 else { return }
        let prev = entries[i - 1].prompt.id
        guard let from = snapshots[prev], let to = snapshots[id], !finished.contains(prev) else { return }
        finished.insert(prev)
        queue.async { [weak self] in
            let files = Self.changes(root, from, to)
            self?.post {
                guard let self, let files, let j = self.entries.firstIndex(where: { $0.prompt.id == prev }) else { return }
                self.entries[j].files = files
                self.entries[j].fromGit = true
                self.onChange?()
            }
        }
    }

    static func changes(_ root: String, _ from: Snapshot, _ to: Snapshot) -> [ChangedFile]? {
        let a = base(root, from, to)
        let raw = LocalGit.runNow(root, ["diff-tree", "-r", "--no-renames", "-z", "--raw", a, to.tree])
        guard raw.ok else { return nil }
        let num = LocalGit.runNow(root, ["diff-tree", "-r", "--no-renames", "-z", "--numstat", a, to.tree]).out
        return PromptChanges.files(raw: raw.out, numstat: num)
    }

    static func diff(_ root: String, _ from: Snapshot, _ to: Snapshot, paths: [String] = []) -> [DiffFile] {
        let args = ["diff", "--no-renames", "--no-color", "--no-ext-diff", base(root, from, to), to.tree]
        return DiffFile.parse(LocalGit.runNow(root, args + (paths.isEmpty ? [] : ["--"] + paths)).out)
    }

    private func span(_ id: String?) -> (from: Snapshot, to: Snapshot?)? {
        let withTrees = entries.filter { snapshots[$0.prompt.id] != nil }
        guard let id else { return withTrees.first.flatMap { snapshots[$0.prompt.id] }.map { ($0, nil) } }
        guard let i = entries.firstIndex(where: { $0.prompt.id == id }), let from = snapshots[id] else { return nil }
        let next = entries.dropFirst(i + 1).first.flatMap { snapshots[$0.prompt.id] }
        return (from, next)
    }

    /// Works out what the latest prompt has changed so far, and the whole chat (once at a time).
    func refresh() {
        guard let latest = entries.last else { return }
        guard !refreshing else { refreshAgain = true; return }
        lastRefresh = Date()
        let id = latest.prompt.id
        let base = snapshots[id]
        let start = span(nil)?.from
        guard let root, base != nil || start != nil else {
            gitChat = []
            updateChat()
            return
        }
        refreshing = true
        queue.async { [weak self] in
            let now = Self.snapshot(root)
            let latestFiles = now.flatMap { n in base.flatMap { Self.changes(root, $0, n) } }
            let chat = now.flatMap { n in start.flatMap { Self.changes(root, $0, n) } }
            self?.post {
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

    /// Every changed file's diff for the prompt `id` (or the whole chat, for nil), by path.
    func diffs(prompt id: String?, done: @escaping ([String: DiffFile]) -> Void) {
        if id == nil, let root, let span = span(nil) {
            let gitPaths = Set(gitChat.map(\.path))
            var out: [String: DiffFile] = [:]
            for f in chatFiles where !gitPaths.contains(f.path) { if let d = editDiff(f.path, ids: beforeWatching.map(\.prompt.id)) { out[f.path] = d } }
            return queue.async { [weak self] in
                if let to = span.to ?? Self.snapshot(root) {
                    for f in Self.diff(root, span.from, to) { out[f.path] = f }
                }
                self?.post { done(out) }
            }
        }
        guard let root, let span = span(id) else {
            let files = id.map { pid in entries.first { $0.prompt.id == pid }?.files ?? [] } ?? chatFiles
            var out: [String: DiffFile] = [:]
            for f in files { out[f.path] = editDiff(f.path, ids: id.map { [$0] } ?? entries.map(\.prompt.id)) }
            return done(out)
        }
        queue.async { [weak self] in
            var out: [String: DiffFile] = [:]
            if let to = span.to ?? Self.snapshot(root) {
                for f in Self.diff(root, span.from, to) { out[f.path] = f }
            }
            self?.post { done(out) }
        }
    }

    /// The diff of one changed file for the prompt `id` (or the whole chat, for nil).
    func diff(_ path: String, prompt id: String?, done: @escaping (DiffFile?) -> Void) {
        if id == nil, !gitChat.contains(where: { $0.path == path }) {
            return done(editDiff(path, ids: entries.map(\.prompt.id)))
        }
        guard let root, let span = span(id) else {
            return done(editDiff(path, ids: id.map { [$0] } ?? entries.map(\.prompt.id)))
        }
        queue.async { [weak self] in
            var f: DiffFile?
            if let to = span.to ?? Self.snapshot(root) {
                f = Self.diff(root, span.from, to, paths: [path]).first
            }
            self?.post { done(f) }
        }
    }

    private func editDiff(_ path: String, ids: [String]) -> DiffFile? {
        let edits = ids.flatMap { scan.edits[$0] ?? [] }.filter { Self.display($0.path, base: base) == path }
        guard var f = edits.first else { return nil }
        for more in edits.dropFirst() { f.lines += more.lines }
        return f
    }

    /// Where `path` (one of `files`) is on disk.
    func absolute(_ path: String) -> String {
        let p = path.replacingOccurrences(of: "/", with: "\\")
        if p.count > 1, p.dropFirst().hasPrefix(":") || p.hasPrefix("\\\\") { return p }
        return WindowsPath.join((base ?? "").replacingOccurrences(of: "/", with: "\\"), p)
    }
}
