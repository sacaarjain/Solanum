import CCanvas
import Foundation

/// Ctrl+F's bar over the terminal (Claude Code's chats included) and the Markdown preview: the Mac's ⌘F SearchBar, at the
/// top right, with VS Code's toggles as the file editor has them. A magnifying glass, the scope where there is one (the
/// terminal's All, Commands or Output), the field, "3/12", Aa, ab and .* (shared with the file editor's bar, as in VS
/// Code), and previous, next and close. What it finds is up to its owner; the terminal's search is below.
final class FindBar {
    enum Part: Equatable { case bar, scope, field, matchCase, wholeWord, regex, previous, next, close }

    /// What a key in the bar comes to, for its owner.
    enum KeyResult { case handled, changed, step(Int), close, pass }

    let showsScope: Bool
    var field = TextFieldState("")
    /// The field's text all selected, as on opening: typing replaces it.
    var fieldSelected = true
    /// It has the keyboard (else what's under it has, the bar staying open).
    var focused = true
    var scope: SearchScope = .all
    /// How many matches, which is current (from 0, -1 for none), and whether the regular expression doesn't parse.
    var total = 0
    var current = -1
    var badRegex = false
    var hovered: Part?
    private(set) var parts: [(Part, UIRect)] = []
    private(set) var box: UIRect?
    /// The last query, to start with next time, as the Mac does.
    static var lastQuery = ""

    /// The toggles, shared with the file editor's bar.
    static var options: EditorFindOptions {
        get { FileEditorPanel.findOptions }
        set { FileEditorPanel.findOptions = newValue }
    }

    init(showsScope: Bool) {
        self.showsScope = showsScope
        field = TextFieldState(Self.lastQuery)
    }

    func step(_ d: Int) {
        guard total > 0 else { return }
        current = ((current < 0 ? 0 : current) + d + total) % total
    }

    /// "3/12", "0/0" for none, nothing before a search.
    var count: (text: String, problem: Bool)? {
        guard !field.text.isEmpty else { return nil }
        if badRegex { return ("Invalid regex", true) }
        return total == 0 ? ("0/0", true) : ("\(current + 1)/\(total)", false)
    }

    var placeholder: String { !showsScope || scope == .all ? "Find" : "Find in \(scope.title.lowercased())" }

    // MARK: Layout and drawing

    /// The Mac's bar, 36 high, 12 from the right and 8 from the top; wider than its 432 for the toggles and the scope.
    func layout(in area: UIRect, scale s: Float) {
        let w = min(((showsScope ? 540 : 440) * s).rounded(), area.width - 24 * s), h = (36 * s).rounded()
        guard w > 240 * s else { box = nil; parts = []; return }
        let b = UIRect(x: (area.maxX - w - 12 * s).rounded(), y: (area.y + 8 * s).rounded(), width: w, height: h)
        box = b
        let side = (22 * s).rounded(), mid = b.y + ((h - side) / 2).rounded()
        // From the right: close, next, previous, the three toggles, then the count; from the left the glass, the scope
        // and the field.
        var right = b.maxX - 6 * s
        var out: [(Part, UIRect)] = []
        for part in [Part.close, .next, .previous] {
            right -= side
            out.append((part, UIRect(x: right, y: mid, width: side, height: side)))
            right -= 1 * s
        }
        right -= 5 * s
        for part in [Part.regex, .wholeWord, .matchCase] {
            right -= 24 * s
            out.append((part, UIRect(x: right, y: mid, width: 24 * s, height: side)))
            right -= 2 * s
        }
        let countRight = right - 4 * s
        var fieldX = b.x + 32 * s
        if showsScope {
            out.append((.scope, UIRect(x: b.x + 28 * s, y: b.y + 6 * s, width: 96 * s, height: h - 12 * s)))
            fieldX = b.x + 140 * s
        }
        out.append((.field, UIRect(x: fieldX, y: b.y + 6 * s, width: max(countRight - 70 * s - fieldX, 40 * s), height: h - 12 * s)))
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
        let o = Self.options
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
            case .matchCase, .wholeWord, .regex:
                // As the file editor's: lit while on.
                let on = part == .matchCase ? o.matchCase : part == .wholeWord ? o.wholeWord : o.regex
                if on || hovered { sol_canvas_fill_rounded(c, r.x, r.y, r.width, r.height, 5 * s, accent, on ? 0.24 : 0.13) }
                let title = part == .matchCase ? "Aa" : part == .wholeWord ? "ab" : ".*"
                let tw = width(title, pixels: 12, semibold: true), lx = (r.x + (r.width - tw) / 2).rounded()
                label(title, UIRect(x: lx, y: r.y, width: tw + 2, height: r.height), pixels: 12, semibold: true,
                      color: on || hovered ? accent : nil, alpha: on || hovered ? 1 : 0.6)
                if part == .wholeWord {
                    sol_canvas_fill_rect(c, lx, (r.midY + 6 * s).rounded(), tw, max((1 * s).rounded(), 1), on || hovered ? accent : fg, on || hovered ? 1 : 0.6)
                }
            case .previous, .next, .close:
                if hovered { sol_canvas_fill_rounded(c, r.x, r.y, r.width, r.height, 5 * s, fg, 0.10) }
                let glyph: UInt16 = part == .previous ? 0xE70E : part == .next ? 0xE70D : 0xE8BB
                sol_canvas_draw_icon(c, r.x, r.y, r.width, r.height, glyph, (part == .close ? 9 : 10) * s, hovered ? accent : fg, hovered ? 1 : 0.75)
            case .bar: break
            }
        }
        if let count, let first = rect(.matchCase) {
            let w = width(count.text, pixels: 11)
            label(count.text, UIRect(x: first.x - 8 * s - w, y: b.y, width: w + 2, height: b.height), pixels: 11,
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

    // MARK: Keys and the mouse

    /// A key while the bar has the keyboard. Characters come through `type`. Ctrl keys it doesn't use pass on, so the app's
    /// own still work; `paste` is the clipboard's text, `copy` puts the field's on it.
    func key(_ key: Int32, shift: Bool, ctrl: Bool, paste: () -> String?, copy: (String) -> Void) -> KeyResult {
        switch key {
        case Win.VK_ESCAPE: return .close
        case Win.VK_RETURN, 0x72: return .step(shift ? -1 : 1)
        case Win.VK_UP, Win.VK_DOWN, Win.VK_PRIOR, Win.VK_NEXT, Win.VK_TAB: return .handled
        case 0x41 where ctrl, 0x46 where ctrl:
            fieldSelected = true
            return .handled
        case 0x43 where ctrl:
            copy(field.text)
            return .handled
        case 0x56 where ctrl:
            guard let text = paste()?.split(whereSeparator: \.isNewline).first.map(String.init) else { return .handled }
            type(text)
            return .changed
        default:
            if ctrl && key != Win.VK_BACK && key != Win.VK_DELETE { return .pass }
            let before = field.text, all = fieldSelected
            switch key {
            case Win.VK_BACK: if all { field = TextFieldState("") } else { field.deleteBackward(word: ctrl) }
            case Win.VK_DELETE: if all { field = TextFieldState("") } else { field.deleteForward() }
            case Win.VK_LEFT: field.move(to: all ? 0 : field.caret - 1)
            case Win.VK_RIGHT: field.move(to: all ? field.text.count : field.caret + 1)
            case Win.VK_HOME: field.move(to: 0)
            case Win.VK_END: field.move(to: field.text.count)
            // Anything else becomes a character (WM_CHAR): not taken here.
            default: return .pass
            }
            fieldSelected = false
            return field.text != before ? .changed : .handled
        }
    }

    func type(_ text: String) {
        if fieldSelected { field = TextFieldState("") }
        fieldSelected = false
        field.insert(text)
        Self.lastQuery = field.text
    }

    /// Alt+C, Alt+W and Alt+R, as VS Code's: true when one was flipped (search again).
    static func flip(_ key: Int32) -> Bool {
        switch key {
        case 0x43: options.matchCase.toggle()
        case 0x57: options.wholeWord.toggle()
        case 0x52: options.regex.toggle()
        default: return false
        }
        return true
    }

    /// What a click on a part does, for its owner; the field and toggles are dealt with here.
    enum Click { case none, changed, step(Int), close, scope }

    func press(_ part: Part, double: Bool) {
        focused = true
        if part == .field {
            if double { fieldSelected = true } else { fieldSelected = false; field.move(to: field.text.count) }
        }
    }

    func release(_ part: Part) -> Click {
        switch part {
        case .matchCase: Self.options.matchCase.toggle(); return .changed
        case .wholeWord: Self.options.wholeWord.toggle(); return .changed
        case .regex: Self.options.regex.toggle(); return .changed
        case .previous: return .step(-1)
        case .next: return .step(1)
        case .close: return .close
        case .scope: return .scope
        default: return .none
        }
    }
}

/// The terminal's find: its matches, as cells to shade, from Core's TerminalSearch.
final class TerminalFindBar {
    let bar = FindBar(showsScope: true)
    private(set) var matches: [SearchMatch] = []
    /// Each line's matches as drawn: columns, and whether it's the current one.
    private(set) var cells: [Int: [(start: Int, end: Int, current: Bool)]] = [:]

    /// Searches again, starting from the last match at or above `bottomLine`.
    func search(_ terminal: Terminal, bottomLine: Int) {
        FindBar.lastQuery = bar.field.text
        do {
            matches = try TerminalSearch.matches(bar.field.text, in: terminal, scope: bar.scope, options: FindBar.options)
            bar.badRegex = false
        } catch {
            matches = []
            bar.badRegex = true
        }
        bar.total = matches.count
        bar.current = TerminalSearch.startIndex(matches, bottomLine: bottomLine) ?? -1
        rebuildCells()
    }

    func step(_ d: Int) {
        bar.step(d)
        rebuildCells()
    }

    var currentLine: Int? { matches.indices.contains(bar.current) ? matches[bar.current].line : nil }

    private func rebuildCells() {
        cells = [:]
        for (i, m) in matches.enumerated() { cells[m.line, default: []].append((m.start, m.end, i == bar.current)) }
    }
}
