import CCanvas
import Foundation

/// Find in the terminal (Ctrl+F), as the Mac's ⌘F SearchBar: at the terminal's top right, a magnifying glass, the scope
/// (All, Commands or Output, as VS Code's terminal find has it), the field, "3/12", and previous, next and close. Which
/// cells match is Core's TerminalSearch, shared with the Mac; matches are shaded yellow, the current one orange.
final class TerminalFindBar {
    enum Part: Equatable { case bar, scope, field, previous, next, close }

    var field = TextFieldState("")
    /// The field's text all selected, as on opening: typing replaces it.
    var fieldSelected = true
    /// It has the keyboard (else the terminal has, the bar staying open).
    var focused = true
    var scope: SearchScope = .all
    private(set) var matches: [SearchMatch] = []
    private(set) var current = -1
    /// Each line's matches as drawn: columns, and whether it's the current one.
    private(set) var cells: [Int: [(start: Int, end: Int, current: Bool)]] = [:]
    var hovered: Part?
    private(set) var parts: [(Part, UIRect)] = []
    private(set) var box: UIRect?
    /// The last query, to start with next time, as the Mac does.
    static var lastQuery = ""

    init() {
        field = TextFieldState(Self.lastQuery)
    }

    /// Searches again, starting from the last match at or above `bottomLine`.
    func search(_ terminal: Terminal, bottomLine: Int) {
        Self.lastQuery = field.text
        matches = TerminalSearch.matches(field.text, in: terminal, scope: scope)
        current = TerminalSearch.startIndex(matches, bottomLine: bottomLine) ?? -1
        rebuildCells()
    }

    func step(_ d: Int) {
        guard !matches.isEmpty else { return }
        current = (current + d + matches.count) % matches.count
        rebuildCells()
    }

    var currentLine: Int? { matches.indices.contains(current) ? matches[current].line : nil }

    private func rebuildCells() {
        cells = [:]
        for (i, m) in matches.enumerated() { cells[m.line, default: []].append((m.start, m.end, i == current)) }
    }

    /// "3/12", "0/0" for none, nothing before a search.
    var count: (text: String, problem: Bool)? {
        guard !field.text.isEmpty else { return nil }
        return matches.isEmpty ? ("0/0", true) : ("\(current + 1)/\(matches.count)", false)
    }

    var placeholder: String { scope == .all ? "Find" : "Find in \(scope.title.lowercased())" }

    // MARK: Layout and drawing

    /// The Mac's bar: 432 points wide, 36 high, 12 from the terminal's right and 8 from its top.
    func layout(in area: UIRect, scale s: Float) {
        let w = min((432 * s).rounded(), area.width - 24 * s), h = (36 * s).rounded()
        guard w > 200 * s else { box = nil; parts = []; return }
        let b = UIRect(x: (area.maxX - w - 12 * s).rounded(), y: (area.y + 8 * s).rounded(), width: w, height: h)
        box = b
        let side = (22 * s).rounded(), mid = b.y + ((h - side) / 2).rounded()
        // From the right: close, next, previous, then the count; from the left the glass, the scope and the field.
        var right = b.maxX - 6 * s
        var out: [(Part, UIRect)] = []
        for part in [Part.close, .next, .previous] {
            right -= side
            out.append((part, UIRect(x: right, y: mid, width: side, height: side)))
            right -= 1 * s
        }
        let countRight = right - 4 * s
        out.append((.scope, UIRect(x: b.x + 28 * s, y: b.y + 6 * s, width: 96 * s, height: h - 12 * s)))
        let fieldX = b.x + 140 * s
        out.append((.field, UIRect(x: fieldX, y: b.y + 6 * s, width: max(countRight - 52 * s - fieldX, 40 * s), height: h - 12 * s)))
        parts = out
    }

    func rect(_ part: Part) -> UIRect? { parts.first { $0.0 == part }?.1 }

    func part(atX x: Float, y: Float) -> Part? {
        guard let box, box.contains(x, y) else { return nil }
        return parts.first { $0.1.contains(x, y) }?.0 ?? .bar
    }

    func draw(on canvas: Canvas, in area: UIRect, scale s: Float) {
        layout(in: area, scale: s)
        guard let b = box else { return }
        let c = canvas.raw, fg = TerminalPalette.foreground, accent = TerminalPalette.accent
        func label(_ text: String, _ r: UIRect, pixels: Float, semibold: Bool = false, color: UInt32? = nil, alpha: Float = 1) {
            let units = Array(text.utf16)
            sol_canvas_draw_label(c, r.x, r.y, r.width, r.height, units, Int32(units.count), pixels * s, semibold ? 1 : 0, color ?? fg, alpha)
        }
        func width(_ text: String, pixels: Float, semibold: Bool = false) -> Float {
            let units = Array(text.utf16)
            return sol_canvas_measure_label(c, units, Int32(units.count), pixels * s, semibold ? 1 : 0).rounded(.up)
        }
        // A card in the theme's surface color, a shadow under it, as the Mac's.
        sol_canvas_fill_rounded(c, b.x, b.y + 3 * s, b.width, b.height, 9 * s, 0x000000, 0.3)
        sol_canvas_fill_rounded(c, b.x, b.y, b.width, b.height, 9 * s, TerminalPalette.surface, 1)
        sol_canvas_stroke_rounded(c, b.x + 0.5, b.y + 0.5, b.width - 1, b.height - 1, 9 * s, fg, TerminalPalette.isDark ? 0.14 : 0.18, 1)
        // The magnifying glass.
        sol_canvas_draw_icon(c, b.x + 8 * s, b.y, 20 * s, b.height, 0xE721, 12 * s, fg, 0.5)
        for (part, r) in parts {
            let hovered = self.hovered == part
            switch part {
            case .scope:
                if hovered { sol_canvas_fill_rounded(c, r.x, r.y, r.width, r.height, 5 * s, fg, 0.08) }
                let tw = width(scope.title, pixels: 12, semibold: true)
                label(scope.title, UIRect(x: r.x + 6 * s, y: r.y, width: tw + 2, height: r.height), pixels: 12, semibold: true, alpha: 0.75)
                sol_canvas_draw_icon(c, r.x + 10 * s + tw, r.y, 12 * s, r.height, 0xE70D, 8 * s, fg, 0.6)
                // The line between the scope and the field.
                sol_canvas_fill_rect(c, b.x + 132 * s, b.y + 9 * s, 1, b.height - 18 * s, fg, 0.14)
            case .field:
                drawField(r, canvas: canvas, scale: s, label: label, width: width)
            case .previous, .next, .close:
                if hovered { sol_canvas_fill_rounded(c, r.x, r.y, r.width, r.height, 5 * s, fg, 0.10) }
                let glyph: UInt16 = part == .previous ? 0xE70E : part == .next ? 0xE70D : 0xE8BB
                sol_canvas_draw_icon(c, r.x, r.y, r.width, r.height, glyph, (part == .close ? 9 : 10) * s, hovered ? accent : fg, hovered ? 1 : 0.75)
            case .bar: break
            }
        }
        if let count, let prev = rect(.previous) {
            let w = width(count.text, pixels: 11)
            label(count.text, UIRect(x: prev.x - 8 * s - w, y: b.y, width: w + 2, height: b.height), pixels: 11,
                  color: count.problem ? TerminalPalette.ansi[1] : nil, alpha: count.problem ? 1 : 0.55)
        }
    }

    private func drawField(_ r: UIRect, canvas: Canvas, scale s: Float, label: (String, UIRect, Float, Bool, UInt32?, Float) -> Void,
                           width: (String, Float, Bool) -> Float) {
        let c = canvas.raw
        guard !field.text.isEmpty else {
            label(placeholder, r, 13, false, nil, 0.45)
            if focused { sol_canvas_fill_rect(c, r.x, r.y + 3 * s, max((1.5 * s).rounded(), 1), r.height - 6 * s, TerminalPalette.accent, 1) }
            return
        }
        let whole = width(field.text, 13, false), caretX = width(field.beforeCaret, 13, false)
        let shift = max(0, min(caretX - r.width + 4 * s, whole - r.width + 4 * s))
        sol_canvas_push_clip(c, r.x, r.y, r.width, r.height)
        if focused && fieldSelected {
            sol_canvas_fill_rect(c, r.x - shift, r.y + 2 * s, min(whole, r.width + shift), r.height - 4 * s, TerminalPalette.accent, 0.3)
        }
        label(field.text, UIRect(x: r.x - shift, y: r.y, width: whole + 4, height: r.height), 13, false, nil, 1)
        if focused && !fieldSelected {
            sol_canvas_fill_rect(c, (r.x - shift + caretX).rounded(), r.y + 3 * s, max((1.5 * s).rounded(), 1), r.height - 6 * s, TerminalPalette.accent, 1)
        }
        sol_canvas_pop_clip(c)
    }

    // MARK: Typing

    /// A key in the field. Returns whether the query changed (to search again).
    func edit(_ key: Int32, ctrl: Bool) -> Bool {
        let before = field.text
        let all = fieldSelected
        switch key {
        case Win.VK_BACK:
            if all { field = TextFieldState("") } else { field.deleteBackward(word: ctrl) }
        case Win.VK_DELETE:
            if all { field = TextFieldState("") } else { field.deleteForward() }
        case Win.VK_LEFT: field.move(to: all ? 0 : field.caret - 1)
        case Win.VK_RIGHT: field.move(to: all ? field.text.count : field.caret + 1)
        case Win.VK_HOME: field.move(to: 0)
        case Win.VK_END: field.move(to: field.text.count)
        default: return false
        }
        fieldSelected = false
        return field.text != before
    }

    func type(_ text: String) {
        if fieldSelected { field = TextFieldState("") }
        fieldSelected = false
        field.insert(text)
    }
}
