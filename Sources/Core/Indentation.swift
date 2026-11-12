import Foundation

/// How a file is indented, as VS Code works it out when it opens one (`editor.detectIndentation`): with tabs or with
/// spaces, and how many spaces a level is. What Tab inserts follows it, so editing a file keeps its own style.
struct Indentation: Equatable {
    /// Tab inserts a tab character (else spaces to the next tab stop).
    var tabs: Bool
    /// Columns per level: what Tab moves to the next multiple of, and how wide a tab character is drawn.
    var size: Int

    /// From the file's own lines (the first few thousand), else the settings: `spaces` and `size`. Files whose format
    /// needs tabs (a Makefile's recipes, Go as gofmt writes it) take tabs when nothing in them says otherwise.
    static func detect(_ text: String, spaces: Bool, size: Int, tabsByDefault: Bool = false) -> Indentation {
        var tabbed = 0, spaced = 0
        var deltas: [Int: Int] = [:]
        var previous = 0
        for line in text.split(separator: "\n", maxSplits: 5000, omittingEmptySubsequences: false).prefix(5000) {
            guard let first = line.first, line.contains(where: { $0 != " " && $0 != "\t" }) else { continue }
            if first == "\t" {
                tabbed += 1
                continue
            }
            let n = line.prefix { $0 == " " }.count
            // One space then a `*` is a block comment's continuation, not a level.
            if n == 1, line.dropFirst().first == "*" { continue }
            if n >= 2 { spaced += 1 }
            let d = abs(n - previous)
            if d >= 2 { deltas[d, default: 0] += 1 }
            previous = n
        }
        if tabbed == 0 && spaced == 0 { return Indentation(tabs: tabsByDefault || !spaces, size: size) }
        if tabbed > spaced { return Indentation(tabs: true, size: size) }
        // The step between levels seen most (2, 4 or 8), else the setting.
        let seen = [2, 4, 8].filter { (deltas[$0] ?? 0) > 0 }
        // Most seen wins; a tie goes to the smaller step.
        let step = seen.max { (deltas[$0]!, -$0) < (deltas[$1]!, -$1) }
        return Indentation(tabs: false, size: step ?? size)
    }

    /// The spaces Tab inserts at `column` (counted with tabs as `size` wide): up to the next tab stop.
    func spaces(at column: Int) -> String { String(repeating: " ", count: size - column % size) }

    /// How many of the spaces just before `column` Backspace takes in leading indentation: back to the tab stop before
    /// (one when not on a stop's worth of spaces).
    func backspace(at column: Int, spacesBefore: Int) -> Int {
        guard spacesBefore > 0 else { return 1 }
        let back = column % size == 0 ? size : column % size
        return min(back, spacesBefore)
    }

    /// The width of `line`'s text up to `offset` UTF-16 units in, with tabs reaching their next stop.
    func column(of line: Substring.UTF16View, upTo offset: Int) -> Int {
        var col = 0
        for (i, u) in line.enumerated() where i < offset { col = u == 9 ? (col / size + 1) * size : col + 1 }
        return col
    }
}
