import AppKit

// The status bar's git segment: branch (click to switch), sync state (click to pull/push/fetch) and the
// number of changed files (click to list them). Works in local folders and, through the session's
// multiplexing socket, on an ssh host.

/// Git state of a folder.
struct GitInfo: Equatable {
    var root: String
    /// Branch name, or the short commit when HEAD is detached.
    var branch = ""
    var detached = false
    var upstream: String?
    var ahead = 0
    var behind = 0
    var changes: [GitChange] = []
}

struct GitChange: Equatable {
    /// M, A, D, R, C, T, U (conflict) or ? (untracked).
    let code: Character
    /// Relative to the repository root.
    let path: String
}

extension GitInfo {
    static let statusScript = "git rev-parse --show-toplevel && git status --porcelain=v2 --branch -z"

    /// Parses `statusScript`'s output: the top-level folder on one line, then NUL-separated porcelain v2.
    init?(statusOutput out: Data) {
        let s = String(decoding: out, as: UTF8.self)
        guard let nl = s.firstIndex(of: "\n") else { return nil }
        root = String(s[..<nl])
        guard root.hasPrefix("/") else { return nil }
        var oid = ""
        let fields = s[s.index(after: nl)...].split(separator: "\0", omittingEmptySubsequences: false)
        var i = 0
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
                let parts = f.split(separator: " ", maxSplits: n, omittingEmptySubsequences: false)
                if kind == "2" { i += 1 }  // skip the rename's original path
                guard parts.count == n + 1 else { continue }
                let code: Character = kind == "u" ? "U" : (parts[1].first { $0 != "." } ?? "M")
                changes.append(GitChange(code: code, path: String(parts[n])))
            } else if f.hasPrefix("? ") {
                changes.append(GitChange(code: "?", path: String(f.dropFirst(2))))
            }
        }
        if branch == "(detached)" {
            detached = true
            branch = String(oid.prefix(7))
        }
    }
}

/// Git state of the files and folders under the file sidebar's folder: a letter for each changed file (and,
/// for a folder, its most serious change inside), plus the files git tracks that are gone from disk.
struct GitTreeStatus: Equatable {
    /// Changed files, by path as the sidebar lists them.
    var files: [String: Character] = [:]
    /// Folders with changes inside: the most serious one.
    var folders: [String: Character] = [:]
    /// Untracked folders (git reports them whole): everything inside is untracked too.
    var untrackedDirs: [String] = []
    /// Names of deleted files, by folder.
    var deleted: [String: [String]] = [:]

    /// The folder's path inside its repository on the first line, then the changes, repository-relative.
    static let script = "p=$(git rev-parse --show-prefix) || exit 1; printf '%s\\n' \"$p\"; git status --porcelain=v2 -z"

    /// Paths are relative to the repository root, so `root`'s place in it (the first line) maps them onto
    /// `root`, whatever symlinks led there. Changes outside `root` are left out.
    init?(output: Data, root: String) {
        let s = String(decoding: output, as: UTF8.self)
        guard let nl = s.firstIndex(of: "\n") else { return nil }
        let prefix = String(s[..<nl])
        guard let changes = GitInfo(statusOutput: Data(("/\n" + s[s.index(after: nl)...]).utf8))?.changes else { return nil }
        for c in changes where c.path.hasPrefix(prefix) {
            let rel = c.path.dropFirst(prefix.count)
            let isDir = rel.hasSuffix("/")
            let path = FilePaths.join(root, String(isDir ? rel.dropLast() : rel))
            if isDir {
                untrackedDirs.append(path)
                folders[path] = c.code
            } else {
                files[path] = c.code
            }
            if c.code == "D" { deleted[FilePaths.parent(path), default: []].append((path as NSString).lastPathComponent) }
            var dir = FilePaths.parent(path)
            while dir.hasPrefix(root + "/") {
                if let old = folders[dir], Self.rank(old) >= Self.rank(c.code) { break }
                folders[dir] = c.code
                dir = FilePaths.parent(dir)
            }
        }
    }

    func code(for path: String, isDirectory: Bool) -> Character? {
        if let c = isDirectory ? folders[path] : files[path] { return c }
        return untrackedDirs.contains { path.hasPrefix($0 + "/") } ? "?" : nil
    }

    /// Which change a folder shows when it holds several: conflicts and deletions over edits over additions.
    static func rank(_ c: Character) -> Int {
        switch c {
        case "U": return 4
        case "D": return 3
        case "M", "T": return 2
        default: return 1
        }
    }

    /// The letter shown (untracked as U, a conflict as C), and its color: green added, orange modified, red
    /// deleted or conflicted, all muted.
    static func badge(_ c: Character) -> (letter: String, color: NSColor) {
        let green = NSColor(srgbRed: 0.45, green: 0.74, blue: 0.47, alpha: 1)
        let orange = NSColor(srgbRed: 0.88, green: 0.61, blue: 0.33, alpha: 1)
        let red = NSColor(srgbRed: 0.88, green: 0.42, blue: 0.42, alpha: 1)
        switch c {
        case "?": return ("U", green)
        case "A", "C": return ("A", green)
        case "R": return ("R", green)
        case "M", "T": return ("M", orange)
        case "D": return ("D", red)
        case "U": return ("C", red)
        default: return (String(c), orange)
        }
    }
}

/// Runs shell scripts in a folder on the pane's machine.
struct GitRunner {
    let dir: String
    let remote: RemoteSession?

    var key: String { (remote?.controlPath ?? "local") + "\n" + dir }
    var fileSystem: FileSystem { remote ?? LocalFileSystem.shared }

    /// `done` gets (exit status, stdout, stderr) on the main queue. Git never prompts: there's no terminal to answer it.
    func run(_ script: String, timeout: TimeInterval = 30, _ done: @escaping (Int32, Data, String) -> Void) {
        let full = "cd \(shellQuote(dir)) || exit 128\nexport GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0\n" + script
        if let remote { return remote.run(full, timeout: timeout, done) }
        DispatchQueue.global(qos: .userInitiated).async {
            let r = GitRunner.runLocal(full, timeout: timeout)
            DispatchQueue.main.async { done(r.0, r.1, r.2) }
        }
    }

    private static func runLocal(_ script: String, timeout: TimeInterval) -> (Int32, Data, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        // Apps started from the Dock get a bare PATH; add Homebrew's so its git (and hook tools) are found.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (127, Data(), error.localizedDescription) }
        let kill = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: kill)
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        kill.cancel()
        return (p.terminationStatus, outData, String(decoding: errData, as: UTF8.self))
    }
}

/// Keeps one window's status-bar git segment current for its focused pane, and runs what its menus offer.
final class GitController {
    private weak var bar: StatusBarView?
    /// The focused pane: whose folder is shown, and where "Run in Solanum" types.
    private let pane: () -> TerminalView?
    private let openFile: (FileSystem, String) -> Void
    /// Opens a tab (in a local folder, if given) and returns its pane, for commands the focused pane can't take.
    private let newTab: (String?) -> TerminalView?
    private var runner: GitRunner?
    private var refreshing = false
    private var refreshAgain = false
    private var lastRefresh = Date.distantPast
    private var trailingRefresh: DispatchWorkItem?
    private var timer: Timer?

    init(bar: StatusBarView, pane: @escaping () -> TerminalView?, openFile: @escaping (FileSystem, String) -> Void,
         newTab: @escaping (String?) -> TerminalView?) {
        self.bar = bar
        self.pane = pane
        self.openFile = openFile
        self.newTab = newTab
        // Picks up commits, edits and checkouts made outside Solanum.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, NSApp.isActive, self.bar?.window?.isVisible == true else { return }
            self.refresh()
        }
    }

    deinit { timer?.invalidate() }

    /// Follows the focused pane's folder; call whenever it (or the pane) may have changed.
    func update() {
        var next: GitRunner?
        if let p = pane(), let dir = p.browseDirectory, p.remote?.isReady ?? true {
            next = GitRunner(dir: dir, remote: p.remote)
        }
        if next?.key != runner?.key {
            runner = next
            bar?.git = nil
            bar?.gitBusy = nil
            lastRefresh = .distantPast
        }
        refresh()
    }

    /// Re-reads the status, at most every 1.5s (a refresh asked for sooner runs once that's up).
    func refresh(now: Bool = false) {
        guard let runner else { return }
        if now { lastRefresh = .distantPast }
        if refreshing { refreshAgain = true; return }
        let wait = 1.5 - Date().timeIntervalSince(lastRefresh)
        if wait > 0 {
            if trailingRefresh == nil {
                let work = DispatchWorkItem { [weak self] in
                    self?.trailingRefresh = nil
                    self?.refresh()
                }
                trailingRefresh = work
                DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
            }
            return
        }
        refreshing = true
        lastRefresh = Date()
        let key = runner.key
        runner.run(GitInfo.statusScript, timeout: 15) { [weak self] status, out, _ in
            guard let self else { return }
            self.refreshing = false
            if self.runner?.key == key {
                let info = status == 0 ? GitInfo(statusOutput: out) : nil
                if info != self.bar?.git { self.bar?.git = info }
            }
            if self.refreshAgain {
                self.refreshAgain = false
                self.refresh()
            }
        }
    }

    // MARK: Branches

    /// A searchable list of branches (most recently committed first); picking one switches to it.
    func showBranches() {
        guard let runner, let info = bar?.git, let window = bar?.window else { return }
        let format = "%(refname)%00%(refname:short)%00%(committerdate:relative)"
        runner.run("git for-each-ref --sort=-committerdate --format='\(format)' refs/heads refs/remotes") { [weak self] status, out, err in
            guard let self else { return }
            guard status == 0 else { return self.showError("Couldn't list branches", output: err) }
            var locals: [(name: String, date: String)] = [], remotes: [(name: String, date: String)] = []
            for line in String(decoding: out, as: UTF8.self).split(separator: "\n") {
                let f = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
                guard f.count == 3 else { continue }
                if f[0].hasPrefix("refs/heads/") {
                    locals.append((f[1], f[2]))
                } else if !f[0].hasSuffix("/HEAD") {
                    remotes.append((f[1], f[2]))
                }
            }
            let localNames = Set(locals.map(\.name))
            // Remote branches that already have a local branch of the same name are reached through that.
            remotes.removeAll { r in r.name.split(separator: "/", maxSplits: 1).last.map { localNames.contains(String($0)) } ?? false }

            typealias Item = CommandPalette.Item
            var items: [Item] = [
                Item(title: "Create New Branch…", path: "from \(info.branch)", shortcut: "") { [weak self] in
                    self?.promptNewBranch()
                },
                Item(title: "Fetch", path: "update remote branches", shortcut: "") { [weak self] in self?.fetch() },
            ]
            if !locals.isEmpty { items.append(.header("Branches")) }
            for b in locals {
                let current = !info.detached && b.name == info.branch
                items.append(Item(title: b.name, path: current ? "current · \(b.date)" : b.date, shortcut: "") { [weak self] in
                    if !current { self?.switchTo(b.name) }
                })
            }
            if !remotes.isEmpty { items.append(.header("Remote branches")) }
            for r in remotes {
                items.append(Item(title: r.name, path: r.date, shortcut: "") { [weak self] in self?.switchTo(r.name, tracking: true) })
            }
            CommandPalette.show(in: window, items: items, placeholder: "Switch branch (on \(info.branch))…",
                                keepsOrder: true, icon: "arrow.triangle.branch")
        }
    }

    private func switchTo(_ branch: String, tracking: Bool = false) {
        // "origin/feature" → a local "feature" that tracks it.
        let script = tracking ? "git switch --track \(shellQuote(branch))" : "git switch \(shellQuote(branch))"
        let local = tracking ? String(branch.split(separator: "/", maxSplits: 1).last ?? Substring(branch)) : branch
        perform("Switching…", script, typed: tracking ? "git switch --track \(branch)" : "git switch \(branch)") { [weak self] err in
            // Uncommitted changes in the way: offer to stash them first, as VS Code does.
            guard err.contains("would be overwritten") || err.contains("commit your changes or stash them") else { return false }
            self?.confirm("Your changes would be overwritten by switching to \(local).", detail: err, button: "Stash & Switch") {
                self?.perform("Switching…", "git stash push -m \(shellQuote("Solanum: before switching to \(local)")) && \(script)",
                              typed: "git stash && git switch \(local)")
            }
            return true
        }
    }

    private func promptNewBranch() {
        guard let window = bar?.window else { return }
        let alert = NSAlert()
        alert.messageText = "Create a branch"
        alert.informativeText = "It starts at the current commit and becomes the checked-out branch."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "feature/my-change"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard response == .alertFirstButtonReturn, !name.isEmpty else { return }
            self?.perform("Creating branch…", "git switch -c \(shellQuote(name))", typed: "git switch -c \(name)")
        }
    }

    // MARK: Sync

    func showSyncMenu(at point: NSPoint, in view: NSView) {
        guard let info = bar?.git else { return }
        let menu = NSMenu()
        if let upstream = info.upstream {
            let header = NSMenuItem(title: "Tracking \(upstream)", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(ActionMenuItem(info.behind > 0 ? "Pull (\(info.behind) incoming)" : "Pull") { [weak self] in self?.pull() })
            menu.addItem(ActionMenuItem(info.ahead > 0 ? "Push (\(info.ahead) outgoing)" : "Push") { [weak self] in self?.push() })
            menu.addItem(ActionMenuItem("Sync (Pull, then Push)") { [weak self] in
                self?.perform("Syncing…", "git pull && git push", typed: "git pull && git push")
            })
        } else if !info.detached {
            menu.addItem(ActionMenuItem("Publish Branch") { [weak self] in
                self?.perform("Publishing…", """
                    r=$(git remote | head -n 1)
                    [ -n "$r" ] || { echo "This repository has no remote to publish to." >&2; exit 1; }
                    git push -u "$r" HEAD
                    """, typed: "git push -u origin HEAD")
            })
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Fetch") { [weak self] in self?.fetch() })
        menu.popUp(positioning: nil, at: point, in: view)
    }

    private func pull() { perform("Pulling…", "git pull", typed: "git pull") }
    private func push() { perform("Pushing…", "git push", typed: "git push") }
    private func fetch() { perform("Fetching…", "git fetch --all --prune", typed: "git fetch --all --prune") }

    // MARK: Changes

    func showChangesMenu(at point: NSPoint, in view: NSView) {
        guard let info = bar?.git, let runner else { return }
        let menu = NSMenu()
        let names: [Character: String] = ["M": "Modified", "A": "Added", "D": "Deleted", "R": "Renamed", "C": "Copied",
                                          "T": "Type changed", "U": "Conflict", "?": "Untracked"]
        let header = NSMenuItem(title: "\(info.changes.count) changed file\(info.changes.count == 1 ? "" : "s")", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let th = Config.shared.theme
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        for c in info.changes.prefix(80) {
            let full = FilePaths.join(info.root, c.path)
            let item = ActionMenuItem(c.path) { [weak self] in self?.openFile(runner.fileSystem, full) }
            let title = NSMutableAttributedString(string: String(c.code == "?" ? "U" : c.code) + "  ",
                                                  attributes: [.font: mono, .foregroundColor: Self.color(for: c.code, th)])
            title.append(NSAttributedString(string: c.path, attributes: [.font: NSFont.menuFont(ofSize: 13)]))
            item.attributedTitle = title
            item.toolTip = names[c.code]
            // Deleted files have nothing to open.
            item.isEnabled = c.code != "D"
            menu.addItem(item)
        }
        if info.changes.count > 80 {
            let more = NSMenuItem(title: "…and \(info.changes.count - 80) more", action: nil, keyEquivalent: "")
            more.isEnabled = false
            menu.addItem(more)
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Show git status in Solanum") { [weak self] in self?.type("git status") })
        menu.autoenablesItems = false
        menu.popUp(positioning: nil, at: point, in: view)
    }

    static func color(for code: Character, _ th: Theme) -> NSColor {
        switch code {
        case "A", "?": return .systemGreen
        case "D": return .systemRed
        case "U": return .systemOrange
        default: return th.accent
        }
    }

    // MARK: Running

    /// Runs a git command in the background with `label` showing in the status bar. On failure `recover`
    /// may handle stderr itself (returning true); otherwise an alert shows it and offers to run `typed`
    /// in the terminal, where prompts (passwords, passphrases) can be answered.
    private func perform(_ label: String, _ script: String, typed: String, recover: ((String) -> Bool)? = nil) {
        guard let runner else { return }
        bar?.gitBusy = label
        runner.run(script, timeout: 300) { [weak self] status, out, err in
            guard let self else { return }
            self.bar?.gitBusy = nil
            self.refresh(now: true)
            guard status != 0 else { return }
            let message = err.isEmpty ? String(decoding: out, as: UTF8.self) : err
            if recover?(message) == true { return }
            self.showError("\(typed) failed", output: message, typed: typed)
        }
    }

    private func showError(_ title: String, output: String, typed: String? = nil) {
        guard let window = bar?.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        let lines = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n", omittingEmptySubsequences: false)
        alert.informativeText = lines.suffix(14).joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        let lock = Self.leftoverLock(in: output)
        if typed != nil { alert.addButton(withTitle: lock == nil ? "Run in Solanum" : "Remove Lock in Solanum") }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn, let typed else { return }
            // Removing the lock is only safe if no other git is still running there, so that one waits for Return.
            if let lock { self?.type("rm -f \(shellQuote(lock)) && \(typed)", run: false) } else { self?.type(typed) }
        }
    }

    /// The lock file in git's "Unable to create '….lock': File exists" (left behind by a git that crashed or was killed).
    static func leftoverLock(in output: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"Unable to create '([^'\n]+\.lock)': File exists"#),
              let m = re.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let r = Range(m.range(at: 1), in: output) else { return nil }
        return String(output[r])
    }

    private func confirm(_ title: String, detail: String, button: String, _ action: @escaping () -> Void) {
        guard let window = bar?.window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { action() } }
    }

    /// Types a command at the focused pane's prompt and (with `run`) runs it. A busy pane (an editor, Claude
    /// Code, a long job) gets a new tab in the repository instead; on an ssh host that tab logs back in and
    /// runs the command there straight away, as there's no prompt to wait at.
    private func type(_ command: String, run: Bool = true) {
        if let p = pane(), !p.exited, !p.terminal.usingAlt, p.remote != nil || !p.hasRunningJob {
            p.send("\u{15}" + command + (run ? "\r" : ""))
            p.window?.makeFirstResponder(p)
            return
        }
        guard let runner else { return NSSound.beep() }
        if let remote = runner.remote {
            guard let ssh = remote.reconnectCommand(in: runner.dir, then: command), let p = newTab(nil) else { return NSSound.beep() }
            p.pendingCommand = ssh
        } else {
            guard let p = newTab(runner.dir) else { return NSSound.beep() }
            p.pendingCommand = command
            p.pendingCommandRuns = run
        }
    }
}
