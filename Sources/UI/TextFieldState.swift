import Foundation

/// A one-line text field's contents and caret, with nothing about drawing.
struct TextFieldState {
    private(set) var text: String
    /// In characters.
    private(set) var caret: Int

    init(_ text: String) {
        self.text = text
        caret = text.count
    }

    var beforeCaret: String { String(text.prefix(caret)) }

    mutating func insert(_ s: String) {
        let clean = s.filter { !$0.isNewline }
        var chars = Array(text)
        chars.insert(contentsOf: clean, at: caret)
        text = String(chars)
        caret += clean.count
    }

    mutating func deleteBackward(word: Bool = false) {
        guard caret > 0 else { return }
        var chars = Array(text)
        var start = caret - 1
        if word {
            while start > 0, chars[start] == " " { start -= 1 }
            while start > 0, chars[start - 1] != " " { start -= 1 }
        }
        chars.removeSubrange(start..<caret)
        text = String(chars)
        caret = start
    }

    mutating func deleteForward() {
        guard caret < text.count else { return }
        var chars = Array(text)
        chars.remove(at: caret)
        text = String(chars)
    }

    mutating func move(by delta: Int) { caret = min(max(caret + delta, 0), text.count) }
    mutating func move(to position: Int) { caret = min(max(position, 0), text.count) }
}

/// Command aliases, as in the Mac's Settings › Aliases: a short name that runs a longer command.
struct CommandAlias: Codable, Equatable {
    var name: String
    var command: String

    /// Letters, digits and `_ . -`, not starting with `-`.
    static func isValidName(_ name: String) -> Bool {
        guard let first = name.first, first != "-" else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) }
    }

    /// PowerShell that defines these and removes the ones it defined before. Each is a function behind an alias, so it
    /// can stand in for one of PowerShell's own aliases and still pass on its arguments.
    static func powerShell(_ aliases: [CommandAlias]) -> String {
        let valid = aliases.filter { isValidName($0.name) && !$0.command.trimmingCharacters(in: .whitespaces).isEmpty }
        var out = #"foreach ($n in @($global:__solanum_alias_names)) { if ($n) { Remove-Item "Alias:\$n" -Force -ErrorAction SilentlyContinue } }"# + "\n"
        out += "$global:__solanum_alias_names = @(" + valid.map { "'\($0.name)'" }.joined(separator: ", ") + ")\n"
        for a in valid {
            let function = "__solanum_alias_" + a.name.replacingOccurrences(of: ".", with: "_").replacingOccurrences(of: "-", with: "_")
            out += "function global:\(function) { \(a.command) @args }\n"
            out += "Set-Alias -Name '\(a.name)' -Value '\(function)' -Scope Global -Option AllScope -Force\n"
        }
        return out
    }
}
