import AppKit

// Search in Project Folder (⇧⌘F, or the sidebar's magnifying glass): searches the text of the files under the folder the sidebar is on, from the palette. It runs
// where the folder is (over the ssh session for a remote one), with ripgrep if that's there, else `git grep` in a
// repository, else `grep`: the first two leave out what .gitignore does.

struct WorkspaceMatch: Equatable {
    /// Relative to the folder searched.
    let path: String
    let line: Int
    let text: String

    /// Matches to show; more than that and the search is too broad to read anyway.
    static let limit = 500

    /// The tool to use. `lead` goes before it: "exec" here, so stopping the shell stops the search.
    private static func command(query: String, lead: String) -> String {
        let q = shellQuote(query)
        let skip = ["node_modules", ".git", ".cache", ".npm", ".nvm", ".gradle", "Library"].map { "--exclude-dir=\($0)" }.joined(separator: " ")
        return """
        if command -v rg >/dev/null 2>&1; then \(lead) rg --null -n -i -F --no-heading --color=never -e \(q) .
        elif git rev-parse --git-dir >/dev/null 2>&1; then \(lead) git grep -z -n -I -i -F --untracked -e \(q)
        else \(lead) grep -rnIiF --null \(skip) -e \(q) .
        fi
        """
    }

    /// On an ssh host it can't be stopped from here, so it's given a time limit and a limit on what it prints.
    static func remoteScript(query: String) -> String {
        "t=; command -v timeout >/dev/null 2>&1 && t='timeout 20'\n{ \(command(query: query, lead: "$t")); } 2>/dev/null | head -n \(limit + 1)"
    }

    static func localScript(query: String, dir: String) -> String {
        "cd \(shellQuote(dir)) || exit 1\nexport GIT_OPTIONAL_LOCKS=0\n" + command(query: query, lead: "exec")
    }

    /// "path<NUL>line:text" per line; a NUL also after the number where git puts one.
    static func parse(_ output: Data) -> [WorkspaceMatch] {
        var out: [WorkspaceMatch] = []
        for raw in String(decoding: output, as: UTF8.self).split(separator: "\n") {
            guard let nul = raw.firstIndex(of: "\0") else { continue }
            var path = raw[..<nul]
            if path.hasPrefix("./") { path = path.dropFirst(2) }
            let rest = raw[raw.index(after: nul)...]
            let digits = rest.prefix { $0.isNumber }
            guard let line = Int(digits), let sep = rest.dropFirst(digits.count).first, sep == ":" || sep == "\0" else { continue }
            out.append(WorkspaceMatch(path: String(path), line: line, text: String(rest.dropFirst(digits.count + 1))))
        }
        return out
    }

    /// The line as a row shows it: no indentation, and a long one starting near the match so that's in view.
    static func excerpt(_ text: String, query: String) -> String {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard let r = t.range(of: query, options: .caseInsensitive) else { return String(t.prefix(300)) }
        let before = t.distance(from: t.startIndex, to: r.lowerBound)
        guard before > 40 else { return String(t.prefix(300)) }
        return "…" + t[t.index(r.lowerBound, offsetBy: -24)...].prefix(300)
    }
}

/// One search at a time, reporting what it's found as it goes. Starting another, or letting go of this, stops the last:
/// a broad search over a big folder shouldn't keep running behind each key typed.
final class WorkspaceSearcher {
    private static let timeLimit: TimeInterval = 20
    /// What's running, for stopping it when Solanum quits (a child process would otherwise carry on by itself).
    private static var running: Process?
    private static let stopAtExit: Void = { atexit { WorkspaceSearcher.running?.terminate() } }()
    private let dir: String
    private let remote: RemoteSession?
    private var generation = 0
    private var process: Process?

    init(dir: String, remote: RemoteSession?) {
        self.dir = dir
        self.remote = remote
    }

    deinit { process?.terminate() }

    func cancel() {
        generation += 1
        process?.terminate()
        process = nil
    }

    /// `update` gets the matches so far on the main queue, last with `done` true; `stopped` if it hit the time limit.
    func start(_ query: String, update: @escaping (_ matches: [WorkspaceMatch], _ done: Bool, _ stopped: Bool) -> Void) {
        cancel()
        let mine = generation
        if let remote {
            GitRunner(dir: dir, remote: remote).run(WorkspaceMatch.remoteScript(query: query), timeout: Self.timeLimit + 5) { [weak self] _, out, _ in
                guard let self, self.generation == mine else { return }
                update(WorkspaceMatch.parse(out), true, false)
            }
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", WorkspaceMatch.localScript(query: query, dir: dir)]
        // Apps started from the Dock get a bare PATH, as for git (see GitRunner).
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return update([], true, false) }
        process = p
        _ = Self.stopAtExit
        Self.running = p
        // Up to here on the main queue; the reading isn't, and goes back there to report.
        let report: ([WorkspaceMatch], Bool, Bool) -> Void = { [weak self] m, done, stopped in
            DispatchQueue.main.async {
                guard let self, self.generation == mine else { return }
                update(m, done, stopped)
            }
        }
        var timedOut = false
        let limiter = DispatchWorkItem { [weak p] in
            timedOut = true
            p?.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeLimit, execute: limiter)
        DispatchQueue.global(qos: .userInitiated).async {
            let handle = pipe.fileHandleForReading
            var buffer = Data()
            var matches: [WorkspaceMatch] = []
            var lastReport = Date()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                // Whole lines only; the rest waits for the next chunk.
                if let end = buffer.lastIndex(of: 0x0A) {
                    matches += WorkspaceMatch.parse(buffer[...end])
                    buffer.removeSubrange(...end)
                }
                if matches.count > WorkspaceMatch.limit {
                    p.terminate()
                    break
                }
                if Date().timeIntervalSince(lastReport) > 0.2 {
                    lastReport = Date()
                    report(matches, false, false)
                }
            }
            limiter.cancel()
            report(matches, true, timedOut)
        }
    }
}

extension CommandPalette {
    /// Opens over `folder`: searches as it's typed, and choosing a result calls `open` with its full path, line and the query.
    static func findInFolder(in window: NSWindow, fs: FileSystem, folder: String, query: String = "",
                             open: @escaping (String, Int, String) -> Void) {
        let searcher = WorkspaceSearcher(dir: folder, remote: fs as? RemoteSession)
        let shown = FilePaths.abbreviate(folder, home: fs.home)
        var pending: DispatchWorkItem?
        showLive(in: window, placeholder: "Search in files…", scope: "in \(shown)", message: "Type to search this folder.", query: query) { palette, typed in
            pending?.cancel()
            searcher.cancel()
            let q = typed
            guard q.count >= 2 else {
                palette.setResults([], scope: "in \(shown)", message: q.isEmpty ? "Type to search this folder." : "Keep typing…")
                return
            }
            palette.setSearching()
            let work = DispatchWorkItem { [weak palette] in
                searcher.start(q) { [weak palette] all, done, stopped in
                    guard let palette else { return }
                    let matches = Array(all.prefix(WorkspaceMatch.limit))
                    var items: [Item] = []
                    var last: String?
                    for m in matches {
                        if m.path != last {
                            var header = Item.header(m.path)
                            header.keepsCase = true
                            items.append(header)
                            last = m.path
                        }
                        var item = Item(title: WorkspaceMatch.excerpt(m.text, query: q), path: "line \(m.line)", shortcut: "") {
                            open(FilePaths.join(folder, m.path), m.line, q)
                        }
                        item.highlight = q
                        items.append(item)
                    }
                    let files = Set(matches.map(\.path)).count
                    let count = all.count > matches.count ? "first \(matches.count) results"
                        : !done ? "\(matches.count)…" : stopped ? "\(matches.count), stopped after 20s"
                        : "\(matches.count) result\(matches.count == 1 ? "" : "s")"
                    let scope = matches.isEmpty ? (done && stopped ? "stopped after 20s · \(shown)" : "in \(shown)") : "\(count) in \(files) file\(files == 1 ? "" : "s") · \(shown)"
                    palette.setResults(items, scope: scope, message: !done ? "Searching…" : stopped ? "Nothing found before the 20 second limit." : "No results in \(shown).",
                                       keepSelection: true)
                }
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
        }
    }
}
