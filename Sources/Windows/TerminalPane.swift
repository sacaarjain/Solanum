import CCanvas
import Foundation
import WinSDK

/// One terminal: a shell, its emulator, and what's selected and being typed. A window shows one pane at a time, its tab's.
/// Everything runs on the thread with the message loop, including the emulator: output is handed over from the reading
/// thread, not fed from it.
final class TerminalPane: TerminalDelegate {
    private static var nextID: UInt = 1
    let id: UInt
    private(set) weak var host: TerminalWindow?
    private let hwnd: HWND
    private var canvas: Canvas { host!.canvas }
    private(set) var terminal: Terminal
    private var pty: ConPTY?
    private var selection: TerminalSelection?
    private var selecting = false
    private(set) var scrollOffset = 0
    var focused = false
    private var pendingSurrogate: UInt16?
    private var lastMouseCell: (Int, Int)?
    private var lastResize: Date?
    private var pendingClick: (() -> Void)?
    private var pendingClickDeadline = Date.distantPast
    private var awaitingCursorEcho = false
    static let clickTimer: UINT_PTR = 2
    private var afterSelectionDeleted: [[UInt8]]?
    private var selectionDeleteDeadline: Date?
    private var quietWork: ((Bool) -> Void)?
    private var quietStart = Date.distantPast
    private var lastOutputAt = Date.distantPast
    static let quietTimer: UINT_PTR = 3

    /// Output waiting for the message loop.
    private let inboxLock = NSLock()
    private var inbox: [UInt8] = []
    private var outputPosted = false
    /// Above this the reading thread waits, which holds back a program printing faster than can be drawn.
    private static let inboxLimit = 8 * 1024 * 1024

    /// Starts a shell. Nil if it can't.
    init?(host: TerminalWindow, commandLine: String, cols: Int, rows: Int) {
        id = Self.nextID
        Self.nextID += 1
        self.host = host
        hwnd = host.hwnd
        terminal = Terminal(cols: cols, rows: rows, scrollbackLimit: 10000)
        terminal.delegate = self
        terminal.repaintedByConsole = true
        let home = ProcessInfo.processInfo.environment["USERPROFILE"]
        let environment = ["TERM": "xterm-256color", "COLORTERM": "truecolor", "TERM_PROGRAM": "Solanum"]
        guard let pty = ConPTY(commandLine: commandLine, extraEnvironment: environment, cwd: home, cols: cols, rows: rows) else { return nil }
        self.pty = pty
        let target = UInt(bitPattern: hwnd), id = id
        pty.onData = { [weak self] bytes in self?.receive(bytes, window: target, id: id) }
        pty.onExit = { code in
            PostMessageW(HWND(bitPattern: target), Win.WM_EXITED, WPARAM(id), LPARAM(code))
        }
    }

    func terminate() { pty?.terminate() }

    /// Its size, as the window has just changed. Later, `reanchorIfSettled` deals with what that did to the shell.
    func resize(cols: Int, rows: Int) {
        guard cols != terminal.cols || rows != terminal.rows else { return }
        terminal.resize(cols: cols, rows: rows)
        pty?.resize(cols: cols, rows: rows)
        scrollOffset = min(scrollOffset, terminal.scrollback.count)
        lastResize = Date()
    }

    func setFocused(_ on: Bool) {
        guard on != focused else { return }
        focused = on
        if terminal.focusEvents { send(on ? "\u{1b}[I" : "\u{1b}[O") }
    }

    var tabTitle: String {
        WindowText.tabTitle(title: terminal.title, folder: terminal.cwd, home: ProcessInfo.processInfo.environment["USERPROFILE"])
    }

    /// Timed work that doesn't depend on being the pane on screen.
    func tick() {
        // Should the cursor never get there (the box closed, say), what's waiting still goes.
        if let deadline = selectionDeleteDeadline, Date() > deadline { endDeletingSelection() }
        reanchorIfSettled()
    }

    func draw() {
        var renderer = TerminalRenderer(canvas: canvas, terminal: terminal)
        renderer.scrollOffset = scrollOffset
        renderer.selection = selection
        renderer.focused = focused
        renderer.drawContents()
    }

    // MARK: - Output

    /// On the reading thread.
    private func receive(_ bytes: UnsafeBufferPointer<UInt8>, window: UInt, id: UInt) {
        while true {
            inboxLock.lock()
            if inbox.count < Self.inboxLimit { break }
            inboxLock.unlock()
            Thread.sleep(forTimeInterval: 0.002)
        }
        inbox.append(contentsOf: bytes)
        let post = !outputPosted
        outputPosted = true
        inboxLock.unlock()
        if post { PostMessageW(HWND(bitPattern: window), Win.WM_OUTPUT, WPARAM(id), 0) }
    }

    func drainOutput() {
        inboxLock.lock()
        let bytes = inbox
        inbox = []
        outputPosted = false
        inboxLock.unlock()
        bytes.withUnsafeBufferPointer { terminal.feed($0) }
        lastOutputAt = Date()
        awaitingCursorEcho = false
        runPendingClick()
        if scrollOffset > 0 { scrollOffset += terminal.scrollbackPushes }
        terminal.scrollbackPushes = 0
        scrollOffset = min(scrollOffset, terminal.scrollback.count)
        guard !terminal.syncOutput else { return }
        host?.paneChanged(self)
    }

    private func invalidate() { host?.paneChanged(self) }

    /// Once the window has stopped changing size and the console has redrawn (see `PowerShellIntegration.reanchorKey`).
    func reanchorIfSettled() {
        guard let last = lastResize, Date().timeIntervalSince(last) > 0.25 else { return }
        lastResize = nil
        if terminal.currentBlock?.state == .prompt { pty?.write(PowerShellIntegration.reanchorKey) }
    }

    // MARK: - Keyboard

    private func isDown(_ key: Int32) -> Bool { GetKeyState(key) < 0 }

    /// Keys that don't type a character. True if it's dealt with, and shouldn't go on to become one.
    func keyDown(_ key: Int32) -> Bool {
        let shift = isDown(Win.VK_SHIFT), ctrl = isDown(Win.VK_CONTROL), alt = isDown(Win.VK_MENU)
        if key == Win.VK_F4 && alt { return false }

        // Ctrl+Shift is what's left for the app: on its own, Ctrl+C and Ctrl+V belong to the shell.
        if ctrl && shift && !alt {
            switch key {
            case 0x43:
                copySelection()
                return true
            case 0x56:
                paste()
                return true
            case 0x58:
                cutSelection()
                return true
            default: break
            }
        }
        if shift && !ctrl && !alt {
            switch key {
            case Win.VK_INSERT:
                paste()
                return true
            case Win.VK_PRIOR, Win.VK_NEXT:
                guard !terminal.usingAlt else { break }
                scroll(by: (key == Win.VK_PRIOR ? 1 : -1) * max(terminal.rows - 1, 1))
                return true
            default: break
            }
        }

        // Backspace or Delete takes out text selected in the line being typed, whatever else is held.
        if (key == Win.VK_BACK || key == Win.VK_DELETE) && selection != nil && replaceSelectedInput(with: []) { return true }
        // PSReadLine undoes on Ctrl+Z itself. Claude Code's undo is Ctrl+_.
        if key == 0x5A && ctrl && !shift && !alt && agentInputActive {
            input([0x1F])
            return true
        }

        let mod = 1 + (shift ? 1 : 0) + (alt ? 2 : 0) + (ctrl ? 4 : 0)
        func csi(_ s: String) -> String { "\u{1b}[" + s }
        func letter(_ c: String) -> String {
            if mod > 1 { return csi("1;\(mod)\(c)") }
            return terminal.appCursorKeys ? "\u{1b}O" + c : csi(c)
        }
        func tilde(_ n: Int) -> String { mod > 1 ? csi("\(n);\(mod)~") : csi("\(n)~") }
        func function(_ c: String) -> String { mod > 1 ? csi("1;\(mod)\(c)") : "\u{1b}O" + c }

        var out: String?
        switch key {
        case Win.VK_UP: out = letter("A")
        case Win.VK_DOWN: out = letter("B")
        case Win.VK_RIGHT: out = letter("C")
        case Win.VK_LEFT: out = letter("D")
        case Win.VK_HOME: out = letter("H")
        case Win.VK_END: out = letter("F")
        case Win.VK_INSERT: out = tilde(2)
        case Win.VK_DELETE: out = tilde(3)
        case Win.VK_PRIOR: out = tilde(5)
        case Win.VK_NEXT: out = tilde(6)
        case Win.VK_BACK: out = alt ? "\u{1b}\u{7f}" : (ctrl ? "\u{08}" : "\u{7f}")
        case Win.VK_RETURN: out = alt ? "\u{1b}\r" : "\r"
        case Win.VK_ESCAPE: out = "\u{1b}"
        case Win.VK_TAB:
            if ctrl { return false }
            out = shift ? csi("Z") : "\t"
        case Win.VK_SPACE:
            if ctrl { out = alt ? "\u{1b}\u{00}" : "\u{00}" }
        case Win.VK_F1...Win.VK_F12:
            let table = ["P", "Q", "R", "S", "15", "17", "18", "19", "20", "21", "23", "24"]
            let code = table[Int(key - Win.VK_F1)]
            out = key < Win.VK_F1 + 4 ? function(code) : tilde(Int(code)!)
        default: break
        }
        guard let out else { return false }
        input(Array(out.utf8))
        return true
    }

    /// A character from the keyboard or an input method, which arrives in UTF-16 units.
    func typed(_ unit: UInt16, meta: Bool) {
        if UTF16.isLeadSurrogate(unit) {
            pendingSurrogate = unit
            return
        }
        var units = [unit]
        if let lead = pendingSurrogate, UTF16.isTrailSurrogate(unit) { units = [lead, unit] }
        pendingSurrogate = nil
        // Anything that prints replaces a selection, space included. Control characters go through as usual.
        let prints = !meta && unit >= 0x20 && unit != 0x7F
        input((meta ? [0x1B] : []) + Array(String(decoding: units, as: UTF16.self).utf8), replacesSelection: prints)
    }

    /// Input from the person: shows the live screen again, as typing does in any terminal.
    private func input(_ bytes: [UInt8], replacesSelection: Bool = false) {
        scrollOffset = 0
        invalidate()
        if afterSelectionDeleted != nil {
            // Keys typed while a selection is still going follow it, in order.
            afterSelectionDeleted?.append(bytes)
        } else if !replacesSelection || !replaceSelectedInput(with: bytes) {
            selection = nil
            write(bytes)
        }
    }

    private func write(_ bytes: [UInt8]) {
        pty?.write(terminal.win32InputMode ? Win32Input.encode(bytes) : bytes)
    }

    private func send(_ text: String) { pty?.write(Array(text.utf8)) }

    // MARK: - Mouse

    private func cell(at lParam: LPARAM) -> (col: Int, row: Int) {
        let m = canvas.metrics
        let x = Float(Int16(truncatingIfNeeded: lParam & 0xFFFF)) - canvas.contentX
        let y = Float(Int16(truncatingIfNeeded: (lParam >> 16) & 0xFFFF)) - canvas.contentY
        return (min(max(Int(x / m.cellWidth + 0.5), 0), terminal.cols), min(max(Int(y / m.cellHeight), 0), terminal.rows - 1))
    }

    private func report(button: Int, col: Int, row: Int, press: Bool, motion: Bool = false) {
        let col = min(col, terminal.cols - 1)
        var code = button + (motion ? 32 : 0)
        if isDown(Win.VK_SHIFT) { code += 4 }
        if isDown(Win.VK_MENU) { code += 8 }
        if isDown(Win.VK_CONTROL) { code += 16 }
        if terminal.mouseSGR {
            send("\u{1b}[<\(code);\(col + 1);\(row + 1)\(press ? "M" : "m")")
        } else {
            if !press { code = 3 + (code & ~3 & ~64) }
            pty?.write([0x1B, 0x5B, 0x4D, UInt8(min(255, 32 + code)), UInt8(min(255, 33 + col)), UInt8(min(255, 33 + row))])
        }
    }

    func mouse(_ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) {
        let (col, row) = cell(at: lParam)
        if terminal.mouseMode != .none && !isDown(Win.VK_SHIFT) {
            reportMouse(message, wParam, col: col, row: row)
            return
        }
        let abs = terminal.screenTopAbs - scrollOffset + row
        switch message {
        case Win.WM_LBUTTONDOWN:
            selection = TerminalSelection(anchor: (abs, col), head: (abs, col))
            selecting = true
            SetCapture(hwnd)
        case Win.WM_LBUTTONDBLCLK:
            selection = wordSelection(line: abs, col: col)
            selecting = false
        case Win.WM_MOUSEMOVE:
            guard selecting else { return }
            selection?.head = (abs, col)
        case Win.WM_LBUTTONUP:
            guard selecting else { return }
            selecting = false
            ReleaseCapture()
            if selection?.isEmpty == true {
                selection = nil
                whenCursorSettled { [weak self] in self?.placeCursor(line: abs, col: col) }
            }
        case Win.WM_RBUTTONUP:
            // As in Windows consoles: right-click copies a selection, and pastes when there isn't one.
            if selection != nil {
                copySelection()
                selection = nil
            } else {
                paste()
            }
        default:
            return
        }
        invalidate()
    }

    private func reportMouse(_ message: UINT, _ wParam: WPARAM, col: Int, row: Int) {
        switch message {
        case Win.WM_LBUTTONDOWN, Win.WM_LBUTTONDBLCLK:
            SetCapture(hwnd)
            report(button: 0, col: col, row: row, press: true)
        case Win.WM_MBUTTONDOWN: report(button: 1, col: col, row: row, press: true)
        case Win.WM_RBUTTONDOWN: report(button: 2, col: col, row: row, press: true)
        case Win.WM_LBUTTONUP:
            ReleaseCapture()
            report(button: 0, col: col, row: row, press: false)
        case Win.WM_MBUTTONUP: report(button: 1, col: col, row: row, press: false)
        case Win.WM_RBUTTONUP: report(button: 2, col: col, row: row, press: false)
        case Win.WM_MOUSEMOVE:
            if let last = lastMouseCell, last == (col, row) { return }
            lastMouseCell = (col, row)
            let held = wParam & Win.MK_LBUTTON != 0 ? 0 : (wParam & Win.MK_MBUTTON != 0 ? 1 : (wParam & Win.MK_RBUTTON != 0 ? 2 : 3))
            guard terminal.mouseMode == .any || (terminal.mouseMode == .button && held != 3) else { return }
            report(button: held, col: col, row: row, press: true, motion: true)
        default: break
        }
    }

    func wheel(_ wParam: WPARAM, _ lParam: LPARAM) {
        let delta = Int(Int16(truncatingIfNeeded: (wParam >> 16) & 0xFFFF))
        guard delta != 0 else { return }
        let up = delta > 0
        let notches = max(abs(delta) / Win.WHEEL_DELTA, 1)
        if terminal.mouseMode != .none {
            // The wheel's position is in screen coordinates.
            var point = POINT(x: LONG(Int16(truncatingIfNeeded: lParam & 0xFFFF)), y: LONG(Int16(truncatingIfNeeded: (lParam >> 16) & 0xFFFF)))
            ScreenToClient(hwnd, &point)
            let (col, row) = cell(at: LPARAM(point.x & 0xFFFF) | (LPARAM(point.y & 0xFFFF) << 16))
            for _ in 0..<notches { report(button: up ? 64 : 65, col: col, row: row, press: true) }
        } else if terminal.usingAlt {
            if terminal.altScroll {
                let key = terminal.appCursorKeys ? (up ? "\u{1b}OA" : "\u{1b}OB") : (up ? "\u{1b}[A" : "\u{1b}[B")
                send(String(repeating: key, count: notches * 3))
            }
        } else {
            scroll(by: (up ? 1 : -1) * notches * 3)
        }
    }

    private func scroll(by lines: Int) {
        scrollOffset = min(max(scrollOffset + lines, 0), terminal.scrollback.count)
        invalidate()
    }

    // MARK: - Click to place the cursor

    /// Runs `work` once the screen has settled: the program has finished redrawing (Claude Code hides the cursor and
    /// parks it below its interface mid-frame) and has echoed arrow keys sent for an earlier click. Reading the cursor
    /// before that is what makes clicks miss. Waits a short while at most; a newer request replaces an older one.
    private func whenCursorSettled(timeout: TimeInterval = 0.3, _ work: @escaping () -> Void) {
        pendingClick = work
        pendingClickDeadline = Date().addingTimeInterval(timeout)
        runPendingClick()
        if pendingClick != nil { _ = SetTimer(hwnd, Self.clickTimer, 20, nil) }
    }

    func runPendingClick() {
        guard let work = pendingClick else { return }
        let settled = terminal.usingAlt || terminal.mouseMode != .none || (terminal.cursorVisible && !awaitingCursorEcho)
        guard settled || Date() >= pendingClickDeadline else { return }
        pendingClick = nil
        KillTimer(hwnd, Self.clickTimer)
        awaitingCursorEcho = false
        work()
    }

    private func sendArrows(_ count: Int, back: String, forward: String) {
        guard count != 0 else { return }
        let key = (terminal.appCursorKeys ? "\u{1b}O" : "\u{1b}[") + (count < 0 ? back : forward)
        send(String(repeating: key, count: abs(count)))
        awaitingCursorEcho = true
    }

    private func placeCursor(line: Int, col: Int) {
        guard !terminal.usingAlt, terminal.mouseMode == .none, let block = terminal.currentBlock else { return }
        let col = min(col, terminal.cols - 1)
        if block.state == .running {
            guard let rows = terminal.agentInputRows(block), rows.contains(line), rows.contains(terminal.cursorAbs) else { return }
            placeAgentCursor(row: line - rows.lowerBound, col: col, sentVertical: false)
        } else if let arrows = terminal.shellCursorArrows(block, line: line, col: col) {
            sendArrows(arrows, back: "D", forward: "C")
        }
    }

    /// Claude Code word-wraps its input box itself, so cells don't map linearly to text. Up or down to the row first
    /// (it moves by visual row), wait for the redraw, then fix the column.
    private func placeAgentCursor(row: Int, col: Int, sentVertical: Bool, giveUpAt: Date = .distantFuture, then: (() -> Void)? = nil) {
        guard let block = terminal.currentBlock, block.state == .running else { return }
        func again(_ deadline: Date) {
            awaitingCursorEcho = true
            whenCursorSettled { [weak self] in self?.placeAgentCursor(row: row, col: col, sentVertical: true, giveUpAt: deadline, then: then) }
        }
        guard let rows = terminal.agentInputRows(block), rows.contains(terminal.cursorAbs) else {
            // Caught partway through a redraw after our arrows, with the box not all there: look again in a moment.
            if sentVertical, Date() < giveUpAt { again(giveUpAt) }
            return
        }
        let target = rows.lowerBound + row
        guard rows.contains(target) else { return }
        if terminal.cursorAbs == target {
            sendArrows(terminal.agentCursorArrows(toCol: col), back: "D", forward: "C")
            then?()
        } else if sentVertical {
            // An unrelated redraw (the spinner, say) can land before the echo of our arrows: wait for the next one.
            if Date() < giveUpAt { again(giveUpAt) }
        } else {
            sendArrows(target - terminal.cursorAbs, back: "A", forward: "B")
            again(Date().addingTimeInterval(2))
        }
    }

    // MARK: - Replacing selected input

    /// Whether the cursor is in Claude Code's input box.
    private var agentInputActive: Bool {
        guard !terminal.usingAlt, let block = terminal.currentBlock, block.state == .running,
              let rows = terminal.agentInputRows(block) else { return false }
        return rows.contains(terminal.cursorAbs)
    }

    /// Replaces the selection, when it's in the line being typed, with `bytes` (nothing: just takes it out), as a text
    /// box does. False when it isn't, and nothing has happened.
    @discardableResult
    private func replaceSelectedInput(with bytes: [UInt8]) -> Bool {
        guard let chosen = selection, !chosen.isEmpty, !terminal.usingAlt, terminal.mouseMode == .none,
              let block = terminal.currentBlock else { return false }
        let (start, end) = chosen.trimmed(cols: terminal.cols)
        if let picked = terminal.shellSelection(block, start: start, end: end) {
            // Selecting with PSReadLine's own Shift+Left, rather than backspacing, makes it one step for Ctrl+Z.
            sendArrows(picked.to - picked.cursor, back: "D", forward: "C")
            send(String(repeating: "\u{1b}[1;2D", count: picked.to - picked.from))
            write(bytes.isEmpty ? [0x7F] : bytes)
        } else if !replaceAgentSelection(block, start: start, end: end, with: bytes) {
            return false
        }
        selection = nil
        invalidate()
        return true
    }

    /// Any number of rows of Claude Code's input box, the selection clipped to the box's text. Keys are worked through
    /// in order, so within a row arrows, backspaces and the replacement could all go at once. Across rows it re-wraps
    /// as characters go, and the breaks between rows may or may not be characters, so those are counted and topped up
    /// after it's redrawn. Anything typed meanwhile waits in `afterSelectionDeleted`.
    private func replaceAgentSelection(_ block: Block, start: (line: Int, col: Int), end: (line: Int, col: Int), with bytes: [UInt8]) -> Bool {
        guard block.state == .running, let rows = terminal.agentInputRows(block), rows.contains(terminal.cursorAbs),
              end.line >= rows.lowerBound, start.line <= rows.upperBound else { return false }
        let first = max(start.line, rows.lowerBound), last = min(end.line, rows.upperBound)
        let startCol = first == start.line ? max(2, min(start.col, terminal.agentTextEnd(first))) : 2
        let endCol = last == end.line ? min(end.col, terminal.agentTextEnd(last)) : terminal.agentTextEnd(last)
        guard last > first || endCol > startCol else { return false }
        let targetOffset = terminal.agentInputOffset(rows, line: first, col: startCol)
        let count = (first...last).reduce(0) { n, a in
            n + terminal.charCount(a, from: a == first ? startCol : 2, to: a == last ? endCol : terminal.agentTextEnd(a))
        }
        // In the queue from the start, so it goes even if the cursor can't be placed.
        afterSelectionDeleted = bytes.isEmpty ? [] : [bytes]
        selectionDeleteDeadline = Date().addingTimeInterval(6)
        placeAgentCursor(row: last - rows.lowerBound, col: endCol, sentVertical: false) { [weak self] in
            guard let self else { return }
            self.send(String(repeating: "\u{7f}", count: count))
            if first == last {
                self.endDeletingSelection()
            } else {
                // Only the breaks between rows can be left over, and only one each.
                self.backspaceAgentInput(toOffset: targetOffset, atMost: last - first)
            }
        }
        return true
    }

    /// Tops up what the first backspaces left: from the cursor back to `target` characters into the input, measured
    /// after each redraw, since it re-wraps as characters go (text before the target never moves). Measuring before
    /// the program has answered would count everything again, so it waits for the answer, and `atMost` caps the total
    /// so that a bad reading can't eat into the text before the selection.
    private func backspaceAgentInput(toOffset target: Int, atMost: Int) {
        whenOutputQuiet { [weak self] answered in
            guard let self, self.afterSelectionDeleted != nil else { return }
            guard answered, atMost > 0, let block = self.terminal.currentBlock, let rows = self.terminal.agentInputRows(block),
                  rows.contains(self.terminal.cursorAbs) else { return self.endDeletingSelection() }
            let left = self.terminal.agentInputOffset(rows, line: self.terminal.cursorAbs, col: self.terminal.cursorX) - target
            guard left > 0 else { return self.endDeletingSelection() }
            let count = min(left, atMost)
            self.send(String(repeating: "\u{7f}", count: count))
            self.backspaceAgentInput(toOffset: target, atMost: atMost - count)
        }
    }

    func endDeletingSelection() {
        guard let waiting = afterSelectionDeleted else { return }
        afterSelectionDeleted = nil
        selectionDeleteDeadline = nil
        waiting.forEach(write)
    }

    /// Runs `work` once the program has answered and stopped drawing for a moment, since it may take several frames to
    /// work through a burst of keys. `work` gets false if nothing arrived within two seconds.
    private func whenOutputQuiet(_ work: @escaping (Bool) -> Void) {
        quietWork = work
        quietStart = Date()
        _ = SetTimer(hwnd, Self.quietTimer, 20, nil)
    }

    func runQuietWork() {
        guard let work = quietWork else { return }
        let answered = lastOutputAt > quietStart && Date().timeIntervalSince(lastOutputAt) >= 0.15 && terminal.cursorVisible
        let late = Date().timeIntervalSince(quietStart) > 2
        guard answered || late else { return }
        quietWork = nil
        KillTimer(hwnd, Self.quietTimer)
        work(answered)
    }

    private func wordSelection(line: Int, col: Int) -> TerminalSelection? {
        guard let l = terminal.line(abs: line) else { return nil }
        func isWord(_ x: Int) -> Bool {
            let ch = l.cell(x).ch
            return ch != 0 && ch != 32
        }
        let col = min(col, terminal.cols - 1)
        guard isWord(col) else { return nil }
        var start = col, end = col
        while start > 0, isWord(start - 1) { start -= 1 }
        while end + 1 < terminal.cols, isWord(end + 1) { end += 1 }
        return TerminalSelection(anchor: (line, start), head: (line, end + 1))
    }

    // MARK: - Clipboard

    private func copySelection() {
        guard let selection, !selection.isEmpty else { return }
        // It stays selected, as in a text box: what's typed or pasted next can replace it.
        setClipboard(selection.text(in: terminal))
    }

    private func cutSelection() {
        guard let selection, !selection.isEmpty else { return }
        let text = selection.text(in: terminal)
        if replaceSelectedInput(with: []) { setClipboard(text) }
    }

    func setClipboard(_ text: String) {
        let units = wide(text)
        let bytes = units.count * MemoryLayout<UInt16>.size
        guard OpenClipboard(hwnd) else { return }
        defer { CloseClipboard() }
        EmptyClipboard()
        guard let memory = GlobalAlloc(Win.GMEM_MOVEABLE, SIZE_T(bytes)), let pointer = GlobalLock(memory) else { return }
        units.withUnsafeBytes { pointer.copyMemory(from: $0.baseAddress!, byteCount: bytes) }
        GlobalUnlock(memory)
        SetClipboardData(Win.CF_UNICODETEXT, memory)
    }

    private func clipboardText() -> String? {
        guard OpenClipboard(hwnd) else { return nil }
        defer { CloseClipboard() }
        guard let memory = GetClipboardData(Win.CF_UNICODETEXT), let pointer = GlobalLock(memory) else { return nil }
        defer { GlobalUnlock(memory) }
        return String(decodingCString: pointer.assumingMemoryBound(to: UInt16.self), as: UTF16.self)
    }

    func paste() {
        guard var text = clipboardText(), !text.isEmpty else { return }
        text = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        // Pasted text could otherwise end the bracketing early, and run what follows.
        text = text.replacingOccurrences(of: "\u{1b}", with: "")
        input(Array((terminal.bracketedPaste ? "\u{1b}[200~" + text + "\u{1b}[201~" : text).utf8), replacesSelection: true)
    }

    // MARK: - For tests

    func type(_ text: String) {
        for unit in text.utf16 { PostMessageW(hwnd, Win.WM_CHAR, WPARAM(unit), 0) }
    }

    /// A plain click on a cell of the screen.
    func click(col: Int, row: Int) {
        let m = canvas.metrics
        let x = Int(canvas.contentX + (Float(col) + 0.1) * m.cellWidth), y = Int(canvas.contentY + (Float(row) + 0.5) * m.cellHeight)
        let position = LPARAM(x & 0xFFFF) | (LPARAM(y & 0xFFFF) << 16)
        PostMessageW(hwnd, Win.WM_LBUTTONDOWN, 1, position)
        PostMessageW(hwnd, Win.WM_LBUTTONUP, 0, position)
    }

    /// Drags the mouse from one cell to another, selecting what's between.
    func drag(fromCol: Int, fromRow: Int, toCol: Int, toRow: Int) {
        let m = canvas.metrics
        func position(_ col: Int, _ row: Int) -> LPARAM {
            let x = Int(canvas.contentX + (Float(col) + 0.1) * m.cellWidth), y = Int(canvas.contentY + (Float(row) + 0.5) * m.cellHeight)
            return LPARAM(x & 0xFFFF) | (LPARAM(y & 0xFFFF) << 16)
        }
        PostMessageW(hwnd, Win.WM_LBUTTONDOWN, Win.MK_LBUTTON, position(fromCol, fromRow))
        PostMessageW(hwnd, Win.WM_MOUSEMOVE, Win.MK_LBUTTON, position(toCol, toRow))
        PostMessageW(hwnd, Win.WM_LBUTTONUP, 0, position(toCol, toRow))
    }

    func drag(fromCol: Int, toCol: Int, row: Int) { drag(fromCol: fromCol, fromRow: row, toCol: toCol, toRow: row) }

    func pressEscape() { PostMessageW(hwnd, Win.WM_KEYDOWN, WPARAM(Win.VK_ESCAPE), 0) }

    func pressBackspace() { PostMessageW(hwnd, Win.WM_KEYDOWN, WPARAM(Win.VK_BACK), 0) }

    func pressEnter() { PostMessageW(hwnd, Win.WM_KEYDOWN, WPARAM(Win.VK_RETURN), 0) }

    var isSettlingResize: Bool { lastResize != nil }

    /// The row the cursor is on, as far as what's on screen goes.
    var cursorRowText: String { terminal.screen[terminal.cursorY].text() }

    var visibleText: String {
        (terminal.scrollback.toArray().map { $0.text() } + terminal.screen.map { $0.text() }).joined(separator: "\n")
    }

    // MARK: - TerminalDelegate

    func terminalSend(_ bytes: [UInt8]) { pty?.write(bytes) }

    func terminalTitleChanged(_ t: Terminal) { host?.paneDetailsChanged(self) }

    func terminalCwdChanged(_ t: Terminal) { host?.paneDetailsChanged(self) }

    func terminalBell(_ t: Terminal) {
        if !(host?.isFocused ?? false) { FlashWindow(hwnd, true) }
    }

    func terminalBlockFinished(_ t: Terminal, block: Block) {}
    func terminalClipboardWrite(_ t: Terminal, text: String) { setClipboard(text) }
    func terminalScreenSwitched(_ t: Terminal) { scrollOffset = 0 }
    func terminalSyncEnded(_ t: Terminal) { invalidate() }

    func terminalColor(_ t: Terminal, code: Int) -> (UInt8, UInt8, UInt8) {
        switch code {
        case 10: return TerminalPalette.tuple(TerminalPalette.foreground)
        case 11: return TerminalPalette.tuple(TerminalPalette.background)
        case 12: return TerminalPalette.tuple(TerminalPalette.cursor)
        default: return TerminalPalette.tuple(TerminalPalette.indexed(min(max(code - 256, 0), 255)))
        }
    }

    func terminalPixelSize(_ t: Terminal) -> (width: Int, height: Int) {
        let m = canvas.metrics
        return (Int(Float(t.cols) * m.cellWidth), Int(Float(t.rows) * m.cellHeight))
    }
}
