import CCanvas
import Foundation
import WinSDK

/// A window: a tab bar drawn in the title bar's place, one pane per tab, and a status bar. The real title bar is gone, but
/// the window keeps its frame, so it still resizes, snaps and has a shadow. Reporting the maximize button to Windows as
/// such is what brings up Snap Layouts when the pointer rests on it.
final class TerminalWindow {
    private static let className = wide("SolanumTerminalWindow")
    private static var windows: [HWND: TerminalWindow] = [:]

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
    private let left: FileSidebar
    private let right: FileSidebar
    private var draggingEdge: WindowPart?
    /// A file opened from a sidebar: hands it to its default app, until there's an editor. Tests look without opening.
    var onOpenFile: ((String) -> Void) = { path in
        _ = wide(path).withUnsafeBufferPointer { ShellExecuteW(nil, nil, $0.baseAddress, nil, nil, 1) }
    }
    private let runLock = NSLock()
    private var runQueue: [() -> Void] = []
    private var lastLook = Date.distantPast

    /// Tabs picked with Ctrl or Shift, by pane.
    private var pickedTabs: Set<UInt> = []
    /// A tab's or a group's name being typed in the tab bar.
    private enum NameTarget { case tab(UInt), group(TabGroup) }
    private var naming: (target: NameTarget, field: TextFieldState, placeholder: String)?
    private var menu: MenuModel?
    private var hoveredCrumb: Int?
    private var themeHovered = false
    /// A new tab's opening has already kept the old tab's sidebar place, so switching to it doesn't again.
    private var sidebarPlaceSaved = false
    /// A press on a tab, which may turn into dragging it.
    private var tabPress: (index: Int, grab: Float, startX: Float, dragging: Bool)?
    private var draggedX: Float = 0
    private var palettePendingSurrogate: UInt16?
    private var palette: PaletteModel?
    private var hoveredPaletteRow: Int?
    private var paletteRecents: [String] = TerminalWindow.loadPaletteRecents()
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
        let saved = Self.loadSidebarSettings()
        left = FileSidebar(visible: saved.leftVisible, width: saved.leftWidth)
        right = FileSidebar(visible: saved.rightVisible, width: saved.rightWidth)
        left.tree.showHidden = saved.showHidden
        right.tree.showHidden = saved.showHidden
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
        TerminalPalette.current = ThemeColors(AppSettings.shared.theme)
        TerminalPalette.boldIsBright = AppSettings.shared.boldIsBright
        applyFont(to: canvas)
        canvas.padding = scaledPadding()
        AppSettings.shared.onChange.append { [weak self] in self?.settingsChanged() }
        Self.windows[created] = self
        for sidebar in [left, right] {
            sidebar.tree.onNeedsListing = { [weak self, weak sidebar] folder in
                guard let sidebar else { return }
                self?.listInBackground(folder, for: sidebar)
            }
        }
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

    /// The right sidebar only exists in a split window, as on the Mac. Windows has no split screen yet.
    private let hasSplit = false
    private var rightIsShowing: Bool { hasSplit && right.isVisible }

    private var dpi: Float { Float(GetDpiForWindow(hwnd)) }
    private var scale: Float { dpi / 96 }
    private func fontPixels() -> Float { Float(AppSettings.shared.fontSize) * dpi / 72 }
    private func scaledPadding() -> Float { (Float(AppSettings.shared.padding) * scale).rounded() }

    private func applyFont(to target: Canvas) {
        target.setFont(family: AppSettings.shared.fontFamily, pixels: fontPixels(), lineHeight: Float(AppSettings.shared.lineHeight))
    }

    /// Settings have changed, here or in the file: everything that depends on them follows.
    private func settingsChanged() {
        let settings = AppSettings.shared
        TerminalPalette.current = ThemeColors(settings.theme)
        TerminalPalette.boldIsBright = settings.boldIsBright
        applyFont(to: canvas)
        canvas.padding = scaledPadding()
        panes.forEach { $0.terminal.setScrollbackLimit(settings.scrollback) }
        layoutChanged()
        detailsChanged()
    }

    private var layout: WindowLayout {
        WindowLayout(width: Float(clientWidth), height: Float(clientHeight), scale: scale, tabCount: panes.count, tabScroll: tabScroll,
                     chips: chipWidths(), hiddenTabs: hiddenTabs,
                     leftWidth: left.isVisible ? sidebarWidth(left) : 0, rightWidth: rightIsShowing ? sidebarWidth(right) : 0, showsRightToggle: hasSplit)
    }

    private func sizeWindow(toCols cols: Int, rows: Int) {
        let m = canvas.metrics, bars = WindowLayout(width: 0, height: 0, scale: scale, tabCount: 0)
        let sides = (left.isVisible ? sidebarWidth(left) : 0) + (rightIsShowing ? sidebarWidth(right) : 0)
        var rect = RECT(left: 0, top: 0,
                        right: LONG(Float(cols) * m.cellWidth + canvas.padding * 2 + 5 + sides),
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
    private func addPane(at index: Int? = nil, cwd: String? = nil, restoring text: String? = nil, place: SidebarPlace? = nil) -> Bool {
        let grid = clientWidth > 0 ? gridSize() : (cols: 110, rows: 32)
        guard let pane = TerminalPane(host: self, commandLine: commandLine, cols: grid.cols, rows: grid.rows, cwd: cwd, restoring: text) else { return false }
        if panes.indices.contains(activeIndex) {
            panes[activeIndex].setFocused(false)
            saveSidebarPlace(to: panes[activeIndex])
            sidebarPlaceSaved = true
        }
        pane.sidebarPlace = place
        let at = min(index ?? panes.count, panes.count)
        panes.insert(pane, at: at)
        activate(at)
        return true
    }

    /// What's needed to bring a closed tab back, most recent last.
    private struct ClosedTab {
        let index: Int, folder: String?, text: String
        let place: SidebarPlace?
    }
    private var closedTabs: [ClosedTab] = []

    /// The last tab closed, in its place and folder, with what it showed in its scrollback.
    func reopenClosedTab() {
        guard let closed = closedTabs.popLast() else { return }
        addPane(at: closed.index, cwd: closed.folder, restoring: closed.text, place: closed.place)
    }

    /// In the current tab's folder, unless Settings says the home folder.
    func newTab() {
        let here = AppSettings.shared.newTabFolder == "current" && !panes.isEmpty ? activePane.terminal.cwd : nil
        addPane(cwd: here)
    }

    func selectTab(_ i: Int) {
        guard panes.indices.contains(i), i != activeIndex else { return }
        activate(i)
    }

    private func activate(_ i: Int) {
        if panes.indices.contains(activeIndex) {
            panes[activeIndex].setFocused(false)
            if !sidebarPlaceSaved { saveSidebarPlace(to: panes[activeIndex]) }
        }
        sidebarPlaceSaved = false
        activeIndex = i
        restoreSidebarPlace(from: panes[i])
        panes[i].setFocused(isFocused && !sidebarHasFocus)
        settleTabScroll()
        detailsChanged()
    }

    /// Stops the tab's shell. The tab goes when it has ended (see `paneExited`).
    func closeTab(_ i: Int) {
        guard panes.indices.contains(i) else { return }
        let terminal = panes[i].terminal
        if i == activeIndex { saveSidebarPlace(to: panes[i]) }
        closedTabs.append(ClosedTab(index: i, folder: terminal.cwd, text: terminal.restorableText(maxLines: 5000), place: panes[i].sidebarPlace))
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
        if wasActive {
            panes[activeIndex].setFocused(isFocused && !sidebarHasFocus)
            restoreSidebarPlace(from: panes[activeIndex])
        }
        hovered = nil
        settleTabScroll()
        detailsChanged()
    }

    /// A tab's title or folder has changed.
    func paneDetailsChanged(_ pane: TerminalPane) { detailsChanged() }

    private func detailsChanged() {
        followTerminalFolder()
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
        chrome.hoveredCrumb = hoveredCrumb
        for (first, group) in groupStarts() {
            let members = panes.indices.filter { panes[$0].group === group }
            chrome.chips[first] = (group.chipLabel(count: members.count), group.color.rgb, members.last ?? first, group.collapsed)
        }
        chrome.picked = Set(panes.indices.filter { pickedTabs.contains(panes[$0].id) })
        if let naming {
            switch naming.target {
            case .tab(let id): if let i = panes.firstIndex(where: { $0.id == id }) { chrome.editingTab = (i, naming.field) }
            case .group(let g):
                if let first = panes.firstIndex(where: { $0.group === g }) { chrome.editingChip = (first, naming.field, naming.placeholder) }
            }
        }
        chrome.themeName = AppSettings.shared.themeName.uppercased()
        chrome.showsThemeIcon = AppSettings.shared.themeIcon
        chrome.themeHovered = themeHovered
        if let press = tabPress, press.dragging {
            chrome.draggedTab = press.index
            chrome.draggedX = draggedX
        }
        return chrome
    }

    /// When the cursor last showed fresh: typing or clicking restarts its blink, as in other terminals.
    private var blinkStart = Date()
    private var cursorShown = true

    func restartBlink() {
        blinkStart = Date()
        if !cursorShown { cursorShown = true; invalidate() }
    }

    private func updateBlink() {
        let blinking = AppSettings.shared.cursorBlink && isFocused && palette == nil && !sidebarHasFocus
        let shown = !blinking || Int(Date().timeIntervalSince(blinkStart) / 0.53) % 2 == 0
        if shown != cursorShown {
            cursorShown = shown
            invalidate()
        }
    }

    private var cursorStyleCode: Int {
        switch AppSettings.shared.cursorStyle {
        case "block": return 2
        case "underline": return 4
        default: return 6
        }
    }

    private func paint() {
        var ps = PAINTSTRUCT()
        _ = BeginPaint(hwnd, &ps)
        defer { EndPaint(hwnd, &ps) }
        guard !panes.isEmpty, sol_canvas_begin(canvas.raw, TerminalPalette.background) >= 0 else { return }
        chrome(on: canvas, layout: layout).draw()
        activePane.draw(cursorShown: cursorShown, style: cursorStyleCode)
        drawSidebars(on: canvas, layout: layout)
        drawPalette(on: canvas)
        if let menu { MenuView(canvas: canvas, menu: menu).draw() }
        _ = sol_canvas_end(canvas.raw)
        paints += 1
        lastDrawn = Date()
    }

    /// What the window shows, to a PNG. For tests.
    func saveSnapshot(to path: String) -> Bool {
        guard let bitmap = Canvas(width: clientWidth, height: clientHeight, fontPixels: fontPixels()) else { return false }
        applyFont(to: bitmap)
        bitmap.padding = canvas.padding
        bitmap.terminalArea = canvas.terminalArea
        guard sol_canvas_begin(bitmap.raw, TerminalPalette.background) >= 0 else { return false }
        chrome(on: bitmap, layout: layout).draw()
        var renderer = TerminalRenderer(canvas: bitmap, terminal: activePane.terminal)
        renderer.scrollOffset = activePane.scrollOffset
        renderer.drawContents()
        drawSidebars(on: bitmap, layout: layout)
        drawPalette(on: bitmap)
        if let menu { MenuView(canvas: bitmap, menu: menu).draw() }
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
            applyFont(to: canvas)
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
        case Win.WM_RUN:
            runLock.lock()
            let work = runQueue
            runQueue = []
            runLock.unlock()
            work.forEach { $0() }
            return 0
        case Win.WM_TIMER:
            if panes.isEmpty { return 0 }
            if wParam == WPARAM(TerminalPane.clickTimer) {
                activePane.runPendingClick()
            } else if wParam == WPARAM(TerminalPane.quietTimer) {
                activePane.runQuietWork()
            } else {
                panes.forEach { $0.tick() }
                lookForChanges()
                updateBlink()
                onTick?()
            }
            return 0
        case Win.WM_CHAR:
            if menu != nil {
                // A menu takes no text.
            } else if var current = naming {
                let unit = UInt16(truncatingIfNeeded: wParam)
                if unit >= 0x20, unit != 0x7F, let scalar = Unicode.Scalar(unit) {
                    current.field.insert(String(Character(scalar)))
                    naming = current
                    invalidate()
                }
            } else if palette != nil {
                paletteTyped(UInt16(truncatingIfNeeded: wParam))
            } else if !panes.isEmpty {
                // Typing is for the terminal, wherever the keyboard was.
                focusTerminal()
                activePane.typed(UInt16(truncatingIfNeeded: wParam), meta: false)
            }
            return 0
        case Win.WM_SYSCHAR:
            if palette == nil && !panes.isEmpty { activePane.typed(UInt16(truncatingIfNeeded: wParam), meta: true) }
            return 0
        case Win.WM_LBUTTONDOWN, Win.WM_LBUTTONUP, Win.WM_LBUTTONDBLCLK, Win.WM_MOUSEMOVE,
             Win.WM_RBUTTONDOWN, Win.WM_RBUTTONUP, Win.WM_MBUTTONDOWN, Win.WM_MBUTTONUP:
            clientMouse(message, wParam, lParam)
            return 0
        case Win.WM_MOUSEHWHEEL:
            // A touchpad's sideways swipe or a tilting wheel, which moves the tabs. It's in small steps on a touchpad, so
            // in proportion. Positive is to the right.
            guard !panes.isEmpty, screenPoint(lParam).y < layout.tabBarHeight else { return 0 }
            let swiped = Float(Int16(truncatingIfNeeded: (wParam >> 16) & 0xFFFF)) / Float(Win.WHEEL_DELTA)
            scrollTabs(by: swiped * layout.tabWidth)
            return 1
        case Win.WM_MOUSEWHEEL:
            guard !panes.isEmpty else { return 0 }
            let (_, y) = screenPoint(lParam)
            let (x, _) = screenPoint(lParam)
            let part = layout.part(atX: x, y: y)
            if let menu {
                menu.scrollBy(Int16(truncatingIfNeeded: (wParam >> 16) & 0xFFFF) > 0 ? -menu.rowHeight * 2 : menu.rowHeight * 2)
                invalidate()
            } else if let palette {
                palette.scroll(by: Int16(truncatingIfNeeded: (wParam >> 16) & 0xFFFF) > 0 ? -2 : 2)
                invalidate()
            } else if part == .leftSidebar || part == .rightSidebar {
                let sidebar = part == .leftSidebar ? left : right
                sidebar.tree.scroll(by: Int16(truncatingIfNeeded: (wParam >> 16) & 0xFFFF) > 0 ? -3 : 3, rowsShowing: sidebarLayout(sidebar).rowsShowing)
                invalidate()
            } else if y < layout.tabBarHeight {
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
        let part = layout.part(atX: Float(point.x), y: Float(point.y))
        let onEdge = palette == nil && (part == .leftEdge || part == .rightEdge) || draggingEdge != nil
        let onTerminal = palette == nil && part == .terminal
        // A pointing hand over the flower, which opens Settings, as on the Mac.
        let onFlower = palette == nil && menu == nil && part == .flower
        SetCursor(LoadCursorW(nil, onEdge ? Win.resizeCursor : onTerminal ? Win.ibeamCursor : onFlower ? Win.handCursor : Win.arrowCursor))
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
        if menu != nil {
            menuMouse(message, x: x, y: y)
            return
        }
        if palette != nil {
            paletteMouse(message, x: x, y: y)
            return
        }
        if tabDragMouse(message, x: x) { return }
        let part = layout.part(atX: x, y: y)
        if part == .statusBar && !terminalHasMouse && statusBarMouse(message, x: x, y: y) { return }
        if part != .statusBar && hoveredCrumb != nil {
            hoveredCrumb = nil
            invalidate()
        }
        if sidebarMouse(message, part: part, x: x, y: y) { return }
        if message == Win.WM_LBUTTONDOWN || message == Win.WM_RBUTTONDOWN || message == Win.WM_MBUTTONDOWN || message == Win.WM_LBUTTONDBLCLK {
            terminalHasMouse = part == .terminal
            if part == .terminal { focusTerminal() }
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
            if naming != nil { finishNaming(commit: true) }
            if case .tab(let i) = part {
                let ctrl = isDown(Win.VK_CONTROL), shift = isDown(Win.VK_SHIFT)
                if ctrl || shift {
                    pick(i, range: shift)
                } else {
                    clearPicked()
                    selectTab(i)
                    tabPress = (i, x - layout.tab(i).x, x, false)
                }
            }
            if part == .scrollLeft { scrollTabs(by: -layout.tabViewport.width * 0.75) }
            if part == .scrollRight { scrollTabs(by: layout.tabViewport.width * 0.75) }
            pressed = part
        case Win.WM_LBUTTONUP:
            if part == pressed {
                switch part {
                case .tabClose(let i): closeTab(i)
                case .newTab: newTab()
                case .chip(let first): if let g = panes[first].group { setCollapsed(g, !g.collapsed) }
                case .flower: SettingsWindow.shared.show()
                case .toggleLeft: toggleSidebar(left)
                case .toggleRight: toggleSidebar(right)
                default: break
                }
            }
            pressed = nil
        case Win.WM_MBUTTONUP:
            if case .tab(let i) = part { closeTab(i) } else if case .tabClose(let i) = part { closeTab(i) }
        case Win.WM_RBUTTONUP:
            if case .tab(let i) = part { showTabMenu(i, at: x, y: y + 4 * scale) }
            if case .tabClose(let i) = part { showTabMenu(i, at: x, y: y + 4 * scale) }
            if case .chip(let first) = part, let g = panes[first].group { showGroupMenu(g, at: x, y: y + 4 * scale) }
        default: break
        }
        invalidate()
    }

    // MARK: - Sidebars

    /// A sidebar's width: what it's been dragged to, up to what leaves the terminal some room.
    private func sidebarWidth(_ sidebar: FileSidebar) -> Float {
        let other = sidebar === left ? right : left
        let taken = other.isVisible ? other.width * scale : 0
        let room = max(Float(clientWidth) - taken - 300 * scale, 160 * scale)
        return min(sidebar.width * scale, room).rounded()
    }

    private func sidebarLayout(_ sidebar: FileSidebar) -> SidebarLayout {
        SidebarLayout(area: sidebar === left ? layout.leftSidebar : layout.rightSidebar, scale: scale)
    }

    private func drawSidebars(on target: Canvas, layout l: WindowLayout) {
        let home = ProcessInfo.processInfo.environment["USERPROFILE"]
        let folder = panes.isEmpty ? nil : activePane.terminal.cwd
        for (sidebar, area, edge) in [(left, l.leftSidebar, l.leftWidth - 1), (right, l.rightSidebar, l.width - l.rightWidth)] where area.width > 0 {
            SidebarView(canvas: target, sidebar: sidebar, layout: SidebarLayout(area: area, scale: scale), terminalFolder: folder, home: home).draw()
            sol_canvas_fill_rect(target.raw, edge, area.y, 1, area.height, TerminalPalette.foreground, 0.10)
        }
    }

    /// Runs `work` on the thread with the message loop. From any thread.
    private func runOnWindowThread(_ work: @escaping () -> Void) {
        runLock.lock()
        runQueue.append(work)
        runLock.unlock()
        PostMessageW(hwnd, Win.WM_RUN, 0, 0)
    }

    private func listInBackground(_ folder: String, for sidebar: FileSidebar) {
        Thread.detachNewThread { [weak self, weak sidebar] in
            let entries = FileSidebar.list(folder)
            self?.runOnWindowThread {
                guard let self, let sidebar else { return }
                if sidebar.tree.receive(folder, entries) { self.invalidate() }
            }
        }
    }

    /// Shows the terminal's folder in the sidebars that aren't pinned.
    private func followTerminalFolder() {
        guard !panes.isEmpty else { return }
        let folder = activePane.terminal.cwd ?? ProcessInfo.processInfo.environment["USERPROFILE"]
        guard let folder else { return }
        for sidebar in [left, right] where sidebar.isVisible && sidebar.pinned == nil {
            guard folder != sidebar.followed || sidebar.tree.root == nil else { continue }
            sidebar.followed = folder
            sidebar.tree.setRoot(folder)
        }
    }

    /// Files change behind the sidebars' backs, so they look again every few seconds while they're showing.
    private func lookForChanges() {
        guard Date().timeIntervalSince(lastLook) > 3 else { return }
        lastLook = Date()
        for sidebar in [left, right] where sidebar.isVisible { sidebar.tree.refresh() }
        AppSettings.shared.reloadIfChanged()
    }

    private func saveSidebarPlace(to pane: TerminalPane) {
        pane.sidebarPlace = SidebarPlace(tree: left.tree.place, pinned: left.pinned, followed: left.followed)
    }

    /// Puts the left sidebar where this tab had it. A tab that hasn't had it yet starts unpinned, following its terminal.
    private func restoreSidebarPlace(from pane: TerminalPane) {
        guard let place = pane.sidebarPlace else {
            left.pinned = nil
            left.followed = nil
            return
        }
        left.pinned = place.pinned
        left.followed = place.followed
        left.tree.restore(place.tree)
    }

    private func toggleSidebar(_ sidebar: FileSidebar) {
        sidebar.isVisible.toggle()
        if !sidebar.isVisible && sidebar.isFocused { focusTerminal() }
        layoutChanged()
        if sidebar.isVisible {
            if let pinned = sidebar.pinned { sidebar.tree.setRoot(pinned) } else { followTerminalFolder() }
            sidebar.tree.refresh()
        }
        saveSidebarSettings()
    }

    /// The bars have moved, so the terminal's area and grid have changed.
    private func layoutChanged() {
        guard clientWidth > 0 else { return }
        canvas.terminalArea = layout.terminal
        let grid = gridSize()
        panes.forEach { $0.resize(cols: grid.cols, rows: grid.rows) }
        settleTabScroll()
        invalidate()
    }

    private func togglePin(_ sidebar: FileSidebar) {
        if !sidebar.isVisible { toggleSidebar(sidebar) }
        sidebar.pinned = sidebar.pinned == nil ? sidebar.tree.root : nil
        // Unpinned, it goes back to wherever the terminal has got to.
        if sidebar.pinned == nil { sidebar.followed = nil }
        followTerminalFolder()
        invalidate()
    }

    private func toggleHidden(_ sidebar: FileSidebar) {
        let on = !sidebar.tree.showHidden
        left.tree.showHidden = on
        right.tree.showHidden = on
        saveSidebarSettings()
        invalidate()
    }

    private func goToParent(_ sidebar: FileSidebar) {
        // Not a pin: it stays here only until the terminal moves (see `followTerminalFolder`).
        guard let root = sidebar.tree.root, let up = WindowsPath.parent(root) else { return }
        sidebar.tree.setRoot(up)
        invalidate()
    }

    private var focusedSidebar: FileSidebar? { left.isFocused ? left : right.isFocused ? right : nil }
    private var sidebarHasFocus: Bool { focusedSidebar != nil }

    private func focus(_ sidebar: FileSidebar) {
        left.isFocused = sidebar === left
        right.isFocused = sidebar === right
        if !panes.isEmpty { activePane.setFocused(false) }
        invalidate()
    }

    private func focusTerminal() {
        guard sidebarHasFocus else { return }
        left.isFocused = false
        right.isFocused = false
        if !panes.isEmpty { activePane.setFocused(isFocused) }
        invalidate()
    }

    /// A folder opens or closes, and a file goes to its app on a double click or Enter.
    private func activate(_ entry: FileEntry, in sidebar: FileSidebar) {
        if entry.isDirectory { sidebar.tree.toggle(entry.path) } else { onOpenFile(entry.path) }
    }

    /// Takes the mouse when it's on a sidebar or its edge. Otherwise false, and it's someone else's.
    private func sidebarMouse(_ message: UINT, part: WindowPart, x: Float, y: Float) -> Bool {
        if let edge = draggingEdge {
            switch message {
            case Win.WM_MOUSEMOVE:
                let sidebar = edge == .leftEdge ? left : right
                let wanted = edge == .leftEdge ? x : Float(clientWidth) - x
                sidebar.width = min(max(wanted / scale, 160), 640)
                layoutChanged()
            case Win.WM_LBUTTONUP:
                draggingEdge = nil
                ReleaseCapture()
                saveSidebarSettings()
            default: break
            }
            return true
        }
        if message == Win.WM_LBUTTONDOWN && (part == .leftEdge || part == .rightEdge) {
            draggingEdge = part
            SetCapture(hwnd)
            return true
        }
        if terminalHasMouse { return false }
        guard part == .leftSidebar || part == .rightSidebar else {
            if left.hoveredRow != nil || right.hoveredRow != nil || left.hoveredButton != nil || right.hoveredButton != nil {
                [left, right].forEach { $0.hoveredRow = nil; $0.hoveredButton = nil }
                invalidate()
            }
            return false
        }
        let sidebar = part == .leftSidebar ? left : right
        let l = sidebarLayout(sidebar)
        let button = SidebarButton.allCases.first { l.button($0.rawValue).contains(x, y) }
        let visible = l.visibleRow(atY: y)
        let index = visible.map { $0 + sidebar.tree.scrollTop }
        let row = index.flatMap { sidebar.tree.rows.indices.contains($0) ? sidebar.tree.rows[$0] : nil }
        switch message {
        case Win.WM_MOUSEMOVE:
            setHovered(part, nonClient: false)
            if sidebar.hoveredRow != visible || sidebar.hoveredButton != button {
                sidebar.hoveredRow = row == nil ? nil : visible
                sidebar.hoveredButton = button
                invalidate()
            }
        case Win.WM_LBUTTONDOWN:
            // Its buttons leave the keyboard where it was, so typing carries on in the terminal.
            if let button { press(button, sidebar) }
            if let row {
                focus(sidebar)
                sidebar.tree.selection = row.entry.path
                if row.entry.isDirectory { sidebar.tree.toggle(row.entry.path) }
            }
            invalidate()
        case Win.WM_LBUTTONDBLCLK:
            guard let row else { break }
            sidebar.tree.selection = row.entry.path
            if row.entry.isDirectory {
                // Back to how it was before this double click's first click, then the terminal goes there, as on the Mac.
                sidebar.tree.toggle(row.entry.path)
                activePane.changeDirectory(to: row.entry.path)
                focusTerminal()
            } else {
                onOpenFile(row.entry.path)
            }
            invalidate()
        default: break
        }
        return true
    }

    private func press(_ button: SidebarButton, _ sidebar: FileSidebar) {
        switch button {
        case .pin: togglePin(sidebar)
        case .parent: goToParent(sidebar)
        case .refresh: sidebar.tree.refresh()
        case .more:
            let anchor = sidebarLayout(sidebar).button(SidebarButton.more.rawValue)
            openMenu([
                MenuItem(title: "Show Hidden Files", isChecked: sidebar.tree.showHidden) { [weak self, weak sidebar] in sidebar.map { self?.toggleHidden($0) } },
                MenuItem(title: "Collapse All") { [weak self, weak sidebar] in
                    sidebar?.tree.collapseAll()
                    self?.invalidate()
                },
            ], x: anchor.x, y: anchor.maxY + 2 * scale, above: false)
        }
    }

    // MARK: - Menus

    var isMenuOpen: Bool { menu != nil }
    var menuTitles: [String] { menu?.items.map(\.title) ?? [] }

    func menuRow(_ title: String) -> UIRect? {
        guard let menu, let i = menu.items.firstIndex(where: { $0.title == title }) else { return nil }
        return menu.rect(i)
    }

    private func openMenu(_ items: [MenuItem], x: Float, y: Float, above: Bool) {
        menu = MenuModel(items: items, anchorX: x, anchorY: y, above: above, width: MenuView.width(for: items, canvas: canvas, scale: scale),
                         window: UIRect(x: 0, y: 0, width: Float(clientWidth), height: Float(clientHeight)), scale: scale)
        invalidate()
    }

    private func closeMenu() {
        menu = nil
        invalidate()
    }

    private func menuMouse(_ message: UINT, x: Float, y: Float) {
        guard let menu else { return }
        let row = menu.item(atX: x, y: y)
        switch message {
        case Win.WM_MOUSEMOVE:
            if row != menu.highlighted {
                menu.highlight(row)
                invalidate()
            }
        case Win.WM_LBUTTONDOWN, Win.WM_RBUTTONDOWN:
            // Outside it dismisses. The click stops there.
            if !menu.frame.contains(x, y) { closeMenu() }
        case Win.WM_LBUTTONUP:
            if let row, menu.items[row].isEnabled {
                let run = menu.items[row].run
                closeMenu()
                run()
            }
        default: break
        }
    }

    private func menuKey(_ key: Int32) -> Bool {
        guard let menu else { return false }
        switch key {
        case Win.VK_ESCAPE: closeMenu()
        case Win.VK_UP: menu.moveHighlight(by: -1)
        case Win.VK_DOWN: menu.moveHighlight(by: 1)
        case Win.VK_RETURN:
            if let i = menu.highlighted {
                let run = menu.items[i].run
                closeMenu()
                run()
            }
        case Win.VK_F4: return false
        default: break
        }
        invalidate()
        return true
    }

    // MARK: - The folder in the status bar

    private func goTo(folder: String) {
        if activePane.atPrompt {
            activePane.changeDirectory(to: folder)
        } else {
            // What's running keeps its place, as on the Mac.
            addPane(cwd: folder)
        }
    }

    /// The folders in one of the path's parts, with what else there is to do with it.
    private func showCrumbMenu(_ crumb: (label: String, path: String, rect: UIRect, hit: UIRect), copyOnly: Bool) {
        let current = activePane.terminal.cwd
        let copy = MenuItem(title: "Copy Path") { [weak self] in self?.activePane.setClipboard(crumb.path) }
        guard !copyOnly else {
            openMenu([copy], x: crumb.rect.x, y: crumb.rect.y - 2 * scale, above: true)
            return
        }
        Thread.detachNewThread { [weak self] in
            let folders = (FileSidebar.list(crumb.path) ?? []).filter { $0.isDirectory && !$0.isHidden }
            let sorted = FileTree.sortedForDisplay(folders).prefix(400)
            self?.runOnWindowThread {
                guard let self else { return }
                var items = [copy, MenuItem.separator]
                if crumb.path.lowercased() != current?.lowercased() {
                    items.append(MenuItem(title: "Go to \(crumb.label)") { [weak self] in self?.goTo(folder: crumb.path) })
                    items.append(.separator)
                }
                for folder in sorted {
                    let onPath = current.map { $0.lowercased() == folder.path.lowercased() || $0.lowercased().hasPrefix(folder.path.lowercased() + "\\") } ?? false
                    items.append(MenuItem(title: folder.name, isChecked: onPath) { [weak self] in self?.goTo(folder: folder.path) })
                }
                if sorted.isEmpty { items.append(MenuItem(title: "No folders inside", isEnabled: false)) }
                self.openMenu(items, x: crumb.rect.x, y: crumb.rect.y - 2 * self.scale, above: true)
            }
        }
    }

    /// The status bar's folder parts under the pointer. True if it dealt with the mouse.
    private func statusBarMouse(_ message: UINT, x: Float, y: Float) -> Bool {
        let bar = chrome(on: canvas, layout: layout)
        let spots = bar.crumbSpots()
        let hit = spots.firstIndex { $0.hit.contains(x, y) }
        let onTheme = bar.themeSpot().contains(x, y)
        switch message {
        case Win.WM_MOUSEMOVE:
            if hit != hoveredCrumb || onTheme != themeHovered {
                hoveredCrumb = hit
                themeHovered = onTheme
                invalidate()
            }
            return false
        case Win.WM_LBUTTONUP where onTheme:
            showThemeMenu(above: bar.themeSpot())
            return true
        case Win.WM_LBUTTONUP, Win.WM_RBUTTONUP:
            guard let hit else { return false }
            showCrumbMenu(spots[hit], copyOnly: message == Win.WM_RBUTTONUP)
            return true
        default:
            return hit != nil
        }
    }

    /// The rectangle of a part of the path in the status bar, for clicking it.
    func crumbRect(_ label: String) -> UIRect? {
        chrome(on: canvas, layout: layout).crumbSpots().first { $0.label == label }?.rect
    }

    /// The folder icon at the start of the path.
    var folderIconRect: UIRect? {
        guard let first = chrome(on: canvas, layout: layout).crumbSpots().first else { return nil }
        return UIRect(x: first.hit.x + 2, y: first.hit.y, width: 8 * scale, height: first.hit.height)
    }

    // MARK: - Themes

    private func useTheme(_ name: String) { AppSettings.shared.set("theme", name) }

    /// Every theme, Solanum's first, with the current one checked.
    private func showThemeMenu(above spot: UIRect) {
        let settings = AppSettings.shared, current = settings.themeName
        func items(_ specs: [ThemeSpec]) -> [MenuItem] {
            specs.map { spec in MenuItem(title: spec.name, isChecked: spec.name == current) { [weak self] in self?.useTheme(spec.name) } }
        }
        var all = items([ThemeSpecs.solanumDefault] + ThemeSpecs.outerWilds)
        if !settings.customThemes.isEmpty { all += [.separator] + items(settings.customThemes) }
        all += [.separator] + items(ThemeSpecs.vsCode)
        let width = MenuView.width(for: all, canvas: canvas, scale: scale)
        openMenu(all, x: spot.maxX - width, y: spot.y - 2 * scale, above: true)
    }

    var themeSpotRect: UIRect { chrome(on: canvas, layout: layout).themeSpot() }

    // MARK: - Dragging tabs

    /// A press, move or release while a tab is held. True if it dealt with the mouse.
    private func tabDragMouse(_ message: UINT, x: Float) -> Bool {
        guard var press = tabPress else { return false }
        switch message {
        case Win.WM_MOUSEMOVE:
            if !press.dragging {
                guard abs(x - press.startX) > 4 * scale else { return true }
                press.dragging = true
                SetCapture(hwnd)
            }
            let l = layout, v = l.tabViewport
            draggedX = min(max(x - press.grab, v.x), max(v.maxX - l.tabWidth, v.x))
            // It trades places with a neighbor as it passes halfway over it, as on the Mac.
            var moved = true
            while moved {
                moved = false
                let floating = UIRect(x: draggedX, y: 0, width: l.tabWidth, height: 1)
                if press.index + 1 < panes.count, floating.maxX > l.tab(press.index + 1).x + l.tabWidth / 2 {
                    moveTab(from: press.index, to: press.index + 1)
                    press.index += 1
                    moved = true
                } else if press.index > 0, floating.x < l.tab(press.index - 1).x + l.tabWidth / 2 {
                    moveTab(from: press.index, to: press.index - 1)
                    press.index -= 1
                    moved = true
                }
            }
            tabPress = press
            invalidate()
            return true
        case Win.WM_LBUTTONUP:
            if press.dragging {
                ReleaseCapture()
                TabGroupOps.settle(panes[press.index], in: panes)
            }
            tabPress = nil
            invalidate()
            return press.dragging
        default:
            return false
        }
    }

    private func moveTab(from: Int, to: Int) {
        let active = panes[activeIndex]
        let pane = panes.remove(at: from)
        panes.insert(pane, at: to)
        activeIndex = panes.firstIndex { $0 === active } ?? activeIndex
    }

    /// Presses a tab and drags it to a position, as the mouse would.
    func dragTab(_ i: Int, toX x: Float) {
        let r = layout.tab(i), y = Int(r.midY)
        func at(_ px: Int) -> LPARAM { LPARAM(px & 0xFFFF) | (LPARAM(y & 0xFFFF) << 16) }
        PostMessageW(hwnd, Win.WM_LBUTTONDOWN, 1, at(Int(r.x + 20)))
        PostMessageW(hwnd, Win.WM_MOUSEMOVE, 1, at(Int(x)))
        PostMessageW(hwnd, Win.WM_LBUTTONUP, 0, at(Int(x)))
    }

    /// Keys while a sidebar has the focus. False hands the key on, and typing goes back to the terminal.
    private func sidebarKey(_ key: Int32, _ sidebar: FileSidebar, shift: Bool, ctrl: Bool, alt: Bool) -> Bool {
        let tree = sidebar.tree
        switch key {
        case Win.VK_UP: tree.moveSelection(by: -1)
        case Win.VK_DOWN: tree.moveSelection(by: 1)
        case Win.VK_PRIOR: tree.moveSelection(by: -max(sidebarLayout(sidebar).rowsShowing - 1, 1))
        case Win.VK_NEXT: tree.moveSelection(by: max(sidebarLayout(sidebar).rowsShowing - 1, 1))
        case Win.VK_RIGHT: tree.stepIn()
        case Win.VK_LEFT: tree.stepOut()
        case Win.VK_RETURN, Win.VK_SPACE:
            if let i = tree.selectedIndex { activate(tree.rows[i].entry, in: sidebar) }
        case Win.VK_ESCAPE:
            focusTerminal()
        default:
            focusTerminal()
            return false
        }
        tree.keepSelectionVisible(rowsShowing: sidebarLayout(sidebar).rowsShowing)
        invalidate()
        return true
    }

    // Sidebars' shape is kept between launches. Tests start with them hidden, and leave a person's settings alone.
    private struct SidebarSettings {
        var leftVisible = true, rightVisible = false, showHidden = false
        var leftWidth: Float = 240, rightWidth: Float = 240
    }

    private static var sidebarSettingsFile: URL? {
        guard !CommandLine.arguments.contains("--window-test"), let appData = ProcessInfo.processInfo.environment["APPDATA"] else { return nil }
        return URL(fileURLWithPath: appData).appendingPathComponent("Solanum").appendingPathComponent("sidebars.txt")
    }

    private static func loadSidebarSettings() -> SidebarSettings {
        guard !CommandLine.arguments.contains("--window-test") else { return SidebarSettings(leftVisible: false) }
        var settings = SidebarSettings()
        guard let file = sidebarSettingsFile, let text = try? String(contentsOf: file, encoding: .utf8) else { return settings }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "left": settings.leftVisible = parts[1] == "1"
            case "right": settings.rightVisible = parts[1] == "1"
            case "hidden": settings.showHidden = parts[1] == "1"
            case "leftWidth": settings.leftWidth = Float(parts[1]) ?? 240
            case "rightWidth": settings.rightWidth = Float(parts[1]) ?? 240
            default: break
            }
        }
        return settings
    }

    private func saveSidebarSettings() {
        guard let file = Self.sidebarSettingsFile else { return }
        let text = "left=\(left.isVisible ? 1 : 0)\nright=\(right.isVisible ? 1 : 0)\nhidden=\(left.tree.showHidden ? 1 : 0)\nleftWidth=\(left.width)\nrightWidth=\(right.width)\n"
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: file, atomically: true, encoding: .utf8)
    }

    // MARK: - Tab groups

    /// Each group by the index of its first tab.
    private func groupStarts() -> [(Int, TabGroup)] {
        panes.indices.compactMap { i in
            guard let g = panes[i].group, i == 0 || panes[i - 1].group !== g else { return nil }
            return (i, g)
        }
    }

    private var hiddenTabs: Set<Int> { Set(panes.indices.filter { panes[$0].group?.collapsed == true }) }

    /// How wide each chip is: its label, or a dot for a group with no name, or room for the name being typed.
    private func chipWidths() -> [Int: Float] {
        guard canvas != nil else { return [:] }
        var out: [Int: Float] = [:]
        func measure(_ text: String) -> Float {
            let units = Array(text.utf16)
            return sol_canvas_measure_label(canvas.raw, units, Int32(units.count), 11.5 * scale, 1)
        }
        for (first, g) in groupStarts() {
            if case .group(let named)? = naming?.target, named === g {
                let text = naming!.field.text.isEmpty ? naming!.placeholder : naming!.field.text
                out[first] = min(max(measure(text) + 26 * scale, 90 * scale), 200 * scale).rounded()
                continue
            }
            let label = g.chipLabel(count: panes.filter { $0.group === g }.count)
            out[first] = label.isEmpty ? (20 * scale).rounded() : min(measure(label) + 18 * scale, 160 * scale).rounded()
        }
        return out
    }

    private var pickedPanes: [TerminalPane] { panes.filter { pickedTabs.contains($0.id) } }

    private func clearPicked() {
        guard !pickedTabs.isEmpty else { return }
        pickedTabs = []
        invalidate()
    }

    /// Ctrl adds or takes out one tab; Shift picks everything between the active tab and this one.
    private func pick(_ i: Int, range: Bool) {
        if range {
            let a = min(activeIndex, i), b = max(activeIndex, i)
            pickedTabs = Set((a...b).filter { !hiddenTabs.contains($0) }.map { panes[$0].id })
        } else {
            if pickedTabs.isEmpty { pickedTabs.insert(activePane.id) }
            if pickedTabs.remove(panes[i].id) == nil { pickedTabs.insert(panes[i].id) }
        }
        invalidate()
    }

    private func reorder(_ change: (inout [TerminalPane]) -> Void) {
        let active = panes.isEmpty ? nil : activePane
        change(&panes)
        if let active, let i = panes.firstIndex(where: { $0 === active }) { activeIndex = i }
        settleTabScroll()
        invalidate()
    }

    func addToNewGroup(_ list: [TerminalPane]) {
        var created: TabGroup?
        reorder { created = TabGroupOps.addToNewGroup(&$0, picked: list) }
        pickedTabs = []
        // Named straight away, as on the Mac.
        if let created { beginNaming(.group(created), text: "") }
    }

    private func add(_ list: [TerminalPane], to group: TabGroup) {
        reorder { tabs in list.forEach { TabGroupOps.add($0, to: group, in: &tabs) } }
        pickedTabs = []
    }

    private func removeFromGroup(_ list: [TerminalPane]) {
        reorder { tabs in list.forEach { TabGroupOps.remove($0, in: &tabs) } }
        pickedTabs = []
    }

    private func ungroup(_ group: TabGroup) {
        group.collapsed = false
        panes.filter { $0.group === group }.forEach { $0.group = nil }
        settleTabScroll()
        invalidate()
    }

    /// Collapsing the group the active tab is in moves to the nearest tab still showing, or a new one if there's none.
    func setCollapsed(_ group: TabGroup, _ collapsed: Bool) {
        group.collapsed = collapsed
        if collapsed, activePane.group === group {
            let order = panes.indices.sorted { abs($0 - activeIndex) < abs($1 - activeIndex) }
            if let i = order.first(where: { panes[$0].group?.collapsed != true }) { selectTab(i) } else { addPane() }
        }
        settleTabScroll()
        invalidate()
    }

    /// A new tab at the end of the active tab's group, in its folder.
    func newTabInGroup() {
        guard let group = activePane.group else { return newTab() }
        let folder = activePane.terminal.cwd
        let at = (panes.lastIndex { $0.group === group } ?? activeIndex) + 1
        guard addPane(at: at, cwd: folder) else { return }
        activePane.group = group
        invalidate()
    }

    private func closeTabs(_ list: [TerminalPane]) {
        list.compactMap { pane in panes.firstIndex { $0 === pane } }.sorted(by: >).forEach { closeTab($0) }
        pickedTabs = []
    }

    private func beginNaming(_ target: NameTarget, text: String) {
        var placeholder = ""
        if case .group = target { placeholder = nextProjectName() }
        naming = (target, TextFieldState(text), placeholder)
        invalidate()
    }

    /// The suggestion a group's empty name field shows: the first "Project N" no group has, as on the Mac.
    private func nextProjectName() -> String {
        let names = Set(TabGroupOps.groups(in: panes).map(\.name))
        var n = 1
        while names.contains("Project \(n)") { n += 1 }
        return "Project \(n)"
    }

    private func finishNaming(commit: Bool) {
        guard let current = naming else { return }
        naming = nil
        if commit {
            let text = current.field.text.trimmingCharacters(in: .whitespaces)
            switch current.target {
            case .tab(let id): panes.first { $0.id == id }?.customTitle = text.isEmpty ? nil : text
            // Enter on a new group's empty field keeps the suggestion. Clearing a name leaves it unnamed.
            case .group(let g): g.name = text.isEmpty && g.name.isEmpty ? current.placeholder : text
            }
        }
        detailsChanged()
    }

    /// A key while a name is being typed. Characters come through as WM_CHAR.
    private func namingKey(_ key: Int32, ctrl: Bool) -> Bool {
        guard var current = naming else { return false }
        switch key {
        case Win.VK_RETURN, Win.VK_TAB: finishNaming(commit: true); return true
        case Win.VK_ESCAPE: finishNaming(commit: false); return true
        case Win.VK_BACK: current.field.deleteBackward(word: ctrl)
        case Win.VK_DELETE: current.field.deleteForward()
        case Win.VK_LEFT: current.field.move(by: -1)
        case Win.VK_RIGHT: current.field.move(by: 1)
        case Win.VK_HOME: current.field.move(to: 0)
        case Win.VK_END: current.field.move(to: current.field.text.count)
        // Everything else goes on to become a character (WM_CHAR), which is what's typed.
        default: return false
        }
        naming = current
        invalidate()
        return true
    }

    private func groupItems(for list: [TerminalPane], verb: String) -> [MenuItem] {
        TabGroupOps.groups(in: panes).filter { g in !list.allSatisfy { $0.group === g } }.map { g in
            MenuItem(title: "\(verb) “\(g.displayName)”", swatch: g.color.rgb) { [weak self] in self?.add(list, to: g) }
        }
    }

    private func showTabMenu(_ i: Int, at x: Float, y: Float) {
        let pane = panes[i]
        let picked = pickedPanes
        if picked.count > 1 && picked.contains(where: { $0 === pane }) {
            let n = picked.count
            var items = [MenuItem(title: "Add \(n) Tabs to New Group") { [weak self] in self?.addToNewGroup(picked) }]
            items += groupItems(for: picked, verb: "Add \(n) Tabs to")
            if picked.contains(where: { $0.group != nil }) { items.append(MenuItem(title: "Remove from Group") { [weak self] in self?.removeFromGroup(picked) }) }
            items += [.separator, MenuItem(title: "Close \(n) Tabs") { [weak self] in self?.closeTabs(picked) }]
            openMenu(items, x: x, y: y, above: false)
            return
        }
        clearPicked()
        var items = [MenuItem(title: "Rename Tab…") { [weak self] in self?.beginNaming(.tab(pane.id), text: pane.customTitle ?? "") }]
        if pane.customTitle != nil { items.append(MenuItem(title: "Reset Tab Name") { [weak self] in pane.customTitle = nil; self?.detailsChanged() }) }
        items += [.separator, MenuItem(title: "Add Tab to New Group") { [weak self] in self?.addToNewGroup([pane]) }]
        items += groupItems(for: [pane], verb: "Add Tab to")
        if pane.group != nil { items.append(MenuItem(title: "Remove from Group") { [weak self] in self?.removeFromGroup([pane]) }) }
        items += [.separator, MenuItem(title: "Close Tab") { [weak self] in self?.closeTabs([pane]) }]
        if panes.count > 1 { items.append(MenuItem(title: "Close Other Tabs") { [weak self] in self.map { $0.closeTabs($0.panes.filter { $0 !== pane }) } }) }
        if i < panes.count - 1 {
            items.append(MenuItem(title: "Close Tabs to the Right") { [weak self] in
                guard let self, let at = self.panes.firstIndex(where: { $0 === pane }) else { return }
                self.closeTabs(Array(self.panes[(at + 1)...]))
            })
        }
        openMenu(items, x: x, y: y, above: false)
    }

    private func showGroupMenu(_ group: TabGroup, at x: Float, y: Float) {
        var items = [MenuItem(title: "Rename Group…") { [weak self] in self?.beginNaming(.group(group), text: group.name) }, .separator]
        for color in TabGroupColor.allCases {
            items.append(MenuItem(title: color.title, isChecked: group.color == color, swatch: color.rgb) { [weak self] in
                group.color = color
                self?.invalidate()
            })
        }
        items += [.separator,
                  MenuItem(title: "New Tab in Group") { [weak self] in
                      guard let self, let last = self.panes.lastIndex(where: { $0.group === group }) else { return }
                      if group.collapsed { group.collapsed = false }
                      self.selectTab(last)
                      self.newTabInGroup()
                  },
                  MenuItem(title: group.collapsed ? "Expand Group" : "Collapse Group") { [weak self] in self?.setCollapsed(group, !group.collapsed) },
                  MenuItem(title: "Ungroup") { [weak self] in self?.ungroup(group) },
                  MenuItem(title: "Close Group") { [weak self] in self.map { $0.closeTabs($0.panes.filter { $0.group === group }) } }]
        openMenu(items, x: x, y: y, above: false)
    }

    // MARK: - Shortcuts

    /// Every shortcut, as Settings › Shortcuts lists them. Ctrl stands in for the Mac's Command.
    static let shortcutGroups: [(title: String, items: [(title: String, keys: String)])] = [
        ("Solanum", [("Settings…", "Ctrl+,"), ("Command Palette…", "Ctrl+Shift+P")]),
        ("Shell", [("New Tab", "Ctrl+T"), ("New Tab in Group", "Ctrl+Alt+T"), ("Reopen Closed Tab", "Ctrl+Shift+T"), ("Close Tab", "Ctrl+W"),
                   ("Close Tab (also)", "Ctrl+Shift+W"), ("Rename Tab…", "Ctrl+Shift+I"), ("Add Tab to New Group", "Ctrl+Alt+G")]),
        ("Tabs", [("Pick another tab", "Ctrl+Click"), ("Pick the tabs between", "Shift+Click"), ("Collapse or expand a group", "Click its chip")]),
        ("Edit", [("Copy (with something selected)", "Ctrl+C"), ("Stop the program (with nothing selected)", "Ctrl+C"), ("Cut (in the line being typed)", "Ctrl+X"),
                  ("Paste", "Ctrl+V"), ("Paste (also)", "Shift+Insert"), ("Undo (PowerShell and Claude Code)", "Ctrl+Z")]),
        ("View", [("Toggle File Sidebar", "Ctrl+B"), ("Pin Sidebar Folder", "Ctrl+Shift+B"), ("Scroll Back a Page", "Shift+PageUp"), ("Scroll Forward a Page", "Shift+PageDown")]),
        ("Window", [("Next Tab", "Ctrl+Tab"), ("Previous Tab", "Ctrl+Shift+Tab"), ("Go to Tab 1 to 9", "Ctrl+1"), ("Close Window", "Alt+F4")]),
    ]

    // MARK: - Command palette

    var isPaletteOpen: Bool { palette != nil }
    var paletteRows: [PaletteItem] { palette?.rows ?? [] }
    var paletteSelection: PaletteItem? { palette?.selectedItem }

    private var paletteLayout: PaletteLayout {
        PaletteLayout(windowWidth: Float(clientWidth), windowHeight: Float(clientHeight), scale: scale, rowCount: palette?.visibleRowCount ?? 0)
    }

    private func drawPalette(on target: Canvas) {
        guard let palette else { return }
        PaletteView(canvas: target, model: palette, layout: paletteLayout, hoveredRow: hoveredPaletteRow).draw()
    }

    /// Everything the app can do. On Windows this stands in for the Mac's menu bar, which is where its palette reads them.
    private func paletteItems() -> [PaletteItem] {
        var items = [
            PaletteItem(title: "New Tab", category: "Shell", shortcut: "Ctrl+T") { [weak self] in self?.newTab() },
            PaletteItem(title: "Reopen Closed Tab", category: "Shell", shortcut: "Ctrl+Shift+T") { [weak self] in self?.reopenClosedTab() },
            PaletteItem(title: "Close Tab", category: "Shell", shortcut: "Ctrl+W") { [weak self] in self.map { $0.closeTab($0.activeIndex) } },
            PaletteItem(title: "Next Tab", category: "Window", shortcut: "Ctrl+Tab") { [weak self] in self.map { $0.selectTab(($0.activeIndex + 1) % $0.panes.count) } },
            PaletteItem(title: "Previous Tab", category: "Window", shortcut: "Ctrl+Shift+Tab") { [weak self] in
                self.map { $0.selectTab(($0.activeIndex + $0.panes.count - 1) % $0.panes.count) }
            },
            PaletteItem(title: "Paste", category: "Edit", shortcut: "Ctrl+V") { [weak self] in self?.activePane.paste() },
            PaletteItem(title: "Rename Tab…", category: "Shell", shortcut: "Ctrl+Shift+I") { [weak self] in self.map { $0.beginNaming(.tab($0.activePane.id), text: $0.activePane.customTitle ?? "") } },
            PaletteItem(title: "New Tab in Group", category: "Shell", shortcut: "Ctrl+Alt+T") { [weak self] in self?.newTabInGroup() },
            PaletteItem(title: "Add Tab to New Group", category: "Shell", shortcut: "Ctrl+Alt+G") { [weak self] in self.map { $0.addToNewGroup([$0.activePane]) } },
            PaletteItem(title: "Remove Tab from Group", category: "Shell") { [weak self] in self.map { $0.removeFromGroup([$0.activePane]) } },
            PaletteItem(title: "Toggle File Sidebar", category: "View", shortcut: "Ctrl+B") { [weak self] in self.map { $0.toggleSidebar($0.left) } },
            PaletteItem(title: "Pin Sidebar Folder", category: "View", shortcut: "Ctrl+Shift+B") { [weak self] in self.map { $0.togglePin($0.left) } },
            PaletteItem(title: "Show Hidden Files", category: "View") { [weak self] in self.map { $0.toggleHidden($0.left) } },
            PaletteItem(title: "Collapse All Folders", category: "View") { [weak self] in
                self?.left.tree.collapseAll()
                self?.right.tree.collapseAll()
                self?.invalidate()
            },
            PaletteItem(title: "Scroll to Top", category: "View") { [weak self] in self?.activePane.scrollToTop() },
            PaletteItem(title: "Scroll to Bottom", category: "View") { [weak self] in self?.activePane.scrollToBottom() },
            PaletteItem(title: "Settings…", category: "Solanum", shortcut: "Ctrl+,") { SettingsWindow.shared.show() },
            PaletteItem(title: "Open Config File", category: "Solanum") {
                guard let url = AppSettings.fileURL else { return }
                _ = wide(url.path).withUnsafeBufferPointer { ShellExecuteW(nil, nil, $0.baseAddress, nil, nil, 1) }
            },
            PaletteItem(title: "Reload Config", category: "Solanum") { AppSettings.shared.reloadIfChanged() },
                        PaletteItem(title: "Minimize", category: "Window") { [weak self] in self?.pressCaptionButton(.minimize) },
            PaletteItem(title: IsZoomed(hwnd) ? "Restore" : "Maximize", category: "Window") { [weak self] in self?.pressCaptionButton(.maximize) },
            PaletteItem(title: "Close Window", category: "Window", shortcut: "Alt+F4") { [weak self] in self?.pressCaptionButton(.close) },
        ]
        for spec in AppSettings.shared.allThemes {
            items.append(PaletteItem(title: "Theme: \(spec.name)", category: "Appearance") { [weak self] in self?.useTheme(spec.name) })
        }
        for (i, pane) in panes.enumerated() {
            items.append(PaletteItem(title: "Go to Tab: \(pane.tabTitle)", category: "Tabs", shortcut: i < 9 ? "Ctrl+\(i + 1)" : "") { [weak self] in self?.selectTab(i) })
        }
        return items
    }

    func togglePalette() {
        if palette != nil {
            closePalette()
        } else {
            palette = PaletteModel(items: paletteItems(), recents: paletteRecents)
            activePane.setFocused(false)
            invalidate()
        }
    }

    private func closePalette() {
        palette = nil
        hoveredPaletteRow = nil
        activePane.setFocused(isFocused)
        invalidate()
    }

    private func runPalette(_ item: PaletteItem? = nil) {
        guard let palette, let item = item ?? palette.selectedItem else { return }
        palette.noteRun(item)
        paletteRecents = palette.recents
        Self.savePaletteRecents(paletteRecents)
        closePalette()
        item.run()
    }

    private func paletteTyped(_ unit: UInt16) {
        guard let palette, unit >= 0x20, unit != 0x7F else { return }
        // Surrogate pairs come in two messages, and the first can't be shown alone.
        if UTF16.isLeadSurrogate(unit) {
            palettePendingSurrogate = unit
            return
        }
        var units = [unit]
        if let lead = palettePendingSurrogate, UTF16.isTrailSurrogate(unit) { units = [lead, unit] }
        palettePendingSurrogate = nil
        palette.insert(String(decoding: units, as: UTF16.self))
        invalidate()
    }

    /// A key while the palette is open. Everything stays with it, so nothing typed lands in the shell behind.
    private func paletteKey(_ key: Int32, ctrl: Bool) -> Bool {
        guard let palette else { return false }
        switch key {
        case Win.VK_ESCAPE: closePalette()
        case Win.VK_RETURN: runPalette()
        case Win.VK_UP: palette.moveSelection(by: -1)
        case Win.VK_DOWN: palette.moveSelection(by: 1)
        case Win.VK_PRIOR: palette.moveSelection(by: -PaletteModel.maxRows)
        case Win.VK_NEXT: palette.moveSelection(by: PaletteModel.maxRows)
        case Win.VK_LEFT: palette.moveCaret(by: -1)
        case Win.VK_RIGHT: palette.moveCaret(by: 1)
        case Win.VK_HOME: palette.moveCaret(to: 0)
        case Win.VK_END: palette.moveCaret(to: palette.query.count)
        case Win.VK_BACK: palette.deleteBackward(word: ctrl)
        case Win.VK_DELETE: palette.deleteForward()
        case 0x56 where ctrl:
            if let text = activePane.clipboardText() { palette.insert(text) }
        case Win.VK_F4: return false
        default:
            // Characters come through as WM_CHAR. With Ctrl they'd be control codes, which have no place in the field.
            if ctrl { return true }
            return false
        }
        invalidate()
        return true
    }

    private func paletteMouse(_ message: UINT, x: Float, y: Float) {
        guard let palette else { return }
        let l = paletteLayout
        let row = l.visibleRow(atX: x, y: y).map { $0 + palette.scrollTop }
        switch message {
        case Win.WM_MOUSEMOVE:
            let visible = l.visibleRow(atX: x, y: y)
            if visible != hoveredPaletteRow {
                hoveredPaletteRow = visible
                invalidate()
            }
        case Win.WM_LBUTTONDOWN, Win.WM_RBUTTONDOWN:
            // Outside it dismisses, as on the Mac.
            if !l.panel.contains(x, y) { closePalette() }
        case Win.WM_LBUTTONUP:
            if let row, palette.rows.indices.contains(row), !palette.rows[row].isHeader { runPalette(palette.rows[row]) }
        default: break
        }
    }

    // Kept between launches, as on the Mac. Tests leave a person's list alone.
    private static var paletteRecentsFile: URL? {
        guard !CommandLine.arguments.contains("--window-test"), let appData = ProcessInfo.processInfo.environment["APPDATA"] else { return nil }
        return URL(fileURLWithPath: appData).appendingPathComponent("Solanum").appendingPathComponent("palette-recents.txt")
    }

    private static func loadPaletteRecents() -> [String] {
        guard let file = paletteRecentsFile, let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    private static func savePaletteRecents(_ recents: [String]) {
        guard let file = paletteRecentsFile else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? recents.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    // MARK: - Keyboard

    private func isDown(_ key: Int32) -> Bool { GetKeyState(key) < 0 }

    /// The window's own keys, ahead of the pane's.
    private func keyDown(_ key: Int32) -> Bool {
        keyDown(key, shift: isDown(Win.VK_SHIFT), ctrl: isDown(Win.VK_CONTROL), alt: isDown(Win.VK_MENU))
    }

    func keyDown(_ key: Int32, shift: Bool, ctrl: Bool, alt: Bool) -> Bool {
        if menu != nil { return menuKey(key) }
        if naming != nil { return namingKey(key, ctrl: ctrl) }
        // Ctrl+Alt+T and Ctrl+Alt+G, as the Mac's Command-Option-T and G: a new tab in this group, and a new group.
        if ctrl && alt && !shift && key == 0x54 { newTabInGroup(); return true }
        if ctrl && alt && !shift && key == 0x47 { addToNewGroup(pickedPanes.isEmpty ? [activePane] : pickedPanes); return true }
        if ctrl && shift && !alt && key == 0x49 { beginNaming(.tab(activePane.id), text: activePane.customTitle ?? ""); return true }
        if ctrl && !shift && !alt && key == 0xBC {
            SettingsWindow.shared.show()
            return true
        }
        if ctrl && shift && !alt && key == 0x50 {
            togglePalette()
            return true
        }
        if palette != nil { return paletteKey(key, ctrl: ctrl) }
        // Ctrl+B and Ctrl+Alt+B show and hide the sidebars, and Ctrl+Shift+B pins the left one to its folder.
        if ctrl && key == 0x42 {
            if alt {
                if hasSplit { toggleSidebar(right) }
            } else if shift {
                togglePin(left)
            } else {
                toggleSidebar(left)
            }
            return true
        }
        if let sidebar = focusedSidebar, sidebarKey(key, sidebar, shift: shift, ctrl: ctrl, alt: alt) { return true }
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
    var fontCellHeight: Float { canvas.metrics.cellHeight }

    var isDraggingTab: Bool { tabPress != nil }
    var groupNames: [String] { TabGroupOps.groups(in: panes).map(\.name) }
    var isNaming: Bool { naming != nil }
    var hoveredPart: WindowPart? { hovered }
    func hover(_ rect: UIRect) {
        let position = LPARAM(Int(rect.x + rect.width / 2) & 0xFFFF) | (LPARAM(Int(rect.y + rect.height / 2) & 0xFFFF) << 16)
        PostMessageW(hwnd, Win.WM_MOUSEMOVE, 0, position)
    }
    func pickForTest(_ i: Int, range: Bool) { pick(i, range: range) }
    func chipRect(_ first: Int) -> UIRect? { layout.chip(first) }
    func rightClick(_ rect: UIRect) {
        let position = LPARAM(Int(rect.x + rect.width / 2) & 0xFFFF) | (LPARAM(Int(rect.y + rect.height / 2) & 0xFFFF) << 16)
        PostMessageW(hwnd, Win.WM_RBUTTONDOWN, 2, position)
        PostMessageW(hwnd, Win.WM_RBUTTONUP, 0, position)
    }
    func typeIntoWindow(_ text: String) { for unit in text.utf16 { PostMessageW(hwnd, Win.WM_CHAR, WPARAM(unit), 0) } }
    var leftTree: FileTree { left.tree }
    var rightIsVisible: Bool { rightIsShowing }
    var leftIsVisible: Bool { left.isVisible }
    var leftPinned: String? { left.pinned }
    var leftHasFocus: Bool { left.isFocused }
    var leftWidthNow: Float { layout.leftWidth }

    /// The rectangle of a row of the left sidebar, for clicking it.
    func leftRow(named name: String) -> UIRect? {
        guard let i = left.tree.rows.firstIndex(where: { $0.entry.name == name }) else { return nil }
        return sidebarLayout(left).row(i - left.tree.scrollTop)
    }

    func leftButton(_ button: SidebarButton) -> UIRect { sidebarLayout(left).button(button.rawValue) }

    func doubleClick(_ rect: UIRect) {
        let position = LPARAM(Int(rect.x + rect.width / 2) & 0xFFFF) | (LPARAM(Int(rect.y + rect.height / 2) & 0xFFFF) << 16)
        PostMessageW(hwnd, Win.WM_LBUTTONDOWN, 1, position)
        PostMessageW(hwnd, Win.WM_LBUTTONUP, 0, position)
        PostMessageW(hwnd, Win.WM_LBUTTONDBLCLK, 1, position)
        PostMessageW(hwnd, Win.WM_LBUTTONUP, 0, position)
    }

    /// Drags the border of the left sidebar to a position.
    func dragLeftEdge(to x: Float) {
        let y = Int(layout.terminal.midY)
        func at(_ px: Int) -> LPARAM { LPARAM(px & 0xFFFF) | (LPARAM(y & 0xFFFF) << 16) }
        PostMessageW(hwnd, Win.WM_LBUTTONDOWN, 1, at(Int(layout.leftWidth)))
        PostMessageW(hwnd, Win.WM_MOUSEMOVE, 1, at(Int(x)))
        PostMessageW(hwnd, Win.WM_LBUTTONUP, 0, at(Int(x)))
    }

    /// A sideways swipe over the tab bar, as a touchpad sends it.
    func swipeTabs(delta: Int) {
        var point = POINT(x: LONG(clientWidth / 2), y: LONG(layout.tabBarHeight / 2))
        ClientToScreen(hwnd, &point)
        let position = LPARAM(Int(point.x) & 0xFFFF) | (LPARAM(Int(point.y) & 0xFFFF) << 16)
        PostMessageW(hwnd, Win.WM_MOUSEHWHEEL, WPARAM(UInt16(truncatingIfNeeded: delta)) << 16, position)
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
        let settings = AppSettings.shared
        if prepare() {
            window = TerminalWindow(commandLine: settings.shellCommandLine, cols: settings.windowColumns, rows: settings.windowRows, failure: &failure)
        }
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
