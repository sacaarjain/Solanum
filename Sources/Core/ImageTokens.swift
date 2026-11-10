import Foundation

/// Images pasted into Claude Code, as its screen shows them: "[Image #N]" where one's typed in the prompt, and
/// "⎿  [Image #8] [Image #9]" under a sent prompt, listing what went with it. The terminal-side logic for drawing the
/// images there (see ImageChips on the Mac and on Windows): which text is an image, which lines are attachment lists,
/// and how thumbnails share the space they get. Plain data, so both apps use the same rules.
enum ImageTokens {
    struct Token: Equatable {
        /// Column of the "[".
        let start: Int
        /// Columns, "[" to "]".
        let length: Int
        let number: Int
    }

    /// Blank in Claude Code's output, which lays out with no-break spaces.
    static func isSpace(_ ch: UInt32) -> Bool { ch == 0 || ch == 0x20 || ch == 0xA0 }

    /// "[Image #N]" runs on a line.
    static func tokens(_ line: Line) -> [Token] {
        let c = line.cells
        let word = Array("Image #".unicodeScalars.map(\.value))
        var out: [Token] = []
        var i = 0
        while i < c.count {
            guard c[i].ch == 0x5B, i + 1 + word.count < c.count else { i += 1; continue }
            var ok = true
            // Claude Code skips over cells that are already blank, so its "space" can be an empty cell.
            for (k, w) in word.enumerated() where w == 0x20 ? !isSpace(c[i + 1 + k].ch) : c[i + 1 + k].ch != w {
                ok = false
                break
            }
            var j = i + 1 + word.count
            var n = 0
            while ok, j < c.count, c[j].ch >= 0x30, c[j].ch <= 0x39, n < 100_000 { n = n * 10 + Int(c[j].ch - 0x30); j += 1 }
            if ok, j > i + 1 + word.count, j < c.count, c[j].ch == 0x5D {
                out.append(Token(start: i, length: j - i + 1, number: n))
                i = j + 1
            } else {
                i += 1
            }
        }
        return out
    }

    /// A sent prompt's attachments, "⎿  [Image #8] [Image #9]", as Claude Code lists them under it. Nil for any other
    /// line: an image mentioned in the middle of text stays text.
    static func attachments(_ line: Line) -> [Token]? {
        let c = line.cells
        guard let mark = c.firstIndex(where: { !isSpace($0.ch) }), c[mark].ch == 0x23BF else { return nil }
        let found = tokens(line)
        guard !found.isEmpty else { return nil }
        var covered = Set<Int>()
        for t in found { covered.formUnion(t.start..<(t.start + t.length)) }
        for x in (mark + 1)..<max(mark + 1, line.trimmedLength) where !covered.contains(x) && !isSpace(c[x].ch) { return nil }
        return found
    }

    /// Whether a line is empty: room for a thumbnail taller than one row.
    static func isBlank(_ line: Line) -> Bool { !line.cells.contains { !isSpace($0.ch) || $0.bg != 0 } }

    struct Rect: Equatable {
        var x: Double, y: Double, width: Double, height: Double
        var maxX: Double { x + width }
        var maxY: Double { y + height }
    }

    /// Thumbnails in rows across `area`, for images of these pixel sizes: all one height, as tall as fits (wrapping onto
    /// more rows when there are many) but no taller than the largest image, each keeping its shape within limits. At the
    /// top of the area, or the bottom. Each rectangle is for the image at the same index.
    static func wrap(_ sizes: [(width: Double, height: Double)], in area: Rect, bottom: Bool, minHeight: Double, gap: Double = 6) -> [Rect] {
        guard !sizes.isEmpty, area.width > 20 else { return [] }
        let shapes = sizes.map { s -> (aspect: Double, natural: Double) in
            guard s.width > 0, s.height > 0 else { return (1.5, area.height) }
            return (min(max(s.width / s.height, 0.75), 2.5), s.height)
        }
        let tallest = shapes.map { max($0.natural, minHeight) }.max() ?? area.height
        func lines(_ h: Double) -> [[(Int, Double, Double)]] {
            var out: [[(Int, Double, Double)]] = [[]]
            var x = 0.0
            let ih = min(h, tallest)
            for (i, shape) in shapes.enumerated() {
                let w = (ih * shape.aspect).rounded()
                if x > 0, x + w > area.width { out.append([]); x = 0 }
                out[out.count - 1].append((i, w, ih))
                x += w + gap
            }
            return out
        }
        var h = area.height
        var rows = lines(h)
        while h > minHeight, Double(rows.count) * h + Double(rows.count - 1) * gap > area.height {
            h = max(minHeight, h - 2)
            rows = lines(h)
        }
        let total = rows.reduce(0.0) { $0 + ($1.map(\.2).max() ?? 0) } + Double(rows.count - 1) * gap
        var y = bottom ? area.maxY - total : area.y
        var out = [Rect](repeating: Rect(x: 0, y: 0, width: 0, height: 0), count: sizes.count)
        for row in rows {
            var x = area.x
            let rowH = row.map(\.2).max() ?? 0
            for (i, w, ih) in row {
                out[i] = Rect(x: x, y: bottom ? y + rowH - ih : y, width: w, height: ih)
                x += w + gap
            }
            y += rowH + gap
        }
        return out
    }
}
