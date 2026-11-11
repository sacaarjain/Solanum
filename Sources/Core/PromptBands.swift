import Foundation

// Claude Code paints a fixed grey behind each prompt you've sent, which ignores the theme. Solanum finds those rows and
// draws them its own way instead: in the theme's colors, with a border, as the boxes around code. Shared by the Mac
// and Windows; each draws the box its own way.

enum PromptBands {
    /// Lines `first`...`last`, absolute, painted behind one prompt, and the background they're painted with (packed, as
    /// cells keep it).
    struct Band: Equatable {
        let first: Int
        let last: Int
        let bg: UInt32
    }

    /// The prompts in lines `from`...`through`: runs of lines whose every cell has the same background, one that isn't
    /// the default, starting at a line that begins "❯ " (or "> ") at its left edge. A prompt right under another starts
    /// its own. A prompt's later lines are indented, so one of them starting ">" (pasted npm output, a quote) stays in
    /// the prompt it's part of.
    static func find(_ line: (Int) -> Line?, from first: Int, through last: Int) -> [Band] {
        func uniform(_ l: Line) -> UInt32? {
            guard let bg = l.cells.first?.bg, bg >> 24 != 0, l.cells.allSatisfy({ $0.bg == bg }) else { return nil }
            return bg
        }
        func startsPrompt(_ l: Line) -> Bool {
            guard let i = l.cells.firstIndex(where: { $0.ch != 0 && $0.ch != 0x20 }), i < 2 else { return false }
            let c = l.cells[i].ch, next = i + 1 < l.cells.count ? l.cells[i + 1].ch : 0
            return (c == 0x276F || c == 0x3E) && (next == 0 || next == 0x20 || next == 0xA0)
        }
        var out: [Band] = []
        var run: (start: Int, bg: UInt32)?
        guard first <= last else { return [] }
        for a in first...(last + 1) {
            let l = a <= last ? line(a) : nil
            let bg = l.flatMap(uniform)
            let prompt = l.map(startsPrompt) ?? false
            if let r = run, bg != r.bg || prompt {
                out.append(Band(first: r.start, last: a - 1, bg: r.bg))
                run = nil
            }
            if run == nil, let bg, prompt { run = (a, bg) }
        }
        return out
    }
}
