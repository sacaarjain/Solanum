import CCanvas
import Foundation
import WinSDK

/// A window: a tab bar drawn in the title bar's place, one pane per tab, and a status bar. The real title bar is gone, but
/// the window keeps its frame, so it still resizes, snaps and has a shadow. Reporting the maximize button to Windows as
/// such is what brings up Snap Layouts when the pointer rests on it.
final class TerminalWindow {
    private static let className = wide("SolanumTerminalWindow")
    private static var windows: [HWND: TerminalWindow] = [:]
    /// Points at 96 DPI: 11pt, about what Windows Terminal starts with.
    private static let fontPoints: Float = 11

    private(set) var hwnd: HWND!
    private(set) var canvas: Canvas!
    private(set) var panes: [TerminalPane] = []
    private(set) var activeIndex = 0
    private(set) var isFocused = false
    private let commandLine: String
    private var hovered: WindowPart?
    private var pressed: WindowPart?
    private var tracking = false
    /// A press that began on the terminal, whose drag and release belong to it wherever they end up.
    private var terminalHasMouse = false
    private var clientWidth = 0, clientHeight = 0
    private var tabScroll: Float = 0
    private var lastDrawn = Date.distantPast
    private(set) var paints = 0

    var activePane: TerminalPane { panes[activeIndex] }

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
        info.hCursor = LoadCursorW(nil, Win.arrowCursor)
        info.hIcon = LoadIconW(GetModuleHandleW(nil), Win.appIcon)
        return className.withUnsafeBufferPointer { name in
            info.lpszClassName = name.baseAddress
            return RegisterClassExW(&info) != 0
        }
    }

    /// Shows the window with a shell in it. Nil, with `failure` set, if it can't.
    init?(commandLine: String, cols: Int = 110, rows: Int = 32, activate: Bool = true, failure: inout String) {
        self.commandLine = commandLine
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
        canvas.padding = scaledPadding()
        Self.windows[created] = self
        sizeWindow(toCols: cols, rows: rows)
        // Takes the title bar's place out of the frame, now that it's listening.
        SetWindowPos(created, nil, 0, 0, 0, 0, Win.SWP_NOMOVE | Win.SWP_NOSIZE | Win.SWP_NOZORDER | Win.SWP_NOACTIVATE | Win.SWP_FRAMECHANGED)
        guard addPane() else {
            failure = "Couldn't start the shell: \(commandLine.prefix(60))"
            Self.windows[created] = nil
            DestroyWindow(created)
            return nil
        }
        ShowWindow(created, activate ? Win.SW_SHOW : Win.SW_SHOWNOACTIVATE)
        _ = SetTimer(created, 1, 100, nil)
    }

    private var dpi: Float { Float(GetDpiForWindow(hwnd)) }
    private var scale: Float { dpi / 96 }
    private func fontPixels() -> Float { Self.fontPoints * dpi / 72 }
    private func scaledPadding() -> Float { (6 * scale).rounded() }

    private var layout: WindowLayout {
        WindowLayout(width: Float(clientWidth), height: Float(clientHeight), scale: scale, tabCount: panes.count, tabScroll: tabScroll)
    }

    private func sizeWindow(toCols cols: Int, rows: Int) {
        let m = canvas.metrics, bars = WindowLayout(width: 0, height: 0, scale: scale, tabCount: 0)
        var rect = RECT(left: 0, top: 0,
                        right: LONG(Float(cols) * m.cellWidth + canvas.padding * 2 + 5),
                        bottom: LONG(Float(rows) * m.cellHeight + canvas.padding * 2 + bars.tabBarHeight + bars.statusBarHeight))
        _ = AdjustWindowRectExForDpi(&rect, Win.WS_OVERLAPPEDWINDOW, false, 0, GetDpiForWindow(hwnd))
        // The frame's top edge isn't added to the client area's height here: the title bar it stands for is gone.
        SetWindowPos(hwnd, nil, 0, 0, rect.right - rect.left, rect.bottom, Win.SWP_NOMOVE | Win.SWP_NOZORDER | Win.SWP_NOACTIVATE)
    }

    // MARK: - Tabs

    private func gridSize() -> (cols: Int, rows: Int) {
        TerminalRenderer.grid(width: clientWidth, height: clientHeight, canvas: canvas)
    }

    @discardableResult
    private func addPane(at index: Int? = nil, cwd: String? = nil, restoring text: String? = nil) -> Bool {
        let grid = clientWidth > 0 ? gridSize() : (cols: 110, rows: 32)
        guard let pane = TerminalPane(host: self, commandLine: commandLine, cols: grid.cols, rows: grid.rows, cwd: cwd, restoring: text) else { return false }
        if panes.indices.contains(activeIndex) { panes[activeIndex].setFocused(false) }
        let at = min(index ?? panes.count, panes.count)
        panes.insert(pane, at: at)
        activate(at)
        return true
    }

    /// What's needed to bring a closed tab back, most recent last.
    private struct ClosedTab {
        let index: Int, folder: String?, text: String
    }
    private var closedTabs: [ClosedTab] = []

    /// The last tab closed, in its place and folder, with what it showed in its scrollback.
    func reopenClosedTab() {
        guard let closed = closedTabs.popLast() else { return }
        addPane(at: closed.index, cwd: closed.folder, restoring: closed.text)
    }

    func newTab() { addPane() }

    func selectTab(_ i: Int) {
        guard panes.indices.contains(i), i != activeIndex else { return }
        activate(i)
    }

    private func activate(_ i: Int) {
        if panes.indices.contains(activeIndex) { panes[activeIndex].setFocused(false) }
        activeIndex = i
        panes[i].setFocused(isFocused)
        settleTabScroll()
        detailsChanged()
    }

    /// Stops the tab's shell. The tab goes when it has ended (see `paneExited`).
    func closeTab(_ i: Int) {
        guard panes.indices.contains(i) else { return }
        let terminal = panes[i].terminal
        closedTabs.append(ClosedTab(index: i, folder: terminal.cwd, text: terminal.restorableText(maxLines: 5000)))
        if closedTabs.count > 25 { closedTabs.removeFirst() }
        panes[i].terminate()
    }

    private func paneExited(id: UInt) {
        guard let i = panes.firstIndex(where: { $0.id == id }) else { return }
        panes[i].drainOutput()
        let wasActive = i == activeIndex
        panes.remove(at: i)
        guard !panes.isEmpty else {
            PostMessageW(hwnd, Win.WM_CLOSE, 0, 0)
            return
        }
        if i < activeIndex || activeIndex >= panes.count { activeIndex = max(activeIndex - 1, 0) }
        if wasActive { panes[activeIndex].setFocused(isFocused) }
        hovered = nil
        settleTabScroll()
        detailsChanged()
    }

    /// A tab's title or folder has changed.
    func paneDetailsChanged(_ pane: TerminalPane) { detailsChanged() }

    private func detailsChanged() {
        if !panes.isEmpty {
            _ = wide(activePane.tabTitle + " — Solanum").withUnsafeBufferPointer { SetWindowTextW(hwnd, $0.baseAddress) }
        }
        invalidate()
    }

    /// What a pane shows has changed. Only the one on screen needs drawing.
    func paneChanged(_ pane: TerminalPane) {
        guard panes.indices.contains(activeIndex), pane === activePane else { return }
        invalidate()
        // Posted messages outrank painting, so a program printing nonstop would otherwise never be seen.
        if Date().timeIntervalSince(lastDrawn) > 1.0 / 30 { UpdateWindow(hwnd) }
    }

    private func invalidate() { InvalidateRect(hwnd, nil, false) }

    /// Keeps the tabs' scroll in range and, unless the person's own scrolling is what moved them, the active tab in view.
    private func settleTabScroll(showingActive: Bool = true) {
        tabScroll = min(max(tabScroll, 0), layout.maxTabScroll)
        if showingActive && panes.indices.contains(activeIndex) { tabScroll = layout.scroll(showing: activeIndex) }
    }

    private func scrollTabs(by delta: Float) {
        tabScroll += delta
        settleTabScroll(showingActive: false)
        invalidate()
    }

    // MARK: - Drawing

    private func chrome(on target: Canvas, layout: WindowLayout) -> WindowChrome {
        var chrome = WindowChrome(canvas: target, layout: layout, tabs: panes.map(\.tabTitle), activeTab: activeIndex)
        chrome.hovered = hovered
        chrome.pressed = pressed
        chrome.maximized = IsZoomed(hwnd)
        chrome.focused = isFocused
        chrome.folder = panes.isEmpty ? nil : activePane.terminal.cwd
        chrome.home = ProcessInfo.processInfo.environment["USERPROFILE"]
        return chrome
    }

    private func paint() {
        var ps = PAINTSTRUCT()
        _ = BeginPaint(hwnd, &ps)
        defer { EndPaint(hwnd, &ps) }
        guard !panes.isEmpty, sol_canvas_begin(canvas.raw, TerminalPalette.background) >= 0 else { return }
        chrome(on: canvas, layout: layout).draw()
        activePane.draw()
        _ = sol_canvas_end(canvas.raw)
        paints += 1
        lastDrawn = Date()
    }

    /// What the window shows, to a PNG. For tests.
    func saveSnapshot(to path: String) -> Bool {
        guard let bitmap = Canvas(width: clientWidth, height: clientHeight, fontPixels: fontPixels()) else { return false }
        bitmap.padding = canvas.padding
        bitmap.terminalArea = canvas.terminalArea
        guard sol_canvas_begin(bitmap.raw, TerminalPalette.background) >= 0 else { return false }
        chrome(on: bitmap, layout: layout).draw()
        var renderer = TerminalRenderer(canvas: bitmap, terminal: activePane.terminal)
        renderer.scrollOffset = activePane.scrollOffset
        renderer.drawContents()
        guard sol_canvas_end(bitmap.raw) >= 0 else { return false }
        return bitmap.savePNG(to: path)
    }

    // MARK: - Messages

    private func clientPoint(_ lParam: LPARAM) -> (x: Float, y: Float) {
        (Float(Int16(truncatingIfNeeded: lParam & 0xFFFF)), Float(Int16(truncatingIfNeeded: (lParam >> 16) & 0xFFFF)))
    }

    private func screenPoint(_ lParam: LPARAM) -> (x: Float, y: Float) {
        var point = POINT(x: LONG(Int16(truncatingIfNeeded: lParam & 0xFFFF)), y: LONG(Int16(truncatingIfNeeded: (lParam >> 16) & 0xFFFF)))
        ScreenToClient(hwnd, &point)
        return (Float(point.x), Float(point.y))
    }

    private func handle(_ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
        switch message {
        case Win.WM_PAINT:
            paint()
            return 0
        case Win.WM_ERASEBKGND:
            return 1
        case Win.WM_NCCALCSIZE:
            return wParam != 0 ? calculateFrame(wParam, lParam) : DefWindowProcW(hwnd, message, wParam, lParam)
        case Win.WM_NCHITTEST:
            return hitTest(wParam, lParam)
        case Win.WM_NCMOUSEMOVE:
            let (x, y) = screenPoint(lParam)
            setHovered(layout.part(atX: x, y: y), nonClient: true)
            return DefWindowProcW(hwnd, message, wParam, lParam)
        case Win.WM_NCMOUSELEAVE, Win.WM_MOUSELEAVE:
            tracking = false
            setHovered(nil, nonClient: false)
            return 0
        case Win.WM_NCLBUTTONDOWN:
            let (x, y) = screenPoint(lParam)
            let part = layout.part(atX: x, y: y)
            if part == .minimize || part == .maximize || part == .close {
                pressed = part
                invalidate()
                return 0
            }
            return DefWindowProcW(hwnd, message, wParam, lParam)
        case Win.WM_NCLBUTTONUP:
            let (x, y) = screenPoint(lParam)
            let part = layout.part(atX: x, y: y), was = pressed
            pressed = nil
            invalidate()
            if let was, part == was { pressCaptionButton(part) }
            return was == nil ? DefWindowProcW(hwnd, message, wParam, lParam) : 0
        case Win.WM_SETCURSOR:
            return setCursor(wParam, lParam)
        case Win.WM_SIZE:
            resized(width: Int(lParam & 0xFFFF), height: Int((lParam >> 16) & 0xFFFF))
            return 0
        case Win.WM_DPICHANGED:
            canvas.setFontPixels(fontPixels())
            canvas.padding = scaledPadding()
            let suggested = UnsafePointer<RECT>(bitPattern: Int(lParam))!.pointee
            SetWindowPos(hwnd, nil, suggested.left, suggested.top, suggested.right - suggested.left,
                         suggested.bottom - suggested.top, Win.SWP_NOZORDER | Win.SWP_NOACTIVATE)
            return 0
        case Win.WM_SETFOCUS, Win.WM_KILLFOCUS:
            isFocused = message == Win.WM_SETFOCUS
            if !panes.isEmpty { activePane.setFocused(isFocused) }
            invalidate()
            return 0
        case Win.WM_OUTPUT:
            panes.first { $0.id == UInt(wParam) }?.drainOutput()
            return 0
        case Win.WM_EXITED:
            paneExited(id: UInt(wParam))
            return 0
        case Win.WM_TIMER:
            if panes.isEmpty { return 0 }
            if wParam == WPARAM(TerminalPane.clickTimer) {
                activePane.runPendingClick()
            } else if wParam == WPARAM(TerminalPane.quietTimer) {
                activePane.runQuietWork()
            } else {
                panes.forEach { $0.tick() }
                onTick?()
            }
            return 0
        case Win.WM_CHAR:
            if !panes.isEmpty { activePane.typed(UInt16(truncatingIfNeeded: wParam), meta: false) }
            return 0
        case Win.WM_SYSCHAR:
            if !panes.isEmpty { activePane.typed(UInt16(truncatingIfNeeded: wParam), meta: true) }
            return 0
        case Win.WM_LBUTTONDOWN, Win.WM_LBUTTONUP, Win.WM_LBUTTONDBLCLK, Win.WM_MOUSEMOVE,
             Win.WM_RBUTTONDOWN, Win.WM_RBUTTONUP, Win.WM_MBUTTONDOWN, Win.WM_MBUTTONUP:
            clientMouse(message, wParam, lParam)
            return 0
        case Win.WM_MOUSEWHEEL:
            guard !panes.isEmpty else { return 0 }
            let (_, y) = screenPoint(lParam)
            if y < layout.tabBarHeight {
                let notches = Float(Int16(truncatingIfNeeded: (wParam >> 16) & 0xFFFF)) / Float(Win.WHEEL_DELTA)
                scrollTabs(by: -notches * layout.tabWidth)
            } else {
                activePane.wheel(wParam, lParam)
            }
            return 0
        case Win.WM_DESTROY:
            panes.forEach { $0.terminate() }
            Self.windows[hwnd] = nil
            if Self.windows.isEmpty { PostQuitMessage(0) }
            return 0
        default:
            return DefWindowProcW(hwnd, message, wParam, lParam)
        }
    }

    /// Keeps the frame's sides and bottom, which resize the window, and gives the top to the client area. A maximized
    /// window hangs off the screen by its frame, so there the top has to stay inside.
    private func calculateFrame(_ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
        guard let params = UnsafeMutablePointer<NCCALCSIZE_PARAMS>(bitPattern: Int(lParam)) else { return 0 }
        let top = params.pointee.rgrc.0.top
        let result = DefWindowProcW(hwnd, Win.WM_NCCALCSIZE, wParam, lParam)
        params.pointee.rgrc.0.top = top + (IsZoomed(hwnd) ? topFrame : 0)
        return result
    }

    private var topFrame: LONG {
        let dpi = GetDpiForWindow(hwnd)
        return LONG(GetSystemMetricsForDpi(Win.SM_CYSIZEFRAME, dpi) + GetSystemMetricsForDpi(Win.SM_CXPADDEDBORDER, dpi))
    }

    private func hitTest(_ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
        let frame = DefWindowProcW(hwnd, Win.WM_NCHITTEST, wParam, lParam)
        guard frame == Win.HTCLIENT || frame == Win.HTCAPTION else { return frame }
        let (x, y) = screenPoint(lParam)
        if !IsZoomed(hwnd) && y < 5 * scale { return Win.HTTOP }
        switch layout.part(atX: x, y: y) {
        case .titleBar: return Win.HTCAPTION
        case .minimize: return Win.HTMINBUTTON
        case .maximize: return Win.HTMAXBUTTON
        case .close: return Win.HTCLOSE
        default: return Win.HTCLIENT
        }
    }

    private func setCursor(_ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
        // Only over the client area: the frame's edges have their own resize cursors.
        guard LRESULT(lParam & 0xFFFF) == Win.HTCLIENT else { return DefWindowProcW(hwnd, Win.WM_SETCURSOR, wParam, lParam) }
        var point = POINT()
        GetCursorPos(&point)
        ScreenToClient(hwnd, &point)
        let onTerminal = layout.part(atX: Float(point.x), y: Float(point.y)) == .terminal
        SetCursor(LoadCursorW(nil, onTerminal ? Win.ibeamCursor : Win.arrowCursor))
        return 1
    }

    private func setHovered(_ part: WindowPart?, nonClient: Bool) {
        if part != nil && !tracking {
            var track = TRACKMOUSEEVENT(cbSize: DWORD(MemoryLayout<TRACKMOUSEEVENT>.size),
                                        dwFlags: Win.TME_LEAVE | (nonClient ? Win.TME_NONCLIENT : 0), hwndTrack: hwnd, dwHoverTime: 0)
            tracking = TrackMouseEvent(&track)
        }
        guard part != hovered else { return }
        hovered = part
        invalidate()
    }

    private func pressCaptionButton(_ part: WindowPart) {
        switch part {
        case .minimize: ShowWindow(hwnd, Win.SW_MINIMIZE)
        case .maximize: ShowWindow(hwnd, IsZoomed(hwnd) ? Win.SW_RESTORE : Win.SW_MAXIMIZE)
        case .close: PostMessageW(hwnd, Win.WM_CLOSE, 0, 0)
        default: break
        }
    }

    private func resized(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        clientWidth = width
        clientHeight = height
        sol_canvas_resize(canvas.raw, Int32(width), Int32(height))
        canvas.terminalArea = layout.terminal
        let grid = gridSize()
        panes.forEach { $0.resize(cols: grid.cols, rows: grid.rows) }
        settleTabScroll()
        invalidate()
    }

    /// The mouse over the client area: the bars take what's on them, and the terminal the rest.
    private func clientMouse(_ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) {
        guard !panes.isEmpty else { return }
        let (x, y) = clientPoint(lParam)
        let part = layout.part(atX: x, y: y)
        if message == Win.WM_LBUTTONDOWN || message == Win.WM_RBUTTONDOWN || message == Win.WM_MBUTTONDOWN || message == Win.WM_LBUTTONDBLCLK {
            terminalHasMouse = part == .terminal
        }
        if terminalHasMouse || (part == .terminal && message != Win.WM_MBUTTONUP && message != Win.WM_LBUTTONUP) {
            if message == Win.WM_MOUSEMOVE { setHovered(.terminal, nonClient: false) }
            activePane.mouse(message, wParam, lParam)
            if message == Win.WM_LBUTTONUP || message == Win.WM_RBUTTONUP || message == Win.WM_MBUTTONUP { terminalHasMouse = false }
            return
        }
        switch message {
        case Win.WM_MOUSEMOVE:
            setHovered(part, nonClient: false)
        case Win.WM_LBUTTONDOWN:
            if case .tab(let i) = part { selectTab(i) }
            if part == .scrollLeft { scrollTabs(by: -layout.tabViewport.width * 0.75) }
            if part == .scrollRight { scrollTabs(by: layout.tabViewport.width * 0.75) }
            pressed = part
        case Win.WM_LBUTTONUP:
            if part == pressed {
                switch part {
                case .tabClose(let i): closeTab(i)
                case .newTab: newTab()
                default: break
                }
            }
            pressed = nil
        case Win.WM_MBUTTONUP:
            if case .tab(let i) = part { closeTab(i) } else if case .tabClose(let i) = part { closeTab(i) }
        default: break
        }
        invalidate()
    }

    // MARK: - Keyboard

    private func isDown(_ key: Int32) -> Bool { GetKeyState(key) < 0 }

    /// The window's own keys, ahead of the pane's.
    private func keyDown(_ key: Int32) -> Bool {
        keyDown(key, shift: isDown(Win.VK_SHIFT), ctrl: isDown(Win.VK_CONTROL), alt: isDown(Win.VK_MENU))
    }

    func keyDown(_ key: Int32, shift: Bool, ctrl: Bool, alt: Bool) -> Bool {
        // Windows' Ctrl stands in for the Mac's Command, and Shift is Shift: keys the app claims are the app's, whatever's
        // running (see WINDOWS.md).
        if ctrl && !alt {
            switch key {
            case 0x54:
                if shift { reopenClosedTab() } else { newTab() }
                return true
            case 0x57:
                closeTab(activeIndex)
                return true
            default: break
            }
        }
        // Ctrl+1 to 9 pick a tab, with or without Shift. Shells and programs have no use for them.
        if ctrl && !alt && (0x31...0x39).contains(key) {
            selectTab(Int(key) - 0x31)
            return true
        }
        if ctrl && !alt && key == Win.VK_TAB && panes.count > 1 {
            selectTab((activeIndex + (shift ? panes.count - 1 : 1)) % panes.count)
            return true
        }
        return activePane.keyDown(key, shift: shift, ctrl: ctrl, alt: alt)
    }

    /// Runs in the message loop, ahead of TranslateMessage. True if a key is dealt with, and shouldn't become a character.
    static func preprocess(_ message: inout MSG) -> Bool {
        guard message.message == Win.WM_KEYDOWN || message.message == Win.WM_SYSKEYDOWN,
              let hwnd = message.hwnd, let window = windows[hwnd], !window.panes.isEmpty else { return false }
        return window.keyDown(Int32(truncatingIfNeeded: message.wParam))
    }

    // MARK: - For tests

    func resizeWindow(toCols cols: Int, rows: Int) { sizeWindow(toCols: cols, rows: rows) }

    func close() { PostMessageW(hwnd, Win.WM_CLOSE, 0, 0) }

    /// Clicks a part of the tab bar, as the mouse would.
    func click(_ rect: UIRect) {
        let position = LPARAM(Int(rect.x + rect.width / 2) & 0xFFFF) | (LPARAM(Int(rect.y + rect.height / 2) & 0xFFFF) << 16)
        PostMessageW(hwnd, Win.WM_LBUTTONDOWN, 1, position)
        PostMessageW(hwnd, Win.WM_LBUTTONUP, 0, position)
    }

    var currentLayout: WindowLayout { layout }

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
