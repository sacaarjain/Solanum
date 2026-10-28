import AppKit

extension TerminalView {
    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53 && mods.isEmpty {
            if selectedBlock != nil || selectedTurnLine != nil || selection != nil {
                selectedBlock = nil
                selectedTurnLine = nil
                selection = nil
                needsDisplay = true
                return
            }
        }
        let plainMods = mods.intersection([.command, .control, .option, .shift])
        // Delete / forward delete with text selected in the line being edited removes the selection, with ⌘ or ⌥
        // too (as in a text field), rather than the line or word they delete otherwise.
        if (event.keyCode == 51 || event.keyCode == 117) && plainMods.subtracting([.command, .option]).isEmpty
            && selection != nil && deleteSelectedInput() { return }
        // ⌃H opens searchable command history at a shell prompt (full-screen programs still get ⌃H).
        if event.keyCode == 4 && plainMods == .control && canShowHistory {
            showHistory(nil)
            return
        }
        // Shift+PageUp/PageDown/Home/End scroll the view instead of going to the shell.
        if mods == .shift && !terminal.usingAlt {
            switch event.keyCode {
            case 116: smoothScroll(to: scrollOffset + terminal.rows - 1); return
            case 121: smoothScroll(to: scrollOffset - (terminal.rows - 1)); return
            case 115: computeRowMap(); smoothScroll(to: maxScrollOffset); return
            case 119: smoothScroll(to: 0); return
            default: break
            }
        }
        guard let bytes = encodeKey(event) else {
            super.keyDown(with: event)
            return
        }
        guard !bytes.isEmpty else { return }
        cancelPendingClick()
        send(bytes)
        if scrollOffset != 0 { scrollOffset = 0 }
        selectedBlock = nil
        selectedTurnLine = nil
        NSCursor.setHiddenUntilMouseMoves(true)
        resetBlink()
        needsDisplay = true
    }

    func encodeKey(_ e: NSEvent) -> [UInt8]? {
        let m = e.modifierFlags
        let shift = m.contains(.shift), ctrl = m.contains(.control), opt = m.contains(.option), cmd = m.contains(.command)
        let mod = 1 + (shift ? 1 : 0) + (opt ? 2 : 0) + (ctrl ? 4 : 0)
        let appCursor = terminal.appCursorKeys
        func csi(_ s: String) -> [UInt8] { Array(("\u{1b}[" + s).utf8) }
        func ss3(_ s: String) -> [UInt8] { Array(("\u{1b}O" + s).utf8) }

        func arrow(_ c: String) -> [UInt8]? {
            if cmd {
                if c == "D" { return [0x01] }   // ⌘← start of line
                if c == "C" { return [0x05] }   // ⌘→ end of line
                return nil
            }
            if opt && !shift && !ctrl {
                if c == "D" { return [0x1B, 0x62] } // ⌥← word back
                if c == "C" { return [0x1B, 0x66] } // ⌥→ word forward
            }
            if mod > 1 { return csi("1;\(mod)\(c)") }
            return appCursor ? ss3(c) : csi(c)
        }
        func tilde(_ n: Int) -> [UInt8] { mod > 1 ? csi("\(n);\(mod)~") : csi("\(n)~") }
        func fkey(_ c: String) -> [UInt8] { mod > 1 ? csi("1;\(mod)\(c)") : ss3(c) }

        switch e.keyCode {
        case 123: return arrow("D")
        case 124: return arrow("C")
        case 125: return arrow("B")
        case 126: return arrow("A")
        case 115: return cmd ? nil : (mod > 1 ? csi("1;\(mod)H") : (appCursor ? ss3("H") : csi("H")))
        case 119: return cmd ? nil : (mod > 1 ? csi("1;\(mod)F") : (appCursor ? ss3("F") : csi("F")))
        case 116: return tilde(5)
        case 121: return tilde(6)
        case 117: return cmd ? [0x0B] : tilde(3)         // forward delete; ⌘⌦ kills to end of line
        case 51:                                          // backspace
            if cmd { return [0x15] }
            if opt { return [0x1B, 0x7F] }
            if ctrl { return [0x08] }
            return [0x7F]
        case 36, 76:                                      // return / enter
            if cmd { return nil }
            // ⇧↩ in Claude Code: a new line instead of sending. Its newline key is ⌃J (a plain ↩ submits).
            if shift && !opt && !ctrl && (agent?.kind == .claude || pty?.foregroundIsClaudeCode == true) { return [0x0A] }
            return opt ? [0x1B, 0x0D] : [0x0D]
        case 48:                                          // tab
            if cmd || ctrl { return nil }
            return shift ? csi("Z") : [0x09]
        case 53: return [0x1B]
        case 122: return fkey("P")
        case 120: return fkey("Q")
        case 99: return fkey("R")
        case 118: return fkey("S")
        case 96: return tilde(15)
        case 97: return tilde(17)
        case 98: return tilde(18)
        case 100: return tilde(19)
        case 101: return tilde(20)
        case 109: return tilde(21)
        case 103: return tilde(23)
        case 111: return tilde(24)
        default: break
        }
        if cmd { return nil }

        if ctrl, let ign = e.charactersIgnoringModifiers?.lowercased().unicodeScalars.first?.value {
            var out: [UInt8]?
            switch ign {
            case 0x61...0x7A: out = [UInt8(ign - 0x60)]
            case 0x20, 0x32, 0x40: out = [0x00]
            case 0x5B, 0x33: out = [0x1B]
            case 0x5C, 0x34: out = [0x1C]
            case 0x5D, 0x35: out = [0x1D]
            case 0x5E, 0x36: out = [0x1E]
            case 0x5F, 0x2D, 0x2F, 0x37: out = [0x1F]
            case 0x38: out = [0x7F]
            default: break
            }
            if var o = out {
                if opt && Config.shared.optionAsMeta { o.insert(0x1B, at: 0) }
                return o
            }
        }
        if opt && Config.shared.optionAsMeta {
            let base = e.characters(byApplyingModifiers: shift ? .shift : []) ?? e.charactersIgnoringModifiers ?? ""
            if !base.isEmpty { return [0x1B] + Array(base.utf8) }
        }
        guard let text = e.characters, !text.isEmpty else { return [] }
        return Array(text.utf8)
    }

    // MARK: - Clipboard

    @objc func copy(_ sender: Any?) {
        var text: String?
        if let s = selection { text = textForSelection(s) }
        else if let t = selectedTurn { text = "❯ \(terminal.agentPromptText(t))\n\n\(agentResponseText(t))" }
        else if let b = selectedBlock { text = blockText(b, includeCommand: true) }
        guard let t = text, !t.isEmpty else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t, forType: .string)
    }

    @objc func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        // Files copied in Finder: their paths, as dropping them would (Claude Code attaches images given by path).
        // Without this the clipboard's plain text is just the file name.
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            sendPaste(urls.map { Self.shellEscaped($0.path) }.joined(separator: " ") + " ")
            return
        }
        if let s = pb.string(forType: .string) { return sendPaste(s) }
        guard pb.availableType(from: [.png, .tiff]) != nil else { return NSSound.beep() }
        // Image data only (a screenshot, "Copy Image"). Claude Code reads the clipboard itself on Ctrl+V.
        if pty?.foregroundIsClaudeCode == true {
            send("\u{16}")
            scrollOffset = 0
            return
        }
        // Anywhere else on this Mac: save it to a file and paste the path.
        guard remote == nil, let path = Self.savePastedImage(pb) else { return NSSound.beep() }
        sendPaste(Self.shellEscaped(path) + " ")
    }

    /// Writes the clipboard's image as a PNG in a temporary folder; returns its path.
    private static func savePastedImage(_ pb: NSPasteboard) -> String? {
        var data = pb.data(forType: .png)
        if data == nil, let tiff = pb.data(forType: .tiff), let bmp = NSBitmapImageRep(data: tiff) {
            data = bmp.representation(using: .png, properties: [:])
        }
        guard let data else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("solanum-pasted-images")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let url = dir.appendingPathComponent("pasted-image-\(f.string(from: Date())).png")
        return (try? data.write(to: url)) != nil ? url.path : nil
    }

    static func shellEscaped(_ path: String) -> String {
        let special = Set(" '\"\\()&;|<>$`!*?[]{}#~")
        return String(path.flatMap { special.contains($0) ? ["\\", $0] : [$0] })
    }

    func sendPaste(_ s: String) {
        var text = s.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        if terminal.bracketedPaste {
            text = text.replacingOccurrences(of: "\u{1b}", with: "")
            send("\u{1b}[200~" + text + "\u{1b}[201~")
        } else {
            send(text)
        }
        scrollOffset = 0
        needsDisplay = true
    }

    @objc override func selectAll(_ sender: Any?) {
        let first = terminal.firstAbs
        var last = terminal.lastAbs
        while last > first, let l = terminal.line(abs: last), l.isBlank { last -= 1 }
        let a = GridPos(line: first, col: 0), b = GridPos(line: last, col: terminal.cols - 1)
        selection = Selection(mode: .line, aStart: a, aEnd: a, hStart: b, hEnd: b)
        needsDisplay = true
    }

    func textForSelection(_ s: Selection) -> String {
        codeText(from: s.start, to: s.end) ?? textForRange(from: s.start, to: s.end)
    }

    /// A selection inside one of Claude's code blocks copies that stretch of the original code: no indentation,
    /// and no line breaks where the screen wrapped a long line.
    private func codeText(from st: GridPos, to en: GridPos) -> String? {
        guard let box = codeBoxes.first(where: { $0.kind == .code && $0.contains(line: st.line) && $0.contains(line: en.line) }) else { return nil }
        var lo = Int.max, hi = Int.min
        for a in st.line...en.line {
            let from = a == st.line ? st.col : 0
            let to = a == en.line ? en.col : terminal.cols - 1
            guard from <= to else { continue }
            for x in from...to {
                if let o = box.offsets[GridPos(line: a, col: x)] { lo = min(lo, o); hi = max(hi, o) }
            }
        }
        guard lo <= hi else { return nil }
        let scalars = Array(box.copyText.unicodeScalars)
        return String(String.UnicodeScalarView(scalars[lo...hi]))
    }

    func textForRange(from st: GridPos, to en: GridPos) -> String {
        var out = ""
        var a = st.line
        while a <= en.line {
            guard let l = terminal.line(abs: a) else { a += 1; continue }
            if hiddenRanges.contains(where: { $0.contains(a) }) { a += 1; continue }
            let lo = a == st.line ? st.col : 0
            let hi = a == en.line ? en.col : terminal.cols - 1
            out += l.text(from: lo, to: hi, trim: !l.wrapped || a == en.line)
            if a != en.line && !l.wrapped { out += "\n" }
            a += 1
        }
        return out
    }

    // MARK: - Mouse helpers

    func gridPos(at p: NSPoint) -> GridPos {
        computeRowMap()
        let row = Int(floor((p.y - padTop) / fonts.cellH))
        let col = Int(floor((p.x - padX) / fonts.cellW))
        let r = max(0, min(row, terminal.rows - 1))
        var line = rowMap.isEmpty ? 0 : rowMap[r]
        if line < 0 {
            line = rowMap.last(where: { $0 >= 0 }) ?? 0
        }
        return GridPos(line: line, col: max(0, min(col, terminal.cols - 1)))
    }

    private func screenCell(at p: NSPoint) -> (col: Int, row: Int) {
        let row = Int(floor((p.y - padTop) / fonts.cellH))
        let col = Int(floor((p.x - padX) / fonts.cellW))
        return (max(0, min(col, terminal.cols - 1)), max(0, min(row, terminal.rows - 1)))
    }

    private func isWordChar(_ v: UInt32) -> Bool {
        if v == 0 || v == 32 { return false }
        if let s = Unicode.Scalar(v) {
            if s.properties.isAlphabetic || ("0"..."9").contains(Character(s)) { return true }
            return "-_.~/:@+%#?&=$".unicodeScalars.contains(s)
        }
        return false
    }

    func wordRange(at pos: GridPos) -> (GridPos, GridPos) {
        guard let l = terminal.line(abs: pos.line) else { return (pos, pos) }
        var c = pos.col
        if c < l.cells.count && l.cells[c].width == 0 && c > 0 { c -= 1 }
        let target = c < l.cells.count ? isWordChar(l.cells[c].ch) : false
        var lo = c, hi = c
        func same(_ x: Int) -> Bool {
            let cell = l.cells[x]
            if cell.width == 0 { return true }
            return target ? isWordChar(cell.ch) : (!isWordChar(cell.ch) && cell.ch == l.cells[c].ch)
        }
        while lo > 0 && same(lo - 1) { lo -= 1 }
        while hi < l.cells.count - 1 && same(hi + 1) { hi += 1 }
        return (GridPos(line: pos.line, col: lo), GridPos(line: pos.line, col: hi))
    }

    func lineRange(at pos: GridPos) -> (GridPos, GridPos) {
        var a = pos.line
        while let prev = terminal.line(abs: a - 1), prev.wrapped { a -= 1 }
        var b = pos.line
        while let l = terminal.line(abs: b), l.wrapped { b += 1 }
        return (GridPos(line: a, col: 0), GridPos(line: b, col: terminal.cols - 1))
    }

    private func shouldReportMouse(_ e: NSEvent) -> Bool {
        terminal.mouseMode != .none && !e.modifierFlags.contains(.shift)
    }

    private func reportMouse(button: Int, _ e: NSEvent, press: Bool, motion: Bool = false) {
        let p = convert(e.locationInWindow, from: nil)
        let (col, row) = screenCell(at: p)
        if motion, let last = lastReportedCell, last == (col, row) { return }
        lastReportedCell = (col, row)
        var cb = button
        if motion { cb += 32 }
        let m = e.modifierFlags
        if m.contains(.shift) { cb += 4 }
        if m.contains(.option) { cb += 8 }
        if m.contains(.control) { cb += 16 }
        if terminal.mouseSGR {
            send("\u{1b}[<\(cb);\(col + 1);\(row + 1)\(press ? "M" : "m")")
        } else {
            if !press { cb = 3 + (cb & ~3 & ~64) }
            send([0x1B, 0x5B, 0x4D, UInt8(min(255, 32 + cb)), UInt8(min(255, 33 + col)), UInt8(min(255, 33 + row))])
        }
    }

    // MARK: - Mouse events

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(e.locationInWindow, from: nil)
        if jumpPillRect.contains(p) {
            smoothScroll(to: 0)
            hoverJumpPill = false
            updateCursor()
            needsDisplay = true
            return
        }
        // Scrollbar: grab the thumb where it was pressed, or jump the thumb's middle to a click on the track.
        if inScrollbarZone(p), let g = scrollbarGeometry() {
            scrollbarGrab = g.thumb.insetBy(dx: -6, dy: 0).contains(p) ? (p.y - g.thumb.minY) / g.thumb.height : 0.5
            dragScrollbar(to: p.y)
            needsDisplay = true
            return
        }
        if let button = blockCopyButton, button.rect.contains(p) {
            copyOutput(of: button.block)
            return
        }
        if let button = codeCopyButtons.first(where: { $0.0.contains(p) }) {
            copyBox(button.1)
            return
        }
        if let chip = collapseChips.first(where: { $0.0.contains(p) }) {
            chip.1()
            return
        }
        if e.modifierFlags.contains(.command), let url = urlAt(p)?.url {
            openLink(url)
            return
        }
        if shouldReportMouse(e) {
            reportingMouse = true
            reportMouse(button: 0, e, press: true)
            return
        }
        reportingMouse = false
        let pos = gridPos(at: p)
        didDrag = false
        switch e.clickCount {
        case 2:
            let (a, b) = wordRange(at: pos)
            selection = Selection(mode: .word, aStart: a, aEnd: b, hStart: a, hEnd: b)
        case 3:
            let (a, b) = lineRange(at: pos)
            selection = Selection(mode: .line, aStart: a, aEnd: b, hStart: a, hEnd: b)
        default:
            selection = nil
            mouseAnchor = pos
            mouseAnchorBoxTop = inputBoxAnchor(pos, pos)
        }
        lastDragCell = screenCell(at: p)
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        if scrollbarGrab != nil {
            dragScrollbar(to: convert(e.locationInWindow, from: nil).y)
            return
        }
        if reportingMouse {
            if terminal.mouseMode == .button || terminal.mouseMode == .any { reportMouse(button: 0, e, press: true, motion: true) }
            return
        }
        let p = convert(e.locationInWindow, from: nil)
        if p.y < 0 { scrollBy(lines: 1) } else if p.y > bounds.height { scrollBy(lines: -1) }
        // Text moving under a pointer that stays on the same cell (Claude Code redrawing its input box lower down)
        // doesn't change the selection; only moving the pointer does.
        let cell = screenCell(at: p)
        if let last = lastDragCell, last == cell, p.y >= 0, p.y <= bounds.height { return }
        lastDragCell = cell
        let pos = gridPos(at: p)
        // Jitter within the clicked cell (common on trackpads) is still a click, not a drag.
        if selection == nil, pos == mouseAnchor { return }
        didDrag = true
        if var s = selection {
            switch s.mode {
            case .char:
                s.hStart = pos; s.hEnd = pos
            case .word:
                let (a, b) = wordRange(at: pos)
                s.hStart = a; s.hEnd = b
            case .line:
                let (a, b) = lineRange(at: pos)
                s.hStart = a; s.hEnd = b
            }
            selection = s
        } else if let a = mouseAnchor, a != pos {
            selection = Selection(mode: .char, aStart: a, aEnd: a, hStart: pos, hEnd: pos)
        }
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        mouseAnchorBoxTop = nil
        if scrollbarGrab != nil {
            scrollbarGrab = nil
            scrollbarHover = inScrollbarZone(convert(e.locationInWindow, from: nil))
            updateCursor()
            needsDisplay = true
            return
        }
        if reportingMouse {
            reportMouse(button: 0, e, press: false)
            reportingMouse = false
            return
        }
        let p = convert(e.locationInWindow, from: nil)
        if !didDrag && e.clickCount == 1 {
            let pos = gridPos(at: p)
            let plain = e.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty
            whenCursorSettled { [weak self] in self?.handleClick(at: pos, plain: plain) }
        } else if Config.shared.copyOnSelect, let s = selection {
            let t = textForSelection(s)
            if !t.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(t, forType: .string)
            }
        }
        mouseAnchor = nil
    }

    private func handleClick(at pos: GridPos, plain: Bool) {
        // A plain click inside the line being edited moves the text cursor there.
        if plain, placeCursor(at: pos) {
            selectedBlock = nil
            selectedTurnLine = nil
            needsDisplay = true
            return
        }
        // Otherwise it selects (or deselects) the agent turn or command block under the pointer.
        if !terminal.usingAlt, let t = terminal.agentTurn(containing: pos.line) {
            selectTurn(selectedTurnLine == t.promptLine ? nil : t)
        } else if let b = blockAt(abs: pos.line), b.state == .finished, !terminal.usingAlt {
            selectedTurnLine = nil
            selectedBlock = selectedBlock === b ? nil : b
        } else {
            selectedBlock = nil
            selectedTurnLine = nil
        }
        needsDisplay = true
    }

    // MARK: - Click to place cursor

    /// Runs `work` once the screen is settled: the program has finished redrawing (Claude Code hides the
    /// cursor and parks it below its UI mid-frame, then moves it back into the input box and shows it) and
    /// has echoed arrow keys sent for an earlier click. Reading the cursor mid-frame is what made clicks
    /// miss. Waits at most a short while, then runs anyway; a newer request replaces an older one.
    func whenCursorSettled(timeout: TimeInterval = 0.3, _ work: @escaping () -> Void) {
        pendingClick = work
        pendingClickDeadline = Date().addingTimeInterval(timeout)
        runPendingClick()
        guard pendingClick != nil, pendingClickTimer == nil else { return }
        pendingClickTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in self?.runPendingClick() }
    }

    /// Called after each chunk of output and by the fallback timer.
    func runPendingClick() {
        guard let work = pendingClick else { return cancelPendingClick() }
        let settled = terminal.usingAlt || terminal.mouseMode != .none || (terminal.cursorVisible && !awaitingCursorEcho)
        guard settled || Date() >= pendingClickDeadline else { return }
        cancelPendingClick()
        awaitingCursorEcho = false
        work()
    }

    func cancelPendingClick() {
        pendingClick = nil
        pendingClickTimer?.invalidate()
        pendingClickTimer = nil
    }

    /// Moves the shell's or Claude Code's text cursor to a clicked cell by sending arrow keys, since neither
    /// handles mouse clicks itself. Returns false when the click isn't inside the input being edited.
    private func placeCursor(at pos: GridPos) -> Bool {
        guard !terminal.usingAlt, terminal.mouseMode == .none, let b = terminal.currentBlock else { return false }
        if b.state == .running {
            guard let rows = terminal.agentInputRows(b), rows.contains(pos.line), rows.contains(terminal.cursorAbs) else { return false }
            placeAgentCursor(row: pos.line - rows.lowerBound, col: pos.col, sentVertical: false)
            return true
        }
        return placeShellCursor(b, at: pos)
    }

    private func arrowKey(_ c: String) -> String { terminal.appCursorKeys ? "\u{1b}O" + c : "\u{1b}[" + c }

    private func sendArrows(_ n: Int, back: String, forward: String) {
        guard n != 0 else { return }
        send(String(repeating: arrowKey(n < 0 ? back : forward), count: abs(n)))
        awaitingCursorEcho = true
        scrollOffset = 0
    }

    /// Characters (not cells: wide-char tails don't count) in columns from..<to of a line.
    private func charCount(_ a: Int, from: Int, to: Int) -> Int {
        guard let l = terminal.line(abs: a) else { return 0 }
        let hi = min(to, l.cells.count)
        guard from < hi else { return 0 }
        return l.cells[from..<hi].reduce(0) { $0 + ($1.width != 0 ? 1 : 0) }
    }

    /// Readline soft-wraps by cell, so the command is one run of cells from the end of PS1 through
    /// the cursor's line and any continuation lines; left/right arrows step through it linearly.
    /// `index` maps a cell to a character offset in the command (cells before it count as 0).
    private func shellInput(_ b: Block) -> (start: Int, last: Int, index: (Int, Int) -> Int)? {
        guard b.state == .prompt, let start = b.commandLine, pty?.hasForegroundJob == false else { return nil }
        var last = max(start, terminal.cursorAbs)
        while last < terminal.lastAbs, terminal.line(abs: last)?.wrapped == true { last += 1 }
        let index: (Int, Int) -> Int = { [unowned self] line, col in
            guard line >= start else { return 0 }
            return (start...line).reduce(0) { n, a in
                n + self.charCount(a, from: a == start ? b.commandCol : 0, to: a == line ? col : self.terminal.cols)
            }
        }
        return (start, last, index)
    }

    private func placeShellCursor(_ b: Block, at pos: GridPos) -> Bool {
        guard let input = shellInput(b), pos.line >= input.start, pos.line <= input.last else { return false }
        let cursor = input.index(terminal.cursorAbs, terminal.cursorX)
        let textEnd = input.index(input.last, terminal.line(abs: input.last)?.trimmedLength ?? 0)
        let target = min(input.index(pos.line, pos.col), max(textEnd, cursor))
        sendArrows(target - cursor, back: "D", forward: "C")
        return true
    }

    // MARK: - Deleting selected input

    /// Removes the selected part of the command being typed: moves the cursor to the end of the selection
    /// and backspaces over it. Works at a shell prompt (any number of rows) and in Claude Code's input box
    /// (within one row, since it word-wraps itself). Returns false when the selection isn't in the input.
    @discardableResult
    func deleteSelectedInput() -> Bool {
        guard let s = selection, !terminal.usingAlt, terminal.mouseMode == .none, let b = terminal.currentBlock else { return false }
        let st = s.start, en = s.end
        if let input = shellInput(b) {
            guard en.line >= input.start, st.line <= input.last else { return false }
            let textEnd = input.index(input.last, terminal.line(abs: input.last)?.trimmedLength ?? 0)
            let from = min(input.index(st.line, st.col), textEnd)
            let to = en.line > input.last ? textEnd : min(input.index(en.line, en.col + 1), textEnd)
            guard to > from else { return false }
            let cursor = input.index(terminal.cursorAbs, terminal.cursorX)
            sendArrows(to - cursor, back: "D", forward: "C")
            send(String(repeating: "\u{7f}", count: to - from))
        } else if b.state == .running, let rows = terminal.agentInputRows(b), rows.contains(terminal.cursorAbs),
                  en.line >= rows.lowerBound, st.line <= rows.upperBound {
            // Any number of rows of Claude Code's input box (the selection is clipped to the box's text).
            let first = max(st.line, rows.lowerBound), last = min(en.line, rows.upperBound)
            let startCol = first == st.line ? max(2, min(st.col, agentTextEnd(first))) : 2
            let endCol = last == en.line ? min(en.col + 1, agentTextEnd(last)) : agentTextEnd(last)
            let target = GridPos(line: first, col: startCol)
            guard GridPos(line: last, col: endCol) > target else { return false }
            let targetOffset = agentInputOffset(rows, target)
            placeAgentCursor(row: last - rows.lowerBound, col: endCol, sentVertical: false) { [weak self] in
                self?.whenOutputQuiet { self?.backspaceAgentInput(toOffset: targetOffset, rounds: 0) }
            }
        } else {
            return false
        }
        selection = nil
        selectedBlock = nil
        needsDisplay = true
        return true
    }

    /// Characters from the start of Claude Code's input text to `p`: each row's text plus one per row break (the
    /// space a word-wrap swallowed, or a typed line break; only a word too long for a row breaks without one).
    private func agentInputOffset(_ rows: ClosedRange<Int>, _ p: GridPos) -> Int {
        var n = 0
        for a in rows.lowerBound..<p.line { n += charCount(a, from: 2, to: agentTextEnd(a)) + 1 }
        return n + charCount(p.line, from: 2, to: p.col)
    }

    /// Backspaces from the cursor back to `target` characters into Claude Code's input. It re-wraps its text as
    /// characters go, so the gap is measured again after each redraw (text before the target never moves) and
    /// topped up until the cursor gets there.
    private func backspaceAgentInput(toOffset target: Int, rounds: Int) {
        guard rounds < 12, let b = terminal.currentBlock, let rows = terminal.agentInputRows(b), rows.contains(terminal.cursorAbs) else { return }
        let n = agentInputOffset(rows, GridPos(line: terminal.cursorAbs, col: terminal.cursorX)) - target
        guard n > 0 else { return }
        send(String(repeating: "\u{7f}", count: n))
        whenOutputQuiet { [weak self] in self?.backspaceAgentInput(toOffset: target, rounds: rounds + 1) }
    }

    /// Runs `work` once the program has stopped drawing for a moment (it may take several frames to work through
    /// a burst of keys, so the first redraw isn't the last). Gives up waiting after `timeout`.
    func whenOutputQuiet(_ quiet: TimeInterval = 0.12, timeout: TimeInterval = 2, _ work: @escaping () -> Void) {
        let start = Date()
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] t in
            guard let self else { return t.invalidate() }
            let idle = Date().timeIntervalSince(max(self.lastOutputAt, start)) >= quiet
            guard (idle && self.terminal.cursorVisible) || Date().timeIntervalSince(start) > timeout else { return }
            t.invalidate()
            work()
        }
    }

    /// ⌘X copies the selection and, when it's part of the command being typed, deletes it.
    @objc func cut(_ sender: Any?) {
        guard let s = selection else { return NSSound.beep() }
        let text = textForSelection(s)
        guard deleteSelectedInput() else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Where the text actually typed on a row of Claude Code's input box ends. Its suggestions (a placeholder
    /// like Try "…", or a completion after what's typed) are drawn dim, the first character inverted as its
    /// cursor. They aren't text yet: arrowing into them accepts the suggestion, so clicks stop short of them.
    func agentTextEnd(_ a: Int) -> Int {
        guard let l = terminal.line(abs: a) else { return 0 }
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

    /// Claude Code word-wraps its input box itself, so cells don't map linearly to text. Move to the
    /// target row with up/down first (it moves by visual row), wait for the redraw, then fix the column.
    private func placeAgentCursor(row: Int, col: Int, sentVertical: Bool, giveUpAt: Date = .distantFuture, then: (() -> Void)? = nil) {
        guard let b = terminal.currentBlock, b.state == .running, let rows = terminal.agentInputRows(b),
              rows.contains(terminal.cursorAbs) else { return }
        let target = rows.lowerBound + row
        guard rows.contains(target) else { return }
        let cursorLine = terminal.cursorAbs
        if cursorLine == target {
            let cx = terminal.cursorX
            let c = max(2, min(col, max(cx, agentTextEnd(target))))
            sendArrows(c >= cx ? charCount(target, from: cx, to: c) : -charCount(target, from: c, to: cx), back: "D", forward: "C")
            then?()
            return
        }
        if sentVertical {
            // An unrelated redraw (e.g. the spinner) can land before the echo of our arrows: wait for the next one.
            guard Date() < giveUpAt else { return }
            awaitingCursorEcho = true
            whenCursorSettled { [weak self] in self?.placeAgentCursor(row: row, col: col, sentVertical: true, giveUpAt: giveUpAt, then: then) }
            return
        }
        sendArrows(target - cursorLine, back: "A", forward: "B")
        let giveUp = Date().addingTimeInterval(0.5)
        whenCursorSettled { [weak self] in self?.placeAgentCursor(row: row, col: col, sentVertical: true, giveUpAt: giveUp, then: then) }
    }

    override func rightMouseDown(with e: NSEvent) {
        if shouldReportMouse(e) {
            reportMouse(button: 2, e, press: true)
            return
        }
        super.rightMouseDown(with: e)
    }

    override func rightMouseUp(with e: NSEvent) {
        if shouldReportMouse(e) { reportMouse(button: 2, e, press: false); return }
        super.rightMouseUp(with: e)
    }

    override func otherMouseDown(with e: NSEvent) {
        if shouldReportMouse(e) { reportMouse(button: 1, e, press: true) }
    }

    override func otherMouseUp(with e: NSEvent) {
        if shouldReportMouse(e) { reportMouse(button: 1, e, press: false) }
    }

    override func mouseMoved(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if terminal.mouseMode == .any && !e.modifierFlags.contains(.shift) {
            reportMouse(button: 3, e, press: true, motion: true)
        }
        var newHover: Block?
        if !terminal.usingAlt && bounds.contains(p) {
            let pos = gridPos(at: p)
            if let b = blockAt(abs: pos.line), b.state != .prompt { newHover = b }
        }
        if newHover !== hoverBlock {
            hoverBlock = newHover
            needsDisplay = true
        }
        let copyHover = codeCopyButtons.first { $0.0.contains(p) }?.1
        let blockHover = blockCopyButton?.rect.contains(p) ?? false
        let pillHover = jumpPillRect.contains(p)
        let barHover = inScrollbarZone(p)
        if copyHover != hoverCopyButton || blockHover != hoverBlockCopy || pillHover != hoverJumpPill || barHover != scrollbarHover {
            hoverCopyButton = copyHover
            hoverBlockCopy = blockHover
            hoverJumpPill = pillHover
            scrollbarHover = barHover
            needsDisplay = true
        }
        updateLinkHover(p, cmd: e.modifierFlags.contains(.command))
        updateCursor()
    }

    override func flagsChanged(with e: NSEvent) {
        super.flagsChanged(with: e)
        guard let w = window else { return }
        let p = convert(w.mouseLocationOutsideOfEventStream, from: nil)
        updateLinkHover(p, cmd: e.modifierFlags.contains(.command))
    }

    private func updateLinkHover(_ p: NSPoint, cmd: Bool) {
        var newHover: (line: Int, start: Int, end: Int)?
        if cmd, bounds.contains(p), let u = urlAt(p) { newHover = (u.line, u.start, u.end) }
        let changed = newHover?.line != hoverURL?.line || newHover?.start != hoverURL?.start
        if changed {
            hoverURL = newHover
            updateCursor()
            needsDisplay = true
        }
    }

    /// Pointing hand over things you click (Copy buttons, ⌘-hovered links), I-beam over text.
    func updateCursor() {
        // Normal arrow over the scrollbar and the jump-to-bottom button; a hand over copy buttons and ⌘-links.
        if scrollbarHover || scrollbarGrab != nil || hoverJumpPill { return NSCursor.arrow.set() }
        (hoverCopyButton != nil || hoverBlockCopy || hoverURL != nil ? NSCursor.pointingHand : NSCursor.iBeam).set()
    }

    override func mouseExited(with e: NSEvent) {
        if hoverBlock != nil || hoverURL != nil || hoverCopyButton != nil || hoverBlockCopy || hoverJumpPill || scrollbarHover {
            hoverBlock = nil
            hoverURL = nil
            hoverCopyButton = nil
            hoverBlockCopy = false
            hoverJumpPill = false
            scrollbarHover = scrollbarGrab != nil
            needsDisplay = true
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor()
    }

    override func scrollWheel(with e: NSEvent) {
        let delta = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * fonts.cellH
        scrollAccum += delta
        let lines = Int(scrollAccum / fonts.cellH)
        guard lines != 0 else { return }
        scrollAccum -= CGFloat(lines) * fonts.cellH

        if terminal.mouseMode != .none && !e.modifierFlags.contains(.shift) {
            for _ in 0..<min(abs(lines), 10) { reportMouse(button: lines > 0 ? 64 : 65, e, press: true) }
            return
        }
        if terminal.usingAlt {
            if terminal.altScroll {
                let seq: [UInt8] = terminal.appCursorKeys ? (lines > 0 ? [0x1B, 0x4F, 0x41] : [0x1B, 0x4F, 0x42])
                                                            : (lines > 0 ? [0x1B, 0x5B, 0x41] : [0x1B, 0x5B, 0x42])
                for _ in 0..<min(abs(lines), 10) { send(seq) }
            }
            return
        }
        scrollBy(lines: lines)
    }

    func scrollBy(lines: Int) {
        let before = scrollOffset
        computeRowMap()
        scrollOffset = max(0, min(scrollOffset + lines, maxScrollOffset))
        lastScrollTime = Date()
        if scrollOffset != before || lines != 0 { needsDisplay = true }
    }

    // MARK: - Links

    /// Finds an http(s)/file URL under the given point, searching the whole wrapped logical line.
    func urlAt(_ p: NSPoint) -> (url: URL, line: Int, start: Int, end: Int)? {
        let pos = gridPos(at: p)
        let (a, b) = lineRange(at: pos)
        var text = ""
        var map: [GridPos] = []
        for ln in a.line...b.line {
            guard let l = terminal.line(abs: ln) else { continue }
            for x in 0..<l.cells.count {
                let c = l.cells[x]
                if c.width == 0 { continue }
                let s = c.ch == 0 ? " " : String(Character(Unicode.Scalar(c.ch) ?? " "))
                for _ in s.utf16 { map.append(GridPos(line: ln, col: x)) }
                text += s
            }
        }
        guard let re = TerminalView.urlRegex else { return nil }
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var r = m.range
            while r.length > 0, let last = ns.substring(with: NSRange(location: r.location + r.length - 1, length: 1)).first,
                  ".,;:!?)]}'\"".contains(last) {
                r.length -= 1
            }
            guard r.length > 0 else { continue }
            let first = map[r.location], last = map[r.location + r.length - 1]
            guard pos >= first && pos <= last else { continue }
            guard let url = URL(string: ns.substring(with: r)) else { continue }
            if first.line == last.line { return (url, first.line, first.col, last.col) }
            // Multi-line links: underline only the hovered row's portion.
            let s = pos.line == first.line ? first.col : 0
            let en = pos.line == last.line ? last.col : terminal.cols - 1
            return (url, pos.line, s, en)
        }
        return nil
    }

    static let urlRegex = try? NSRegularExpression(pattern: #"(?:https?|file|ftp)://[^\s<>"'`]+"#)

    // MARK: - Drag & drop files

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty else { return false }
        send(urls.map { Self.shellEscaped($0.path) }.joined(separator: " ") + " ")
        window?.makeFirstResponder(self)
        return true
    }

    // MARK: - Focus

    override func becomeFirstResponder() -> Bool {
        if terminal.focusEvents { send("\u{1b}[I") }
        blinkOn = true
        needsDisplay = true
        tab?.paneDidFocus(self)
        return true
    }

    override func resignFirstResponder() -> Bool {
        if terminal.focusEvents { send("\u{1b}[O") }
        needsDisplay = true
        return true
    }

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        let menu = NSMenu()
        if let u = urlAt(p) {
            let open = NSMenuItem(title: "Open Link", action: #selector(openLinkFromMenu(_:)), keyEquivalent: "")
            open.representedObject = u.url
            open.target = self
            menu.addItem(open)
            let copyLink = NSMenuItem(title: "Copy Link", action: #selector(copyLinkFromMenu(_:)), keyEquivalent: "")
            copyLink.representedObject = u.url
            copyLink.target = self
            menu.addItem(copyLink)
            menu.addItem(.separator())
        }
        let pos = gridPos(at: p)
        if !terminal.usingAlt, let t = terminal.agentTurn(containing: pos.line) {
            selectTurn(t)
            menu.addItem(withTitle: "Copy Prompt", action: #selector(copyBlockCommand(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Copy Response", action: #selector(copyBlockOutput(_:)), keyEquivalent: "")
            menu.addItem(withTitle: collapsedTurns.contains(t.promptLine) ? "Expand Response" : "Collapse Response",
                         action: #selector(toggleBlockCollapse(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Jump to Prompt…", action: #selector(jumpToPrompt(_:)), keyEquivalent: "")
            menu.addItem(.separator())
        } else if let b = blockAt(abs: pos.line), b.state == .finished {
            selectedTurnLine = nil
            selectedBlock = b
            needsDisplay = true
            menu.addItem(withTitle: "Copy Command", action: #selector(copyBlockCommand(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Copy Output", action: #selector(copyBlockOutput(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Re-run Command", action: #selector(rerunBlockCommand(_:)), keyEquivalent: "")
            menu.addItem(withTitle: b.collapsed ? "Expand Output" : "Collapse Output", action: #selector(toggleBlockCollapse(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Save Command as Snippet…", action: #selector(saveCommandAsSnippet(_:)), keyEquivalent: "")
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Split Right", action: #selector(TerminalWindowController.splitIntoColumns(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Clear Buffer", action: #selector(clearBuffer(_:)), keyEquivalent: "")
        return menu
    }

    @objc func openLinkFromMenu(_ sender: NSMenuItem) {
        if let u = sender.representedObject as? URL { openLink(u) }
    }

    /// file:// links to files open in Solanum's editor; folders and web links go to their usual app.
    private func openLink(_ url: URL) {
        var isDir: ObjCBool = false
        if url.isFileURL, FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
           let app = NSApp.delegate as? AppDelegate {
            app.openInEditor(url.path)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func copyLinkFromMenu(_ sender: NSMenuItem) {
        if let u = sender.representedObject as? URL {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(u.absoluteString, forType: .string)
        }
    }
}
