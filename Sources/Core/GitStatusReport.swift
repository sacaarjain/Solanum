import Foundation

// One commit's files and their changes, as the Mac's Git page shows them (GitStatusView.swift there): parsed here, without
// drawing, so Windows shows the same page. Foundation only.

/// A commit's changed files, with their line counts.
struct GitCommitReport: Equatable {
    struct Entry: Equatable {
        let path: String
        /// What a renamed or copied file was called.
        var oldPath: String?
        /// M, A, D, R, C or T.
        let code: Character
        /// Lines added and removed; nil when git doesn't count them (binary files).
        var added: Int?
        var removed: Int?
    }

    var root = ""
    let hash: String
    let short: String
    let author: String
    /// "3 days ago".
    let date: String
    let subject: String
    /// What it's compared with: its first parent, or the empty tree for a repository's first commit.
    let base: String
    var files: [Entry] = []

    var added: Int { files.compactMap(\.added).reduce(0, +) }
    var removed: Int { files.compactMap(\.removed).reduce(0, +) }

    /// The top folder, the commit and what it's compared with; the files changed; their line counts.
    static func script(commit hash: String) -> String {
        """
        h=\(quote(hash)); base=$(git rev-parse -q --verify "$h^" || git hash-object -t tree /dev/null)
        git rev-parse --show-toplevel && git log -1 --format='%H%x1f%h%x1f%an%x1f%ar%x1f%s' "$h" && printf '%s\\036' "$base" \
        && git diff --name-status -M -z "$base" "$h" && printf '\\036' && git diff --numstat -M -z "$base" "$h"
        """
    }

    init?(output: Data) {
        let parts = String(decoding: output, as: UTF8.self).components(separatedBy: "\u{1E}")
        guard parts.count == 3 else { return nil }
        // Split at any line ending: Swift counts "\r\n" as one character, which splitting at "\n" alone would miss.
        let head = parts[0].split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        // A top folder: /home/me/repo, or on Windows C:/Users/me/repo.
        guard head.count == 3, head[0].hasPrefix("/") || head[0].dropFirst().hasPrefix(":") else { return nil }
        let f = head[1].components(separatedBy: "\u{1F}")
        guard f.count == 5 else { return nil }
        root = head[0]
        hash = f[0]
        short = f[1]
        author = f[2]
        date = f[3]
        subject = f[4]
        base = head[2]
        let lines = Self.lineCounts(parts[2])
        // "M<NUL>path<NUL>", or for a rename or copy "R100<NUL>old<NUL>new<NUL>".
        let names = parts[1].split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i + 1 < names.count {
            guard let code = names[i].first else { break }
            let moved = code == "R" || code == "C"
            guard !moved || i + 2 < names.count else { break }
            let path = moved ? names[i + 2] : names[i + 1]
            files.append(Entry(path: path, oldPath: moved ? names[i + 1] : nil, code: code, added: lines[path]?.0, removed: lines[path]?.1))
            i += moved ? 3 : 2
        }
    }

    /// `git diff --numstat -z`: "added<TAB>removed<TAB>path", or for a rename an empty path and then both names.
    static func lineCounts(_ s: String) -> [String: (Int?, Int?)] {
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

    /// A word for sh.
    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

/// One line of a file's changes, as unfolded under its row.
struct GitPageLine: Equatable {
    enum Kind { case hunk, added, removed, context, note }
    let kind: Kind
    var old: Int?
    var new: Int?
    let text: String

    /// Lines shown per file.
    static let limit = 3000

    /// `git diff` output: what's in its hunks, without the file headers. A conflict's combined diff has a column per side
    /// and "@@@" hunks, so its lines have no single old and new number.
    static func parse(_ output: Data) -> [GitPageLine] {
        var out: [GitPageLine] = []
        var old = 0, new = 0, columns = 1, inHunk = false
        // Any line ending: git on Windows can print "\r\n", which Swift counts as one character.
        for line in String(decoding: output, as: UTF8.self).split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let raw = String(line)
            if raw.hasPrefix("Binary files ") || raw.hasPrefix("GIT binary patch") {
                return [GitPageLine(kind: .note, text: "Binary file: no text changes to show.")]
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
                out.append(GitPageLine(kind: .hunk, text: raw))
                continue
            }
            guard inHunk, !raw.isEmpty, !raw.hasPrefix("\\") else { continue }
            let prefix = raw.prefix(columns), text = String(raw.dropFirst(columns))
            if out.count >= limit {
                out.append(GitPageLine(kind: .note, text: "Showing the first \(limit) lines."))
                break
            }
            if columns > 1 {
                out.append(GitPageLine(kind: prefix.contains("+") ? .added : prefix.contains("-") ? .removed : .context, text: text))
            } else if prefix == "+" {
                out.append(GitPageLine(kind: .added, new: new, text: text))
                new += 1
            } else if prefix == "-" {
                out.append(GitPageLine(kind: .removed, old: old, text: text))
                old += 1
            } else {
                out.append(GitPageLine(kind: .context, old: old, new: new, text: text))
                old += 1
                new += 1
            }
        }
        return out
    }

    /// What one file of a commit changed against `base`.
    static func script(for e: GitCommitReport.Entry, hash: String, base: String) -> String {
        let q = GitCommitReport.quote
        let path = q(":(literal)" + e.path), old = e.oldPath.map { " " + q(":(literal)" + $0) } ?? ""
        return "git diff --no-color --no-ext-diff -M \(q(base)) \(q(hash)) -- \(path)\(old) | head -n \(limit + 20)"
    }
}
