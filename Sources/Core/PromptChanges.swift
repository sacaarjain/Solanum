import Foundation

// "Files changed this prompt": the pill over a pane running a coding agent and the panel it opens (the Mac's
// PromptChangesPanel). What's here is shared and Foundation only: reading the prompts and edits out of Claude Code's
// transcript, and reading git's answers about what changed since a prompt was sent.
//
// What changed comes from git when the pane's in a repository: when a prompt shows up in the transcript (it's written
// as you send it, before the agent does anything), the working tree is snapshotted (a tree object, made through a
// scratch index: nothing in the repository changes), and the files changed since are the difference between that
// tree and one made now. That sees every change however it was made (the agent's shell commands and scripts too, not
// only its edit tools). Outside a repository, or for a prompt sent before Solanum was watching, the transcript's own
// record of the agent's edits stands in.

/// A prompt sent to the agent.
struct AgentPrompt: Equatable {
    let id: String
    let text: String
}

/// A file changed since a prompt was sent, with git's counts (`path` relative to the repository's top folder, or
/// absolute outside one).
struct ChangedFile: Equatable {
    enum Change: Equatable { case modified, added, deleted }
    let path: String
    var change: Change = .modified
    var added: Int
    var removed: Int
    var binary = false
}

enum PromptChanges {
    /// What a stretch of a Claude Code transcript (JSON lines) holds: the prompts typed, in order, and the edits its
    /// tools made, by the prompt they were made for. Scanning more of the transcript adds to it.
    struct Scan {
        var prompts: [AgentPrompt] = []
        var edits: [String: [DiffFile]] = [:]
        var latest: AgentPrompt? { prompts.last }
    }

    static func scan(_ data: Data, into s: inout Scan) {
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            guard let j = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], j["type"] as? String == "user" else { continue }
            let id = j["promptId"] as? String ?? j["uuid"] as? String
            if let text = promptText(j), let id {
                // A prompt goes in once (Claude Code writes some twice, the second with attachments).
                if !s.prompts.contains(where: { $0.id == id }) { s.prompts.append(AgentPrompt(id: id, text: text)) }
                continue
            }
            guard let r = j["toolUseResult"] as? [String: Any], let file = edit(r), let owner = id ?? s.latest?.id else { continue }
            var list = s.edits[owner] ?? []
            if let i = list.firstIndex(where: { $0.path == file.path }) {
                // Another edit to the same file: its hunks follow the earlier ones.
                list[i].lines += file.lines
            } else {
                list.append(file)
            }
            s.edits[owner] = list
        }
    }

    /// The text of a prompt you typed, or nil for anything else on a "user" line: a tool's result, a slash command's
    /// wrapper or output, a note Claude Code adds itself.
    static func promptText(_ j: [String: Any]) -> String? {
        if j["isMeta"] as? Bool == true || j["isCompactSummary"] as? Bool == true { return nil }
        let content = (j["message"] as? [String: Any])?["content"]
        var text: String?
        if let s = content as? String { text = s }
        else if let parts = content as? [[String: Any]] {
            if parts.contains(where: { $0["type"] as? String == "tool_result" }) { return nil }
            let texts = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            if !texts.isEmpty { text = texts.joined(separator: "\n") }
        }
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty,
              !t.hasPrefix("<"), !t.hasPrefix("[Request interrupted"), !t.hasPrefix("Caveat:") else { return nil }
        return t
    }

    /// An edit tool's result as a file's diff: Edit's and MultiEdit's patch, or a new file Write made whole.
    static func edit(_ r: [String: Any]) -> DiffFile? {
        guard let path = r["filePath"] as? String else { return nil }
        if r["type"] as? String == "create", let content = r["content"] as? String {
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            let body = (lines.last?.isEmpty == true ? lines.dropLast() : lines[...]).enumerated().map {
                DiffFile.Line(kind: .added, text: String($0.element), old: nil, new: $0.offset + 1)
            }
            return DiffFile(oldPath: nil, newPath: path, lines: [DiffFile.Line(kind: .hunk, text: "@@ -0,0 +1,\(body.count) @@", old: nil, new: nil)] + body)
        }
        guard let hunks = r["structuredPatch"] as? [[String: Any]], !hunks.isEmpty else { return nil }
        var out: [DiffFile.Line] = []
        for h in hunks {
            var old = (h["oldStart"] as? NSNumber)?.intValue ?? 0, new = (h["newStart"] as? NSNumber)?.intValue ?? 0
            out.append(DiffFile.Line(kind: .hunk, text: "@@ -\(old),\((h["oldLines"] as? NSNumber)?.intValue ?? 0) +\(new),\((h["newLines"] as? NSNumber)?.intValue ?? 0) @@",
                                     old: nil, new: nil))
            for l in h["lines"] as? [String] ?? [] {
                if l.hasPrefix("+") { out.append(DiffFile.Line(kind: .added, text: String(l.dropFirst()), old: nil, new: new)); new += 1 }
                else if l.hasPrefix("-") { out.append(DiffFile.Line(kind: .removed, text: String(l.dropFirst()), old: old, new: nil)); old += 1 }
                else if l.hasPrefix("\\") { out.append(DiffFile.Line(kind: .note, text: String(l.dropFirst(2)), old: nil, new: nil)) }
                else { out.append(DiffFile.Line(kind: .context, text: String(l.dropFirst()), old: old, new: new)); old += 1; new += 1 }
            }
        }
        return DiffFile(oldPath: path, newPath: path, lines: out)
    }

    /// The transcript's edits as changed files, for when git can't say (`root`: shown relative to it).
    static func files(from edits: [DiffFile], root: String?) -> [ChangedFile] {
        edits.map { f in
            ChangedFile(path: relative(f.path, to: root), change: f.oldPath == nil ? .added : .modified, added: f.added, removed: f.removed)
        }
    }

    static func relative(_ path: String, to root: String?) -> String {
        guard let root, !root.isEmpty else { return path }
        let r = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(r) ? String(path.dropFirst(r.count)) : path
    }

    /// `git diff-tree -r --no-renames -z --raw` and `--numstat` for two trees, together: each file changed, how, and
    /// by how many lines.
    static func files(raw: String, numstat: String) -> [ChangedFile] {
        var kinds: [String: ChangedFile.Change] = [:]
        var order: [String] = []
        // ":100644 100644 <sha> <sha> M\0path\0", repeated.
        let r = raw.split(separator: "\0", omittingEmptySubsequences: false)
        var i = 0
        while i + 1 < r.count {
            let head = r[i], path = String(r[i + 1])
            guard head.hasPrefix(":") else { i += 1; continue }
            let status = head.split(separator: " ").last?.first
            kinds[path] = status == "A" ? .added : status == "D" ? .deleted : .modified
            order.append(path)
            i += 2
        }
        // "<added>\t<removed>\t<path>\0", "-\t-\t<path>" for a binary file.
        var counts: [String: (Int, Int, Bool)] = [:]
        for rec in numstat.split(separator: "\0") {
            let parts = rec.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let path = String(parts[2]).trimmingCharacters(in: .newlines)
            counts[path] = (Int(parts[0]) ?? 0, Int(parts[1]) ?? 0, parts[0] == "-")
            if kinds[path] == nil { kinds[path] = .modified; order.append(path) }
        }
        return order.map { p in
            let c = counts[p] ?? (0, 0, false)
            return ChangedFile(path: p, change: kinds[p] ?? .modified, added: c.0, removed: c.1, binary: c.2)
        }
    }
}

// MARK: - Asking the agent

extension PromptChanges {
    /// What "Ask about this change" pastes into the agent's input box (not sent: you write the question after it): a line
    /// saying which change, where in the file and how big, not the diff itself (the agent can read the files and git).
    /// `scope` says which prompt's ("for my last prompt", "in this chat").
    static func ask(about changes: [(file: ChangedFile, diff: DiffFile?)], scope: String = "for my last prompt") -> String {
        func place(_ c: (file: ChangedFile, diff: DiffFile?)) -> String {
            var parts: [String] = []
            if c.file.change == .modified, let d = c.diff, let lines = where_(d) { parts.append(lines) }
            parts.append(summary(c.file))
            return parts.joined(separator: ", ")
        }
        if changes.count == 1, let c = changes.first { return "About your change to \(c.file.path) (\(place(c))): " }
        let list = changes.map { "\(($0.file.path as NSString).lastPathComponent): \(place($0))" }
        return "About the changes you made \(scope) (\(list.joined(separator: "; "))): "
    }

    /// Where a file's change is, by its lines now ("line 6", "lines 3–4 and 20"; a few, then "and more"), or where lines
    /// were taken out when none were added.
    static func where_(_ d: DiffFile) -> String? {
        var nums = d.lines.compactMap { $0.kind == .added ? $0.new : nil }
        var removedOnly = false
        if nums.isEmpty { nums = d.lines.compactMap { $0.kind == .removed ? $0.old : nil }; removedOnly = true }
        guard !nums.isEmpty else { return nil }
        var ranges: [ClosedRange<Int>] = []
        for n in nums.sorted() {
            if let last = ranges.last, n <= last.upperBound + 1 { ranges[ranges.count - 1] = last.lowerBound...max(last.upperBound, n) }
            else { ranges.append(n...n) }
        }
        let shown = ranges.prefix(3).map { $0.count == 1 ? "\($0.lowerBound)" : "\($0.lowerBound)–\($0.upperBound)" }
        let single = ranges.count == 1 && ranges[0].count == 1
        let list = ranges.count > 3 ? shown.joined(separator: ", ") + " and more"
            : shown.count > 1 ? shown.dropLast().joined(separator: ", ") + " and " + shown.last! : shown[0]
        let text = (single ? "line " : "lines ") + list
        return removedOnly ? "removed at " + text : text
    }

    private static func summary(_ f: ChangedFile) -> String {
        switch f.change {
        case .added: return "new file, +\(f.added)"
        case .deleted: return "deleted, −\(f.removed)"
        case .modified: return "+\(f.added) −\(f.removed)"
        }
    }
}
