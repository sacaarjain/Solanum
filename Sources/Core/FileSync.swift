import Foundation

/// Keeping an open file current with the disk, as the Mac does (FileEditor's syncWithDisk and RemoteFileWatch there):
/// what's on disk is known by a signature (its modified time and size, and on a host its inode); when that differs from
/// what was read or saved, something else changed the file. Shared by the Mac and Windows.
enum FileSync {
    /// What to do about the signature on disk now, for a file read (or saved) as `known`.
    enum Action: Equatable {
        /// The same as what's shown.
        case nothing
        /// Changed, and nothing's typed: read it again, keeping the place.
        case reload
        /// Changed under unsaved edits: they stay, and the header says so (saving asks first).
        case changedUnderEdits
        /// Gone from disk.
        case deleted
    }

    static func action(known: String?, now: String?, hasUnsavedEdits: Bool) -> Action {
        guard let now else { return .deleted }
        guard now != known else { return .nothing }
        return hasUnsavedEdits ? .changedUnderEdits : .reload
    }

    /// On a host, a file's signature: modified time, size and inode, from GNU or BSD stat.
    static let statCommand = #"stat -c '%y %s %i' -- "$f" 2>/dev/null || stat -f '%Fm %z %i' -- "$f" 2>/dev/null"#

    /// One look at each of `paths` on a host: "<index from 1>\t<signature, or - when it's not there>" a line. Each is
    /// opened first: on a network mount (NFS) that makes the client ask the server, where a bare stat can keep answering
    /// from its cache for up to a minute while another machine writes the file.
    static func statScript(_ paths: [String]) -> String {
        """
        i=0
        for f in \(paths.map(quote).joined(separator: " ")); do
          i=$((i+1))
          [ -f "$f" ] && { : < "$f"; } 2>/dev/null
          g=$(\(statCommand))
          [ -n "$g" ] || g=-
          printf '%s\\t%s\\n' "$i" "$g"
        done
        """
    }

    /// `statScript`'s output: each path's signature, nil when it's not there. Paths it didn't report aren't in it.
    static func parseStats(_ output: String, paths: [String]) -> [String: String?] {
        var out: [String: String?] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, let i = Int(parts[0]), paths.indices.contains(i - 1) else { continue }
            out[paths[i - 1]] = parts[1] == "-" ? .some(nil) : .some(parts[1])
        }
        return out
    }

    private static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

/// Two texts side by side, line against line, as the Mac's Compare shows what's on disk beside unsaved edits.
enum TextDiff {
    enum Kind: Equatable { case same, removed, added, changed }

    struct Row: Equatable {
        /// Line numbers from 1, and the text, on each side; nil where that side has nothing.
        var left: (number: Int, text: String)?
        var right: (number: Int, text: String)?
        var kind: Kind

        static func == (a: Row, b: Row) -> Bool {
            a.kind == b.kind && a.left?.number == b.left?.number && a.left?.text == b.left?.text
                && a.right?.number == b.right?.number && a.right?.text == b.right?.text
        }
    }

    /// Lines the same on both sides line up; a run removed beside a run added pairs off as changed lines.
    static func rows(old: [String], new: [String]) -> [Row] {
        var ops: [(Kind, Int?, Int?)] = []
        // What's the same at the start and the end needn't be compared.
        var head = 0
        while head < old.count, head < new.count, old[head] == new[head] { head += 1 }
        var tail = 0
        while tail < old.count - head, tail < new.count - head, old[old.count - 1 - tail] == new[new.count - 1 - tail] { tail += 1 }
        for i in 0..<head { ops.append((.same, i, i)) }
        let a = Array(old[head..<(old.count - tail)]), b = Array(new[head..<(new.count - tail)])
        if a.count * b.count <= 4_000_000 {
            // Longest common run of lines, then walked from the start.
            let n = a.count, m = b.count
            var lcs = [[Int32]](repeating: [Int32](repeating: 0, count: m + 1), count: n + 1)
            if n > 0 && m > 0 {
                for i in stride(from: n - 1, through: 0, by: -1) {
                    for j in stride(from: m - 1, through: 0, by: -1) {
                        lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
                    }
                }
            }
            var i = 0, j = 0
            while i < n || j < m {
                if i < n, j < m, a[i] == b[j] { ops.append((.same, head + i, head + j)); i += 1; j += 1 }
                else if j < m, i == n || lcs[i][j + 1] >= lcs[i + 1][j] { ops.append((.added, nil, head + j)); j += 1 }
                else { ops.append((.removed, head + i, nil)); i += 1 }
            }
        } else {
            // Too big to compare line by line: the middle as one change.
            for i in a.indices { ops.append((.removed, head + i, nil)) }
            for j in b.indices { ops.append((.added, nil, head + j)) }
        }
        for k in 0..<tail { ops.append((.same, old.count - tail + k, new.count - tail + k)) }

        var out: [Row] = []
        var k = 0
        while k < ops.count {
            let (kind, l, r) = ops[k]
            if kind == .same, let l, let r {
                out.append(Row(left: (l + 1, old[l]), right: (r + 1, new[r]), kind: .same))
                k += 1
                continue
            }
            // A run of changes: removed lines beside added ones.
            var removed: [Int] = [], added: [Int] = []
            while k < ops.count, ops[k].0 != .same {
                if let l = ops[k].1 { removed.append(l) }
                if let r = ops[k].2 { added.append(r) }
                k += 1
            }
            for p in 0..<max(removed.count, added.count) {
                let left = p < removed.count ? (removed[p] + 1, old[removed[p]]) : nil
                let right = p < added.count ? (added[p] + 1, new[added[p]]) : nil
                out.append(Row(left: left, right: right, kind: left != nil && right != nil ? .changed : left != nil ? .removed : .added))
            }
        }
        return out
    }
}
