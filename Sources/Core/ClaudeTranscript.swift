import Foundation

/// What's in a Claude Code transcript (~/.claude/projects/<folder>/<session>.jsonl, one JSON record a line): the latest
/// prompt and what Claude last said after it, for the card shown when it finishes. Read from the file rather than the
/// screen, where a redraw can leave only an older prompt to find and the reply's mixed in with tool output. (Its code
/// blocks are in CodeBoxFinder.swift.)
extension ClaudeTranscript {
    /// From the end of a transcript (its first line may be cut off, and is skipped then): the latest prompt typed, and
    /// the text of Claude's last message after it (nil while it hasn't said anything since).
    static func lastExchange(_ tail: Data) -> (prompt: String?, reply: String?) {
        var prompt: String?, reply: String?
        for raw in tail.split(separator: UInt8(ascii: "\n")) {
            guard let record = try? JSONSerialization.jsonObject(with: Data(raw)) as? [String: Any],
                  let type = record["type"] as? String, record["isSidechain"] as? Bool != true else { continue }
            switch type {
            case "user":
                // A prompt (typed or pasted, images beside it), not a tool's result, a reminder the harness added
                // (`isMeta`), or a slash command's wrapper.
                guard record["isMeta"] as? Bool != true, let text = text(of: record, kind: "text"), !text.hasPrefix("<") else { continue }
                prompt = text
                reply = nil
            case "last-prompt":
                if prompt == nil, let p = record["lastPrompt"] as? String, !p.isEmpty { prompt = p }
            case "assistant":
                if let t = text(of: record, kind: "text") { reply = t }
            default:
                continue
            }
        }
        return (prompt, reply)
    }

    /// A message's text: its content when that's a string, else its parts of `kind` joined (nil without any).
    private static func text(of record: [String: Any], kind: String) -> String? {
        guard let message = record["message"] as? [String: Any] else { return nil }
        let text: String
        if let s = message["content"] as? String {
            text = s
        } else if let parts = message["content"] as? [[String: Any]] {
            let texts = parts.filter { $0["type"] as? String == kind }.compactMap { $0["text"] as? String }
            guard !texts.isEmpty else { return nil }
            text = texts.joined(separator: "\n")
        } else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// One line of `text` for a card: its first line with words in it, markdown's marks (headings, bullets, bold,
    /// code ticks) taken off, cut to `limit` characters.
    static func summary(_ text: String, limit: Int = 110) -> String {
        let line = text.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.contains { $0.isLetter || $0.isNumber } } ?? ""
        var s = line
        while let first = s.first, "#>-*+".contains(first) { s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces) }
        s = s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "").replacingOccurrences(of: "`", with: "")
        s = s.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return s.count > limit ? String(s.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…" : s
    }

    /// The end of the file at `path`: its last `bytes` (all of a smaller one).
    static func tail(of path: String, bytes: Int = 1 << 20) -> Data? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let size = h.seekToEndOfFile()
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        h.seek(toFileOffset: start)
        var data = h.readDataToEndOfFile()
        // Started mid-record: that part line isn't JSON.
        if start > 0, let nl = data.firstIndex(of: UInt8(ascii: "\n")) { data = data.subdata(in: data.index(after: nl)..<data.endIndex) }
        return data
    }
}
