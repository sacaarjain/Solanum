import Foundation

/// What a shell prompt on an ssh host looks like, for finding its commands without hooks in that shell (see
/// `Terminal.remoteEnterPressed`).
enum HostPrompt {
    /// What prompts end with, before the space where typing goes.
    static let endings: Set<Character> = ["$", "#", "%", ">", "❯", "➜", "»", "λ", "→", "➤", "▶", "❱", "⟩", "✗", "✔"]

    /// Whether `text`, what's before the cursor, is a prompt: it ends in a prompt character, or starts like the prompts
    /// this session has had.
    static func isPrompt(_ text: String, heads: [String]) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count <= 200 else { return false }
        if let last = t.last, endings.contains(last) { return true }
        return heads.contains { t.hasPrefix($0) }
    }

    /// Where the prompt ends on the line Enter was pressed on, or nil when it isn't a prompt. `noted` is what was before
    /// the cursor when typing began there; without it (the command was pasted, or came back from history before
    /// anything was typed), a prompt character followed by a space after something like user@host, a path or a [.
    /// The session's first command trusts what was noted, whatever its shape, so an unusual prompt can be learned.
    static func end(of line: String, noted: String?, heads: [String], firstCommand: Bool) -> Int? {
        if let noted, line.hasPrefix(noted) {
            if isPrompt(noted, heads: heads) { return noted.count }
            // Not a question or a password: those end in ? or :.
            let t = noted.trimmingCharacters(in: .whitespaces)
            if firstCommand, let last = t.last, last != ":", last != "?" { return noted.count }
            return nil
        }
        let chars = Array(line)
        for i in 0..<min(chars.count, 160) where endings.contains(chars[i]) && (i + 1 == chars.count || chars[i + 1] == " ") {
            let head = String(chars[0...i])
            if i == 0 || head.contains("@") || head.contains("~") || head.contains("/") || head.hasPrefix("[") || heads.contains(where: { head.hasPrefix($0) }) {
                return min(i + 2, chars.count)
            }
        }
        if let h = heads.first(where: { line.hasPrefix($0) }) { return h.count }
        return nil
    }

    /// How later prompts will start: the prompt's first word, when it has a letter in it.
    static func head(_ prompt: String) -> String? {
        guard let first = prompt.split(separator: " ").first.map(String.init), first.count >= 2,
              first.contains(where: { $0.isLetter }), first.count < 60 else { return nil }
        return first
    }
}
