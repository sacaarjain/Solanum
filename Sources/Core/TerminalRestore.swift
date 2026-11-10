import Foundation

extension Terminal {
    /// The primary buffer as text with SGR styling, minus the idle prompt at the bottom (the new shell
    /// prints its own). Soft-wrapped lines are joined so they reflow at the restored width.
    func restorableText(maxLines: Int) -> String {
        var lines = (0..<scrollback.count).map { scrollback[$0] } + (usingAlt ? primaryScreen : screen)
        if !usingAlt, let b = currentBlock, b.state == .prompt {
            lines = Array(lines.prefix(max(0, b.promptLine - dropped)))
        }
        while let l = lines.last, l.isBlank { lines.removeLast() }
        var out = ""
        var style: (UInt32, UInt32, CellFlags) = (0, 0, [])
        for l in lines.suffix(maxLines) {
            let end = l.wrapped ? l.cells.count : l.trimmedLength
            for x in 0..<end where l.cells[x].width != 0 {
                let c = l.cells[x]
                if (c.fg, c.bg, c.flags) != style {
                    style = (c.fg, c.bg, c.flags)
                    out += Terminal.sgr(c)
                }
                out += l.string(at: x)
            }
            if !l.wrapped {
                if style != (0, 0, []) { out += "\u{1b}[0m"; style = (0, 0, []) }
                out += "\r\n"
            }
        }
        if style != (0, 0, []) { out += "\u{1b}[0m" }
        return out
    }

    private static func sgr(_ c: Cell) -> String {
        var p = ["0"]
        let f = c.flags
        if f.contains(.bold) { p.append("1") }
        if f.contains(.dim) { p.append("2") }
        if f.contains(.italic) { p.append("3") }
        if !f.intersection(CellFlags.anyUnderline).isEmpty { p.append("4") }
        if f.contains(.inverse) { p.append("7") }
        if f.contains(.invisible) { p.append("8") }
        if f.contains(.strike) { p.append("9") }
        for (v, base) in [(c.fg, 38), (c.bg, 48)] {
            switch v >> 24 {
            case 1: p.append("\(base);5;\(v & 0xFF)")
            case 2: p.append("\(base);2;\((v >> 16) & 0xFF);\((v >> 8) & 0xFF);\(v & 0xFF)")
            default: break
            }
        }
        return "\u{1b}[" + p.joined(separator: ";") + "m"
    }
}
