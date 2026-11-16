import Foundation

/// A one-line text field's contents, caret and selection, with its own undo, and nothing about drawing or keys: every
/// field in the app is one of these, so they all edit alike, as a document's text does (see `TextFieldKeys` for the
/// keys, `FieldPainter` for the look and the mouse).
struct TextFieldState {
    private(set) var text: String
    /// In characters.
    private(set) var caret: Int
    /// Where a selection started; the caret is its other end. Nil when nothing's selected.
    private(set) var anchor: Int?

    /// What an edit was, so a run of typing (or of deleting) undoes as one step, as in a document.
    private enum EditKind { case typing, deleting, other }
    private struct Snapshot { var text: String; var caret: Int; var anchor: Int? }
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var lastEdit: EditKind?
    private static let maxUndo = 200

    init(_ text: String, selected: Bool = false) {
        let clean = text.filter { !$0.isNewline }
        self.text = clean
        caret = clean.count
        anchor = selected && !clean.isEmpty ? 0 : nil
    }

    var beforeCaret: String { String(text.prefix(caret)) }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // MARK: Selecting

    /// The characters selected, if any.
    var selection: Range<Int>? {
        guard let anchor, anchor != caret else { return nil }
        return min(anchor, caret)..<max(anchor, caret)
    }

    var selectedText: String? { selection.map { String(Array(text)[$0]) } }
    var isAllSelected: Bool { !text.isEmpty && selection == 0..<text.count }

    mutating func selectAll() {
        guard !text.isEmpty else { return }
        anchor = 0
        caret = text.count
        lastEdit = nil
    }

    /// The word around a character (a double-click), or the run of spaces or punctuation there.
    mutating func selectWord(at index: Int) {
        let chars = Array(text)
        guard !chars.isEmpty else { return }
        let i = min(max(index, 0), chars.count - 1)
        let kind = Self.kind(chars[i])
        var start = i, end = i + 1
        while start > 0, Self.kind(chars[start - 1]) == kind { start -= 1 }
        while end < chars.count, Self.kind(chars[end]) == kind { end += 1 }
        anchor = start
        caret = end
        lastEdit = nil
    }

    /// Letters and digits, spaces, or anything else: what a double-click or Ctrl+arrow takes together.
    private static func kind(_ c: Character) -> Int { c.isLetter || c.isNumber || c == "_" ? 0 : c.isWhitespace ? 1 : 2 }

    /// The start of the word before `position`, or the end of the one after it (Ctrl+Left and Ctrl+Right).
    func wordBoundary(from position: Int, forward: Bool) -> Int {
        let chars = Array(text)
        var i = min(max(position, 0), chars.count)
        if forward {
            while i < chars.count, chars[i].isWhitespace { i += 1 }
            guard i < chars.count else { return i }
            let k = Self.kind(chars[i])
            while i < chars.count, Self.kind(chars[i]) == k { i += 1 }
        } else {
            while i > 0, chars[i - 1].isWhitespace { i -= 1 }
            guard i > 0 else { return i }
            let k = Self.kind(chars[i - 1])
            while i > 0, Self.kind(chars[i - 1]) == k { i -= 1 }
        }
        return i
    }

    // MARK: Moving

    /// With `extend` (Shift), the selection grows or shrinks from where it started; without, a selection collapses to
    /// its start or end, as text fields do, before the caret moves on.
    mutating func move(by delta: Int, extend: Bool = false, word: Bool = false) {
        if !extend, !word, let r = selection {
            anchor = nil
            caret = delta < 0 ? r.lowerBound : r.upperBound
            lastEdit = nil
            return
        }
        let target = word ? wordBoundary(from: caret, forward: delta > 0) : caret + delta
        move(to: target, extend: extend)
    }

    mutating func move(to position: Int, extend: Bool = false) {
        if extend { if anchor == nil { anchor = caret } } else { anchor = nil }
        caret = min(max(position, 0), text.count)
        if anchor == caret { anchor = nil }
        lastEdit = nil
    }

    // MARK: Editing

    /// Typing (or pasting) at the caret, over the selection.
    mutating func insert(_ s: String) {
        let clean = s.filter { !$0.isNewline }
        guard !clean.isEmpty || selection != nil else { return }
        // One character typed after another is one step to undo; a paste, a space after a word, or typing over a
        // selection starts a new one.
        let typing = clean.count == 1 && selection == nil
        // A space after a word starts a new step there, so undoing takes back the next word with the space before it.
        let breaks = clean == " " && lastEdit == .typing
        record(typing && !breaks ? .typing : .other)
        replaceSelection(with: clean)
        lastEdit = typing ? .typing : .other
    }

    mutating func deleteBackward(word: Bool = false) {
        if selection != nil { record(.other); replaceSelection(with: ""); lastEdit = .other; return }
        guard caret > 0 else { return }
        record(word ? .other : .deleting)
        let start = word ? wordBoundary(from: caret, forward: false) : caret - 1
        var chars = Array(text)
        chars.removeSubrange(start..<caret)
        text = String(chars)
        caret = start
        if word { lastEdit = .other }
    }

    mutating func deleteForward(word: Bool = false) {
        if selection != nil { record(.other); replaceSelection(with: ""); lastEdit = .other; return }
        guard caret < text.count else { return }
        record(word ? .other : .deleting)
        let end = word ? wordBoundary(from: caret, forward: true) : caret + 1
        var chars = Array(text)
        chars.removeSubrange(caret..<end)
        text = String(chars)
        if word { lastEdit = .other }
    }

    /// Everything before the caret (Ctrl+Backspace at a word's start does a word; this is the Mac's ⌘⌫).
    mutating func deleteToStart() {
        if selection != nil { deleteBackward(); return }
        guard caret > 0 else { return }
        record(.other)
        text = String(text.dropFirst(caret))
        caret = 0
        lastEdit = .other
    }

    /// The whole text replaced, as one step to undo (a picked completion, say). The caret goes to its end.
    mutating func setText(_ s: String) {
        let clean = s.filter { !$0.isNewline }
        guard clean != text else { return }
        record(.other)
        text = clean
        caret = clean.count
        anchor = nil
        lastEdit = .other
    }

    /// Takes out what's selected. False if nothing was.
    @discardableResult
    mutating func deleteSelection() -> Bool {
        guard selection != nil else { anchor = nil; return false }
        record(.other)
        replaceSelection(with: "")
        lastEdit = .other
        return true
    }

    private mutating func replaceSelection(with s: String) {
        var chars = Array(text)
        let r = selection ?? caret..<caret
        chars.replaceSubrange(r, with: Array(s))
        text = String(chars)
        caret = r.lowerBound + s.count
        anchor = nil
    }

    // MARK: Undo

    /// Before an edit: what to go back to, unless this edit carries on the last one (typing, then more typing).
    private mutating func record(_ kind: EditKind) {
        if kind == .other || kind != lastEdit {
            undoStack.append(Snapshot(text: text, caret: caret, anchor: anchor))
            if undoStack.count > Self.maxUndo { undoStack.removeFirst() }
        }
        redoStack.removeAll()
        lastEdit = kind
    }

    /// Ctrl+Z: back to before the last step. False if there's nothing to undo.
    @discardableResult
    mutating func undo() -> Bool {
        guard let last = undoStack.popLast() else { return false }
        redoStack.append(Snapshot(text: text, caret: caret, anchor: anchor))
        (text, caret, anchor) = (last.text, last.caret, last.anchor)
        lastEdit = nil
        return true
    }

    /// Ctrl+Y or Ctrl+Shift+Z: the step undone, done again.
    @discardableResult
    mutating func redo() -> Bool {
        guard let next = redoStack.popLast() else { return false }
        undoStack.append(Snapshot(text: text, caret: caret, anchor: anchor))
        (text, caret, anchor) = (next.text, next.caret, next.anchor)
        lastEdit = nil
        return true
    }

    // MARK: The mouse

    /// A press at a character: the caret there, the selection grown to it with Shift; a double-click takes the word,
    /// a triple-click all of it.
    mutating func press(at index: Int, extend: Bool, clicks: Int = 1) {
        switch clicks {
        case 2: selectWord(at: index)
        case 3...: selectAll()
        default: move(to: index, extend: extend)
        }
    }

    /// Dragging from a press: the selection runs from where it began to here.
    mutating func drag(to index: Int) { move(to: index, extend: true) }
}

/// Command aliases, as in the Mac's Settings › Aliases: a short name that runs a longer command.
struct CommandAlias: Codable, Equatable {
    var name: String
    var command: String

    /// Letters, digits and `_ . -`, not starting with `-`.
    static func isValidName(_ name: String) -> Bool {
        guard let first = name.first, first != "-" else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) }
    }

    /// PowerShell that defines these and removes the ones it defined before. Each is a function behind an alias, so it
    /// can stand in for one of PowerShell's own aliases and still pass on its arguments.
    static func powerShell(_ aliases: [CommandAlias]) -> String {
        let valid = aliases.filter { isValidName($0.name) && !$0.command.trimmingCharacters(in: .whitespaces).isEmpty }
        var out = #"foreach ($n in @($global:__solanum_alias_names)) { if ($n) { Remove-Item "Alias:\$n" -Force -ErrorAction SilentlyContinue } }"# + "\n"
        out += "$global:__solanum_alias_names = @(" + valid.map { "'\($0.name)'" }.joined(separator: ", ") + ")\n"
        for a in valid {
            let function = "__solanum_alias_" + a.name.replacingOccurrences(of: ".", with: "_").replacingOccurrences(of: "-", with: "_")
            out += "function global:\(function) { \(a.command) @args }\n"
            out += "Set-Alias -Name '\(a.name)' -Value '\(function)' -Scope Global -Option AllScope -Force\n"
        }
        return out
    }
}
