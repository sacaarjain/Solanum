import Foundation

// Search in Project Folder, without drawing: the script that searches (ripgrep, git grep or grep, wherever the folder
// is) and what it prints. Shared by the Mac and Windows, where Git for Windows' sh runs it.

struct WorkspaceMatch: Equatable {
    /// Relative to the folder searched.
    let path: String
    let line: Int
    let text: String

    /// A word for sh.
    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Matches to show; more than that and the search is too broad to read anyway.
    static let limit = 500

    /// The tool to use. `lead` goes before it: "exec" here, so stopping the shell stops the search.
    private static func command(query: String, lead: String) -> String {
        let q = Self.quote(query)
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
        "cd \(Self.quote(dir)) || exit 1\nexport GIT_OPTIONAL_LOCKS=0\n" + command(query: query, lead: "exec")
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

