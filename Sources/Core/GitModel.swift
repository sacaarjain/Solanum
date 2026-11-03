import Foundation

// Git, without drawing: a folder's status for the status bar, its branches, and its history as a graph with lanes.
// Shared by the Mac and Windows. Paths are as git gives them: "/…" on a Mac or an ssh host, "C:/…" on Windows.

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
    /// What's staged ("." for nothing) and what's not, as git status's XY: Git Changes lists them apart.
    var staged: Character = "."
    var unstaged: Character = "."
}

extension GitInfo {
    static let statusScript = "git rev-parse --show-toplevel && git status --porcelain=v2 --branch -z"

    /// Parses `statusScript`'s output: the top-level folder on one line, then NUL-separated porcelain v2.
    init?(statusOutput out: Data) {
        let s = String(decoding: out, as: UTF8.self)
        guard let nl = s.firstIndex(of: "\n") else { return nil }
        root = String(s[..<nl])
        // Windows' git gives "C:/…".
        guard root.hasPrefix("/") || root.dropFirst().hasPrefix(":") else { return nil }
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
                let xy = Array(parts[1])
                var change = GitChange(code: code, path: String(parts[n]))
                if kind == "u" { change.unstaged = "U" } else if xy.count == 2 { change.staged = xy[0]; change.unstaged = xy[1] }
                changes.append(change)
            } else if f.hasPrefix("? ") {
                changes.append(GitChange(code: "?", path: String(f.dropFirst(2)), unstaged: "?"))
            }
        }
        if branch == "(detached)" {
            detached = true
            branch = String(oid.prefix(7))
        }
    }
}

extension GitInfo {
    /// The lock file in git's "Unable to create '….lock': File exists" (left behind by a git that crashed or was killed).
    static func leftoverLock(in output: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"Unable to create '([^'\n]+\.lock)': File exists"#),
              let m = re.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let r = Range(m.range(at: 1), in: output) else { return nil }
        return String(output[r])
    }
}

struct GraphCommit {
    let hash: String
    let parents: [String]
    let author: String
    let date: Date
    let subject: String
    /// Branches and tags pointing here, as `git log --format=%D` lists them ("HEAD -> main", "origin/main", "tag: v1").
    let refs: [String]

    static let limit = 2000
    /// HEAD's hash on the first line (empty in a repository without commits), then the newest commits on any branch.
    static let script = """
        printf '%s\\n' "$(git rev-parse HEAD 2>/dev/null)"
        git log --all --date-order -n \(limit) --format='%H%x1f%P%x1f%an%x1f%at%x1f%s%x1f%D%x1e'
        """

    static func parse(_ out: Data) -> (head: String, commits: [GraphCommit]) {
        let s = String(decoding: out, as: UTF8.self)
        guard let nl = s.firstIndex(of: "\n") else { return ("", []) }
        var commits: [GraphCommit] = []
        for record in s[s.index(after: nl)...].split(separator: "\u{1e}") {
            let f = record.trimmingCharacters(in: .newlines).components(separatedBy: "\u{1f}")
            guard f.count == 6 else { continue }
            commits.append(GraphCommit(hash: f[0], parents: f[1].split(separator: " ").map(String.init), author: f[2],
                                       date: Date(timeIntervalSince1970: TimeInterval(f[3]) ?? 0), subject: f[4],
                                       refs: f[5].isEmpty ? [] : f[5].components(separatedBy: ", ")))
        }
        return (String(s[..<nl]), commits)
    }
}

/// A commit's place in the graph: its lane, and the lines through its row.
struct GraphRow {
    enum Segment {
        /// A lane passing by, top to bottom.
        case through(Int)
        /// From a lane at the top into the commit (a branch ending here, or merging into it).
        case top(from: Int, to: Int)
        /// From the commit down to a parent's lane.
        case bottom(from: Int, to: Int)
    }

    let commit: GraphCommit
    let lane: Int
    let color: Int
    let segments: [(segment: Segment, color: Int)]
    /// Lanes in use across the row; the text starts after them.
    let width: Int
}

enum GraphLayout {
    /// Lanes are handed out left to right and kept until their line ends, so a line stays in one column for
    /// its whole length; a lane's color is picked when it starts and stays with it.
    static func rows(_ commits: [GraphCommit]) -> [GraphRow] {
        var lanes: [String?] = [], colors: [Int] = [], nextColor = 0
        func freeLane() -> Int {
            if let i = lanes.firstIndex(where: { $0 == nil }) { return i }
            lanes.append(nil)
            colors.append(0)
            return lanes.count - 1
        }
        var rows: [GraphRow] = []
        for c in commits {
            let before = lanes, beforeColors = colors
            let lane: Int
            if let i = lanes.firstIndex(of: c.hash) {
                lane = i
            } else {
                // A branch tip: nothing above leads here.
                lane = freeLane()
                lanes[lane] = c.hash
                colors[lane] = nextColor
                nextColor += 1
            }
            let color = colors[lane]
            var segments: [(GraphRow.Segment, Int)] = []
            for (i, h) in before.enumerated() {
                guard let h else { continue }
                if h == c.hash {
                    segments.append((.top(from: i, to: lane), beforeColors[i]))
                    if i != lane { lanes[i] = nil }
                } else {
                    segments.append((.through(i), beforeColors[i]))
                }
            }
            if let first = c.parents.first {
                lanes[lane] = first
                segments.append((.bottom(from: lane, to: lane), colors[lane]))
                for p in c.parents.dropFirst() {
                    let j: Int
                    if let k = lanes.firstIndex(of: p) {
                        j = k
                    } else {
                        j = freeLane()
                        lanes[j] = p
                        colors[j] = nextColor
                        nextColor += 1
                    }
                    segments.append((.bottom(from: lane, to: j), colors[j]))
                }
            } else {
                lanes[lane] = nil
            }
            while let last = lanes.last, last == nil {
                lanes.removeLast()
                colors.removeLast()
            }
            rows.append(GraphRow(commit: c, lane: lane, color: color, segments: segments, width: max(before.count, lanes.count, lane + 1)))
        }
        return rows
    }
}

/// A branch or tag beside a commit in the graph.
struct GraphLabel {
    enum Kind { case branch, remote, tag, head }
    let kind: Kind
    let name: String
    /// The current branch.
    var current = false
    /// A branch whose remote twin (origin/<name>) points here too: shown as a cloud on the branch.
    var onRemote = false


    static func labels(_ refs: [String]) -> [GraphLabel] {
        var out: [GraphLabel] = []
        for ref in refs {
            if ref.hasPrefix("HEAD -> ") {
                out.append(GraphLabel(kind: .branch, name: String(ref.dropFirst(8)), current: true))
            } else if ref == "HEAD" {
                out.append(GraphLabel(kind: .head, name: "HEAD"))
            } else if ref.hasPrefix("tag: ") {
                out.append(GraphLabel(kind: .tag, name: String(ref.dropFirst(5))))
            } else if ref.contains("/") {
                out.append(GraphLabel(kind: .remote, name: ref))
            } else {
                out.append(GraphLabel(kind: .branch, name: ref))
            }
        }
        for (i, l) in out.enumerated() where l.kind == .branch {
            if let r = out.firstIndex(where: { $0.kind == .remote && $0.name.split(separator: "/", maxSplits: 1).last.map(String.init) == l.name }) {
                out[i].onRemote = true
                out[r] = GraphLabel(kind: .remote, name: "")
            }
        }
        out.removeAll { $0.kind == .remote && $0.name.hasSuffix("/HEAD") || $0.name.isEmpty }
        // Current branch first, then branches, tags, and remotes last.
        let order: [GraphLabel.Kind: Int] = [.head: 0, .branch: 1, .tag: 2, .remote: 3]
        return out.enumerated().sorted { a, b in
            (a.element.current ? -1 : order[a.element.kind]!, a.offset) < (b.element.current ? -1 : order[b.element.kind]!, b.offset)
        }.map(\.element)
    }
}

/// A branch, as `for-each-ref` lists them: local first, most recently committed first.
struct GitBranch: Equatable {
    let name: String
    let isRemote: Bool
    /// When it was last committed to, as git says it ("3 days ago").
    let date: String

    static let script = "git for-each-ref --sort=-committerdate --format='%(refname)%00%(refname:short)%00%(committerdate:relative)' refs/heads refs/remotes"

    /// Remote branches with a local branch of the same name are reached through that one, so they're left out.
    static func parse(_ out: Data) -> [GitBranch] {
        var locals: [GitBranch] = [], remotes: [GitBranch] = []
        for line in String(decoding: out, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let f = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 3 else { continue }
            if f[0].hasPrefix("refs/heads/") {
                locals.append(GitBranch(name: f[1], isRemote: false, date: f[2]))
            } else if !f[0].hasSuffix("/HEAD") {
                remotes.append(GitBranch(name: f[1], isRemote: true, date: f[2]))
            }
        }
        let names = Set(locals.map(\.name))
        remotes.removeAll { r in r.name.split(separator: "/", maxSplits: 1).last.map { names.contains(String($0)) } ?? false }
        return locals + remotes
    }
}

/// A line of `git diff`, for colouring it.
enum GitDiffKind: Equatable { case header, hunk, added, removed, context }

extension GitDiffKind {
    static func of(_ line: Substring) -> GitDiffKind {
        if line.hasPrefix("@@") { return .hunk }
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ")
            || line.hasPrefix("new file") || line.hasPrefix("deleted file") || line.hasPrefix("similarity") || line.hasPrefix("rename ") { return .header }
        if line.hasPrefix("+") { return .added }
        if line.hasPrefix("-") { return .removed }
        return .context
    }
}
