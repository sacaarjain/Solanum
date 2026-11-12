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
        let run = commandRun(line: start, col: b.commandCol)
        return (run.start, run.last, run.index)
    }

    /// The command being typed from (line, col), just after its prompt, through the cursor's line and the lines the
    /// screen wrapped it onto; `index` as for `shellInput`.
    func commandRun(line start: Int, col startCol: Int) -> (start: Int, col: Int, last: Int, index: (Int, Int) -> Int) {
        var last = max(start, cursorAbs)
        while last < lastAbs, line(abs: last)?.wrapped == true { last += 1 }
        let index: (Int, Int) -> Int = { [unowned self] line, col in
            guard line >= start else { return 0 }
            return (start...line).reduce(0) { n, a in
                n + self.charCount(a, from: a == start ? startCol : 0, to: a == line ? col : self.cols)
            }
        }
        return (start, startCol, last, index)
    }

    /// The command being typed as stops a keyboard selection can end at (see `InputText`): from `startCol` of `start`
    /// through the text on `last` (and the cursor, past spaces typed at the end).
    func commandText(start: Int, col startCol: Int, last: Int) -> InputText {
        var t = InputText(wholeLines: true)
        for a in start...last {
            guard let l = line(abs: a) else { continue }
            let lo = a == start ? startCol : 0
            var hi = a == last ? l.trimmedLength : cols
            if a == last, cursorAbs == last { hi = max(hi, cursorX) }
            hi = min(hi, l.cells.count)
            var c = lo
            while c < hi {
                if l.cells[c].width != 0 {
                    t.stops.append(GridPos(line: a, col: c))
                    t.chars.append(l.cells[c].ch == 0 ? 0x20 : l.cells[c].ch)
                }
                c += 1
            }
            if a == last { t.stops.append(GridPos(line: a, col: max(lo, hi))) }
        }
        return t
    }

    /// Claude Code's input box as stops (see `InputText`): each row's typed text, and its end, where the space a
    /// word-wrap swallowed (or a typed line break) is.
    func agentInputText(_ rows: ClosedRange<Int>) -> InputText {
        var t = InputText(wholeLines: false)
        for a in rows {
            guard let l = line(abs: a) else { continue }
            let end = min(agentTextEnd(a), l.cells.count)
            var c = 2
            while c < end {
                if l.cells[c].width != 0 {
                    t.stops.append(GridPos(line: a, col: c))
                    t.chars.append(l.cells[c].ch == 0 ? 0x20 : l.cells[c].ch)
                }
                c += 1
            }
            t.stops.append(GridPos(line: a, col: max(2, end)))
            if a < rows.upperBound { t.chars.append(0x0A) }
        }
        return t
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

/// Text being typed, as the places a keyboard selection can start or end ("stops", between two characters or at
/// either end), in reading order: ⇧← and ⇧→ step from one to the next, ⌥ a word at a time, ⌘ to the line's ends.
struct InputText {
    var stops: [GridPos] = []
    /// What's between stop i and i + 1 (a row break of Claude Code's box reads as a line break).
    var chars: [UInt32] = []
    /// ⌘← and ⌘→ go to the ends of the whole text (a shell's command is one line, however it wraps), not of its row.
    var wholeLines: Bool

    init(wholeLines: Bool) { self.wholeLines = wholeLines }

    var isEmpty: Bool { stops.count < 2 }

    /// The stop at `p`, or the last one before it (the first when it's before them all).
    func index(of p: GridPos) -> Int {
        var i = 0
        while i + 1 < stops.count, stops[i + 1] <= p { i += 1 }
        return i
    }

    private func isWord(_ k: Int) -> Bool {
        guard chars.indices.contains(k), let u = Unicode.Scalar(chars[k]) else { return false }
        return u.properties.isAlphabetic || u.properties.numericType != nil || u == "_"
    }

    func left(_ i: Int) -> Int { max(0, i - 1) }
    func right(_ i: Int) -> Int { min(stops.count - 1, i + 1) }

    /// Back to the start of the word before (over any spaces first), as ⌥← in a text field.
    func wordLeft(_ i: Int) -> Int {
        var k = i
        while k > 0, !isWord(k - 1) { k -= 1 }
        while k > 0, isWord(k - 1) { k -= 1 }
        return k
    }

    /// On to the end of the word after.
    func wordRight(_ i: Int) -> Int {
        var k = i
        while k < stops.count - 1, !isWord(k) { k += 1 }
        while k < stops.count - 1, isWord(k) { k += 1 }
        return k
    }

    func lineStart(_ i: Int) -> Int {
        guard !wholeLines else { return 0 }
        var k = i
        while k > 0, stops[k - 1].line == stops[i].line { k -= 1 }
        return k
    }

    func lineEnd(_ i: Int) -> Int {
        guard !wholeLines else { return stops.count - 1 }
        var k = i
        while k < stops.count - 1, stops[k + 1].line == stops[i].line { k += 1 }
        return k
    }

    /// The same column a row up (or down), or the start (end) from the first (last) row.
    func vertical(_ i: Int, by d: Int) -> Int {
        let row = stops[i].line + d, col = stops[i].col
        let onRow = stops.indices.filter { stops[$0].line == row }
        guard let first = onRow.first, let last = onRow.last else { return d < 0 ? 0 : stops.count - 1 }
        return onRow.last(where: { stops[$0].col <= col }) ?? (stops[first].col > col ? first : last)
    }

    /// The cells from stop `a` up to stop `b` (either way round), as the first and last cell; nil when they're the same.
    func cells(_ a: Int, _ b: Int) -> (GridPos, GridPos)? {
        let lo = min(a, b), hi = max(a, b)
        guard lo < hi else { return nil }
        // The last character's cell: the one just before stop `hi`, which is stop hi - 1's.
        return (stops[lo], stops[hi - 1])
    }
}
