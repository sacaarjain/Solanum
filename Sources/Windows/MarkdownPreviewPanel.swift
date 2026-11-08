import CCanvas
import Foundation
import WinSDK

/// A Markdown file rendered as GitHub shows it, in a sub-tab of its own, as on the Mac (Open Preview in the editor's header,
/// or the sidebar's menu). It reads the file again every couple of seconds, so saving in the editor shows here. Links open
/// in the browser.
final class MarkdownPreviewPanel: ColumnPanel {
    let path: String
    let name: String
    private let read: (_ limit: Int, _ done: @escaping (Data?, Bool) -> Void) -> Void
    private(set) var blocks: [MarkdownDoc.Block]?
    private var source = Data()
    private var failed = false
    private var reading = false
    private var lastRead = Date.distantPast
    private var scrollY: Float = 0
    private var hoveredClose = false
    private var hoveredLink: String?
    /// What was laid out, for its width: what to draw, where the links are, and the text that can be selected.
    private var laidOut: (width: Float, scale: Float, items: [Item], height: Float, links: [(UIRect, String)], runs: [Run])?
    /// The text selected by dragging across it, from where the drag began to where it is; and whether it's going on.
    private var selection: (anchor: TextSpot, head: TextSpot)?
    private var selecting = false
    /// The width and scale last laid out for.
    private var layoutSize: (width: Float, scale: Float)?
    /// Where the press was, so a click that doesn't move still opens a link.
    private var pressedAt: (x: Float, y: Float)?
    private weak var lastCanvas: Canvas?
    var copy: (String) -> Void = { _ in }
    private var lastArea = UIRect(x: 0, y: 0, width: 0, height: 0)
    var invalidate: () -> Void = {}
    var close: () -> Void = {}
    var post: (@escaping () -> Void) -> Void = { $0() }
    var openLink: (String) -> Void = { _ in }
    var cellSize: (width: Float, height: Float) = (8, 16)

    init(path: String, name: String, read: @escaping (_ limit: Int, _ done: @escaping (Data?, Bool) -> Void) -> Void) {
        self.path = path
        self.name = name
        self.read = read
    }

    func reload() {
        guard !reading else { return }
        reading = true
        read(4 * 1024 * 1024) { [weak self] data, _ in
            self?.post {
                guard let self else { return }
                self.reading = false
                self.lastRead = Date()
                guard let data else { self.failed = self.blocks == nil; return self.invalidate() }
                guard data != self.source || self.blocks == nil else { return }
                self.source = data
                self.blocks = MarkdownDoc.parse(String(decoding: data, as: UTF8.self))
                self.laidOut = nil
                self.invalidate()
            }
        }
    }

    func tick() {
        if Date().timeIntervalSince(lastRead) >= 2 { reload() }
    }

    // MARK: Layout

    private enum Item {
        case text(String, x: Float, y: Float, width: Float, height: Float, pixels: Float, flags: Int32, color: UInt32, alpha: Float)
        case mono(String, x: Float, y: Float, cells: Int, color: UInt32)
        case rect(UIRect, color: UInt32, alpha: Float, radius: Float)
        case strike(x: Float, y: Float, width: Float, color: UInt32)
        case box(UIRect, checked: Bool)
    }

    /// A piece of text as laid out, in reading order: a word (with the space after it), a piece of code, a line of a code
    /// block or a table's cell. `block` tells one paragraph, list item or table row from the next, for copying.
    private struct Run {
        let text: String
        let rect: UIRect
        let pixels: Float
        let flags: Int32
        let mono: Bool
        let block: Int
        /// A table's cell: copied with tabs between them.
        var cell = false
    }

    /// A place in the text: a run, and how many characters into it.
    private struct TextSpot: Comparable {
        let run: Int
        let offset: Int
        static func < (a: TextSpot, b: TextSpot) -> Bool { a.run != b.run ? a.run < b.run : a.offset < b.offset }
    }

    /// Runs being made by `layout`, and the block they're in.
    private var layoutRuns: [Run] = []
    private var layoutBlock = 0

    private func header(_ a: UIRect, _ s: Float) -> UIRect { UIRect(x: a.x, y: a.y, width: a.width, height: (36 * s).rounded()) }
    private func closeButton(_ a: UIRect, _ s: Float) -> UIRect { UIRect(x: a.maxX - 36 * s, y: a.y + 5 * s, width: 26 * s, height: 26 * s) }

    private func measure(_ canvas: Canvas, _ text: String, _ pixels: Float, _ flags: Int32) -> Float {
        let units = Array(text.utf16)
        return sol_canvas_measure_label(canvas.raw, units, Int32(units.count), pixels, flags)
    }

    /// Lays out styled text from `x0` within `width`, wrapping at spaces, from `y`. Returns where it ends.
    private func flow(_ spans: [MarkdownDoc.Span], x0: Float, width: Float, y: Float, pixels: Float, bold: Bool = false, color: UInt32,
                      alpha: Float = 1, canvas: Canvas, s: Float, into items: inout [Item], links: inout [(UIRect, String)]) -> Float {
        let lh = (pixels * 1.55).rounded()
        var x = x0, line = y
        for span in spans {
            var flags: Int32 = bold ? 1 : 0, ink = color, linkTarget: String?
            switch span.style {
            case .bold: flags |= 1
            case .italic: flags |= 2
            case .boldItalic: flags |= 3
            case .link(let target): ink = TerminalPalette.accent; linkTarget = target
            default: break
            }
            // Words, each with the space after it.
            var words: [String] = []
            if span.style == .code { words = [span.text] } else {
                var current = ""
                for ch in span.text {
                    current.append(ch)
                    if ch == " " { words.append(current); current = "" }
                }
                if !current.isEmpty { words.append(current) }
            }
            for word in words {
                let isCode = span.style == .code
                let w = isCode ? Float(word.count) * cellSize.width + 8 * s : measure(canvas, word, pixels, flags)
                let trimmedW = isCode ? w : measure(canvas, word.trimmingCharacters(in: .whitespaces), pixels, flags)
                if x > x0, x + trimmedW > x0 + width {
                    x = x0
                    line += lh
                    if word == " " { continue }
                }
                if isCode {
                    items.append(.rect(UIRect(x: x, y: line + (lh - cellSize.height) / 2 - 1 * s, width: w, height: cellSize.height + 2 * s), color: TerminalPalette.foreground, alpha: 0.10, radius: 4 * s))
                    items.append(.mono(word, x: x + 4 * s, y: line + (lh - cellSize.height) / 2, cells: word.count, color: color))
                    layoutRuns.append(Run(text: word, rect: UIRect(x: x + 4 * s, y: line, width: Float(word.count) * cellSize.width, height: lh), pixels: pixels, flags: 0, mono: true, block: layoutBlock))
                } else {
                    items.append(.text(word, x: x, y: line, width: w + 2, height: lh, pixels: pixels, flags: flags, color: ink, alpha: alpha))
                    layoutRuns.append(Run(text: word, rect: UIRect(x: x, y: line, width: w, height: lh), pixels: pixels, flags: flags, mono: false, block: layoutBlock))
                    if span.style == .strike { items.append(.strike(x: x, y: line + lh / 2, width: trimmedW, color: ink)) }
                    if let linkTarget {
                        items.append(.rect(UIRect(x: x, y: line + lh - 4 * s, width: trimmedW, height: max(1, s.rounded())), color: ink, alpha: hoveredLink == linkTarget ? 0.9 : 0.35, radius: 0))
                        links.append((UIRect(x: x, y: line, width: w, height: lh), linkTarget))
                    }
                }
                x += w
            }
        }
        return line + lh
    }

    private func layout(width full: Float, canvas: Canvas, s: Float) -> (items: [Item], height: Float, links: [(UIRect, String)], runs: [Run]) {
        var items: [Item] = [], links: [(UIRect, String)] = []
        let pad = 32 * s, width = min(full - pad * 2, 900 * s), x0 = pad, fg = TerminalPalette.foreground
        var y = 20 * s
        layoutRuns = []
        layoutBlock = 0
        for block in blocks ?? [] {
            layoutBlock += 1
            switch block {
            case .heading(let level, let spans):
                let sizes: [Float] = [26, 21, 17, 15, 14, 13.5]
                let pixels = sizes[min(max(level, 1), 6) - 1] * s
                y += (level <= 2 ? 10 : 6) * s
                y = flow(spans, x0: x0, width: width, y: y, pixels: pixels, bold: true, color: fg, canvas: canvas, s: s, into: &items, links: &links)
                if level <= 2 {
                    y += 4 * s
                    items.append(.rect(UIRect(x: x0, y: y, width: width, height: max(1, s.rounded())), color: fg, alpha: 0.14, radius: 0))
                    y += 6 * s
                }
                y += 8 * s
            case .paragraph(let spans):
                y = flow(spans, x0: x0, width: width, y: y, pixels: 14 * s, color: fg, canvas: canvas, s: s, into: &items, links: &links) + 12 * s
            case .listItem(let depth, let marker, let checked, let spans):
                let indent = x0 + Float(depth) * 22 * s, textX = indent + 24 * s, lh = (14 * s * 1.55).rounded()
                if let checked {
                    items.append(.box(UIRect(x: indent + 3 * s, y: y + (lh - 13 * s) / 2, width: 13 * s, height: 13 * s), checked: checked))
                } else {
                    let w = measure(canvas, marker, 14 * s, 0)
                    items.append(.text(marker, x: textX - 6 * s - w, y: y, width: w + 2, height: lh, pixels: 14 * s, flags: 0, color: fg, alpha: 0.75))
                }
                y = flow(spans, x0: textX, width: width - (textX - x0), y: y, pixels: 14 * s, color: fg, alpha: checked == true ? 0.6 : 1,
                         canvas: canvas, s: s, into: &items, links: &links) + 4 * s
            case .quote(let spans):
                let top = y
                y = flow(spans, x0: x0 + 16 * s, width: width - 16 * s, y: y, pixels: 14 * s, color: fg, alpha: 0.7, canvas: canvas, s: s, into: &items, links: &links)
                items.append(.rect(UIRect(x: x0, y: top, width: 3 * s, height: y - top), color: fg, alpha: 0.25, radius: 1.5 * s))
                y += 12 * s
            case .code(_, let lines):
                let inner = 12 * s, h = Float(max(lines.count, 1)) * cellSize.height + inner * 2
                items.append(.rect(UIRect(x: x0, y: y, width: width, height: h), color: TerminalPalette.surface, alpha: 1, radius: 6 * s))
                let cells = max(Int((width - inner * 2) / max(cellSize.width, 1)), 1)
                for (k, line) in lines.enumerated() {
                    let shown = String(line.prefix(cells)), top = y + inner + Float(k) * cellSize.height
                    items.append(.mono(shown, x: x0 + inner, y: top, cells: min(line.count, cells), color: fg))
                    // Each line its own, so copying keeps the lines.
                    layoutBlock += 1
                    layoutRuns.append(Run(text: shown, rect: UIRect(x: x0 + inner, y: top, width: Float(shown.count) * cellSize.width, height: cellSize.height),
                                          pixels: 0, flags: 0, mono: true, block: layoutBlock))
                }
                y += h + 14 * s
            case .table(let headerCells, let rows):
                let columnCount = max(headerCells.count, rows.map(\.count).max() ?? 0)
                guard columnCount > 0 else { continue }
                func plain(_ spans: [MarkdownDoc.Span]) -> String { spans.map(\.text).joined() }
                var widths = [Float](repeating: 40 * s, count: columnCount)
                for (i, cell) in headerCells.enumerated() { widths[i] = max(widths[i], measure(canvas, plain(cell), 14 * s, 1) + 26 * s) }
                for row in rows { for (i, cell) in row.enumerated() where i < columnCount { widths[i] = max(widths[i], measure(canvas, plain(cell), 14 * s, 0) + 26 * s) } }
                let total = widths.reduce(0, +)
                if total > width { widths = widths.map { $0 * width / total } }
                let rh = 34 * s
                for (r, row) in ([headerCells] + rows).enumerated() {
                    var x = x0
                    if r == 0 { items.append(.rect(UIRect(x: x0, y: y, width: min(total, width), height: rh), color: fg, alpha: 0.06, radius: 0)) }
                    else if r % 2 == 0 { items.append(.rect(UIRect(x: x0, y: y, width: min(total, width), height: rh), color: fg, alpha: 0.03, radius: 0)) }
                    layoutBlock += 1
                    for i in 0..<columnCount {
                        let text = i < row.count ? plain(row[i]) : ""
                        items.append(.text(text, x: x + 13 * s, y: y, width: max(widths[i] - 26 * s, 0), height: rh, pixels: 14 * s, flags: r == 0 ? 1 : 0, color: fg, alpha: 1))
                        var run = Run(text: text, rect: UIRect(x: x + 13 * s, y: y, width: min(measure(canvas, text, 14 * s, r == 0 ? 1 : 0), max(widths[i] - 26 * s, 0)), height: rh),
                                      pixels: 14 * s, flags: r == 0 ? 1 : 0, mono: false, block: layoutBlock)
                        run.cell = true
                        layoutRuns.append(run)
                        items.append(.rect(UIRect(x: x, y: y, width: max(1, s.rounded()), height: rh), color: fg, alpha: 0.15, radius: 0))
                        x += widths[i]
                    }
                    items.append(.rect(UIRect(x: x, y: y, width: max(1, s.rounded()), height: rh), color: fg, alpha: 0.15, radius: 0))
                    items.append(.rect(UIRect(x: x0, y: y, width: x - x0, height: max(1, s.rounded())), color: fg, alpha: 0.15, radius: 0))
                    y += rh
                    if r == rows.count { items.append(.rect(UIRect(x: x0, y: y, width: x - x0, height: max(1, s.rounded())), color: fg, alpha: 0.15, radius: 0)) }
                }
                y += 14 * s
            case .rule:
                y += 8 * s
                items.append(.rect(UIRect(x: x0, y: y, width: width, height: max(2, (2 * s).rounded())), color: fg, alpha: 0.14, radius: 0))
                y += 18 * s
            }
        }
        return (items, y + 24 * s, links, layoutRuns)
    }

    // MARK: Drawing

    func draw(on canvas: Canvas, in a: UIRect, scale s: Float) {
        lastArea = a
        let p = PanelPaint(canvas: canvas, scale: s), fg = p.fg
        p.backdrop(a, TerminalPalette.background)
        sol_canvas_push_clip(canvas.raw, a.x, a.y, a.width, a.height)
        defer { sol_canvas_pop_clip(canvas.raw) }
        let h = header(a, s), body = UIRect(x: a.x, y: h.maxY, width: a.width, height: max(a.maxY - h.maxY, 0))
        if blocks == nil {
            p.label(failed ? "Couldn't read this file." : "Loading…", UIRect(x: body.x + 32 * s, y: body.y + 16 * s, width: body.width - 64 * s, height: 22 * s), alpha: 0.55)
        } else {
            if laidOut == nil || laidOut!.width != a.width || laidOut!.scale != s {
                let l = layout(width: a.width, canvas: canvas, s: s)
                // A new width puts the runs somewhere else: a selection from the old one goes. (A link hovered lays it out
                // again just the same, and keeps it.)
                if layoutSize.map({ $0.width != a.width || $0.scale != s }) ?? false { selection = nil }
                layoutSize = (a.width, s)
                laidOut = (a.width, s, l.items, l.height, l.links, l.runs)
            }
            let content = laidOut!
            scrollY = min(max(scrollY, 0), max(content.height - body.height, 0))
            sol_canvas_push_clip(canvas.raw, body.x, body.y, body.width, body.height)
            let dx = body.x, dy = body.y - scrollY
            lastCanvas = canvas
            // What's selected, under the text.
            if let (from, to) = selectedRange, from < to {
                for i in from.run...min(to.run, content.runs.count - 1) {
                    let run = content.runs[i], r = run.rect
                    guard r.y + dy < body.maxY, r.maxY + dy > body.y else { continue }
                    let a = i == from.run ? from.offset : 0, b = i == to.run ? to.offset : run.text.count
                    guard b > a || (b == a && i != to.run) else { continue }
                    let x1 = r.x + width(of: run, upTo: a, canvas), x2 = i == to.run || b < run.text.count ? r.x + width(of: run, upTo: b, canvas) : max(r.maxX, r.x + width(of: run, upTo: b, canvas))
                    p.fill(UIRect(x: x1 + dx, y: r.y + dy, width: max(x2 - x1, 2 * s), height: r.height), TerminalPalette.accent, 0.30)
                }
            }
            for item in content.items {
                switch item {
                case .text(let text, let x, let y, let w, let ht, let pixels, let flags, let color, let alpha):
                    guard y + dy < body.maxY, y + ht + dy > body.y else { continue }
                    let units = Array(text.utf16)
                    sol_canvas_draw_label(canvas.raw, x + dx, y + dy, w, ht, units, Int32(units.count), pixels, flags, color, alpha)
                case .mono(let text, let x, let y, let cells, let color):
                    guard y + dy < body.maxY, y + cellSize.height + dy > body.y else { continue }
                    p.mono(text, x: x + dx, y: y + dy, maxCells: cells, color: color)
                case .rect(let r, let color, let alpha, let radius):
                    guard r.y + dy < body.maxY, r.maxY + dy > body.y else { continue }
                    p.fill(UIRect(x: r.x + dx, y: r.y + dy, width: r.width, height: r.height), color, alpha, radius: radius / s)
                case .strike(let x, let y, let w, let color):
                    p.fill(UIRect(x: x + dx, y: (y + dy).rounded(), width: w, height: max(1, s.rounded())), color, 0.8)
                case .box(let r, let checked):
                    let box = UIRect(x: r.x + dx, y: r.y + dy, width: r.width, height: r.height)
                    if checked { p.fill(box, TerminalPalette.accent, 1, radius: 3) } else {
                        sol_canvas_stroke_rounded(canvas.raw, box.x + 0.5, box.y + 0.5, box.width - 1, box.height - 1, 3 * s, fg, 0.55, max(1, s))
                    }
                    if checked { p.icon(0xE73E, box, pixels: 9, color: TerminalPalette.background) }
                }
            }
            sol_canvas_pop_clip(canvas.raw)
        }
        // The header: what this is, and close.
        p.backdrop(h, TerminalPalette.chrome)
        p.fill(UIRect(x: a.x, y: h.maxY - 1, width: a.width, height: 1), fg, 0.10)
        p.icon(0xE8A1, UIRect(x: a.x + 10 * s, y: h.y, width: 18 * s, height: h.height), pixels: 12, alpha: 0.65)
        p.label("Preview " + name, UIRect(x: a.x + 34 * s, y: h.y, width: max(closeButton(a, s).x - a.x - 44 * s, 0), height: h.height), pixels: 13, semibold: true)
        p.button(0xE8BB, closeButton(a, s), hovered: hoveredClose)
    }

    // MARK: Selecting

    /// The selection in reading order, start then end.
    private var selectedRange: (TextSpot, TextSpot)? {
        guard let sel = selection else { return nil }
        return sel.anchor <= sel.head ? (sel.anchor, sel.head) : (sel.head, sel.anchor)
    }

    /// How far into a run its first `count` characters reach.
    private func width(of run: Run, upTo count: Int, _ canvas: Canvas) -> Float {
        guard count > 0 else { return 0 }
        if run.mono { return Float(count) * cellSize.width }
        return measure(canvas, String(run.text.prefix(count)), run.pixels, run.flags)
    }

    /// The place in the text nearest a point in the content: on its line, the character the point is in front of; above
    /// or below all text, its start or end.
    private func spot(atContentX x: Float, y: Float) -> TextSpot? {
        guard let runs = laidOut?.runs, !runs.isEmpty, let canvas = lastCanvas else { return nil }
        let onLine = runs.indices.filter { runs[$0].rect.y <= y && y < runs[$0].rect.maxY }
        guard !onLine.isEmpty else {
            // Between lines or past the end: the start of the next line down, or the very end.
            if let next = runs.indices.first(where: { runs[$0].rect.y > y }) { return TextSpot(run: next, offset: 0) }
            return TextSpot(run: runs.count - 1, offset: runs[runs.count - 1].text.count)
        }
        let first = onLine[0]
        if x < runs[first].rect.x { return TextSpot(run: first, offset: 0) }
        guard let i = onLine.last(where: { runs[$0].rect.x <= x }) else { return TextSpot(run: first, offset: 0) }
        let run = runs[i]
        // The character boundary nearest the point.
        var best = 0, bestDistance = Float.greatestFiniteMagnitude
        for k in 0...run.text.count {
            let d = abs(run.rect.x + width(of: run, upTo: k, canvas) - x)
            if d < bestDistance { best = k; bestDistance = d }
        }
        return TextSpot(run: i, offset: best)
    }

    /// The text selected, as it reads: words run on, lines and paragraphs on lines of their own, table cells with tabs.
    var selectedText: String {
        guard let runs = laidOut?.runs, let (from, to) = selectedRange, from < to else { return "" }
        var out = ""
        for i in from.run...min(to.run, runs.count - 1) {
            let run = runs[i], chars = Array(run.text)
            let a = i == from.run ? from.offset : 0, b = i == to.run ? to.offset : chars.count
            if i > from.run {
                let before = runs[i - 1]
                if before.block != run.block { out += "\n" } else if run.cell { out += "\t" }
            }
            if a < b { out += String(chars[a..<b]) }
        }
        return out
    }

    private func contentPoint(_ x: Float, _ y: Float) -> (Float, Float) {
        let s = laidOut?.scale ?? 1
        return (x - lastArea.x, y - header(lastArea, s).maxY + scrollY)
    }

    // MARK: Mouse and keys

    private func link(atX x: Float, y: Float) -> String? {
        guard let content = laidOut else { return nil }
        let h = header(lastArea, content.scale), px = x - lastArea.x, py = y - h.maxY + scrollY
        return content.links.first { $0.0.contains(px, py) }?.1
    }

    func mouse(_ message: UINT, x: Float, y: Float, in a: UIRect, scale s: Float) -> Bool {
        let before = (hoveredClose, hoveredLink)
        hoveredClose = closeButton(a, s).contains(x, y)
        let inBody = y > header(a, s).maxY
        hoveredLink = inBody ? link(atX: x, y: y) : nil
        // Dragging across the text selects it, as in a browser; a click that doesn't move still opens a link.
        let (cx, cy) = contentPoint(x, y)
        switch message {
        case Win.WM_LBUTTONDOWN where inBody && !hoveredClose:
            pressedAt = (x, y)
            selection = spot(atContentX: cx, y: cy).map { ($0, $0) }
            selecting = selection != nil
            invalidate()
        case Win.WM_LBUTTONDBLCLK where inBody:
            // A word, and the space after it.
            if let at = spot(atContentX: cx, y: cy), let runs = laidOut?.runs {
                selection = (TextSpot(run: at.run, offset: 0), TextSpot(run: at.run, offset: runs[at.run].text.count))
                selecting = false
                invalidate()
            }
        case Win.WM_MOUSEMOVE where selecting:
            // Let go somewhere the page didn't hear of: the drag's over.
            if GetKeyState(Int32(VK_LBUTTON)) >= 0 { selecting = false; break }
            if let head = spot(atContentX: cx, y: cy), let sel = selection, head != sel.head {
                selection = (sel.anchor, head)
                invalidate()
            }
        case Win.WM_LBUTTONUP:
            let moved = pressedAt.map { abs($0.x - x) > 3 * s || abs($0.y - y) > 3 * s } ?? false
            selecting = false
            pressedAt = nil
            if !moved, selection.map({ $0.anchor == $0.head }) == true { selection = nil }
            if hoveredClose { close() } else if !moved, selection == nil, let target = hoveredLink { openLink(target) }
            invalidate()
        default: break
        }
        if before.0 != hoveredClose || before.1 != hoveredLink {
            laidOut = nil
            invalidate()
        }
        return true
    }

    func mouseLeft() {
        guard hoveredClose || hoveredLink != nil else { return }
        hoveredClose = false
        hoveredLink = nil
        laidOut = nil
        invalidate()
    }

    func scroll(lines: Int, x: Float, y: Float, in a: UIRect, scale s: Float) {
        scrollY -= Float(lines) * 20 * s
        invalidate()
    }

    func key(_ key: Int32, shift: Bool, ctrl: Bool) -> Bool {
        let page = max(lastArea.height - 80, 40)
        if ctrl && key == 0x43 {
            // Ctrl+C: what's selected.
            let text = selectedText
            if !text.isEmpty { copy(text) }
            return true
        }
        if ctrl && key == 0x41, let runs = laidOut?.runs, !runs.isEmpty {
            // Ctrl+A: all of it.
            selection = (TextSpot(run: 0, offset: 0), TextSpot(run: runs.count - 1, offset: runs[runs.count - 1].text.count))
            invalidate()
            return true
        }
        switch key {
        case Win.VK_ESCAPE:
            // Escape lets go of a selection first, then closes.
            if selection != nil { selection = nil } else { close() }
        case Win.VK_UP: scrollY -= 40
        case Win.VK_DOWN: scrollY += 40
        case Win.VK_PRIOR: scrollY -= page
        case Win.VK_NEXT, Win.VK_SPACE: scrollY += page
        case Win.VK_HOME: scrollY = 0
        case Win.VK_END: scrollY = .greatestFiniteMagnitude / 4
        default: return ctrl
        }
        invalidate()
        return true
    }

    func typed(_ text: String) {}

    var hoveredLinkTarget: String? { hoveredLink }
}
