import Foundation

// The Git Graph's filters, as IntelliJ's Git log has them, without drawing: a search for text or a hash, and Branch,
// User, Date and Paths. git does the filtering, so a search reaches the whole history rather than the newest commits
// loaded. Shared by the Mac (GitGraphFilters.swift draws its toolbar and branch list) and Windows (GitGraphPanel).

/// A word for sh, in single quotes.
func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// What the graph shows. Empty: every branch's history.
struct GraphFilter: Equatable {
    /// In a commit's message, or the start of its hash.
    var text = ""
    var regex = false
    var matchCase = false
    /// One branch or tag's history (its short name, as `git log` takes it); nil for all of them.
    var branch: String?
    var user: String?
    /// The last so many days.
    var days: Int?
    /// A folder or file in the repository (from its top).
    var path: String?

    var isEmpty: Bool { text.isEmpty && branch == nil && user == nil && days == nil && path == nil }
    /// Whether git keeps what's left connected: it rewrites parents past the commits a branch, date or path leaves
    /// out, but not past ones a text or user search does. For those the history's shape is read too (see `arrange`).
    var keepsAncestry: Bool { text.isEmpty && user == nil }

    /// How many commits' parents are read to connect a text or user search's commits.
    static let topologyLimit = 50000
    /// Between the commits and the history's shape in the script's output.
    static let topologyMark: UInt8 = 0x1D

    static let dayChoices: [(title: String, days: Int)] = [("Last 24 Hours", 1), ("Last 7 Days", 7), ("Last 30 Days", 30),
                                                          ("Last 90 Days", 90), ("Last Year", 365)]

    /// HEAD's hash on the first line, then the commits (see `GraphCommit.parse`).
    func script(limit: Int = GraphCommit.limit) -> String {
        let format = "--format='%H%x1f%P%x1f%an%x1f%at%x1f%s%x1f%D%x1e'"
        var args = [branch.map { shellQuote($0) } ?? "--all", "--parents", "--date-order", "-n \(limit)", format]
        if let user { args.append("--author=" + shellQuote("^" + NSRegularExpression.escapedPattern(for: user) + " <")) }
        if let days { args.append("--since=" + shellQuote("\(days) days ago")) }
        let query = text.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            args.append("--grep=" + shellQuote(query))
            args.append(regex ? "-E" : "-F")
            if !matchCase { args.append("-i") }
        }
        if let path { args += ["--", shellQuote(path)] }
        var script = "printf '%s\\n' \"$(git rev-parse HEAD 2>/dev/null)\"\ngit log " + args.joined(separator: " ")
        // A hash (or the start of one): that commit too, when it's one.
        if query.count >= 4, query.count <= 40, query.allSatisfy(\.isHexDigit) {
            let q = shellQuote(query + "^{commit}")
            script += "\nif h=$(git rev-parse -q --verify \(q) 2>/dev/null); then git log -n 1 \(format) \"$h\"; fi"
        }
        // Text or user: the history's shape too, newest first with children before parents, to connect what's shown.
        if !keepsAncestry {
            script += "\nprintf '\\035'\ngit log \(branch.map { shellQuote($0) } ?? "--all") --topo-order -n \(Self.topologyLimit) --format='%H %P'"
        }
        return script
    }

    /// The script's output split into the commits (for `GraphCommit.parse`) and, when it was read, each commit's
    /// parents.
    static func split(_ out: Data) -> (log: Data, topology: [(String, [String])]?) {
        guard let mark = out.firstIndex(of: topologyMark) else { return (out, nil) }
        var topology: [(String, [String])] = []
        for line in String(decoding: out[out.index(after: mark)...], as: UTF8.self).split(separator: "\n") {
            let f = line.split(separator: " ").map(String.init)
            if let h = f.first { topology.append((h, Array(f.dropFirst()))) }
        }
        return (Data(out[..<mark]), topology)
    }

    /// The commits as the graph should lay them out: each once, newest first, and (for a text or user search) with
    /// parents that aren't shown left out, rather than lines to commits that aren't there.
    /// The commits as the graph should lay them out: each once, newest first. For a text or user search, each one's
    /// parents become its nearest ancestors that are shown, through the ones that aren't (as IntelliJ draws it), from
    /// `topology` (children before parents); without it, parents that aren't shown are just left out.
    func arrange(_ commits: [GraphCommit], topology: [(String, [String])]? = nil) -> [GraphCommit] {
        var seen = Set<String>(), out: [GraphCommit] = []
        for c in commits where seen.insert(c.hash).inserted { out.append(c) }
        if out.count != commits.count || !text.isEmpty { out.sort { $0.date > $1.date } }
        guard !keepsAncestry else { return out }
        let shown = Set(out.map(\.hash))
        // Oldest first, so each commit's parents are worked out before it: its nearest shown ancestors are its shown
        // parents, and those of the parents that aren't (a few at most, so a busy history stays cheap).
        var nearest: [String: [String]] = [:]
        for (hash, parents) in (topology ?? []).reversed() {
            var acc: [String] = []
            for p in parents {
                for a in shown.contains(p) ? [p] : nearest[p] ?? [] where !acc.contains(a) && acc.count < 3 { acc.append(a) }
            }
            nearest[hash] = acc
        }
        return out.map { c in
            let parents = nearest[c.hash] ?? c.parents.filter(shown.contains)
            return GraphCommit(hash: c.hash, parents: parents, author: c.author, date: c.date, subject: c.subject, refs: c.refs)
        }
    }
}

/// A repository's branches and tags, for the list beside the graph.
struct GraphRefs {
    var current: String?
    var locals: [String] = []
    var remotes: [String] = []
    var tags: [String] = []

    static let script = """
        git symbolic-ref -q --short HEAD; printf '\\036'
        git for-each-ref --sort=refname --format='%(refname)' refs/heads refs/remotes refs/tags
        """

    static func parse(_ out: Data) -> GraphRefs {
        let s = String(decoding: out, as: UTF8.self)
        let parts = s.components(separatedBy: "\u{1e}")
        var refs = GraphRefs()
        let current = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        refs.current = current.isEmpty ? nil : current
        for line in (parts.count > 1 ? parts[1] : "").split(separator: "\n").map(String.init) {
            if line.hasPrefix("refs/heads/") { refs.locals.append(String(line.dropFirst(11))) }
            else if line.hasPrefix("refs/remotes/"), !line.hasSuffix("/HEAD") { refs.remotes.append(String(line.dropFirst(13))) }
            else if line.hasPrefix("refs/tags/") { refs.tags.append(String(line.dropFirst(10))) }
        }
        return refs
    }
}

