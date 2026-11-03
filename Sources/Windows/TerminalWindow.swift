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
    /// Where ssh in this window's tabs asks for passwords (see Askpass).
    private var askpass: Askpass.Server!
    var askpassPipeName: String { askpass.pipeName }
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
    /// The tab whose place the left sidebar shows (see `syncLeftSidebar`).
    private weak var leftOwner: TerminalPane?
    /// While split, the active tab of the column that doesn't have the keyboard.
    private var otherActiveID: UInt?
    /// How far the right column's tabs are scrolled.
    private var rightTabScroll: Float = 0
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
        // Files from Explorer can be dropped on the sidebars and terminals.
        DragAcceptFiles(created, true)
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
        askpass = Askpass.Server(post: { [weak self] work in self?.runOnWindowThread(work) })
        askpass.handler = { [weak self] request, reply in self?.answerAskpass(request, reply) ?? reply(nil) }
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

    /// The right sidebar only exists in a split window, as on the Mac.
    private var rightIsShowing: Bool { isSplit && right.isVisible }

    // MARK: - Columns

    /// Two columns side by side, each with its own tabs, as on the Mac. The tabs stay in one list, the left column's first.
    var isSplit: Bool { panes.contains { $0.column == 1 } }
    private var splitCount: Int? { isSplit ? panes.filter { $0.column == 0 }.count : nil }

    /// The active tab of the column without the keyboard, while split.
    private var otherActivePane: TerminalPane? {
        guard isSplit, !panes.isEmpty else { return nil }
        let column = 1 - activePane.column
        return panes.first { $0.id == otherActiveID && $0.column == column } ?? panes.first { $0.column == column }
    }
    /// What's on screen: the active tab, and while split the other column's.
    private var visiblePanes: [TerminalPane] { panes.isEmpty ? [] : [activePane] + (otherActivePane.map { [$0] } ?? []) }
    private var leftActivePane: TerminalPane { activePane.column == 0 ? activePane : otherActivePane ?? activePane }
    private var rightActivePane: TerminalPane? { !isSplit ? nil : activePane.column == 1 ? activePane : otherActivePane }
    /// The tab a sidebar follows: the right one's is the right column's.
    private func pane(for sidebar: FileSidebar) -> TerminalPane { sidebar === right ? rightActivePane ?? activePane : leftActivePane }
    /// The visible tab under a point of the terminal area.
    private func pane(atX x: Float) -> TerminalPane { isSplit && x >= layout.divider ? rightActivePane ?? activePane : leftActivePane }

    /// Keeps each column's tabs together, the left one's first, after anything that moved them; one column if the left
    /// one has emptied.
    private func normalizeColumns() {
        if !panes.contains(where: { $0.column == 0 }) { panes.forEach { $0.column = 0 } }
        let active = panes.indices.contains(activeIndex) ? panes[activeIndex] : nil
        panes = panes.filter { $0.column == 0 } + panes.filter { $0.column == 1 }
        if let active, let i = panes.firstIndex(where: { $0 === active }) { activeIndex = i }
        if !isSplit {
            otherActiveID = nil
            rightTabScroll = 0
        }
    }

    /// Where a tab's terminal is drawn.
    func area(for pane: TerminalPane) -> UIRect { isSplit && pane.column == 1 ? rightTerminalArea : terminalArea }

    private func grid(for area: UIRect) -> (cols: Int, rows: Int) {
        let m = canvas.metrics
        let w = max(area.width - canvas.padding * 2, 0), h = max(area.height - canvas.padding * 2, 0)
        return (max(Int(w / m.cellWidth), 2), max(Int(h / m.cellHeight), 1))
    }

    /// Each tab sized to its column.
    private func resizePanes() {
        for pane in panes {
            let g = grid(for: area(for: pane))
            pane.resize(cols: g.cols, rows: g.rows)
        }
    }

    /// Splits the window, with a new tab in the right column in this one's folder, or a new tab in the right column.
    func splitRight() {
        let cwd = activePane.sshArguments == nil ? activePane.terminal.cwd : nil
        addPane(cwd: cwd, column: 1)
    }

    /// Moves a tab to the other column, splitting the window if it isn't; it can't be the only tab.
    func moveToOtherColumn(_ pane: TerminalPane, at index: Int? = nil) {
        guard isSplit || panes.count > 1 else { return }
        let from = pane.column
        // The column it leaves keeps an active tab: the one before it, or after.
        if pane === activePane || pane.id == otherActiveID || otherActiveID == nil {
            let rest = panes.filter { $0.column == from && $0 !== pane }
            let at = panes.firstIndex { $0 === pane } ?? 0
            let stay = rest.last { r in (panes.firstIndex { $0 === r } ?? 0) < at } ?? rest.first
            if pane === activePane { otherActiveID = stay?.id } else if pane.id == otherActiveID { otherActiveID = stay?.id }
        }
        let wasSplit = isSplit
        pane.column = wasSplit ? 1 - from : 1
        pane.group = nil
        if let index, let i = panes.firstIndex(where: { $0 === pane }) {
            panes.remove(at: i)
            panes.insert(pane, at: min(index, panes.count))
        }
        normalizeColumns()
        layoutChanged()
        if let i = panes.firstIndex(where: { $0 === pane }) { activate(i) }
    }

    /// Puts the columns back together: the right one's tabs join the left one's, nothing in them lost.
    func closeSplit() {
        guard isSplit else { return }
        panes.forEach { $0.column = 0 }
        normalizeColumns()
        layoutChanged()
        detailsChanged()
    }

    /// The keyboard to the other column's active tab.
    func focusOtherColumn() {
        guard let other = otherActivePane, let i = panes.firstIndex(where: { $0 === other }) else { return }
        activate(i)
    }

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

    private var layout: WindowLayout { layout(leftWidth: (sidebarWidth(left) * left.shown).rounded()) }

    private func layout(leftWidth: Float) -> WindowLayout {
        WindowLayout(width: Float(clientWidth), height: Float(clientHeight), scale: scale, tabCount: panes.count, tabScroll: tabScroll,
                     chips: chipWidths(), hiddenTabs: hiddenTabs, leftWidth: leftWidth, rightWidth: rightIsShowing ? sidebarWidth(right) : 0,
                     showsRightToggle: isSplit, splitCount: splitCount, rightTabScroll: rightTabScroll)
    }

    /// The layout once the left sidebar has finished sliding.
    private var settledLayout: WindowLayout { layout(leftWidth: left.isVisible || left.shown > 0 ? sidebarWidth(left) : 0) }

    /// Where the terminal (the left column's, when split) is drawn. While a sidebar slides, the terminal moves with it but
    /// keeps the size it has at the start of opening or the end of closing, as on the Mac: each resize makes the shell and
    /// programs redraw.
    private var terminalArea: UIRect {
        let now = layout.terminal
        return UIRect(x: now.x, y: now.y, width: settledLayout.terminal.width, height: now.height)
    }

    /// The right column's, while split: it moves along with the left sidebar's slide too.
    private var rightTerminalArea: UIRect {
        let settled = settledLayout, shift = layout.terminal.x - settled.terminal.x
        let r = settled.rightTerminal
        return UIRect(x: r.x + shift, y: r.y, width: r.width, height: r.height)
    }

    /// Where the left sidebar is drawn: its full width, slid partly off the window's edge while it comes and goes.
    private var leftSidebarArea: UIRect {
        let l = layout, full = sidebarWidth(left)
        return UIRect(x: l.leftWidth - full, y: l.leftSidebar.y, width: full, height: l.leftSidebar.height)
    }

    // MARK: - Sliding the sidebars

    private var slideStart = Date.distantPast
    private var slideFrom: Float = 0
    private static let slideTimer: UINT_PTR = 5

    /// Windows' own "Animation effects" setting, which turns off motion like this.
    var animatesSidebars: Bool {
        var on: WindowsBool = true
        _ = SystemParametersInfoW(UINT(0x1042), 0, &on, 0)
        return on.boolValue && IsWindowVisible(hwnd)
    }

    private func slideLeft() {
        let target: Float = left.isVisible ? 1 : 0
        guard animatesSidebars else {
            left.shown = target
            layoutChanged()
            return
        }
        slideFrom = left.shown
        slideStart = Date()
        _ = SetTimer(hwnd, Self.slideTimer, 10, nil)
    }

    /// One frame: a critically damped spring, as on the Mac, which sets off gently and settles without overshooting.
    private func slideStep() {
        let target: Float = left.isVisible ? 1 : 0
        let t = Float(Date().timeIntervalSince(slideStart)), w: Float = 20
        let done = t >= 0.4
        let e = done ? 1 : 1 - (1 + w * t) * exp(-w * t)
        left.shown = slideFrom + (target - slideFrom) * e
        canvas.terminalArea = terminalArea
        if done {
            KillTimer(hwnd, Self.slideTimer)
            // Closing resizes the terminal at the end, now that the sidebar's gone.
            layoutChanged()
        }
        invalidate()
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

    /// A new tab: at `index`, or at the end of `column` (the active tab's column unless given).
    @discardableResult
    private func addPane(at index: Int? = nil, cwd: String? = nil, restoring text: String? = nil, place: SidebarPlace? = nil, column: Int? = nil) -> Bool {
        let wasSplit = isSplit
        let col = column ?? index.flatMap { i in panes.indices.contains(i - 1) ? panes[i - 1].column : nil } ?? (panes.isEmpty ? 0 : activePane.column)
        let grid = clientWidth > 0 ? self.grid(for: col == 1 ? rightTerminalArea : terminalArea) : (cols: 110, rows: 32)
        guard let pane = TerminalPane(host: self, commandLine: commandLine, cols: grid.cols, rows: grid.rows, cwd: cwd, restoring: text) else { return false }
        pane.column = col
        pane.onRemoteChange = { [weak self, weak pane] in
            guard let self, let pane, self.visiblePanes.contains(where: { $0 === pane }) else { return }
            if pane === self.leftActivePane { self.left.followed = nil }
            if pane === self.rightActivePane { self.right.followed = nil }
            self.followTerminalFolder()
            self.invalidate()
        }
        if panes.indices.contains(activeIndex) { panes[activeIndex].setFocused(false) }
        pane.sidebarPlace = place
        let end = (panes.lastIndex { $0.column == col }).map { $0 + 1 } ?? panes.count
        panes.insert(pane, at: min(index ?? end, panes.count))
        normalizeColumns()
        if isSplit != wasSplit { layoutChanged() }
        activate(panes.firstIndex { $0 === pane } ?? 0)
        return true
    }

    /// What's needed to bring a closed tab back, most recent last.
    private struct ClosedTab {
        let index: Int, folder: String?, text: String
        let place: SidebarPlace?
        let column: Int
    }
    private var closedTabs: [ClosedTab] = []

    /// The last tab closed, in its place and folder, with what it showed in its scrollback.
    func reopenClosedTab() {
        guard let closed = closedTabs.popLast() else { return }
        let column = isSplit ? closed.column : 0
        let range = panes.indices.filter { panes[$0].column == column }
        let at = min(max(closed.index, range.first ?? 0), (range.last ?? panes.count - 1) + 1)
        addPane(at: at, cwd: closed.folder, restoring: closed.text, place: closed.place, column: column)
    }

    /// In the current tab's folder, unless Settings says the home folder; in the active tab's column, or `column`.
    func newTab(column: Int? = nil) {
        let from = column.flatMap { $0 == 1 ? rightActivePane : leftActivePane } ?? (panes.isEmpty ? nil : activePane)
        let here = AppSettings.shared.newTabFolder == "current" ? from?.terminal.cwd : nil
        addPane(cwd: here, column: column)
    }

    func selectTab(_ i: Int) {
        guard panes.indices.contains(i), i != activeIndex else { return }
        activate(i)
    }

    /// The `n`th tab of the column with the keyboard (Ctrl+1 to 9).
    private func selectTab(inColumn n: Int) {
        let range = panes.indices.filter { panes[$0].column == activePane.column }
        if range.indices.contains(n) { selectTab(range[n]) }
    }

    private func activate(_ i: Int) {
        let previous = panes.indices.contains(activeIndex) ? panes[activeIndex] : nil
        previous?.setFocused(false)
        // Going to the other column leaves the one before as that column's active tab.
        if let previous, previous !== panes[i], previous.column != panes[i].column, panes.contains(where: { $0 === previous }) {
            otherActiveID = previous.id
        }
        activeIndex = i
        syncLeftSidebar()
        panes[i].setFocused(isFocused && !sidebarHasFocus)
        settleTabScroll()
        detailsChanged()
    }

    /// The left sidebar keeps each tab's place (its pin, open folders, where it was): it shows the left column's active
    /// tab's, keeping the one before's.
    private func syncLeftSidebar() {
        guard !panes.isEmpty else { return }
        let owner = leftActivePane
        guard owner !== leftOwner else { return }
        if let old = leftOwner, panes.contains(where: { $0 === old }) { saveSidebarPlace(to: old) }
        restoreSidebarPlace(from: owner)
        leftOwner = owner
    }

    /// Stops the tab's shell. The tab goes when it has ended (see `paneExited`).
    func closeTab(_ i: Int) {
        guard panes.indices.contains(i) else { return }
        let terminal = panes[i].terminal
        if panes[i] === leftOwner { saveSidebarPlace(to: panes[i]) }
        closedTabs.append(ClosedTab(index: i, folder: terminal.cwd, text: terminal.restorableText(maxLines: 5000), place: panes[i].sidebarPlace,
                                    column: panes[i].column))
        if closedTabs.count > 25 { closedTabs.removeFirst() }
        panes[i].terminate()
    }

    private func paneExited(id: UInt) {
        guard let i = panes.firstIndex(where: { $0.id == id }) else { return }
        panes[i].drainOutput()
        let wasActive = i == activeIndex, column = panes[i].column, wasSplit = isSplit
        let keep = wasActive ? nil : activePane
        let other = otherActivePane
        panes.remove(at: i)
        guard !panes.isEmpty else {
            PostMessageW(hwnd, Win.WM_CLOSE, 0, 0)
            return
        }
        if let keep, let k = panes.firstIndex(where: { $0 === keep }) {
            activeIndex = k
            normalizeColumns()
        } else {
            // The tab that took its place in the same column, or the one before it; with that column empty, the other's.
            let same = panes.indices.filter { panes[$0].column == column }
            let next = same.first { $0 >= i } ?? same.last ?? other.flatMap { o in panes.firstIndex { $0 === o } } ?? 0
            activeIndex = next
            normalizeColumns()
            panes[activeIndex].setFocused(isFocused && !sidebarHasFocus)
            syncLeftSidebar()
        }
        if isSplit != wasSplit { layoutChanged() }
        syncLeftSidebar()
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
        guard panes.indices.contains(activeIndex), visiblePanes.contains(where: { $0 === pane }) else { return }
        invalidate()
        // Posted messages outrank painting, so a program printing nonstop would otherwise never be seen.
        if Date().timeIntervalSince(lastDrawn) > 1.0 / 30 { UpdateWindow(hwnd) }
    }

    private func invalidate() { InvalidateRect(hwnd, nil, false) }

    /// Keeps the tabs' scroll in range and, unless the person's own scrolling is what moved them, the active tab in view.
    private func settleTabScroll(showingActive: Bool = true) {
        tabScroll = min(max(tabScroll, 0), layout.maxTabScroll(column: 0))
        rightTabScroll = min(max(rightTabScroll, 0), layout.maxTabScroll(column: 1))
        guard showingActive else { return }
        for pane in visiblePanes {
            guard let i = panes.firstIndex(where: { $0 === pane }) else { continue }
            let l = layout, to = l.scroll(showing: i)
            if l.column(ofTab: i) == 0 { tabScroll = to } else { rightTabScroll = to }
        }
    }

    /// Scrolls a column's strip of tabs (the left one's, or the only one).
    private func scrollTabs(by delta: Float, column: Int = 0) {
        if column == 1 { rightTabScroll += delta } else { tabScroll += delta }
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
        // Over ssh, the host's folder, when it's known. While split, each column's half has its own.
        func folder(_ p: TerminalPane) -> String? { p.sshArguments != nil ? p.remoteTerminalFolder : p.terminal.cwd }
        func home(_ p: TerminalPane) -> String? { p.sshArguments != nil ? p.remote?.home : ProcessInfo.processInfo.environment["USERPROFILE"] }
        if !panes.isEmpty {
            let l = leftActivePane
            chrome.folder = folder(l)
            chrome.home = home(l)
            chrome.sshHost = l.sshHost
            if let r = rightActivePane {
                chrome.rightFolder = folder(r)
                chrome.rightHome = home(r)
                chrome.rightSSHHost = r.sshHost
            }
            chrome.otherActiveTab = otherActivePane.flatMap { o in panes.firstIndex { $0 === o } }
        }
        chrome.hoveredCrumb = hoveredCrumb
        for (first, group) in groupStarts() {
            let members = panes.indices.filter { panes[$0].group === group && panes[$0].column == panes[first].column }
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
        for pane in visiblePanes { pane.draw(cursorShown: pane === activePane ? cursorShown : true, style: cursorStyleCode) }
        drawDivider(on: canvas)
        drawSidebars(on: canvas, layout: layout)
        drawPalette(on: canvas)
        if let menu { MenuView(canvas: canvas, menu: menu).draw() }
        _ = sol_canvas_end(canvas.raw)
        paints += 1
        lastDrawn = Date()
    }

    /// The line between the columns, while split.
    private func drawDivider(on target: Canvas) {
        guard isSplit else { return }
        let l = layout
        sol_canvas_fill_rect(target.raw, l.divider, l.tabBarHeight, 1, l.terminal.height, TerminalPalette.foreground, 0.12)
    }

    /// What the window shows, to a PNG. For tests.
    func saveSnapshot(to path: String) -> Bool {
        guard let bitmap = Canvas(width: clientWidth, height: clientHeight, fontPixels: fontPixels()) else { return false }
        applyFont(to: bitmap)
        bitmap.padding = canvas.padding
        bitmap.terminalArea = canvas.terminalArea
        guard sol_canvas_begin(bitmap.raw, TerminalPalette.background) >= 0 else { return false }
        chrome(on: bitmap, layout: layout).draw()
        for pane in visiblePanes {
            bitmap.terminalArea = area(for: pane)
            var renderer = TerminalRenderer(canvas: bitmap, terminal: pane.terminal)
            renderer.scrollOffset = pane.scrollOffset
            renderer.focused = pane === activePane
            renderer.drawContents()
            pane.drawOverlays(on: bitmap)
        }
        drawDivider(on: bitmap)
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
            if naming != nil { finishNaming(commit: true) }
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
            // Going to another window keeps the name typed so far, as clicking elsewhere does.
            if !isFocused && naming != nil { finishNaming(commit: true) }
            if !panes.isEmpty { activePane.setFocused(isFocused) }
            invalidate()
            return 0
        case Win.WM_OUTPUT:
            panes.first { $0.id == UInt(wParam) }?.drainOutput()
            return 0
        case Win.WM_DROPFILES:
            droppedFromExplorer(wParam)
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
            } else if wParam == WPARAM(Self.slideTimer) {
                slideStep()
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
            } else if !panes.isEmpty, activePane.hasQuestion {
                activePane.questionTyped(UInt16(truncatingIfNeeded: wParam))
            } else if let sidebar = editingSidebar {
                let unit = UInt16(truncatingIfNeeded: wParam)
                if unit >= 0x20, unit != 0x7F, let scalar = Unicode.Scalar(unit) {
                    sidebar.tree.updateEditing { $0.insert(String(Character(scalar))) }
                    invalidate()
                }
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
            let point = screenPoint(lParam)
            guard !panes.isEmpty, point.y < layout.tabBarHeight else { return 0 }
            let swiped = Float(Int16(truncatingIfNeeded: (wParam >> 16) & 0xFFFF)) / Float(Win.WHEEL_DELTA)
            let column = isSplit && point.x >= layout.divider ? 1 : 0
            scrollTabs(by: swiped * layout.tabWidth(column: column), column: column)
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
                let column = isSplit && x >= layout.divider ? 1 : 0
                scrollTabs(by: -notches * layout.tabWidth(column: column), column: column)
            } else {
                // The column under the pointer scrolls, whichever has the keyboard.
                pane(atX: x).wheel(wParam, lParam)
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
        canvas.terminalArea = terminalArea
        resizePanes()
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
        let part = layout.part(atX: x, y: y)
        // A click anywhere but the name being typed keeps it and ends the typing, as on the Mac.
        let presses = [Win.WM_LBUTTONDOWN, Win.WM_RBUTTONDOWN, Win.WM_MBUTTONDOWN, Win.WM_LBUTTONDBLCLK]
        if naming != nil, presses.contains(message), !isOnNameField(part) {
            finishNaming(commit: true)
        }
        // Likewise a name typed in a sidebar.
        if let sidebar = editingSidebar, presses.contains(message) {
            let l = sidebarLayout(sidebar)
            let onField = sidebar.tree.editingRow.map { l.row($0 - sidebar.tree.scrollTop).contains(x, y) } ?? false
            if !onField { finishSidebarEdit(commit: true) }
        }
        if tabDragMouse(message, x: x) { return }
        if part == .statusBar && !terminalHasMouse && statusBarMouse(message, x: x, y: y) { return }
        if part != .statusBar && hoveredCrumb != nil {
            hoveredCrumb = nil
            invalidate()
        }
        if sidebarMouse(message, part: part, x: x, y: y) { return }
        if part == .terminal && !terminalHasMouse && lostBarMouse(message, x: x, y: y) { return }
        let under = pane(atX: x)
        if message == Win.WM_LBUTTONDOWN || message == Win.WM_RBUTTONDOWN || message == Win.WM_MBUTTONDOWN || message == Win.WM_LBUTTONDBLCLK {
            terminalHasMouse = part == .terminal
            if part == .terminal {
                // A press in the other column gives it the keyboard.
                if under !== activePane, let i = panes.firstIndex(where: { $0 === under }) { activate(i) }
                focusTerminal()
            }
        }
        if terminalHasMouse || (part == .terminal && message != Win.WM_MBUTTONUP && message != Win.WM_LBUTTONUP) {
            if message == Win.WM_MOUSEMOVE { setHovered(.terminal, nonClient: false) }
            (terminalHasMouse ? activePane : under).mouse(message, wParam, lParam)
            if message == Win.WM_LBUTTONUP || message == Win.WM_RBUTTONUP || message == Win.WM_MBUTTONUP { terminalHasMouse = false }
            return
        }
        switch message {
        case Win.WM_MOUSEMOVE:
            setHovered(part, nonClient: false)
        case Win.WM_LBUTTONDBLCLK:
            // Double-clicking a tab renames it, as on the Mac.
            if case .tab(let i) = part, panes.indices.contains(i) {
                tabPress = nil
                beginNaming(.tab(panes[i].id), text: panes[i].customTitle ?? "")
            }
        case Win.WM_LBUTTONDOWN:
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
            if part == .rightScrollLeft { scrollTabs(by: -layout.tabViewport(column: 1).width * 0.75, column: 1) }
            if part == .rightScrollRight { scrollTabs(by: layout.tabViewport(column: 1).width * 0.75, column: 1) }
            pressed = part
        case Win.WM_LBUTTONUP:
            if part == pressed {
                switch part {
                case .tabClose(let i): closeTab(i)
                case .newTab: newTab(column: 0)
                case .newTabRight: newTab(column: 1)
                case .closeSplit: closeSplit()
                case .chip(let first): if let g = panes[first].group { setCollapsed(g, !g.collapsed) }
                case .flower: SettingsWindow.shared.show()
                case .toggleLeft: toggleSidebar(left)
                case .hosts: showHostsMenu()
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
        SidebarLayout(area: sidebar === left ? leftSidebarArea : layout.rightSidebar, scale: scale)
    }

    private func drawSidebars(on target: Canvas, layout l: WindowLayout) {
        let home = ProcessInfo.processInfo.environment["USERPROFILE"]
        for (sidebar, visible, area, edge) in [(left, l.leftSidebar, leftSidebarArea, l.leftWidth - 1), (right, l.rightSidebar, l.rightSidebar, l.width - l.rightWidth)] where visible.width > 0 {
            // Each follows its own column's tab.
            let pane = panes.isEmpty ? nil : self.pane(for: sidebar)
            let folder = pane?.terminal.cwd, remoteHome = pane?.remote?.home, sshHost = pane?.sshHost, status = pane?.remoteStatus
            sol_canvas_push_clip(target.raw, visible.x, visible.y, visible.width, visible.height)
            let onHost = sidebar.tree.root.map(AnyPath.isUnix) ?? false
            let showsStatus = sidebar.pinned == nil && status != nil
            SidebarView(canvas: target, sidebar: sidebar, layout: SidebarLayout(area: area, scale: scale), terminalFolder: folder,
                        home: onHost ? remoteHome : home, host: onHost || showsStatus ? sshHost : nil, status: showsStatus ? status : nil).draw()
            sol_canvas_pop_clip(target.raw)
            sol_canvas_fill_rect(target.raw, edge, visible.y, 1, visible.height, TerminalPalette.foreground, 0.10)
        }
    }

    func runOnWindowThreadPublic(_ work: @escaping () -> Void) { runOnWindowThread(work) }

    /// Runs `work` on the thread with the message loop. From any thread.
    private func runOnWindowThread(_ work: @escaping () -> Void) {
        runLock.lock()
        runQueue.append(work)
        runLock.unlock()
        PostMessageW(hwnd, Win.WM_RUN, 0, 0)
    }

    private func listInBackground(_ folder: String, for sidebar: FileSidebar) {
        // A folder on an ssh host is listed over the tab's own connection to it.
        if AnyPath.isUnix(folder) {
            guard let remote = panes.isEmpty ? nil : pane(for: sidebar).remote else { return }
            remote.list(folder) { [weak self, weak sidebar] entries in
                self?.runOnWindowThread {
                    guard let self, let sidebar else { return }
                    if sidebar.tree.receive(folder, entries) { self.invalidate() }
                }
            }
            return
        }
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
        for sidebar in [left, right] where sidebar.isVisible && sidebar.pinned == nil && (sidebar === left || rightIsShowing) {
            // Over ssh, the host's folder once the sidebar's connection is up; this machine's otherwise.
            let pane = self.pane(for: sidebar)
            let local = pane.sshArguments == nil ? pane.terminal.cwd ?? ProcessInfo.processInfo.environment["USERPROFILE"] : nil
            guard let folder = pane.remoteFolder ?? local else { continue }
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
        // The right sidebar is the right column's: there's none without a split.
        guard sidebar === left || isSplit else { return }
        sidebar.isVisible.toggle()
        if !sidebar.isVisible && sidebar.isFocused { focusTerminal() }
        // Opening resizes the terminal at the start, closing at the end of the slide.
        if sidebar === left {
            if left.isVisible { layoutChanged() }
            slideLeft()
        } else {
            layoutChanged()
        }
        if sidebar.isVisible {
            if let pinned = sidebar.pinned { sidebar.tree.setRoot(pinned) } else { followTerminalFolder() }
            sidebar.tree.refresh()
        }
        saveSidebarSettings()
    }

    /// The bars have moved, so the terminal's area and grid have changed.
    private func layoutChanged() {
        guard clientWidth > 0 else { return }
        canvas.terminalArea = terminalArea
        resizePanes()
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
        guard let root = sidebar.tree.root, let up = AnyPath.parent(root) else { return }
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
        if entry.isDirectory { sidebar.tree.toggle(entry.path) } else if !AnyPath.isUnix(entry.path) { onOpenFile(entry.path) }
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
        // A row held down: a click on it, or dragging it somewhere.
        if var press = rowPress {
            switch message {
            case Win.WM_MOUSEMOVE:
                if !press.dragging {
                    guard abs(x - press.x) > 4 * scale || abs(y - press.y) > 4 * scale else { return true }
                    press.dragging = true
                    rowPress = press
                    SetCapture(hwnd)
                }
                [left, right].forEach { $0.dropFolder = nil }
                if case .folder(let over, let folder)? = dropSpot(atX: x, y: y) { over.dropFolder = folder }
                invalidate()
                return true
            case Win.WM_LBUTTONUP:
                rowPress = nil
                [left, right].forEach { $0.dropFolder = nil }
                if press.dragging {
                    ReleaseCapture()
                    let path = press.entry.path, copy = isDown(Win.VK_CONTROL)
                    if let spot = dropSpot(atX: x, y: y) {
                        // Onto itself or where it already is, it stays put.
                        if case .folder(let over, let folder) = spot, over === press.sidebar, !copy,
                           folder == path || AnyPath.parent(path) == folder { invalidate(); return true }
                        drop([path], at: spot, from: press.sidebar, copy: copy)
                    }
                } else if press.entry.isDirectory {
                    // A click on a folder opens or closes it.
                    press.sidebar.tree.toggle(press.entry.path)
                }
                invalidate()
                return true
            default: break
            }
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
            if let row, row.entry.path != FileTree.newItemPath {
                focus(sidebar)
                sidebar.tree.selection = row.entry.path
                rowPress = (sidebar, row.entry, x, y, false)
            }
            invalidate()
        case Win.WM_RBUTTONDOWN:
            if let row, row.entry.path != FileTree.newItemPath {
                focus(sidebar)
                sidebar.tree.selection = row.entry.path
            }
            invalidate()
        case Win.WM_RBUTTONUP:
            // The list's menu: for the row under the pointer, or for the folder itself below the rows.
            if button == nil, y >= l.list.y { showSidebarMenu(sidebar, entry: row?.entry, x: x, y: y) }
        case Win.WM_LBUTTONDBLCLK:
            guard let row else { break }
            sidebar.tree.selection = row.entry.path
            if row.entry.isDirectory {
                // Back to how it was before this double click's first click, then the terminal goes there, as on the Mac (on
                // an ssh host too, by typing a cd into the session).
                sidebar.tree.toggle(row.entry.path)
                pane(for: sidebar).changeDirectory(to: row.entry.path)
                focusTerminal()
            } else if !AnyPath.isUnix(row.entry.path) {
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


    // MARK: - Files in the sidebars

    /// Files cut or copied on an ssh host, which Windows' clipboard can't carry; this PC's go on that clipboard, so
    /// Explorer can paste them too. They count while the clipboard hasn't changed since.
    private var hostClipboard: (paths: [String], cut: Bool, remote: RemoteConnection, sequence: DWORD)?
    /// A press on a sidebar's row, which may turn into dragging it.
    private var rowPress: (sidebar: FileSidebar, entry: FileEntry, x: Float, y: Float, dragging: Bool)?

    private var editingSidebar: FileSidebar? { left.tree.editing != nil ? left : right.tree.editing != nil ? right : nil }

    /// The sidebar's connection to the host it shows, when that's an ssh host's.
    private func remote(for sidebar: FileSidebar) -> RemoteConnection? {
        guard sidebar.tree.root.map(AnyPath.isUnix) == true, !panes.isEmpty else { return nil }
        return pane(for: sidebar).remote.flatMap { $0.state == .ready ? $0 : nil }
    }

    /// Where new and pasted things go: the folder clicked, the clicked file's folder, or the root.
    private func targetFolder(_ entry: FileEntry?, in sidebar: FileSidebar) -> String? {
        guard let entry else { return sidebar.tree.root }
        return entry.isDirectory ? entry.path : AnyPath.parent(entry.path)
    }

    private func relist(_ folder: String?, in sidebar: FileSidebar) {
        if let folder { listInBackground(folder, for: sidebar) }
        invalidate()
    }

    /// Runs a script on the sidebar's host; `done` on the window's thread with whether it worked.
    private func onHost(_ sidebar: FileSidebar, _ script: String, timeout: TimeInterval = 60, _ done: @escaping (Bool, String) -> Void) {
        guard let remote = remote(for: sidebar) else { MessageBeep(UINT(0xFFFF_FFFF)); return }
        remote.run(script, timeout: timeout) { [weak self] text, code in
            self?.runOnWindowThread { done(code == 0, text ?? "") }
        }
    }

    /// Something went wrong with a file: a sound, as Explorer makes.
    private func fileProblem() { _ = MessageBeep(UINT(0x30)) }

    private func showSidebarMenu(_ sidebar: FileSidebar, entry: FileEntry?, x: Float, y: Float) {
        let onHost = sidebar.tree.root.map(AnyPath.isUnix) ?? false
        var items: [MenuItem] = []
        func item(_ title: String, _ keys: String = "", enabled: Bool = true, _ run: @escaping () -> Void) {
            var m = MenuItem(title: title, isEnabled: enabled, run: run)
            m.shortcut = keys
            items.append(m)
        }
        if let entry {
            if entry.isDirectory {
                item("Open in Solanum") { [weak self] in self?.openInTerminal(entry.path, sidebar) }
                if !onHost { item("Open in New Tab") { [weak self] in self?.openInNewTab(entry.path, sidebar) } }
                item("Pin as Sidebar Root") { [weak self] in self?.pin(sidebar, to: entry.path) }
            } else if !onHost {
                item("Open", "Enter") { [weak self] in self?.onOpenFile(entry.path) }
            }
            items.append(.separator)
        }
        let folder = targetFolder(entry, in: sidebar)
        item("New File…") { [weak self] in folder.map { self?.beginNew(folder: false, in: $0, sidebar) } }
        item("New Folder…", "Ctrl+Shift+N") { [weak self] in folder.map { self?.beginNew(folder: true, in: $0, sidebar) } }
        items.append(.separator)
        if let entry {
            item("Cut", "Ctrl+X") { [weak self] in self?.copyFiles([entry.path], cut: true, sidebar) }
            item("Copy", "Ctrl+C") { [weak self] in self?.copyFiles([entry.path], cut: false, sidebar) }
        }
        item("Paste", "Ctrl+V", enabled: canPaste) { [weak self] in folder.map { self?.pasteFiles(into: $0, sidebar) } }
        if let entry {
            item("Duplicate") { [weak self] in self?.duplicate(entry, sidebar) }
            items.append(.separator)
            item("Copy Path", "Ctrl+Shift+C") { [weak self] in self?.activePane.setClipboard(entry.path) }
            item("Rename…", "F2") { [weak self] in self?.beginRename(entry, sidebar) }
            item(onHost ? "Delete…" : "Delete", "Del") { [weak self] in self?.deleteFiles([entry], sidebar, x: x, y: y) }
        }
        items.append(.separator)
        if onHost {
            if let entry { item("Download to Downloads") { [weak self] in self?.download([entry.path], into: FileOps.downloadsFolder, sidebar) } }
            item("Upload Files Here…") { [weak self] in folder.map { self?.pickAndUpload(into: $0, sidebar) } }
        } else {
            item(entry == nil ? "Open in Explorer" : "Show in Explorer") {
                if let entry { FileOps.onReveal(entry.path) } else if let root = sidebar.tree.root { FileOps.onReveal(root) }
            }
        }
        item("Refresh") { sidebar.tree.refresh() }
        openMenu(items, x: x, y: y, above: false)
    }

    private func openInTerminal(_ folder: String, _ sidebar: FileSidebar) {
        pane(for: sidebar).changeDirectory(to: folder)
        focusTerminal()
    }

    private func openInNewTab(_ folder: String, _ sidebar: FileSidebar) {
        addPane(cwd: folder, column: sidebar === right && isSplit ? 1 : 0)
    }

    private func pin(_ sidebar: FileSidebar, to folder: String) {
        if sidebar === left { return pinLeft(to: folder) }
        sidebar.pinned = folder
        sidebar.tree.setRoot(folder)
        invalidate()
    }

    // Naming new items, and renaming

    private func beginNew(folder: Bool, in parent: String, _ sidebar: FileSidebar) {
        finishSidebarEdit(commit: true)
        focus(sidebar)
        sidebar.tree.beginNew(folder: folder, in: parent)
        if let i = sidebar.tree.editingRow { sidebar.tree.selection = sidebar.tree.rows[i].entry.path }
        sidebar.tree.keepSelectionVisible(rowsShowing: sidebarLayout(sidebar).rowsShowing)
        invalidate()
    }

    private func beginRename(_ entry: FileEntry, _ sidebar: FileSidebar) {
        finishSidebarEdit(commit: true)
        focus(sidebar)
        sidebar.tree.beginRename(entry)
        invalidate()
    }

    /// Keys while a name's typed in a sidebar. Characters come as WM_CHAR.
    private func sidebarEditKey(_ key: Int32, ctrl: Bool) -> Bool {
        guard let sidebar = editingSidebar else { return false }
        switch key {
        case Win.VK_RETURN: finishSidebarEdit(commit: true)
        case Win.VK_ESCAPE: finishSidebarEdit(commit: false)
        case Win.VK_BACK: sidebar.tree.updateEditing { $0.deleteBackward(word: ctrl) }
        case Win.VK_DELETE: sidebar.tree.updateEditing { $0.deleteForward() }
        case Win.VK_LEFT: sidebar.tree.updateEditing { $0.move(by: -1) }
        case Win.VK_RIGHT: sidebar.tree.updateEditing { $0.move(by: 1) }
        case Win.VK_HOME: sidebar.tree.updateEditing { $0.move(to: 0) }
        case Win.VK_END: sidebar.tree.updateEditing { $0.move(to: $0.text.count) }
        case 0x56 where ctrl:
            if let text = activePane.clipboardText() { sidebar.tree.updateEditing { $0.insert(text.filter { !$0.isNewline }) } }
        default: return !ctrl ? false : true
        }
        invalidate()
        return true
    }

    /// Makes the file or folder, or renames it. A name that can't be (taken, or with characters it can't have) keeps the
    /// field open with a sound.
    private func finishSidebarEdit(commit: Bool) {
        guard let sidebar = editingSidebar, let e = sidebar.tree.endEditing() else { return }
        invalidate()
        guard commit else { return }
        let name = e.field.text.trimmingCharacters(in: .whitespaces)
        func again() {
            fileProblem()
            switch e.kind {
            case .newFile(let parent): sidebar.tree.beginNew(folder: false, in: parent)
            case .newFolder(let parent): sidebar.tree.beginNew(folder: true, in: parent)
            case .rename(let entry): sidebar.tree.beginRename(entry)
            }
            sidebar.tree.updateEditing { $0 = TextFieldState(name) }
            invalidate()
        }
        switch e.kind {
        case .newFile(let parent), .newFolder(let parent):
            guard !name.isEmpty else { return }
            let isFolder: Bool = { if case .newFolder = e.kind { return true }; return false }()
            let unix = AnyPath.isUnix(parent)
            guard FileOps.isValidName(name, unix: unix), !sidebar.tree.contains(name, in: parent) else { return again() }
            let path = AnyPath.join(parent, name)
            if unix {
                onHost(sidebar, FileOps.remoteCreate(path, folder: isFolder)) { [weak self] ok, _ in
                    if ok { sidebar.tree.selection = path; self?.relist(parent, in: sidebar) } else { again() }
                }
            } else if isFolder ? FileOps.createFolder(path) : FileOps.createFile(path) {
                sidebar.tree.selection = path
                relist(parent, in: sidebar)
            } else {
                again()
            }
        case .rename(let entry):
            guard name != entry.name, let parent = AnyPath.parent(entry.path) else { return }
            let unix = AnyPath.isUnix(parent)
            guard FileOps.isValidName(name, unix: unix) else { return again() }
            if unix {
                let target = AnyPath.join(parent, name)
                onHost(sidebar, FileOps.remoteRename(entry.path, to: target)) { [weak self] ok, _ in
                    if ok { sidebar.tree.selection = target; self?.relist(parent, in: sidebar) } else { again() }
                }
            } else if let target = FileOps.rename(entry.path, to: name) {
                sidebar.tree.selection = target
                relist(parent, in: sidebar)
            } else {
                again()
            }
        }
    }

    // Copying, cutting and pasting

    private func copyFiles(_ paths: [String], cut: Bool, _ sidebar: FileSidebar) {
        guard !paths.isEmpty else { return }
        [left, right].forEach { $0.tree.cutPaths = [] }
        if AnyPath.isUnix(paths[0]) {
            guard let remote = remote(for: sidebar) else { return fileProblem() }
            hostClipboard = (paths, cut, remote, GetClipboardSequenceNumber())
        } else {
            hostClipboard = nil
            FileOps.putOnClipboard(paths, cut: cut, owner: hwnd)
        }
        if cut { sidebar.tree.cutPaths = Set(paths) }
        invalidate()
    }

    private var canPaste: Bool {
        if let h = hostClipboard, h.sequence == GetClipboardSequenceNumber() { return true }
        return IsClipboardFormatAvailable(UINT(15))
    }

    /// What's been cut or copied, here or in Explorer, into `folder`: moved if it was cut.
    private func pasteFiles(into folder: String, _ sidebar: FileSidebar) {
        let toHost = AnyPath.isUnix(folder)
        if let h = hostClipboard, h.sequence == GetClipboardSequenceNumber() {
            if toHost {
                guard let remote = remote(for: sidebar), remote === h.remote else { return fileProblem() }
                var taken = sidebar.tree.names(in: folder)
                let pairs = h.paths.compactMap { path -> (from: String, to: String)? in
                    if h.cut && AnyPath.parent(path) == folder { return nil }
                    let name = FileOps.uniqueName(AnyPath.name(path), taken: taken, copy: AnyPath.parent(path) == folder, caseSensitive: true)
                    taken.insert(name)
                    return (path, AnyPath.join(folder, name))
                }
                guard !pairs.isEmpty else { return }
                onHost(sidebar, FileOps.remoteTransfer(pairs, move: h.cut), timeout: 600) { [weak self] ok, _ in
                    if !ok { self?.fileProblem() }
                    self?.afterPaste(cut: h.cut, folders: [folder] + h.paths.compactMap(AnyPath.parent))
                }
            } else {
                download(h.paths, into: folder, sidebar, from: h.remote)
                if h.cut { hostClipboard = nil }
            }
            return
        }
        guard let files = FileOps.clipboardFiles(owner: hwnd) else { return fileProblem() }
        if toHost {
            upload(files.paths, into: folder, sidebar)
            return
        }
        sidebar.transfer = files.cut ? "Moving…" : "Copying…"
        invalidate()
        Thread.detachNewThread { [weak self] in
            let done = FileOps.transfer(files.paths, into: folder, move: files.cut)
            self?.runOnWindowThread {
                guard let self else { return }
                sidebar.transfer = nil
                if done.count < files.paths.count { self.fileProblem() }
                if let first = done.first { sidebar.tree.selection = first }
                self.afterPaste(cut: files.cut, folders: [folder] + files.paths.compactMap(WindowsPath.parent))
            }
        }
    }

    /// A cut's been pasted: nothing's waiting to move any more, and the folders on both sides are listed again.
    private func afterPaste(cut: Bool, folders: [String]) {
        if cut {
            [left, right].forEach { $0.tree.cutPaths = [] }
            hostClipboard = nil
        }
        for sidebar in [left, right] { Set(folders).forEach { relist($0, in: sidebar) } }
    }

    private func duplicate(_ entry: FileEntry, _ sidebar: FileSidebar) {
        guard let parent = AnyPath.parent(entry.path) else { return }
        if AnyPath.isUnix(parent) {
            let name = FileOps.uniqueName(entry.name, taken: sidebar.tree.names(in: parent), copy: true, caseSensitive: true)
            onHost(sidebar, FileOps.remoteTransfer([(entry.path, AnyPath.join(parent, name))], move: false), timeout: 600) { [weak self] ok, _ in
                if !ok { self?.fileProblem() }
                self?.relist(parent, in: sidebar)
            }
        } else {
            if let copy = FileOps.transfer([entry.path], into: parent, move: false).first { sidebar.tree.selection = copy } else { fileProblem() }
            relist(parent, in: sidebar)
        }
    }

    /// This PC's go to the Recycle Bin; a host's are gone for good, so it asks first.
    private func deleteFiles(_ entries: [FileEntry], _ sidebar: FileSidebar, x: Float, y: Float) {
        guard let first = entries.first else { return }
        let parents = Set(entries.compactMap { AnyPath.parent($0.path) })
        if AnyPath.isUnix(first.path) {
            let what = entries.count == 1 ? "“\(first.name)”" : "\(entries.count) items"
            openMenu([
                MenuItem(title: "Delete \(what) for good", isEnabled: false),
                .separator,
                MenuItem(title: "Delete") { [weak self] in
                    self?.onHost(sidebar, FileOps.remoteDelete(entries.map(\.path)), timeout: 600) { ok, _ in
                        if !ok { self?.fileProblem() }
                        parents.forEach { self?.relist($0, in: sidebar) }
                    }
                },
                MenuItem(title: "Cancel") {},
            ], x: x, y: y, above: false)
            return
        }
        if !FileOps.recycle(entries.map(\.path)) { fileProblem() }
        if entries.contains(where: { $0.path == sidebar.tree.selection }) { sidebar.tree.selection = nil }
        parents.forEach { relist($0, in: sidebar) }
    }

    // Between this PC and an ssh host

    private func upload(_ paths: [String], into folder: String, _ sidebar: FileSidebar, then: (() -> Void)? = nil) {
        guard let remote = remote(for: sidebar) else { return fileProblem() }
        var taken = sidebar.tree.names(in: folder)
        let jobs = paths.map { path -> (path: String, name: String) in
            let name = FileOps.uniqueName(WindowsPath.name(path), taken: taken, caseSensitive: true)
            taken.insert(name)
            return (path, name)
        }
        sidebar.transfer = "Uploading \(paths.count == 1 ? WindowsPath.name(paths[0]) : "\(paths.count) items")…"
        invalidate()
        Thread.detachNewThread { [weak self] in
            var failed = false
            for job in jobs {
                guard let data = FileOps.pack(job.path) else { failed = true; continue }
                let sent = DispatchSemaphore(value: 0)
                remote.run(FileOps.remoteUnpack(data, item: WindowsPath.name(job.path), into: folder, as: job.name), timeout: 600) { _, code in
                    if code != 0 { failed = true }
                    sent.signal()
                }
                sent.wait()
            }
            self?.runOnWindowThread {
                sidebar.transfer = nil
                if failed { self?.fileProblem() }
                self?.relist(folder, in: sidebar)
                then?()
            }
        }
    }

    private func download(_ paths: [String], into folder: String, _ sidebar: FileSidebar, from source: RemoteConnection? = nil) {
        guard let remote = source ?? remote(for: sidebar) else { return fileProblem() }
        sidebar.transfer = "Downloading \(paths.count == 1 ? AnyPath.name(paths[0]) : "\(paths.count) items")…"
        invalidate()
        Thread.detachNewThread { [weak self] in
            var failed = false, landed: [String] = []
            for path in paths {
                let got = DispatchSemaphore(value: 0)
                var text: String?
                remote.run(FileOps.remotePack(path), timeout: 600) { out, code in
                    text = code == 0 ? out : nil
                    got.signal()
                }
                got.wait()
                if let text, let at = FileOps.unpack(text, item: AnyPath.name(path), into: folder) { landed.append(at) } else { failed = true }
            }
            self?.runOnWindowThread {
                guard let self else { return }
                sidebar.transfer = nil
                if failed { self.fileProblem() }
                for s in [self.left, self.right] { self.relist(folder, in: s) }
                if let first = landed.first, folder == FileOps.downloadsFolder, !self.isTesting { FileOps.onReveal(first) }
            }
        }
    }

    /// Windows' Open dialog, for files to upload to the host.
    private func pickAndUpload(into folder: String, _ sidebar: FileSidebar) {
        var buffer = [UInt16](repeating: 0, count: 65536)
        var title = wide("Upload to \(AnyPath.name(folder))")
        let picked = buffer.withUnsafeMutableBufferPointer { file -> Bool in
            title.withUnsafeMutableBufferPointer { titleText -> Bool in
                var info = OPENFILENAMEW()
                info.lStructSize = DWORD(MemoryLayout<OPENFILENAMEW>.size)
                info.hwndOwner = hwnd
                info.lpstrFile = file.baseAddress
                info.nMaxFile = DWORD(file.count)
                info.lpstrTitle = UnsafePointer(titleText.baseAddress)
                info.Flags = DWORD(OFN_ALLOWMULTISELECT | OFN_EXPLORER | OFN_FILEMUSTEXIST | OFN_NOCHANGEDIR)
                return GetOpenFileNameW(&info)
            }
        }
        guard picked else { return }
        // One file is its whole path; several are the folder, then each name, NUL between and two at the end.
        var parts: [String] = [], start = 0
        for i in buffer.indices where buffer[i] == 0 {
            if i == start { break }
            parts.append(String(decoding: buffer[start..<i], as: UTF16.self))
            start = i + 1
        }
        let paths = parts.count == 1 ? parts : parts.dropFirst().map { WindowsPath.join(parts[0], $0) }
        upload(paths, into: folder, sidebar)
    }

    /// For tests: what the Open dialog would have handed over.
    func uploadForTest(_ paths: [String], into folder: String) { upload(paths, into: folder, left) }
    func downloadForTest(_ paths: [String], into folder: String) { download(paths, into: folder, left) }

    private var isTesting: Bool { CommandLine.arguments.contains("--window-test") }

    // Dragging and dropping

    /// Where a drag over a point would drop: a sidebar and its folder there, or a terminal.
    private enum DropSpot { case folder(FileSidebar, String), terminal(TerminalPane) }

    private func dropSpot(atX x: Float, y: Float) -> DropSpot? {
        switch layout.part(atX: x, y: y) {
        case .leftSidebar, .rightSidebar:
            let sidebar = layout.part(atX: x, y: y) == .leftSidebar ? left : right
            let l = sidebarLayout(sidebar)
            let row = l.visibleRow(atY: y).map { $0 + sidebar.tree.scrollTop }.flatMap { sidebar.tree.rows.indices.contains($0) ? sidebar.tree.rows[$0] : nil }
            return targetFolder(row?.entry, in: sidebar).map { .folder(sidebar, $0) }
        case .terminal:
            return .terminal(pane(atX: x))
        default:
            return nil
        }
    }

    /// A path as the shell in a tab would read it: in quotes when it has spaces or the like.
    private func shellWord(_ path: String) -> String {
        if AnyPath.isUnix(path) { return path.contains(where: { " '\"$`\\()&;|<>*?![]{}".contains($0) }) ? RemoteConnection.quote(path) : path }
        return path.contains(where: { " '`$&()[]{};,@#".contains($0) }) ? "'" + path.replacingOccurrences(of: "'", with: "''") + "'" : path
    }

    /// Files dropped somewhere: into a folder (copied or moved, uploaded or downloaded) or into a terminal, as their paths.
    private func drop(_ paths: [String], at spot: DropSpot, from source: FileSidebar?, copy: Bool) {
        switch spot {
        case .terminal(let pane):
            if pane !== activePane, let i = panes.firstIndex(where: { $0 === pane }) { activate(i) }
            focusTerminal()
            pane.pasteText(paths.map(shellWord).joined(separator: " ") + " ")
        case .folder(let sidebar, let folder):
            let fromHost = paths.first.map(AnyPath.isUnix) ?? false, toHost = AnyPath.isUnix(folder)
            switch (fromHost, toHost) {
            case (false, false):
                Thread.detachNewThread { [weak self] in
                    let done = FileOps.transfer(paths, into: folder, move: !copy)
                    self?.runOnWindowThread {
                        if done.isEmpty { self?.fileProblem() }
                        self?.afterPaste(cut: false, folders: [folder] + paths.compactMap(WindowsPath.parent))
                    }
                }
            case (false, true):
                upload(paths, into: folder, sidebar)
            case (true, false):
                download(paths, into: folder, sidebar, from: source.flatMap { remote(for: $0) })
            case (true, true):
                guard let source, let from = remote(for: source), from === remote(for: sidebar) else { return fileProblem() }
                var taken = sidebar.tree.names(in: folder)
                let pairs = paths.compactMap { path -> (from: String, to: String)? in
                    if !copy && AnyPath.parent(path) == folder { return nil }
                    if folder == path || folder.hasPrefix(path + "/") { return nil }
                    let name = FileOps.uniqueName(AnyPath.name(path), taken: taken, copy: AnyPath.parent(path) == folder, caseSensitive: true)
                    taken.insert(name)
                    return (path, AnyPath.join(folder, name))
                }
                guard !pairs.isEmpty else { return }
                onHost(sidebar, FileOps.remoteTransfer(pairs, move: !copy), timeout: 600) { [weak self] ok, _ in
                    if !ok { self?.fileProblem() }
                    self?.afterPaste(cut: false, folders: [folder] + paths.compactMap(AnyPath.parent))
                }
            }
        }
    }

    /// Files dropped from Explorer.
    private func droppedFromExplorer(_ wParam: WPARAM) {
        guard let raw = UnsafeMutableRawPointer(bitPattern: UInt(wParam)) else { return }
        let drop = HDROP(OpaquePointer(raw))
        var point = POINT()
        _ = DragQueryPoint(drop, &point)
        let paths = FileOps.paths(in: drop)
        DragFinish(drop)
        guard !paths.isEmpty, let spot = dropSpot(atX: Float(point.x), y: Float(point.y)) else { return }
        // From Explorer, a drop copies, as it does between drives there.
        drop(paths, at: spot, from: nil, copy: true)
        invalidate()
    }

    /// For tests: files dropped from Explorer at a point, as Explorer hands them over.
    func dropFilesForTest(_ paths: [String], atX x: Float, y: Float) {
        guard let list = FileOps.dropList(paths), let raw = GlobalLock(list) else { return }
        raw.storeBytes(of: Int32(x), toByteOffset: 4, as: Int32.self)
        raw.storeBytes(of: Int32(y), toByteOffset: 8, as: Int32.self)
        GlobalUnlock(list)
        _ = SendMessageW(hwnd, Win.WM_DROPFILES, WPARAM(UInt(bitPattern: list)), 0)
    }

    // MARK: - Menus

    var isMenuOpen: Bool { menu != nil }
    var tabCount: Int { panes.count }

    /// As they show: with Alt held, the alternates.
    var menuTitles: [String] { menu.map { m in m.items.indices.map { m.title($0) } } ?? [] }

    /// The keys each item shows at its right.
    var menuShortcuts: [String: String] {
        guard let menu else { return [:] }
        return Dictionary(menu.items.indices.map { (menu.title($0), menu.items[$0].shortcut) }, uniquingKeysWith: { a, _ in a })
    }

    func menuRow(_ title: String) -> UIRect? {
        guard let menu, let i = menu.items.indices.first(where: { menu.title($0) == title }) else { return nil }
        return menu.rect(i)
    }

    private func openMenu(_ items: [MenuItem], x: Float, y: Float, above: Bool) {
        menu = MenuModel(items: items, anchorX: x, anchorY: y, above: above, width: MenuView.width(for: items, canvas: canvas, scale: scale),
                         window: UIRect(x: 0, y: 0, width: Float(clientWidth), height: Float(clientHeight)), scale: scale)
        menu?.showsAlternates = GetKeyState(Win.VK_MENU) < 0
        invalidate()
    }

    /// Alt pressed or let go while a menu is open: its items with an alternate switch to it, and back.
    func menuAltChanged(_ down: Bool) {
        guard let menu, menu.showsAlternates != down else { return }
        menu.showsAlternates = down
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
                let run = menu.action(row)
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
                let run = menu.action(i)
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
        if AnyPath.isUnix(folder) {
            activePane.changeDirectory(to: folder)
            focusTerminal()
        } else if activePane.atPrompt {
            activePane.changeDirectory(to: folder)
        } else {
            // What's running keeps its place, as on the Mac.
            addPane(cwd: folder)
        }
    }

    /// The folders in one of the path's parts, with what else there is to do with it.
    private func showCrumbMenu(_ crumb: (label: String, path: String, rect: UIRect, hit: UIRect), copyOnly: Bool) {
        let unix = AnyPath.isUnix(crumb.path)
        let current = unix ? activePane.remoteTerminalFolder : activePane.terminal.cwd
        let copy = MenuItem(title: "Copy Path") { [weak self] in self?.activePane.setClipboard(crumb.path) }
        let pin = pinItem(crumb.path, current: current)
        guard !copyOnly else {
            openMenu([pin, copy], x: crumb.rect.x, y: crumb.rect.y - 2 * scale, above: true)
            return
        }
        var goTo = MenuItem(title: "Go to Folder…") { [weak self] in self?.showGoToFolder() }
        goTo.shortcut = "Ctrl+Shift+O"
        // Unix paths are case-sensitive; Windows ones aren't.
        func same(_ a: String) -> String { unix ? a : a.lowercased() }
        let show: ([FileEntry]?) -> Void = { [weak self] entries in
            self?.runOnWindowThread {
                guard let self else { return }
                let sorted = FileTree.sortedForDisplay((entries ?? []).filter { $0.isDirectory && !$0.isHidden }).prefix(400)
                var items = [goTo, pin, copy, MenuItem.separator]
                if same(crumb.path) != current.map(same) {
                    items.append(MenuItem(title: "Go to \(crumb.label)") { [weak self] in self?.goTo(folder: crumb.path) })
                    items.append(.separator)
                }
                let separator = unix ? "/" : "\\"
                for folder in sorted {
                    let onPath = current.map { same($0) == same(folder.path) || same($0).hasPrefix(same(folder.path) + separator) } ?? false
                    items.append(MenuItem(title: folder.name, isChecked: onPath) { [weak self] in self?.goTo(folder: folder.path) })
                }
                if sorted.isEmpty { items.append(MenuItem(title: entries == nil ? "Couldn't read this folder" : "No folders inside", isEnabled: false)) }
                self.openMenu(items, x: crumb.rect.x, y: crumb.rect.y - 2 * self.scale, above: true)
            }
        }
        if unix {
            // On the host, through the sidebar's connection.
            guard let remote = activePane.remote else { return show(nil) }
            remote.list(crumb.path) { show($0) }
        } else {
            Thread.detachNewThread { show(FileSidebar.list(crumb.path)) }
        }
    }

    /// Keeps the left sidebar on a folder from the path while the terminal goes elsewhere, or, when it's already pinned
    /// there, lets it follow the terminal again. Ctrl+Shift+B shows beside it when that does the same.
    private func pinItem(_ folder: String, current: String?) -> MenuItem {
        let unix = AnyPath.isUnix(folder)
        func same(_ a: String?, _ b: String?) -> Bool { unix ? a == b : a?.lowercased() == b?.lowercased() }
        let unpins = same(left.pinned, folder)
        var item = MenuItem(title: unpins ? "Unpin Sidebar" : "Pin in Sidebar") { [weak self] in self?.pinLeft(to: unpins ? nil : folder) }
        item.icon = unpins ? 0xE77A : 0xE718
        if unpins || (left.pinned == nil && same(folder, current)) { item.shortcut = "Ctrl+Shift+B" }
        return item
    }

    /// Pins the left sidebar to `folder`, opening it if it's closed; nil unpins it.
    private func pinLeft(to folder: String?) {
        if let folder {
            if !left.isVisible { toggleSidebar(left) }
            left.pinned = folder
            left.tree.setRoot(folder)
        } else {
            left.pinned = nil
            left.followed = nil
            followTerminalFolder()
        }
        invalidate()
    }

    /// The status bar's folder parts under the pointer. True if it dealt with the mouse.
    private func statusBarMouse(_ message: UINT, x: Float, y: Float) -> Bool {
        let bar = chrome(on: canvas, layout: layout)
        // While split, the right column's half follows the left one's.
        let leftSpots = bar.crumbSpots(), spots = leftSpots + (isSplit ? bar.crumbSpots(column: 1) : [])
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
            // The column whose folder it is gets the keyboard, so what the menu does happens there.
            let owner = hit < leftSpots.count ? leftActivePane : rightActivePane ?? activePane
            if owner !== activePane, let i = panes.firstIndex(where: { $0 === owner }) { activate(i) }
            showCrumbMenu(spots[hit], copyOnly: message == Win.WM_RBUTTONUP)
            return true
        default:
            return hit != nil
        }
    }

    /// The rectangle of a part of the path in the status bar, for clicking it.
    func crumbRect(_ label: String, column: Int = 0) -> UIRect? {
        chrome(on: canvas, layout: layout).crumbSpots(column: column).first { $0.label == label }?.rect
    }

    /// The folder icon at the start of the path.
    var folderIconRect: UIRect? {
        guard let first = chrome(on: canvas, layout: layout).crumbSpots().first else { return nil }
        return UIRect(x: first.hit.x + 2, y: first.hit.y, width: 8 * scale, height: first.hit.height)
    }

    // MARK: - ssh

    /// A question from ssh in one of this window's tabs: that tab shows it, coming to the front if it isn't already.
    private func answerAskpass(_ request: Askpass.Request, _ reply: @escaping (String?) -> Void) {
        if let pane = panes.first(where: { $0.remote?.token == request.token }) {
            pane.answerForRemote(request.prompt, reply: reply)
            invalidate()
            return
        }
        guard let i = panes.firstIndex(where: { $0.askpassToken == request.token }) else { return reply(nil) }
        if i != activeIndex { selectTab(i) }
        panes[i].answerForTerminal(request.prompt, reply: reply)
        invalidate()
    }

    /// The pane's "Lost connection" bar takes the clicks over it, not the terminal underneath.
    private func lostBarMouse(_ message: UINT, x: Float, y: Float) -> Bool {
        let pane = self.pane(atX: x)
        let button = pane.lostBarButton(atX: x, y: y)
        if pane.hoveredLostButton != button {
            pane.hoveredLostButton = button
            invalidate()
        }
        guard pane.lostBarContains(x: x, y: y) else { return false }
        if message == Win.WM_MOUSEMOVE { setHovered(.terminal, nonClient: false) }
        if message == Win.WM_LBUTTONUP, let button {
            switch button {
            case .reconnect:
                pane.reconnect()
                focusTerminal()
            case .close:
                pane.dismissLost()
                if let i = panes.firstIndex(where: { $0 === pane }) { closeTab(i) }
            }
        }
        return true
    }

    /// Hosts from ~/.ssh/config and known_hosts, as on the Mac. A new tab connects; with Alt held, this one does.
    private func showHostsMenu() {
        let folder = (ProcessInfo.processInfo.environment["USERPROFILE"] ?? "") + "\\.ssh"
        let (configured, known) = SSHHostList.load(sshFolder: folder)
        func connect(_ host: SSHHostEntry, here: Bool) {
            let command = "ssh " + host.target
            // In this pane only when its shell is at a prompt to take it; otherwise a new tab, rather than typing into
            // whatever's running.
            if !(here && activePane.atPrompt) { newTab() }
            activePane.pendingCommand = command
        }
        // Hold Alt to connect in this pane instead of a new tab, as Option does on the Mac.
        func item(_ host: SSHHostEntry, title: String) -> MenuItem {
            var item = MenuItem(title: title) { connect(host, here: false) }
            item.alternate = ("\(host.title) — in This Pane", { connect(host, here: true) })
            return item
        }
        var items = [MenuItem(title: configured.isEmpty ? "No hosts in ~\\.ssh\\config" : "Connect in a new tab (Alt: this pane)", isEnabled: false)]
        items += configured.map { host in item(host, title: host.title + (host.detail.map { "  —  " + $0 } ?? "")) }
        if !known.isEmpty {
            items += [.separator, MenuItem(title: "Known Hosts", isEnabled: false)]
            items += known.prefix(60).map { host in item(host, title: host.title) }
        }
        items += [.separator, MenuItem(title: "Edit SSH Config…") {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let config = folder + "\\config"
            if !FileManager.default.fileExists(atPath: config) { _ = FileManager.default.createFile(atPath: config, contents: Data()) }
            _ = wide(config).withUnsafeBufferPointer { ShellExecuteW(nil, nil, $0.baseAddress, nil, nil, 1) }
        }]
        let anchor = layout.hostsButton
        openMenu(items, x: anchor.x, y: anchor.y - 2 * scale, above: true)
    }

    var hostsButtonRect: UIRect { layout.hostsButton }

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
            // Within its own column's strip; let go over the other column's, it moves there.
            let l = layout, column = l.column(ofTab: press.index), v = l.tabViewport(column: column), w = l.tabWidth(column: column)
            let range = l.tabRange(column: column)
            draggedX = min(max(x - press.grab, v.x), max(v.maxX - w, v.x))
            // It trades places with a neighbor as it passes halfway over it, as on the Mac.
            var moved = true
            while moved {
                moved = false
                let floating = UIRect(x: draggedX, y: 0, width: w, height: 1)
                if press.index + 1 < range.upperBound, floating.maxX > l.tab(press.index + 1).x + w / 2 {
                    moveTab(from: press.index, to: press.index + 1)
                    press.index += 1
                    moved = true
                } else if press.index > range.lowerBound, floating.x < l.tab(press.index - 1).x + w / 2 {
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
                let pane = panes[press.index], l = layout
                let over = l.isSplit ? (x >= l.divider ? 1 : 0) : pane.column
                tabPress = nil
                if over != pane.column {
                    // Dropped on the other column's strip: into it, where it was let go.
                    let target = l.tabRange(column: over)
                    let at = target.first { l.tab($0).x + l.tab($0).width / 2 > x } ?? target.upperBound
                    moveToOtherColumn(pane, at: at > press.index ? at - 1 : at)
                } else {
                    TabGroupOps.settle(pane, in: panes)
                }
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
        _ = SendMessageW(hwnd, Win.WM_LBUTTONDOWN, 1, at(Int(r.x + 20)))
        _ = SendMessageW(hwnd, Win.WM_MOUSEMOVE, 1, at(Int(x)))
        _ = SendMessageW(hwnd, Win.WM_LBUTTONUP, 0, at(Int(x)))
    }

    /// Keys while a sidebar has the focus. False hands the key on, and typing goes back to the terminal.
    private func sidebarKey(_ key: Int32, _ sidebar: FileSidebar, shift: Bool, ctrl: Bool, alt: Bool) -> Bool {
        let tree = sidebar.tree
        let selected = tree.selectedIndex.map { tree.rows[$0].entry }
        // Explorer's keys for files.
        switch key {
        case Win.VK_F2 where !ctrl && !alt:
            if let selected { beginRename(selected, sidebar) }
            return true
        case Win.VK_DELETE where !ctrl && !alt:
            if let selected, let i = tree.selectedIndex {
                let r = sidebarLayout(sidebar).row(i - tree.scrollTop)
                deleteFiles([selected], sidebar, x: r.x + 24 * scale, y: r.maxY)
            }
            return true
        case 0x43 where ctrl && shift && !alt:
            if let selected { activePane.setClipboard(selected.path) }
            return true
        case 0x43 where ctrl && !alt, 0x58 where ctrl && !alt:
            if let selected { copyFiles([selected.path], cut: key == 0x58, sidebar) }
            return true
        case 0x56 where ctrl && !alt:
            if let folder = targetFolder(selected, in: sidebar) { pasteFiles(into: folder, sidebar) }
            return true
        case 0x4E where ctrl && shift && !alt:
            if let folder = targetFolder(selected, in: sidebar) { beginNew(folder: true, in: folder, sidebar) }
            return true
        default: break
        }
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
            guard let g = panes[i].group, i == 0 || panes[i - 1].group !== g || panes[i - 1].column != panes[i].column else { return nil }
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
        let wasSplit = isSplit
        normalizeColumns()
        if isSplit != wasSplit { layoutChanged() }
        settleTabScroll()
        invalidate()
    }

    /// A group is in one column: tabs going into it go there too.
    private func bring(_ list: [TerminalPane], toColumn column: Int) {
        guard list.contains(where: { $0.column != column }) else { return }
        list.forEach { $0.column = column }
        let wasSplit = isSplit
        normalizeColumns()
        if isSplit != wasSplit { layoutChanged() } else { resizePanes() }
    }

    func addToNewGroup(_ list: [TerminalPane]) {
        if let first = list.first { bring(list, toColumn: first.column) }
        var created: TabGroup?
        reorder { created = TabGroupOps.addToNewGroup(&$0, picked: list) }
        pickedTabs = []
        // Named straight away, as on the Mac.
        if let created { beginNaming(.group(created), text: "") }
    }

    private func add(_ list: [TerminalPane], to group: TabGroup) {
        if let member = panes.first(where: { $0.group === group }) { bring(list, toColumn: member.column) }
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
            let order = panes.indices.filter { panes[$0].column == activePane.column }.sorted { abs($0 - activeIndex) < abs($1 - activeIndex) }
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

    /// Whether a part of the window is the tab or chip whose name is being typed.
    private func isOnNameField(_ part: WindowPart) -> Bool {
        guard let naming else { return false }
        switch (naming.target, part) {
        case (.tab(let id), .tab(let i)): return panes.indices.contains(i) && panes[i].id == id
        case (.group(let g), .chip(let first)): return panes.indices.contains(first) && panes[first].group === g
        default: return false
        }
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
        if isSplit || panes.count > 1 {
            var move = MenuItem(title: isSplit ? "Move to Other Split" : "Move to New Split") { [weak self] in self?.moveToOtherColumn(pane) }
            move.shortcut = "Ctrl+Shift+D"
            items += [.separator, move]
        }
        if isSplit { items.append(MenuItem(title: "Close Split") { [weak self] in self?.closeSplit() }) }
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

    // MARK: - Go to Folder

    /// Folder listings for Go to Folder, by path, while it's open: nil inside while an ssh host's is on its way.
    private var goToListings: [String: [FileEntry]?] = [:]

    /// Where Go to Folder looks: this PC, or the host of an ssh tab once the sidebar's connection is up.
    private func goToPlace() -> (paths: GoToPaths, remote: RemoteConnection?)? {
        guard !panes.isEmpty else { return nil }
        let pane = activePane
        if pane.sshArguments != nil {
            guard let remote = pane.remote, remote.state == .ready, let home = remote.home else { return nil }
            return (GoToPaths(unix: true, base: pane.remoteFolder ?? home, home: home), remote)
        }
        let home = ProcessInfo.processInfo.environment["USERPROFILE"] ?? #"C:\"#
        return (GoToPaths(unix: false, base: pane.terminal.cwd ?? home, home: home), nil)
    }

    /// Ctrl+Shift+O: a palette whose field is just a path, starting at the terminal's folder. Ctrl+Backspace clears it
    /// for typing one afresh. Enter goes there in this tab (or a new one, with Ctrl), Tab goes into the folder picked.
    func showGoToFolder(path: String? = nil) {
        goToListings = [:]
        let place = goToPlace()
        let start = path ?? place.map { $0.paths.field($0.paths.base) } ?? ""
        let waiting = activePane.sshArguments != nil && place == nil
        palette = PaletteModel(query: start, placeholder: "Go to folder: a path, ~\\…, or a folder in this one", icon: 0xE8B7,
                               emptyMessage: waiting ? "Waiting for the ssh connection…" : "No folders") { [weak self] typed in
            self?.goToItems(typed) ?? []
        }
        hoveredPaletteRow = nil
        activePane.setFocused(false)
        invalidate()
    }

    /// The folders in `dir`, or nil while an ssh host's are on their way (the rows are worked out again when they come).
    private func goToFolders(in dir: String, remote: RemoteConnection?) -> [FileEntry]? {
        if let listed = goToListings[dir] { return listed }
        guard let remote else {
            let entries = (FileSidebar.list(dir) ?? []).filter(\.isDirectory)
            goToListings[dir] = entries
            return entries
        }
        goToListings[dir] = .some(nil)
        remote.list(dir) { [weak self] entries in
            self?.runOnWindowThread {
                guard let self, let palette = self.palette, palette.isLive else { return }
                self.goToListings[dir] = (entries ?? []).filter(\.isDirectory)
                palette.refresh()
                self.invalidate()
            }
        }
        return nil
    }

    /// Whether `path` is a folder; nil while that's not known yet.
    private func isGoToFolder(_ path: String, _ paths: GoToPaths, remote: RemoteConnection?) -> Bool? {
        guard remote != nil else {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        guard let up = paths.parent(path) else { return true }
        return goToFolders(in: up, remote: remote)?.contains { $0.name == AnyPath.name(path) }
    }

    /// Go to Folder's rows for what's typed: opening that folder, then the folders that start with its last part (or,
    /// when it ends at a folder, the ones inside), as on the Mac.
    private func goToItems(_ raw: String) -> [PaletteItem] {
        guard let place = goToPlace() else { return [] }
        let paths = place.paths, remote = place.remote
        let typed = paths.cleaned(raw)
        let target = paths.resolve(typed.isEmpty ? "." : typed)
        // Here is a cd typed at the prompt; over ssh, whenever the session isn't in a full-screen program.
        let here = remote == nil ? activePane.atPrompt : activePane.canChangeRemoteFolder
        let newTab: ((String) -> Void)? = remote == nil ? { [weak self] dir in _ = self?.addPane(cwd: dir) } : nil
        let open: (String) -> Void = { [weak self] dir in
            guard let self else { return }
            if here { self.activePane.changeDirectory(to: dir); self.focusTerminal() } else { newTab?(dir) }
        }
        func shown(_ p: String) -> String { paths.shown(p) }
        var out: [PaletteItem] = []
        let isFolder = isGoToFolder(target, paths, remote: remote)
        if isFolder == true {
            if here {
                var item = PaletteItem(title: "Open \(shown(target)) Here", category: "cd in this tab", shortcut: "Enter") { open(target) }
                item.alternate = newTab.map { f in { f(target) } }
                out.append(item)
                if let newTab { out.append(PaletteItem(title: "Open \(shown(target)) in a New Tab", shortcut: "Ctrl+Enter") { newTab(target) }) }
            } else if let newTab {
                out.append(PaletteItem(title: "Open \(shown(target)) in a New Tab", category: "a program is running here", shortcut: "Enter") { newTab(target) })
            } else {
                out.append(.header("A program is running here: go once it's done"))
            }
        }
        let inside = typed.isEmpty || paths.endsInSeparator(typed) || (isFolder == true && typed.hasSuffix("."))
        let parent = inside ? target : paths.parent(target) ?? target
        let stem = inside ? "" : paths.lastPart(typed).lowercased()
        let typedParent = paths.typedParent(typed)
        guard let listed = goToFolders(in: parent, remote: remote) else {
            out.append(.header("Loading \(shown(parent))…"))
            return out
        }
        let names = FileTree.sortedForDisplay(listed.filter {
            let name = $0.name.lowercased()
            return name.hasPrefix(stem) && (!$0.isHidden || stem.hasPrefix(".")) && (inside || name != stem)
        }).prefix(30)
        if inside { out.append(.header("In \(shown(parent))")) } else if !names.isEmpty { out.append(.header("Folders")) }
        if inside, let up = paths.parent(parent) {
            var item = PaletteItem(title: "..", category: "Parent folder", shortcut: "Tab") { [weak self] in self?.showGoToFolder(path: paths.field(up)) }
            item.completion = paths.field(up)
            out.append(item)
        }
        for entry in names {
            let dir = AnyPath.join(parent, entry.name)
            var item = PaletteItem(title: entry.name, category: shown(parent), shortcut: "Tab") { open(dir) }
            item.alternate = newTab.map { f in { f(dir) } }
            item.completion = typedParent + entry.name + paths.separator
            out.append(item)
        }
        if out.allSatisfy(\.isHeader) && !(inside && out.count == 1) { out.append(.header("No folder at \(shown(target))")) }
        return out
    }

    // MARK: - Shortcuts

    /// Every shortcut, as Settings › Shortcuts lists them. Ctrl stands in for the Mac's Command.
    static let shortcutGroups: [(title: String, items: [(title: String, keys: String)])] = [
        ("Solanum", [("Settings…", "Ctrl+,"), ("Command Palette…", "Ctrl+Shift+P")]),
        ("Shell", [("New Tab", "Ctrl+T"), ("New Tab in Group", "Ctrl+Alt+T"), ("Reopen Closed Tab", "Ctrl+Shift+T"), ("Go to Folder…", "Ctrl+Shift+O"),
                   ("Split Right", "Ctrl+Alt+D"), ("Move Tab to Other Split", "Ctrl+Shift+D"), ("Close Split", "Ctrl+Alt+W"), ("Close Tab", "Ctrl+W"),
                   ("Close Tab (also)", "Ctrl+Shift+W"), ("Rename Tab…", "Ctrl+Shift+I"), ("Add Tab to New Group", "Ctrl+Alt+G")]),
        ("Tabs", [("Pick another tab", "Ctrl+Click"), ("Pick the tabs between", "Shift+Click"), ("Collapse or expand a group", "Click its chip")]),
        ("Edit", [("Copy (with something selected)", "Ctrl+C"), ("Stop the program (with nothing selected)", "Ctrl+C"), ("Cut (in the line being typed)", "Ctrl+X"),
                  ("Paste", "Ctrl+V"), ("Paste (also)", "Shift+Insert"), ("Undo (PowerShell and Claude Code)", "Ctrl+Z")]),
        ("View", [("Toggle File Sidebar", "Ctrl+B"), ("Toggle Right Sidebar (split)", "Ctrl+Alt+B"), ("Pin Sidebar Folder", "Ctrl+Shift+B"), ("Scroll Back a Page", "Shift+PageUp"), ("Scroll Forward a Page", "Shift+PageDown")]),
        ("Window", [("Next Tab", "Ctrl+Tab"), ("Previous Tab", "Ctrl+Shift+Tab"), ("Go to Tab 1 to 9", "Ctrl+1"), ("Close Window", "Alt+F4")]),
    ]

    // MARK: - Command palette

    var isPaletteOpen: Bool { palette != nil }
    var paletteRows: [PaletteItem] { palette?.rows ?? [] }
    var paletteSelection: PaletteItem? { palette?.selectedItem }
    var paletteQuery: String? { palette?.query }

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
            PaletteItem(title: "Go to Folder…", category: "Shell", shortcut: "Ctrl+Shift+O") { [weak self] in self?.showGoToFolder() },
            PaletteItem(title: "Split Right", category: "Shell", shortcut: "Ctrl+Alt+D") { [weak self] in self?.splitRight() },
            PaletteItem(title: isSplit ? "Move Tab to Other Split" : "Move Tab to New Split", category: "Shell", shortcut: "Ctrl+Shift+D") { [weak self] in
                self.map { $0.moveToOtherColumn($0.activePane) }
            },
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
        if isSplit {
            items.append(PaletteItem(title: "Close Split", category: "Shell", shortcut: "Ctrl+Alt+W") { [weak self] in self?.closeSplit() })
            items.append(PaletteItem(title: "Focus Other Split", category: "Window") { [weak self] in self?.focusOtherColumn() })
            items.append(PaletteItem(title: "Toggle Right Sidebar", category: "View", shortcut: "Ctrl+Alt+B") { [weak self] in self.map { $0.toggleSidebar($0.right) } })
        }
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
        if !palette.isLive {
            palette.noteRun(item)
            paletteRecents = palette.recents
            Self.savePaletteRecents(paletteRecents)
        }
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
        case Win.VK_RETURN:
            // Ctrl+Enter: Go to Folder's new tab.
            if ctrl, let alternate = palette.selectedItem?.alternate {
                closePalette()
                alternate()
                return true
            }
            runPalette()
        case Win.VK_TAB:
            if let completion = palette.selectedItem?.completion { palette.setQuery(completion) }
        case Win.VK_UP: palette.moveSelection(by: -1)
        case Win.VK_DOWN: palette.moveSelection(by: 1)
        case Win.VK_PRIOR: palette.moveSelection(by: -PaletteModel.maxRows)
        case Win.VK_NEXT: palette.moveSelection(by: PaletteModel.maxRows)
        case Win.VK_LEFT: palette.moveCaret(by: -1)
        case Win.VK_RIGHT: palette.moveCaret(by: 1)
        case Win.VK_HOME: palette.moveCaret(to: 0)
        case Win.VK_END: palette.moveCaret(to: palette.query.count)
        // In a path, Ctrl+Backspace clears the field for typing one afresh, as ⌘⌫ does on the Mac.
        case Win.VK_BACK where ctrl && palette.isLive: palette.deleteToStart()
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
        if !panes.isEmpty, activePane.hasQuestion { return activePane.questionKey(key, ctrl: ctrl) }
        if naming != nil { return namingKey(key, ctrl: ctrl) }
        if editingSidebar != nil { return sidebarEditKey(key, ctrl: ctrl) }
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
        if ctrl && shift && !alt && key == 0x4F {
            if palette?.isLive == true { closePalette() } else { showGoToFolder() }
            return true
        }
        if palette != nil { return paletteKey(key, ctrl: ctrl) }
        // Ctrl+B and Ctrl+Alt+B show and hide the sidebars, and Ctrl+Shift+B pins the left one to its folder.
        if ctrl && key == 0x42 {
            if alt {
                if isSplit { toggleSidebar(right) }
            } else if shift {
                togglePin(left)
            } else {
                toggleSidebar(left)
            }
            return true
        }
        // Splits, as the Mac's ⌘D, ⇧⌘D and ⌃⌘W: Ctrl+D itself stays the shell's (end of input).
        if ctrl && alt && !shift && key == 0x44 { splitRight(); return true }
        if ctrl && shift && !alt && key == 0x44 { moveToOtherColumn(activePane); return true }
        if ctrl && alt && !shift && key == 0x57 { closeSplit(); return true }
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
        // In the column with the keyboard, while split.
        if ctrl && !alt && (0x31...0x39).contains(key) {
            selectTab(inColumn: Int(key) - 0x31)
            return true
        }
        let column = panes.indices.filter { panes[$0].column == activePane.column }
        if ctrl && !alt && key == Win.VK_TAB && column.count > 1, let at = column.firstIndex(of: activeIndex) {
            selectTab(column[(at + (shift ? column.count - 1 : 1)) % column.count])
            return true
        }
        return activePane.keyDown(key, shift: shift, ctrl: ctrl, alt: alt)
    }

    /// Runs in the message loop, ahead of TranslateMessage. True if a key is dealt with, and shouldn't become a character.
    static func preprocess(_ message: inout MSG) -> Bool {
        // Alt, while a menu is open, swaps in its items' alternates. Kept from Windows, which would otherwise take a lone
        // Alt as going to the window's own menu.
        if [Win.WM_KEYDOWN, Win.WM_SYSKEYDOWN, Win.WM_KEYUP, Win.WM_SYSKEYUP].contains(message.message),
           Int32(truncatingIfNeeded: message.wParam) == Win.VK_MENU, let hwnd = message.hwnd, let window = windows[hwnd], window.menu != nil {
            window.menuAltChanged(message.message == Win.WM_KEYDOWN || message.message == Win.WM_SYSKEYDOWN)
            return true
        }
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
        _ = SendMessageW(hwnd, Win.WM_LBUTTONDOWN, 1, position)
        _ = SendMessageW(hwnd, Win.WM_LBUTTONUP, 0, position)
    }

    /// Clicks a button on the active tab's "Lost connection" bar.
    func clickLostBar(_ button: TerminalPane.LostBarButton) {
        guard let l = activePane.lostBarLayout() else { return }
        click(button == .reconnect ? l.reconnect : l.close)
    }

    var currentLayout: WindowLayout { layout }
    var fontCellHeight: Float { canvas.metrics.cellHeight }

    var isDraggingTab: Bool { tabPress != nil }
    var groupNames: [String] { TabGroupOps.groups(in: panes).map(\.name) }
    var isNaming: Bool { naming != nil }
    var paneNameField: String? { naming?.field.text }
    var hoveredPart: WindowPart? { hovered }
    var leftShown: Float { left.shown }
    /// The pointer over a rectangle, handled before this returns, so a real pointer elsewhere can't get in first.
    func hover(_ rect: UIRect) {
        let position = LPARAM(Int(rect.x + rect.width / 2) & 0xFFFF) | (LPARAM(Int(rect.y + rect.height / 2) & 0xFFFF) << 16)
        _ = SendMessageW(hwnd, Win.WM_MOUSEMOVE, 0, position)
    }
    func pickForTest(_ i: Int, range: Bool) { pick(i, range: range) }
    func chipRect(_ first: Int) -> UIRect? { layout.chip(first) }
    func rightClick(_ rect: UIRect) {
        let position = LPARAM(Int(rect.x + rect.width / 2) & 0xFFFF) | (LPARAM(Int(rect.y + rect.height / 2) & 0xFFFF) << 16)
        _ = SendMessageW(hwnd, Win.WM_RBUTTONDOWN, 2, position)
        _ = SendMessageW(hwnd, Win.WM_RBUTTONUP, 0, position)
    }
    func typeIntoWindow(_ text: String) { for unit in text.utf16 { PostMessageW(hwnd, Win.WM_CHAR, WPARAM(unit), 0) } }
    var leftTree: FileTree { left.tree }
    var rightTree: FileTree { right.tree }
    var splitColumnCounts: [Int] { isSplit ? [panes.filter { $0.column == 0 }.count, panes.filter { $0.column == 1 }.count] : [panes.count] }
    var focusedColumn: Int { activePane.column }
    var shownPaneIDs: [UInt] { visiblePanes.map(\.id) }
    func paneArea(_ pane: TerminalPane) -> UIRect { area(for: pane) }
    func toggleRightSidebarForTest() { toggleSidebar(right) }
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
    /// Below the left sidebar's rows, where its menu is the folder's own.
    var leftListEmptySpot: UIRect {
        let l = sidebarLayout(left).list
        return UIRect(x: l.x + 20, y: l.maxY - 30, width: 4, height: 4)
    }
    var leftEditingText: String? { left.tree.editing?.field.text }

    /// Presses a row of the left sidebar and lets go over another's, as dragging it there would.
    func dragLeftRow(_ from: String, onto to: String) {
        guard let a = leftRow(named: from), let b = leftRow(named: to) else { return }
        func at(_ r: UIRect, _ dx: Float = 0) -> LPARAM { LPARAM(Int(r.x + 30 + dx) & 0xFFFF) | (LPARAM(Int(r.midY) & 0xFFFF) << 16) }
        _ = SendMessageW(hwnd, Win.WM_LBUTTONDOWN, 1, at(a))
        _ = SendMessageW(hwnd, Win.WM_MOUSEMOVE, 1, at(a, 12))
        _ = SendMessageW(hwnd, Win.WM_MOUSEMOVE, 1, at(b))
        _ = SendMessageW(hwnd, Win.WM_LBUTTONUP, 0, at(b))
    }

    func doubleClick(_ rect: UIRect) {
        let position = LPARAM(Int(rect.x + rect.width / 2) & 0xFFFF) | (LPARAM(Int(rect.y + rect.height / 2) & 0xFFFF) << 16)
        _ = SendMessageW(hwnd, Win.WM_LBUTTONDOWN, 1, position)
        _ = SendMessageW(hwnd, Win.WM_LBUTTONUP, 0, position)
        _ = SendMessageW(hwnd, Win.WM_LBUTTONDBLCLK, 1, position)
        _ = SendMessageW(hwnd, Win.WM_LBUTTONUP, 0, position)
    }

    /// Drags the border of the left sidebar to a position.
    func dragLeftEdge(to x: Float) {
        let y = Int(layout.terminal.midY)
        func at(_ px: Int) -> LPARAM { LPARAM(px & 0xFFFF) | (LPARAM(y & 0xFFFF) << 16) }
        _ = SendMessageW(hwnd, Win.WM_LBUTTONDOWN, 1, at(Int(layout.leftWidth)))
        _ = SendMessageW(hwnd, Win.WM_MOUSEMOVE, 1, at(Int(x)))
        _ = SendMessageW(hwnd, Win.WM_LBUTTONUP, 0, at(Int(x)))
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
