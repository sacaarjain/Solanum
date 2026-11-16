import CCanvas
import Foundation
import WinSDK

/// What a key did to a field, for its owner: `changed` the text (search again, say), only `moved` the caret or the
/// selection (draw again), or `pass`: not a field key, for the owner (Enter, Esc, Up…) or the app (its Ctrl keys).
enum FieldKeyResult: Equatable { case changed, moved, pass }

extension TextFieldState {
    /// The keys every field takes, as a document's text does: arrows (Ctrl by word, Shift selecting), Home and End,
    /// Backspace and Delete (Ctrl by word), Ctrl+A, C, X and V, Ctrl+Z, and Ctrl+Y or Ctrl+Shift+Z. Characters come
    /// through `insert` (WM_CHAR), so a key that makes one passes.
    mutating func key(_ key: Int32, shift: Bool, ctrl: Bool, paste: () -> String? = FieldClipboard.text,
                      copy: (String) -> Void = FieldClipboard.set) -> FieldKeyResult {
        let before = text
        func done() -> FieldKeyResult { text != before ? .changed : .moved }
        switch key {
        case Win.VK_LEFT: move(by: -1, extend: shift, word: ctrl)
        case Win.VK_RIGHT: move(by: 1, extend: shift, word: ctrl)
        case Win.VK_HOME: move(to: 0, extend: shift)
        case Win.VK_END: move(to: text.count, extend: shift)
        case Win.VK_BACK: deleteBackward(word: ctrl)
        case Win.VK_DELETE where !shift: deleteForward(word: ctrl)
        case Win.VK_DELETE where shift:
            // Shift+Delete cuts, as in Windows' own fields.
            guard let s = selectedText else { return .moved }
            copy(s)
            deleteSelection()
        case Win.VK_INSERT where shift:
            guard let s = paste() else { return .moved }
            insert(Self.firstLine(s))
        case 0x41 where ctrl && !shift: selectAll()
        case 0x43 where ctrl && !shift, Win.VK_INSERT where ctrl:
            // Copy: what's selected. Nothing selected, the key's the app's (Ctrl+C in a terminal, say).
            guard let s = selectedText else { return .pass }
            copy(s)
            return .moved
        case 0x58 where ctrl && !shift:
            guard let s = selectedText else { return .moved }
            copy(s)
            deleteSelection()
        case 0x56 where ctrl && !shift:
            guard let s = paste() else { return .moved }
            insert(Self.firstLine(s))
        case 0x5A where ctrl && !shift: undo()
        case 0x59 where ctrl && !shift, 0x5A where ctrl && shift: redo()
        default: return .pass
        }
        return done()
    }

    /// A paste into a one-line field: its first line (a path or a word, usually), trailing spaces kept.
    private static func firstLine(_ s: String) -> String {
        s.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }
}

/// The clipboard's text, for a field that has no terminal at hand (Settings, say). Waits a moment if another program
/// has it open, as the terminal's own copy and paste do.
enum FieldClipboard {
    private static func open() -> Bool {
        for _ in 0..<20 {
            if OpenClipboard(nil) { return true }
            Sleep(10)
        }
        return false
    }

    static func text() -> String? {
        guard open() else { return nil }
        defer { CloseClipboard() }
        guard let memory = GetClipboardData(Win.CF_UNICODETEXT), let pointer = GlobalLock(memory) else { return nil }
        defer { GlobalUnlock(memory) }
        return String(decodingCString: pointer.assumingMemoryBound(to: UInt16.self), as: UTF16.self)
    }

    static func set(_ text: String) {
        let units = Array(text.utf16) + [0]
        let bytes = units.count * MemoryLayout<UInt16>.size
        guard open() else { return }
        defer { CloseClipboard() }
        EmptyClipboard()
        guard let memory = GlobalAlloc(Win.GMEM_MOVEABLE, SIZE_T(bytes)), let pointer = GlobalLock(memory) else { return }
        units.withUnsafeBytes { pointer.copyMemory(from: $0.baseAddress!, byteCount: bytes) }
        GlobalUnlock(memory)
        SetClipboardData(Win.CF_UNICODETEXT, memory)
    }
}

/// The caret's blink, shared by every field and the editor: off for the dark half (the window sets it from its clock).
enum CaretBlink {
    static var shown = true
}

/// How a one-line field looks, the same everywhere: its text scrolled to keep the caret in view, the selection shaded in
/// the accent, the caret blinking while it has the keyboard, else the placeholder. And where in it a click lands.
struct FieldPainter {
    let canvas: Canvas
    let scale: Float
    var pixels: Float = 13
    var semibold = false

    private func width(_ s: String) -> Float {
        let units = Array(s.utf16)
        return sol_canvas_measure_label(canvas.raw, units, Int32(units.count), pixels * scale, semibold ? 1 : 0)
    }

    /// How far the text is scrolled left, keeping the caret in view (the same for drawing and the mouse).
    func scroll(_ state: TextFieldState, in r: UIRect) -> Float {
        let whole = width(state.text), caretX = width(state.beforeCaret)
        return max(0, min(caretX - r.width + 4 * scale, whole - r.width + 4 * scale))
    }

    func draw(_ state: TextFieldState, in r: UIRect, focused: Bool, placeholder: String = "", color: UInt32 = TerminalPalette.foreground,
              alpha: Float = 1, placeholderAlpha: Float = 0.45, caretInset: Float = 3, caretColor: UInt32? = nil) {
        let c = canvas.raw, caretW = max((1.5 * scale).rounded(), 1), accent = caretColor ?? TerminalPalette.accent
        let caretY = r.y + caretInset * scale, caretH = r.height - 2 * caretInset * scale
        guard !state.text.isEmpty else {
            if !placeholder.isEmpty {
                let units = Array(placeholder.utf16)
                sol_canvas_draw_label(c, r.x, r.y, r.width, r.height, units, Int32(units.count), pixels * scale, semibold ? 1 : 0, color, placeholderAlpha)
            }
            if focused && CaretBlink.shown { sol_canvas_fill_rect(c, r.x, caretY, caretW, caretH, accent, 1) }
            return
        }
        let shift = scroll(state, in: r)
        sol_canvas_push_clip(c, r.x, r.y, r.width, r.height)
        if let sel = state.selection {
            let chars = Array(state.text)
            let x0 = width(String(chars[..<sel.lowerBound])), x1 = width(String(chars[..<sel.upperBound]))
            sol_canvas_fill_rect(c, (r.x - shift + x0).rounded(), caretY - 1 * scale, (x1 - x0).rounded(.up), caretH + 2 * scale, accent, focused ? 0.32 : 0.16)
        }
        let units = Array(state.text.utf16), whole = width(state.text)
        sol_canvas_draw_label(c, r.x - shift, r.y, whole + 4, r.height, units, Int32(units.count), pixels * scale, semibold ? 1 : 0, color, alpha)
        if focused && CaretBlink.shown {
            sol_canvas_fill_rect(c, (r.x - shift + width(state.beforeCaret)).rounded(), caretY, caretW, caretH, accent, 1)
        }
        sol_canvas_pop_clip(c)
    }

    /// The character boundary nearest `x`, for a click or a drag.
    func index(atX x: Float, _ state: TextFieldState, in r: UIRect) -> Int {
        let chars = Array(state.text), target = x - r.x + scroll(state, in: r)
        guard target > 0 else { return 0 }
        var previous: Float = 0
        for i in chars.indices {
            let w = width(String(chars[...i]))
            if w >= target { return target - previous < w - target ? i : i + 1 }
            previous = w
        }
        return chars.count
    }
}

/// A field's mouse, the same everywhere: a press places the caret (Shift grows the selection, two clicks take a word,
/// three the lot), and dragging from it selects. The owner keeps one of these per field and says whether it's pressed.
struct FieldMouse {
    private(set) var dragging = false
    private var lastPress: (time: DWORD, x: Float, y: Float, clicks: Int)?

    /// A button press over the field's rectangle `r`.
    mutating func press(_ state: inout TextFieldState, x: Float, y: Float, in r: UIRect, painter: FieldPainter, shift: Bool) {
        let now = GetTickCount()
        var clicks = 1
        if let last = lastPress, now &- last.time <= GetDoubleClickTime(), abs(last.x - x) < 4, abs(last.y - y) < 4 { clicks = last.clicks + 1 }
        lastPress = (now, x, y, clicks)
        state.press(at: painter.index(atX: x, state, in: r), extend: shift, clicks: clicks)
        dragging = clicks == 1
    }

    /// The pointer moving with the button held: the selection follows. True if it's being dragged.
    @discardableResult
    mutating func drag(_ state: inout TextFieldState, x: Float, in r: UIRect, painter: FieldPainter) -> Bool {
        guard dragging else { return false }
        if GetKeyState(0x01) >= 0 { dragging = false; return false }
        state.drag(to: painter.index(atX: x, state, in: r))
        return true
    }

    mutating func release() { dragging = false }
}
