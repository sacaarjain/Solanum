import Foundation

// Find in the terminal (⌘F on the Mac, Ctrl+F on Windows), without drawing: which cells of the transcript match, in all
// of it, only what was typed (commands and agent prompts), or only output. Shared by the Mac's SearchBar and Windows'.

struct SearchMatch: Equatable {
    var line: Int
    var start: Int
    var end: Int
}

/// Which part of the transcript ⌘F searches.
enum SearchScope: Int, CaseIterable {
    case all, commands, output

    var title: String {
        switch self {
        case .all: return "All"
        case .commands: return "Commands"
        case .output: return "Output"
        }
    }
}

enum TerminalSearch {
    /// Every match of `query` in the transcript, top to bottom: case matters only when the query has a capital.
    /// `start` and `end` are columns, both included.
    static func matches(_ query: String, in terminal: Terminal, scope: SearchScope) -> [SearchMatch] {
        guard !query.isEmpty else { return [] }
        let caseSensitive = query.contains { $0.isUppercase }
        let opts: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        let (commandCols, promptLines) = scope == .all ? ([:], []) : commandAndPromptLines(terminal)
        var out: [SearchMatch] = []
        var a = terminal.firstAbs
        while a <= terminal.lastAbs {
            defer { a += 1 }
            let minCol: Int
            switch scope {
            case .all: minCol = 0
            case .commands:
                guard let c = commandCols[a] else { continue }
                minCol = c
            case .output:
                guard commandCols[a] == nil, !promptLines.contains(a) else { continue }
                minCol = 0
            }
            guard let l = terminal.line(abs: a) else { continue }
            var s = ""
            var map: [Int] = []
            for x in 0..<l.cells.count {
                let c = l.cells[x]
                if c.width == 0 { continue }
                let str = c.ch == 0 ? " " : String(Character(Unicode.Scalar(c.ch) ?? " "))
                for _ in str.utf16 { map.append(x) }
                s += str
            }
            let ns = NSString(string: s)
            var range = NSRange(location: 0, length: ns.length)
            while range.length > 0 {
                let r = ns.range(of: query, options: opts, range: range)
                if r.location == NSNotFound { break }
                let m = SearchMatch(line: a, start: map[r.location], end: map[max(r.location, r.location + r.length - 1)])
                if m.start >= minCol { out.append(m) }
                let next = r.location + max(r.length, 1)
                range = NSRange(location: next, length: ns.length - next)
            }
        }
        return out
    }

    /// Lines holding typed commands (shell commands and agent prompts) mapped to the column the text starts at,
    /// plus shell-prompt (PS1) lines, which count as neither commands nor output.
    static func commandAndPromptLines(_ terminal: Terminal) -> ([Int: Int], Set<Int>) {
        var commands: [Int: Int] = [:]
        var prompts = Set<Int>()
        for b in terminal.blocks {
            guard let c = b.commandLine else {
                if b.state == .prompt { for a in b.promptLine...b.lastLine(cursorAbs: terminal.cursorAbs) { prompts.insert(a) } }
                continue
            }
            for a in stride(from: b.promptLine, to: c, by: 1) { prompts.insert(a) }
            let end = max(c, b.state == .prompt ? b.lastLine(cursorAbs: terminal.cursorAbs) : (b.outputLine ?? c + 1) - 1)
            for a in c...end { commands[a] = a == c ? b.commandCol : 0 }
            for t in terminal.agentTurns(in: b) {
                for a in t.promptLine...t.promptEnd { commands[a] = 2 }
            }
        }
        return (commands, prompts)
    }

    /// The match to start from: the last one at or above the bottom of what's showing.
    static func startIndex(_ matches: [SearchMatch], bottomLine: Int) -> Int? {
        guard !matches.isEmpty else { return nil }
        return matches.lastIndex { $0.line <= bottomLine } ?? matches.count - 1
    }
}
