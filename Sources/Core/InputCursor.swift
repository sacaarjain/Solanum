import Foundation

// Where the text being typed is on screen, for moving its cursor to a click. Shells and Claude Code don't handle mouse
// clicks themselves, so the app sends the arrow keys that get there, and has to work out how many.
extension Terminal {
    /// Characters (not cells: wide-char tails don't count) in columns from..<to of a line.
    func charCount(_ a: Int, from: Int, to: Int) -> Int {
        guard let l = line(abs: a) else { return 0 }
        let hi = min(to, l.cells.count)
        guard from < hi else { return 0 }
        return l.cells[from..<hi].reduce(0) { $0 + ($1.width != 0 ? 1 : 0) }
    }

    /// Readline soft-wraps by cell, so the command is one run of cells from the end of the prompt through
    /// the cursor's line and any continuation lines; left/right arrows step through it linearly.
    /// `index` maps a cell to a character offset in the command (cells before it count as 0).
    func shellInput(_ b: Block) -> (start: Int, last: Int, index: (Int, Int) -> Int)? {
        guard b.state == .prompt, let start = b.commandLine else { return nil }
        var last = max(start, cursorAbs)
        while last < lastAbs, line(abs: last)?.wrapped == true { last += 1 }
        let index: (Int, Int) -> Int = { [unowned self] line, col in
            guard line >= start else { return 0 }
            return (start...line).reduce(0) { n, a in
                n + self.charCount(a, from: a == start ? b.commandCol : 0, to: a == line ? col : self.cols)
            }
        }
        return (start, last, index)
    }

    /// The arrow presses (negative: left) that take a shell's cursor to a clicked cell, stopping at the end of the text.
    /// Nil when the click isn't in the command being typed.
    func shellCursorArrows(_ b: Block, line clicked: Int, col: Int) -> Int? {
        guard let input = shellInput(b), clicked >= input.start, clicked <= input.last else { return nil }
        let cursor = input.index(cursorAbs, cursorX)
        let textEnd = input.index(input.last, line(abs: input.last)?.trimmedLength ?? 0)
        return min(input.index(clicked, col), max(textEnd, cursor)) - cursor
    }

    /// A selection from `start` up to `end` as character offsets in the command being typed, clipped to its text, with
    /// the cursor's offset. Nil when none of it is in the command.
    func shellSelection(_ b: Block, start: (line: Int, col: Int), end: (line: Int, col: Int)) -> (from: Int, to: Int, cursor: Int)? {
        guard let input = shellInput(b), end.line >= input.start, start.line <= input.last else { return nil }
        let textEnd = input.index(input.last, line(abs: input.last)?.trimmedLength ?? 0)
        let from = min(input.index(start.line, start.col), textEnd)
        let to = end.line > input.last ? textEnd : min(input.index(end.line, end.col), textEnd)
        guard to > from else { return nil }
        return (from, to, input.index(cursorAbs, cursorX))
    }

    /// Characters from the start of Claude Code's input text to a cell: each row's text plus one per row break (the
    /// space a word-wrap swallowed, or a typed line break; only a word too long for a row breaks without one).
    func agentInputOffset(_ rows: ClosedRange<Int>, line target: Int, col: Int) -> Int {
        var n = 0
        for a in rows.lowerBound..<target { n += charCount(a, from: 2, to: agentTextEnd(a)) + 1 }
        return n + charCount(target, from: 2, to: col)
    }

    /// Where the text actually typed on a row of Claude Code's input box ends. Its suggestions (a placeholder
    /// like Try "…", or a completion after what's typed) are drawn dim, the first character inverted as its
    /// cursor. They aren't text yet: arrowing into them accepts the suggestion, so clicks stop short of them.
    func agentTextEnd(_ a: Int) -> Int {
        guard let l = line(abs: a) else { return 0 }
        let full = l.trimmedLength
        var end = full
        while end > 0 {
            let f = l.cells[end - 1].flags
            if f.contains(.dim) { end -= 1; continue }
            if f.contains(.inverse), end < full, l.cells[end].flags.contains(.dim) { end -= 1; continue }
            break
        }
        return end
    }

    /// The arrow presses (negative: left) that take Claude Code's cursor to a clicked column on the cursor's row.
    func agentCursorArrows(toCol col: Int) -> Int {
        let target = cursorAbs, cx = cursorX
        let c = max(2, min(col, max(cx, agentTextEnd(target))))
        return c >= cx ? charCount(target, from: cx, to: c) : -charCount(target, from: c, to: cx)
    }
}
