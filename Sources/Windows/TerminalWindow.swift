import CCanvas
import Foundation
import WinSDK

/// Written out because several of the SDK's are macros Swift doesn't import.
private enum Win {
    static let WM_DESTROY: UINT = 0x0002, WM_SIZE: UINT = 0x0005, WM_SETFOCUS: UINT = 0x0007, WM_KILLFOCUS: UINT = 0x0008
    static let WM_PAINT: UINT = 0x000F, WM_CLOSE: UINT = 0x0010, WM_ERASEBKGND: UINT = 0x0014
    static let WM_KEYDOWN: UINT = 0x0100, WM_CHAR: UINT = 0x0102, WM_SYSKEYDOWN: UINT = 0x0104, WM_SYSCHAR: UINT = 0x0106
    static let WM_TIMER: UINT = 0x0113
    static let WM_MOUSEMOVE: UINT = 0x0200, WM_LBUTTONDOWN: UINT = 0x0201, WM_LBUTTONUP: UINT = 0x0202
    static let WM_LBUTTONDBLCLK: UINT = 0x0203, WM_RBUTTONDOWN: UINT = 0x0204, WM_RBUTTONUP: UINT = 0x0205
    static let WM_MBUTTONDOWN: UINT = 0x0207, WM_MBUTTONUP: UINT = 0x0208, WM_MOUSEWHEEL: UINT = 0x020A
    static let WM_DPICHANGED: UINT = 0x02E0
    /// More output has arrived.
    static let WM_OUTPUT: UINT = 0x8001
    /// The program ended.
    static let WM_EXITED: UINT = 0x8002

    static let VK_BACK: Int32 = 0x08, VK_TAB: Int32 = 0x09, VK_RETURN: Int32 = 0x0D, VK_SHIFT: Int32 = 0x10
    static let VK_CONTROL: Int32 = 0x11, VK_MENU: Int32 = 0x12, VK_ESCAPE: Int32 = 0x1B, VK_SPACE: Int32 = 0x20
    static let VK_PRIOR: Int32 = 0x21, VK_NEXT: Int32 = 0x22, VK_END: Int32 = 0x23, VK_HOME: Int32 = 0x24
    static let VK_LEFT: Int32 = 0x25, VK_UP: Int32 = 0x26, VK_RIGHT: Int32 = 0x27, VK_DOWN: Int32 = 0x28
    static let VK_INSERT: Int32 = 0x2D, VK_DELETE: Int32 = 0x2E, VK_F1: Int32 = 0x70, VK_F4: Int32 = 0x73, VK_F12: Int32 = 0x7B

    static let WS_OVERLAPPEDWINDOW: DWORD = 0x00CF_0000
    static let CW_USEDEFAULT: Int32 = Int32.min
    static let CS_DBLCLKS: UINT = 0x0008
    static let CF_UNICODETEXT: UINT = 13
    static let GMEM_MOVEABLE: UINT = 0x0002
    static let SW_SHOW: Int32 = 5, SW_SHOWNOACTIVATE: Int32 = 4
    static let SWP_NOZORDER: UINT = 0x0004, SWP_NOACTIVATE: UINT = 0x0010, SWP_NOMOVE: UINT = 0x0002
    static let MB_ICONERROR: UINT = 0x10
    static let MK_LBUTTON: WPARAM = 0x0001, MK_RBUTTON: WPARAM = 0x0002, MK_MBUTTON: WPARAM = 0x0010
    static let WHEEL_DELTA: Int = 120
    static let ibeamCursor = UnsafePointer<WCHAR>(bitPattern: 32513)
}

private func wide(_ s: String) -> [UInt16] { Array(s.utf16) + [0] }

/// A window with a terminal in it: one shell, for now. Everything runs on the thread with the message loop, including
/// the emulator: output is handed over from the reading thread, not fed from it.
final class TerminalWindow: TerminalDelegate {
    private static let className = wide("SolanumTerminalWindow")
    private static var windows: [HWND: TerminalWindow] = [:]
    /// Points at 96 DPI: 11pt, about what Windows Terminal starts with.
    private static let fontPoints: Float = 11

    private(set) var hwnd: HWND!
    private var canvas: Canvas!
    private(set) var terminal: Terminal!
    private var pty: ConPTY?
    private var selection: TerminalSelection?
    private var selecting = false
    private(set) var scrollOffset = 0
    private var focused = false
    private var pendingSurrogate: UInt16?
    private var lastDrawn = Date.distantPast
    private var lastMouseCell: (Int, Int)?
    private(set) var paints = 0
    private(set) var exitCode: Int32?

    /// Output waiting for the message loop.
    private let inboxLock = NSLock()
    private var inbox: [UInt8] = []
    private var outputPosted = false
    /// Above this the reading thread waits, which holds back a program printing faster than can be drawn.
    private static let inboxLimit = 8 * 1024 * 1024

    /// Called about ten times a second, for tests.
    var onTick: (() -> Void)?

    // MARK: - Starting

    private static func registerClass() -> Bool {
        var info = WNDCLASSEXW()
        info.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
        info.style = Win.CS_DBLCLKS
        info.lpfnWndProc = { hwnd, message, wParam, lParam in
            if let hwnd, let window = TerminalWindow.windows[hwnd] {
                return window.handle(message, wParam, lParam)
            }
            return DefWindowProcW(hwnd, message, wParam, lParam)
        }
        info.hInstance = GetModuleHandleW(nil)
        info.hCursor = LoadCursorW(nil, Win.ibeamCursor)
        return className.withUnsafeBufferPointer { name in
            info.lpszClassName = name.baseAddress
            return RegisterClassExW(&info) != 0
        }
    }

    /// Shows the window with a shell in it. Nil, with `failure` set, if it can't.
    init?(commandLine: String, cols: Int = 110, rows: Int = 32, activate: Bool = true, failure: inout String) {
        let created = Self.className.withUnsafeBufferPointer { name in
            wide("Solanum").withUnsafeBufferPointer { title in
                CreateWindowExW(0, name.baseAddress, title.baseAddress, Win.WS_OVERLAPPEDWINDOW, Win.CW_USEDEFAULT,
                                Win.CW_USEDEFAULT, 800, 600, nil, nil, GetModuleHandleW(nil), nil)
            }
        }
        guard let created else {
            failure = "Couldn't create the window (error \(GetLastError()))."
            return nil
        }
        hwnd = created
        sol_use_dark_titlebar(UnsafeMutableRawPointer(created))
        guard let canvas = Canvas(window: UnsafeMutableRawPointer(created), fontPixels: fontPixels()) else {
            failure = "Couldn't start Direct2D (HRESULT \(String(UInt32(bitPattern: Canvas.lastError), radix: 16)))."
            DestroyWindow(created)
            return nil
        }
        self.canvas = canvas
        terminal = Terminal(cols: cols, rows: rows, scrollbackLimit: 10000)
        terminal.delegate = self
        Self.windows[created] = self
        sizeWindow(toCols: cols, rows: rows)

        let home = ProcessInfo.processInfo.environment["USERPROFILE"]
        let environment = ["TERM": "xterm-256color", "COLORTERM": "truecolor", "TERM_PROGRAM": "Solanum"]
        guard let pty = ConPTY(commandLine: commandLine, extraEnvironment: environment, cwd: home,
                               cols: terminal.cols, rows: terminal.rows) else {
            failure = "Couldn't start the shell: \(commandLine.prefix(60))"
            Self.windows[created] = nil
            DestroyWindow(created)
            return nil
        }
        self.pty = pty
        let target = UInt(bitPattern: created)
        pty.onData = { [unowned self] bytes in receive(bytes, window: target) }
        pty.onExit = { code in
            PostMessageW(HWND(bitPattern: target), Win.WM_EXITED, WPARAM(UInt32(bitPattern: code)), 0)
        }
        ShowWindow(created, activate ? Win.SW_SHOW : Win.SW_SHOWNOACTIVATE)
        _ = SetTimer(created, 1, 100, nil)
    }

    private func fontPixels() -> Float {
        Self.fontPoints * Float(GetDpiForWindow(hwnd)) / 72
    }

    private func sizeWindow(toCols cols: Int, rows: Int) {
        let m = canvas.metrics
        var rect = RECT(left: 0, top: 0,
                        right: LONG(Float(cols) * m.cellWidth + TerminalRenderer.padding * 2 + 5),
                        bottom: LONG(Float(rows) * m.cellHeight + TerminalRenderer.padding * 2))
        _ = AdjustWindowRectExForDpi(&rect, Win.WS_OVERLAPPEDWINDOW, false, 0, GetDpiForWindow(hwnd))
        SetWindowPos(hwnd, nil, 0, 0, rect.right - rect.left, rect.bottom - rect.top,
                     Win.SWP_NOMOVE | Win.SWP_NOZORDER | Win.SWP_NOACTIVATE)
    }

    // MARK: - Output

    /// On the reading thread.
    private func receive(_ bytes: UnsafeBufferPointer<UInt8>, window: UInt) {
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
        if post { PostMessageW(HWND(bitPattern: window), Win.WM_OUTPUT, 0, 0) }
    }

    private func drainOutput() {
        inboxLock.lock()
        let bytes = inbox
        inbox = []
        outputPosted = false
        inboxLock.unlock()
        bytes.withUnsafeBufferPointer { terminal.feed($0) }
        if scrollOffset > 0 { scrollOffset += terminal.scrollbackPushes }
        terminal.scrollbackPushes = 0
        scrollOffset = min(scrollOffset, terminal.scrollback.count)
        guard !terminal.syncOutput else { return }
        invalidate()
        // Posted messages outrank painting, so a program printing nonstop would otherwise never be seen.
        if Date().timeIntervalSince(lastDrawn) > 1.0 / 30 { UpdateWindow(hwnd) }
    }

    private func invalidate() { InvalidateRect(hwnd, nil, false) }

    private func paint() {
        var ps = PAINTSTRUCT()
        _ = BeginPaint(hwnd, &ps)
        var renderer = TerminalRenderer(canvas: canvas, terminal: terminal)
        renderer.scrollOffset = scrollOffset
        renderer.selection = selection
        renderer.focused = focused
        renderer.draw()
        paints += 1
        lastDrawn = Date()
        EndPaint(hwnd, &ps)
    }

    // MARK: - Messages

    private func handle(_ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
        switch message {
        case Win.WM_PAINT:
            paint()
            return 0
        case Win.WM_ERASEBKGND:
            return 1
        case Win.WM_SIZE:
            resized(width: Int(lParam & 0xFFFF), height: Int((lParam >> 16) & 0xFFFF))
            return 0
        case Win.WM_DPICHANGED:
            canvas.setFontPixels(fontPixels())
            let suggested = UnsafePointer<RECT>(bitPattern: Int(lParam))!.pointee
            SetWindowPos(hwnd, nil, suggested.left, suggested.top, suggested.right - suggested.left,
                         suggested.bottom - suggested.top, Win.SWP_NOZORDER | Win.SWP_NOACTIVATE)
            return 0
        case Win.WM_SETFOCUS, Win.WM_KILLFOCUS:
            focused = message == Win.WM_SETFOCUS
            if terminal.focusEvents { send(focused ? "\u{1b}[I" : "\u{1b}[O") }
            invalidate()
            return 0
        case Win.WM_OUTPUT:
            drainOutput()
            return 0
        case Win.WM_EXITED:
            drainOutput()
            exitCode = Int32(truncatingIfNeeded: wParam)
            PostMessageW(hwnd, Win.WM_CLOSE, 0, 0)
            return 0
        case Win.WM_TIMER:
            onTick?()
            return 0
        case Win.WM_CHAR:
            typed(UInt16(truncatingIfNeeded: wParam), meta: false)
            return 0
        case Win.WM_SYSCHAR:
            typed(UInt16(truncatingIfNeeded: wParam), meta: true)
            return 0
        case Win.WM_LBUTTONDOWN, Win.WM_LBUTTONUP, Win.WM_LBUTTONDBLCLK, Win.WM_MOUSEMOVE,
             Win.WM_RBUTTONDOWN, Win.WM_RBUTTONUP, Win.WM_MBUTTONDOWN, Win.WM_MBUTTONUP:
            mouse(message, wParam, lParam)
            return 0
        case Win.WM_MOUSEWHEEL:
            wheel(wParam, lParam)
            return 0
        case Win.WM_DESTROY:
            pty?.terminate()
            Self.windows[hwnd] = nil
            if Self.windows.isEmpty { PostQuitMessage(0) }
            return 0
        default:
            return DefWindowProcW(hwnd, message, wParam, lParam)
        }
    }

    private func resized(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        sol_canvas_resize(canvas.raw, Int32(width), Int32(height))
        let grid = TerminalRenderer.grid(width: width, height: height, metrics: canvas.metrics)
        if grid.cols != terminal.cols || grid.rows != terminal.rows {
            terminal.resize(cols: grid.cols, rows: grid.rows)
            pty?.resize(cols: grid.cols, rows: grid.rows)
            scrollOffset = min(scrollOffset, terminal.scrollback.count)
        }
        invalidate()
    }

    // MARK: - Keyboard

    private func isDown(_ key: Int32) -> Bool { GetKeyState(key) < 0 }

    /// Keys that don't type a character. True if it's dealt with, and shouldn't go on to become one.
    fileprivate func keyDown(_ key: Int32) -> Bool {
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
    private func typed(_ unit: UInt16, meta: Bool) {
        if UTF16.isLeadSurrogate(unit) {
            pendingSurrogate = unit
            return
        }
        var units = [unit]
        if let lead = pendingSurrogate, UTF16.isTrailSurrogate(unit) { units = [lead, unit] }
        pendingSurrogate = nil
        input((meta ? [0x1B] : []) + Array(String(decoding: units, as: UTF16.self).utf8))
    }

    /// Input from the person: shows the live screen again, as typing does in any terminal.
    private func input(_ bytes: [UInt8]) {
        selection = nil
        scrollOffset = 0
        pty?.write(bytes)
        invalidate()
    }

    private func send(_ text: String) { pty?.write(Array(text.utf8)) }

    /// Runs in the message loop, ahead of TranslateMessage.
    static func preprocess(_ message: inout MSG) -> Bool {
        guard message.message == Win.WM_KEYDOWN || message.message == Win.WM_SYSKEYDOWN,
              let hwnd = message.hwnd, let window = windows[hwnd] else { return false }
        return window.keyDown(Int32(truncatingIfNeeded: message.wParam))
    }

    // MARK: - Mouse

    private func cell(at lParam: LPARAM) -> (col: Int, row: Int) {
        let m = canvas.metrics
        let x = Float(Int16(truncatingIfNeeded: lParam & 0xFFFF)) - TerminalRenderer.padding
        let y = Float(Int16(truncatingIfNeeded: (lParam >> 16) & 0xFFFF)) - TerminalRenderer.padding
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

    private func mouse(_ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) {
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
            if selection?.isEmpty == true { selection = nil }
        case Win.WM_RBUTTONUP:
            // As in Windows consoles: right-click copies a selection, and pastes when there isn't one.
            if selection != nil { copySelection() } else { paste() }
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

    private func wheel(_ wParam: WPARAM, _ lParam: LPARAM) {
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
        setClipboard(selection.text(in: terminal))
        self.selection = nil
        invalidate()
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
        input(Array((terminal.bracketedPaste ? "\u{1b}[200~" + text + "\u{1b}[201~" : text).utf8))
    }

    // MARK: - For tests

    func type(_ text: String) {
        for unit in text.utf16 { PostMessageW(hwnd, Win.WM_CHAR, WPARAM(unit), 0) }
    }

    func pressEnter() { PostMessageW(hwnd, Win.WM_KEYDOWN, WPARAM(Win.VK_RETURN), 0) }

    func resizeWindow(toCols cols: Int, rows: Int) { sizeWindow(toCols: cols, rows: rows) }

    func close() { PostMessageW(hwnd, Win.WM_CLOSE, 0, 0) }

    var visibleText: String {
        (terminal.scrollback.toArray().map { $0.text() } + terminal.screen.map { $0.text() }).joined(separator: "\n")
    }

    // MARK: - TerminalDelegate

    func terminalSend(_ bytes: [UInt8]) { pty?.write(bytes) }

    func terminalTitleChanged(_ t: Terminal) {
        let title = t.title.map { "\($0) — Solanum" } ?? "Solanum"
        _ = wide(title).withUnsafeBufferPointer { SetWindowTextW(hwnd, $0.baseAddress) }
    }

    func terminalCwdChanged(_ t: Terminal) {}

    func terminalBell(_ t: Terminal) {
        if !focused { FlashWindow(hwnd, true) }
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

    // MARK: - The app

    static func runLoop() {
        var message = MSG()
        while GetMessageW(&message, nil, 0, 0) {
            if preprocess(&message) { continue }
            TranslateMessage(&message)
            DispatchMessageW(&message)
        }
    }

    static func prepare() -> Bool {
        sol_enable_dpi_awareness()
        return registerClass()
    }

    /// The app itself: one window with the default shell, until it's closed.
    static func runApp() -> Int32 {
        var failure = "Couldn't register the window class."
        var window: TerminalWindow?
        if prepare() { window = TerminalWindow(commandLine: PowerShellIntegration.commandLine(), failure: &failure) }
        guard window != nil else {
            _ = wide(failure).withUnsafeBufferPointer { text in
                wide("Solanum").withUnsafeBufferPointer { title in
                    MessageBoxW(nil, text.baseAddress, title.baseAddress, Win.MB_ICONERROR)
                }
            }
            return 1
        }
        runLoop()
        return 0
    }
}
