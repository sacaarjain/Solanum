import CCanvas
import Foundation
import WinSDK

/// A window: a tab bar drawn in the title bar's place, one pane per tab, and a status bar. The real title bar is gone, but
/// the window keeps its frame, so it still resizes, snaps and has a shadow. Reporting the maximize button to Windows as
/// such is what brings up Snap Layouts when the pointer rests on it.
final class TerminalWindow {
    private static let className = wide("SolanumTerminalWindow")
    private static var windows: [HWND: TerminalWindow] = [:]
    /// Runs work on a Solanum window's thread (the one all windows share), from another thread: for Settings, which has
    /// no queue of its own. With no window open it runs straight away.
    static func onAnyWindowThread(_ work: @escaping () -> Void) {
        if let w = windows.values.first { w.runOnWindowThread(work) } else { work() }
    }

    /// The window that last had the keyboard, for what's opened from elsewhere (Settings).
    private static weak var lastFocused: TerminalWindow?

    /// A file in a tab of its own in the Solanum window used last, brought to the front: a theme's file, from Settings.
    /// A card about `pane`, as on the Mac: in the window in front (else the pane's own), going to the pane's tab when
    /// clicked; the taskbar button flashes when Solanum isn't in front.
    @discardableResult
    static func postNotice(_ card: NoticeRules.Card, about pane: TerminalPane, button: (title: String, action: () -> Void)? = nil,
                           keepsOpen: Bool = false, lifetime: TimeInterval = 30) -> CornerNotice? {
        guard let own = pane.host else { return nil }
        let foreground = windows.values.first { $0.hwnd == GetForegroundWindow() }
        let shown = foreground ?? own
        let notice = CornerNotice(card, button: button, keepsOpen: keepsOpen, lifetime: lifetime)
        notice.onClick = { [weak pane] in pane?.host?.goTo(pane) }
        shown.notices.show(notice)
        shown.invalidate()
        if foreground == nil { FlashWindow(own.hwnd, true) }
        return notice
    }

    /// The pane is on screen in front of the user: this window in front, its tab showing.
    func isWatching(_ pane: TerminalPane) -> Bool {
        hwnd == GetForegroundWindow() && visiblePanes.contains { $0 === pane }
    }

    /// Brings a pane's tab to the front, and its window.
    func goTo(_ pane: TerminalPane?) {
        guard let pane, let i = panes.firstIndex(where: { $0 === pane }) else { return }
        selectTab(i)
        if IsIconic(hwnd) { ShowWindow(hwnd, 9) }
        SetForegroundWindow(hwnd)
        invalidate()
    }

    static func openFileTabInFront(_ path: String) {
        guard let w = lastFocused ?? windows.values.first, !w.panes.isEmpty else { return }
        w.openFileTab(path, column: w.activePane.column)
        if IsIconic(w.hwnd) { ShowWindow(w.hwnd, 9) }
        SetForegroundWindow(w.hwnd)
    }

    private(set) var hwnd: HWND!
    private(set) var canvas: Canvas!
    /// Cards in the top-right corner: long commands finishing, agents stopping, ssh dropping (see CornerNotices).
    let notices = CornerNoticeStack()
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
    private var hoveredGit: (column: Int, part: GitPart)?
    private var themeHovered = false
    /// The tab whose place the left sidebar shows (see `syncLeftSidebar`).
    private weak var leftOwner: TerminalPane?
    /// While split, the active tab of the column that doesn't have the keyboard.
    private var otherActiveID: UInt?
    /// How far the right column's tabs are scrolled.
    private var rightTabScroll: Float = 0
    /// The left column's share of the room while split, set by dragging the band between the columns.
    private var splitFraction: Float = 0.5
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
    init?(commandLine: String, cols: Int = 110, rows: Int = 32, activate: Bool = true, session: SavedSession? = nil, failure: inout String) {
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
        applyBackdrop()
        AppSettings.shared.onChange.append { [weak self] in self?.settingsChanged() }
        KeepAwake.onChange.append { [weak self] in self?.invalidate() }
        // WSL's distributions, for the shell menus, once known.
        Shells.findWSL(post: { [weak self] work in self?.runOnWindowThread(work) }, done: {})
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
        if let session { restore(session) }
        guard !panes.isEmpty || addPane() else {
            failure = "Couldn't start the shell: \(commandLine.prefix(60))"
            Self.windows[created] = nil
            DestroyWindow(created)
            return nil
        }
        ShowWindow(created, session?.maximized == true ? Win.SW_MAXIMIZE : activate ? Win.SW_SHOW : Win.SW_SHOWNOACTIVATE)
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

    /// Where a tab's terminal is drawn: its column, under any pages open above it.
    func area(for pane: TerminalPane) -> UIRect { editorSplit(for: pane).terminal }

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
    /// Splits the window with `pane` alone on the left and every other tab on the right: a tab dragged onto the left
    /// half of the terminals.
    func splitToLeft(_ pane: TerminalPane) {
        guard !isSplit, panes.count > 1 else { return }
        let previous = activePane
        panes.forEach { $0.column = 1 }
        pane.column = 0
        pane.group = nil
        // The right column shows the tab that was showing (or, if that's the one moving, the one beside it).
        otherActiveID = previous !== pane ? previous.id : panes.first { $0 !== pane }?.id
        normalizeColumns()
        layoutChanged()
        if let i = panes.firstIndex(where: { $0 === pane }) { activate(i) }
    }

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
        applyBackdrop()
        panes.forEach { $0.terminal.setScrollbackLimit(settings.scrollback) }
        layoutChanged()
        detailsChanged()
    }

    /// What the window was last told about showing the desktop through it.
    private var appliedBackdrop: (transparent: Bool, blur: Bool)?

    /// The background as solid as asked, as on the Mac: below 1 the desktop shows through, blurred by Windows 11's
    /// acrylic if blur is on. Text and everything drawn on the background stay solid.
    private func applyBackdrop() {
        let settings = AppSettings.shared, opacity = Float(settings.opacity)
        // A theme's own picture comes first: the window shows it rather than the desktop.
        if let image = settings.theme.image, let url = ThemeFiles.imageURL(image), FileManager.default.fileExists(atPath: url.path) {
            sol_canvas_set_opacity(canvas.raw, Float(image.tint))
            showThemeImage(url, image)
            if appliedBackdrop.map({ $0 != (false, false) }) ?? true {
                appliedBackdrop = (false, false)
                sol_window_set_backdrop(UnsafeMutableRawPointer(hwnd), 0, 0)
            }
            return
        }
        if themeImageSize != nil {
            themeImageSize = nil
            wallpaperKey = nil
            sol_canvas_set_wallpaper_zoom(canvas.raw, 1)
            sol_canvas_set_wallpaper(canvas.raw, nil, 0, 0, 0, 0xFFFFFFFF, 0)
        }
        let wallpaper = opacity < 1 && settings.showsWallpaper
        sol_canvas_set_opacity(canvas.raw, opacity)
        if wallpaper {
            followWallpaper(recheck: true)
        } else if wallpaperKey != nil {
            wallpaperKey = nil
            wallpaperMonitor = nil
            sol_canvas_set_wallpaper(canvas.raw, nil, 0, 0, 0, 0xFFFFFFFF, 0)
        }
        // With the wallpaper drawn in, the window itself is solid: the system has nothing to do.
        let wanted = (transparent: opacity < 1 && !wallpaper, blur: settings.blur)
        guard appliedBackdrop.map({ $0 != wanted }) ?? true else { return }
        appliedBackdrop = wanted
        sol_window_set_backdrop(UnsafeMutableRawPointer(hwnd), wanted.transparent ? 1 : 0, wanted.blur ? 1 : 0)
    }

    /// The theme's picture's size as it was made, while one is showing (see `showThemeImage`).
    private var themeImageSize: (width: Int32, height: Int32)?

    /// A theme's picture behind the window, blurred as the theme has it, made again only when it's changed.
    private func showThemeImage(_ url: URL, _ image: ThemeImage) {
        let modified = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let blur = Float(image.blur) * scale
        let color = HexColor(AppSettings.shared.theme.background)?.rgb ?? 0
        let key = "image|\(url.path)|\(modified)|\(blur)|\(color)"
        if key != wallpaperKey {
            wallpaperKey = key
            wallpaperMonitor = nil
            let made = wide(url.path).withUnsafeBufferPointer { path -> (Int32, Int32) in
                var w: Int32 = 0, h: Int32 = 0
                guard sol_image_file_size(canvas.raw, path.baseAddress, &w, &h) >= 0, w > 0, h > 0 else { return (0, 0) }
                // Big pictures are made no bigger than a large screen: more wouldn't show.
                let shrink = min(1, 2560 / Float(max(w, h)))
                let size = (Int32(Float(w) * shrink), Int32(Float(h) * shrink))
                sol_canvas_set_wallpaper(canvas.raw, path.baseAddress, size.0, size.1, 2, color, blur)
                return size
            }
            themeImageSize = made.0 > 0 ? (made.0, made.1) : nil
        }
        fitThemeImage()
    }

    /// The theme's picture filling the window, cropped to it, centered.
    private func fitThemeImage() {
        guard let size = themeImageSize else { return }
        let w = Float(clientWidth), h = Float(clientHeight)
        let zoom = max(w / Float(size.width), h / Float(size.height))
        sol_canvas_set_wallpaper_zoom(canvas.raw, zoom)
        sol_canvas_set_wallpaper_origin(canvas.raw, ((w - Float(size.width) * zoom) / 2).rounded(), ((h - Float(size.height) * zoom) / 2).rounded())
        invalidate()
    }

    /// The wallpaper drawn in (see `followWallpaper`): what it was made from, and where its monitor is on the screen.
    private var wallpaperKey: String?
    private var wallpaperArea: (x: Int32, y: Int32) = (0, 0)
    private var wallpaperMonitor: HMONITOR?

    /// Keeps the wallpaper behind the window lined up with the screen, so the window seems to show the desktop: read
    /// again when asked (`recheck`) or the window's moved to another monitor, and made again only if it's changed.
    private func followWallpaper(recheck: Bool = false) {
        let settings = AppSettings.shared
        guard themeImageSize == nil, settings.opacity < 1, settings.showsWallpaper, recheck || wallpaperKey != nil else { return }
        let monitor = MonitorFromWindow(hwnd, DWORD(2))
        if recheck || monitor != wallpaperMonitor {
            var info = MONITORINFO()
            info.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)
            guard let monitor, GetMonitorInfoW(monitor, &info) else { return }
            let center = ((info.rcMonitor.left + info.rcMonitor.right) / 2, (info.rcMonitor.top + info.rcMonitor.bottom) / 2)
            var path = [UInt16](repeating: 0, count: 2048), area = [Int32](repeating: 0, count: 4)
            var position: Int32 = 4, color: UInt32 = 0
            guard sol_wallpaper_at(center.0, center.1, &path, Int32(path.count), &area, &position, &color) >= 0 else { return }
            let file = String(decoding: path.prefix { $0 != 0 }, as: UTF16.self)
            // A slideshow changes the picture in the same file.
            let modified = ((try? FileManager.default.attributesOfItem(atPath: file))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let blur = settings.blur ? (48 * scale).rounded() : 0
            let key = "\(file)|\(modified)|\(area)|\(position)|\(color)|\(blur)"
            if key != wallpaperKey {
                wallpaperKey = key
                if file.isEmpty {
                    sol_canvas_set_wallpaper(canvas.raw, nil, area[2], area[3], position, color, blur)
                } else {
                    _ = wide(file).withUnsafeBufferPointer { sol_canvas_set_wallpaper(canvas.raw, $0.baseAddress, area[2], area[3], position, color, blur) }
                }
            }
            wallpaperArea = (area[0], area[1])
            wallpaperMonitor = monitor
        }
        var origin = POINT()
        ClientToScreen(hwnd, &origin)
        sol_canvas_set_wallpaper_origin(canvas.raw, Float(wallpaperArea.x - origin.x), Float(wallpaperArea.y - origin.y))
        invalidate()
    }

    private var layout: WindowLayout { layout(leftWidth: (sidebarWidth(left) * left.shown).rounded()) }

    private func layout(leftWidth: Float) -> WindowLayout {
        var l = WindowLayout(width: Float(clientWidth), height: Float(clientHeight), scale: scale, tabCount: panes.count, tabScroll: tabScroll,
                             chips: chipWidths(), hiddenTabs: hiddenTabs, leftWidth: leftWidth, rightWidth: rightIsShowing ? sidebarWidth(right) : 0,
                             showsRightToggle: isSplit, splitCount: splitCount, rightTabScroll: rightTabScroll, splitFraction: splitFraction)
        // Windows' shells, beside the ssh hosts button.
        l.hasShellButton = true
        return l
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
    /// While the Quantum Moon's reading animates.
    private static let readingTimer: UINT_PTR = 6

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
    private func addPane(at index: Int? = nil, cwd: String? = nil, restoring text: String? = nil, place: SidebarPlace? = nil, column: Int? = nil,
                         shell: ShellOption? = nil) -> Bool {
        let wasSplit = isSplit
        let col = column ?? index.flatMap { i in panes.indices.contains(i - 1) ? panes[i - 1].column : nil } ?? (panes.isEmpty ? 0 : activePane.column)
        let grid = clientWidth > 0 ? self.grid(for: col == 1 ? rightTerminalArea : terminalArea) : (cols: 110, rows: 32)
        // A shell asked for, else the default as Settings has it now (a window started with its own command keeps that).
        let line = shell.map(Shells.commandLine) ?? (usesDefaultShell ? AppSettings.shared.shellCommandLine : commandLine)
        guard let pane = TerminalPane(host: self, commandLine: line, cols: grid.cols, rows: grid.rows, cwd: cwd, restoring: text) else { return false }
        pane.shell = shell ?? Shells.identify(line)
        pane.column = col
        pane.showFindScopeMenu = { [weak self] items, r in
            guard let self else { return }
            self.openMenu(items, x: r.x, y: r.maxY + 4 * self.scale, above: false)
        }
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

    /// In the current tab's folder, unless Settings says the home folder; in the active tab's column, or `column`; in the
    /// default shell, or `shell`.
    func newTab(column: Int? = nil, shell: ShellOption? = nil) {
        let from = column.flatMap { $0 == 1 ? rightActivePane : leftActivePane } ?? (panes.isEmpty ? nil : activePane)
        let here = AppSettings.shared.newTabFolder == "current" ? from?.terminal.cwd : nil
        addPane(cwd: here, column: column, shell: shell)
    }

    // MARK: - Shells

    /// The window was started with the default shell, so new tabs follow Settings when it changes.
    private lazy var usesDefaultShell = commandLine == AppSettings.shared.shellCommandLine

    /// Every shell here, each opening a new tab with it; the default one checked. Then changing the default.
    private func shellItems(newTabIn column: Int?) -> [MenuItem] {
        let fallback = Shells.defaultShell
        var items = Shells.available.map { shell in
            MenuItem(title: shell.name, isChecked: shell == fallback, shortcut: shell == fallback ? "Default" : "") { [weak self] in
                self?.newTab(column: column, shell: shell)
            }
        }
        items.append(.separator)
        items.append(MenuItem(title: "Change Default Shell\u{2026}") { [weak self] in self?.showDefaultShellMenu() })
        return items
    }

    /// Right-click on +: a new tab with any shell here.
    private func showNewTabShells(column: Int) {
        let r = layout.newTab(column: column)
        openMenu([MenuItem(title: "New Tab With", isEnabled: false)] + shellItems(newTabIn: column), x: r.x, y: r.maxY + 4 * scale, above: false)
    }

    /// The status bar's shell button: what this tab runs, switching it to another, a new tab with one, and the default.
    private func showShellMenu() {
        guard !panes.isEmpty else { return }
        let pane = activePane, current = pane.shell
        var items = [MenuItem(title: "This tab: " + (current?.name ?? "another program"), isEnabled: false), .separator,
                     MenuItem(title: "Switch This Tab To", isEnabled: false)]
        for shell in Shells.available where shell != current {
            items.append(MenuItem(title: "    " + shell.name) { [weak self, weak pane] in
                if let self, let pane { self.switchShell(of: pane, to: shell) }
            })
        }
        items += [.separator, MenuItem(title: "New Tab With", isEnabled: false)]
        items += shellItems(newTabIn: pane.column).map { item in
            var item = item
            if !item.isSeparator && item.title != "Change Default Shell\u{2026}" { item.title = "    " + item.title }
            return item
        }
        let b = layout.shellButton
        openMenu(items, x: b.x, y: b.y - 4 * scale, above: true)
    }

    /// Which shell new tabs start with: kept in Settings › Preferences › Shell.
    private func showDefaultShellMenu() {
        let fallback = Shells.defaultShell
        let items = Shells.available.map { shell in
            MenuItem(title: shell.name, isChecked: shell == fallback) { AppSettings.shared.set("shell", Shells.setting(for: shell)) }
        }
        let b = layout.shellButton
        openMenu([MenuItem(title: "Default Shell", isEnabled: false)] + items, x: b.x, y: b.y - 4 * scale, above: true)
    }

    /// A tab started again in another shell, in the same place and folder; the old one closes (Reopen Closed Tab brings it
    /// back). Something running there is asked about first.
    func switchShell(of pane: TerminalPane, to shell: ShellOption) {
        guard let i = panes.firstIndex(where: { $0 === pane }) else { return }
        let replace = { [weak self, weak pane] in
            guard let self, let pane, let i = self.panes.firstIndex(where: { $0 === pane }) else { return }
            let group = pane.group, title = pane.customTitle
            let folder = pane.sshArguments == nil ? pane.terminal.cwd : nil
            guard self.addPane(at: i, cwd: folder, column: pane.column, shell: shell) else { return }
            self.activePane.group = group
            self.activePane.customTitle = title
            if let old = self.panes.firstIndex(where: { $0 === pane }) { self.closeTab(old) }
            self.invalidate()
        }
        if panes[i].atPrompt || panes[i].terminal.currentBlock == nil { return replace() }
        ask(DialogModel(title: "Switch this tab to \(shell.name)?",
                        message: "Something is still running in it, and switching stops it. Reopen Closed Tab brings back what it showed.",
                        primary: "Switch", run: replace))
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
        panes[i].setFocused(isFocused && !sidebarHasFocus && !panes[i].editorFocused)
        // A restored tab's agent or ssh session carries on once it's shown (the other column's too, while split).
        for pane in visiblePanes {
            if let command = pane.resumeOnShow {
                pane.resumeOnShow = nil
                pane.pendingCommand = command
            }
        }
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
    func paneDetailsChanged(_ pane: TerminalPane) {
        // Another folder may be another repository, or none.
        if visiblePanes.contains(where: { $0 === pane }) { refreshGit(pane) }
        detailsChanged()
    }

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
        chrome.tabIcons = panes.map { p -> TabIcon in
            if let agent = p.agent { return .agent(agent) }
            if !p.showsTerminal, p.editors.indices.contains(p.activeEditor) {
                return .file(p.editors[p.activeEditor].glyph, name: p.editors[p.activeEditor].fileName)
            }
            return .prompt
        }
        chrome.hovered = hovered
        chrome.pressed = pressed
        chrome.shell = panes.isEmpty ? nil : activePane.shell
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
            chrome.git = l.git.map { GitBadge($0, busy: l.gitBusy) }
            if let r = rightActivePane { chrome.rightGit = r.git.map { GitBadge($0, busy: r.gitBusy) } }
            chrome.hoveredGit = hoveredGit
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
        chrome.keepAwakeLeft = KeepAwake.secondsLeft.map { "Awake \(KeepAwake.shortDuration($0))" }
        chrome.keepAwakeHovered = keepAwakeHovered
        // As on the Mac: a planet theme's planet, Solanum Default's flower, and nothing for the rest. The Quantum Moon
        // may have wandered off (see QuantumMoon), leaving its name.
        let theme = AppSettings.shared.themeName, custom = AppSettings.shared.customThemes.contains { $0.name == theme }
        chrome.themePlanet = AppSettings.shared.themePlanet
        if QuantumMoon.active && !QuantumMoon.at(.home) { chrome.themePlanet = nil }
        chrome.showsThemeIcon = AppSettings.shared.themeIcon && (chrome.themePlanet != nil || (!custom && theme == ThemeSpecs.defaultName))
        chrome.moonInCorner = QuantumMoon.at(.flower)
        chrome.moonByFolders = QuantumMoon.at(.folders)
        chrome.moonHovered = moonHovered
        chrome.themeHovered = themeHovered
        if let press = tabPress, press.dragging {
            chrome.draggedTab = press.index
            chrome.draggedX = draggedX
        }
        chrome.dropMarker = tabDropMarker
        if let p = fileDragPoint, let spot = tabBarSpot(atX: p.x, y: p.y) {
            chrome.dropMarker = tabBarMarker(spot)
            chrome.dropMarkerColumn = spot.column
        }
        if let spot = tabStripTarget {
            chrome.dropMarker = tabBarMarker(spot)
            chrome.dropMarkerColumn = spot.column
        }
        // A tab lifted out of its strip, following the pointer, leaves its place empty.
        chrome.draggedTabLifted = tabPress?.dragging == true && dragGhost != nil
        if let g = tabDropChip { chrome.dropChip = panes.firstIndex { $0.group === g } }
        if let shape = chipDragShape {
            chrome.liftedGroup = shape.lifted
            chrome.dropMarker = shape.marker
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
        for pane in visiblePanes { drawColumn(pane, on: canvas, snapshot: false) }
        drawDivider(on: canvas)
        drawSplitDrop(on: canvas)
        drawSidebars(on: canvas, layout: layout)
        notices.draw(on: canvas, windowWidth: Float(clientWidth), top: layout.tabBarHeight, scale: scale)
        drawPalette(on: canvas)
        drawReading(on: canvas)
        drawDragGhost(on: canvas)
        if let menu { MenuView(canvas: canvas, menu: menu).draw() }
        if let dialog { DialogView(canvas: canvas, dialog: dialog, width: Float(clientWidth), height: Float(clientHeight), scale: scale).draw() }
        _ = sol_canvas_end(canvas.raw)
        paints += 1
        lastDrawn = Date()
    }

    /// The band between the columns, while split, with its grip.
    private func drawDivider(on target: Canvas) {
        guard let band = layout.columnBand else { return }
        Self.drawBand(band, vertical: true, on: target, scale: scale, active: draggingEdge == .columnDivider)
    }

    /// A band (not a hairline) between the columns, or between a tab's pages and its terminal, with a grip to show it
    /// can be dragged, as on the Mac.
    static func drawBand(_ r: UIRect, vertical: Bool, on target: Canvas, scale: Float, active: Bool = false) {
        let c = target.raw, fg = TerminalPalette.foreground
        sol_canvas_backdrop_rect(c, r.x, r.y, r.width, r.height, TerminalPalette.chrome)
        if vertical {
            sol_canvas_fill_rect(c, r.x, r.y, 1, r.height, fg, 0.10)
            sol_canvas_fill_rect(c, r.maxX - 1, r.y, 1, r.height, fg, 0.10)
        } else {
            sol_canvas_fill_rect(c, r.x, r.y, r.width, 1, fg, 0.10)
            sol_canvas_fill_rect(c, r.x, r.maxY - 1, r.width, 1, fg, 0.10)
        }
        let midX = r.x + r.width / 2, midY = r.y + r.height / 2
        for i in -1...1 {
            let d = Float(i) * 7 * scale
            sol_canvas_fill_ellipse(c, vertical ? midX : midX + d, vertical ? midY + d : midY, 1.5 * scale, 1.5 * scale, fg, active ? 0.6 : 0.35)
        }
    }

    /// What the window shows, to a PNG. For tests.
    func saveSnapshot(to path: String) -> Bool {
        guard let bitmap = Canvas(width: clientWidth, height: clientHeight, fontPixels: fontPixels()) else { return false }
        applyFont(to: bitmap)
        bitmap.padding = canvas.padding
        bitmap.terminalArea = canvas.terminalArea
        guard sol_canvas_begin(bitmap.raw, TerminalPalette.background) >= 0 else { return false }
        chrome(on: bitmap, layout: layout).draw()
        for pane in visiblePanes { drawColumn(pane, on: bitmap, snapshot: true) }
        drawDivider(on: bitmap)
        drawSplitDrop(on: bitmap)
        drawSidebars(on: bitmap, layout: layout)
        drawPalette(on: bitmap)
        drawReading(on: bitmap)
        drawDragGhost(on: bitmap)
        if let menu { MenuView(canvas: bitmap, menu: menu).draw() }
        if let dialog { DialogView(canvas: bitmap, dialog: dialog, width: Float(clientWidth), height: Float(clientHeight), scale: scale).draw() }
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
            if !panes.isEmpty { leaveEditors() }
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
            followWallpaper()
            fitThemeImage()
            return 0
        case Win.WM_MOVE:
            // The wallpaper stays put on the screen as the window moves over it.
            followWallpaper()
            return 0
        case Win.WM_SETTINGCHANGE, Win.WM_DISPLAYCHANGE:
            // A new wallpaper, or monitors added, moved or resized.
            followWallpaper(recheck: true)
            return DefWindowProcW(hwnd, message, wParam, lParam)
        case Win.WM_DPICHANGED:
            applyFont(to: canvas)
            canvas.padding = scaledPadding()
            let suggested = UnsafePointer<RECT>(bitPattern: Int(lParam))!.pointee
            SetWindowPos(hwnd, nil, suggested.left, suggested.top, suggested.right - suggested.left,
                         suggested.bottom - suggested.top, Win.SWP_NOZORDER | Win.SWP_NOACTIVATE)
            return 0
        case Win.WM_SETFOCUS, Win.WM_KILLFOCUS:
            isFocused = message == Win.WM_SETFOCUS
            if isFocused { Self.lastFocused = self }
            // Going to another window keeps the name typed so far, as clicking elsewhere does.
            if !isFocused && naming != nil { finishNaming(commit: true) }
            if !panes.isEmpty { activePane.setFocused(isFocused && !activePane.editorFocused) }
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
            } else if wParam == WPARAM(Self.readingTimer) {
                readingTick()
            } else {
                // An agent starting, stopping or changing what it's doing shows on its tab.
                if panes.map({ $0.tick() }).contains(true) { invalidate() }
                if notices.tick() { invalidate() }
                for pane in visiblePanes { pane.panel?.tick() }
                // Files open in tabs or sub-tabs not showing keep up with the disk too (on this PC; ssh ones catch up when shown).
                for pane in panes {
                    for (i, item) in pane.editors.enumerated() {
                        guard let file = item.panel as? FileEditorPanel else { continue }
                        let showing = visiblePanes.contains { $0 === pane } && i == pane.activeEditor
                        if !showing { file.syncTick(showing: false) }
                    }
                }
                lookForChanges()
                KeepAwake.tick()
                let awake = KeepAwake.secondsLeft.map(KeepAwake.shortDuration)
                if awake != keepAwakeShown { keepAwakeShown = awake; invalidate() }
                updateBlink()
                onTick?()
            }
            return 0
        case Win.WM_CHAR:
            if menu != nil || dialog != nil {
                // A menu or a question takes no text.
            } else if notices.hasFocusedField {
                if notices.typed(UInt16(truncatingIfNeeded: wParam)) { invalidate() }
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
            } else if !panes.isEmpty, activePane.findFocused, !activePane.editorFocused {
                activePane.findTyped(UInt16(truncatingIfNeeded: wParam))
            } else if !panes.isEmpty, let panel = activePane.focusedPanel {
                let unit = UInt16(truncatingIfNeeded: wParam)
                if unit >= 0x20, unit != 0x7F, let scalar = Unicode.Scalar(unit) { panel.typed(String(Character(scalar))) }
            } else if !panes.isEmpty {
                // Typing is for the terminal, wherever the keyboard was.
                focusTerminal()
                activePane.typed(UInt16(truncatingIfNeeded: wParam), meta: false)
            }
            return 0
        case Win.WM_SYSCHAR:
            if palette == nil && !panes.isEmpty { activePane.typed(UInt16(truncatingIfNeeded: wParam), meta: true) }
            return 0
        case Win.WM_ACTIVATEAPP:
            // Solanum came back to the front: the Quantum Moon may have moved while nobody was looking.
            if wParam != 0, QuantumMoon.cameToFront() { Self.windows.values.forEach { $0.invalidate() } }
            // A slideshow may have moved on while Solanum was in the background.
            if wParam != 0 { followWallpaper(recheck: true) }
            return 0
        case Win.WM_LBUTTONDOWN, Win.WM_LBUTTONUP, Win.WM_LBUTTONDBLCLK, Win.WM_MOUSEMOVE,
             Win.WM_RBUTTONDOWN, Win.WM_RBUTTONUP, Win.WM_MBUTTONDOWN, Win.WM_MBUTTONUP:
            if touchMouse(message, lParam) { return 0 }
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
                let under = pane(atX: x)
                let split = editorSplit(for: under)
                if let editor = split.editor, editor.contains(x, y) || !split.showsTerminal {
                    let delta = Double(Int16(truncatingIfNeeded: (wParam >> 16) & 0xFFFF))
                    if let panel = under.panel, let page = split.page, page.contains(x, y) {
                        // At the scroll speed Settings has, as the terminal: lines a notch, a touchpad's small steps adding up.
                        if pageWheelRemainder != 0 && (pageWheelRemainder > 0) != (delta > 0) { pageWheelRemainder = 0 }
                        pageWheelRemainder += delta / Double(Win.WHEEL_DELTA) * AppSettings.shared.scrollSpeed
                        let lines = Int(pageWheelRemainder)
                        if lines != 0 {
                            pageWheelRemainder -= Double(lines)
                            panel.scroll(lines: lines, x: x, y: y, in: page, scale: scale)
                        }
                    } else if let strip = editorStrip(for: under), strip.strip.contains(x, y) {
                        // Over the sub-tabs, the wheel takes them along, when they don't all fit.
                        scrollStrip(under, by: -Float(Int16(truncatingIfNeeded: (wParam >> 16) & 0xFFFF)) / Float(Win.WHEEL_DELTA) * 80 * scale)
                    }
                } else {
                    under.wheel(wParam, lParam)
                }
            }
            return 0
        case Win.WM_RESTART:
            restart(fresh: false)
            return 0
        case Win.WM_DESTROY:
            // Closing the last window keeps what it had for next time; with no tabs left (closed one by one), it starts over.
            if !sessionHandled { saveSession() }
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
        // Full screen: all of it is the window's, with no frame to resize by.
        if fullScreenRestore != nil { return 0 }
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
        if fullScreenRestore != nil {
            // Nothing to resize or drag by; the window's buttons still work.
            let (x, y) = screenPoint(lParam)
            switch layout.part(atX: x, y: y) {
            case .minimize: return Win.HTMINBUTTON
            case .maximize: return Win.HTMAXBUTTON
            case .close: return Win.HTCLOSE
            default: return Win.HTCLIENT
            }
        }
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
        if dialog != nil {
            SetCursor(LoadCursorW(nil, Win.arrowCursor))
            return 1
        }
        let px = Float(point.x), py = Float(point.y)
        if menu == nil, palette == nil, !notices.isEmpty,
           let hand = notices.wantsHand(atX: px, y: py, canvas: canvas, windowWidth: Float(clientWidth), top: layout.tabBarHeight, scale: scale) {
            SetCursor(LoadCursorW(nil, hand ? Win.handCursor : Win.arrowCursor))
            return 1
        }
        // What's on top decides, not what's under it: a menu shows the arrow; the palette, the I-beam over the field it's
        // typed in and the arrow over the rest; the Quantum Moon's reading, the arrow.
        if let menu, menu.frame.contains(px, py) {
            SetCursor(LoadCursorW(nil, Win.arrowCursor))
            return 1
        }
        if palette != nil {
            let l = paletteLayout
            SetCursor(LoadCursorW(nil, l.field.contains(px, py) ? Win.ibeamCursor : Win.arrowCursor))
            return 1
        }
        if reading?.contains(px, py) == true || (QuantumMoon.at(.folders) && moonRect?.contains(px, py) == true) {
            SetCursor(LoadCursorW(nil, reading?.contains(px, py) == true ? Win.arrowCursor : Win.handCursor))
            return 1
        }
        let onEdge = palette == nil && (part == .leftEdge || part == .rightEdge || part == .columnDivider) || draggingEdge != nil
        let onLink = palette == nil && part == .terminal && !panes.isEmpty && activePane.hoveredLink != nil
        let onEditorLine = palette == nil && menu == nil && part == .terminal && !panes.isEmpty
            && (draggingEditorLine != nil || editorSplit(for: pane(atX: px)).divider?.contains(px, py) == true)
        if onEditorLine {
            SetCursor(LoadCursorW(nil, Win.resizeUpDownCursor))
            return 1
        }
        // A pointing hand over a pasted image's thumbnail, or its larger look, as on the Mac.
        let onImage = palette == nil && menu == nil && part == .terminal && !panes.isEmpty
            && (pane(atX: px).imageChips.isOver(x: px, y: py) || pane(atX: px).isOverCopyButton(x: px, y: py))
        let onTerminal = palette == nil && part == .terminal && !onLink && !onImage && (panes.isEmpty || area(for: pane(atX: px)).contains(px, py)
            && (editorSplit(for: pane(atX: px)).showsTerminal || pane(atX: px).editors.isEmpty))
        // A pointing hand over the flower, which opens Settings, as on the Mac.
        let onFlower = palette == nil && menu == nil && part == .flower
        SetCursor(LoadCursorW(nil, onEdge ? Win.resizeCursor : onTerminal ? Win.ibeamCursor : onFlower || onLink || onImage ? Win.handCursor : Win.arrowCursor))
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
    // MARK: - The Quantum Moon

    /// The moon's reading, while it's showing (see QuantumMoon), and where the moon was when it was last drawn.
    private var reading: NomaiReading?
    private var readingAnchor: UIRect?
    private var moonHovered = false

    /// Where the moon is by the folders, when it is.
    private var moonRect: UIRect? { QuantumMoon.at(.folders) ? chrome(on: canvas, layout: layout).moonRect() : nil }

    /// The pointer over the moon, a click on it (which shows its reading or puts it away), or a click while the reading
    /// shows, which puts it away: one on the wall or the box goes no further, one elsewhere still lands. True when it's
    /// taken the message.
    private func moonMouse(_ message: UINT, x: Float, y: Float) -> Bool {
        guard QuantumMoon.at(.folders) || reading != nil || moonHovered else { return false }
        let onMoon = moonRect?.contains(x, y) ?? false
        if message == Win.WM_MOUSEMOVE {
            if onMoon != moonHovered {
                moonHovered = onMoon
                invalidate()
            }
            // Over the moon, it's the only thing lit: the folder path beside it doesn't hear of the pointer.
            if onMoon && hoveredCrumb != nil {
                hoveredCrumb = nil
                invalidate()
            }
            return onMoon || (reading?.contains(x, y) ?? false)
        }
        let presses = [Win.WM_LBUTTONDOWN, Win.WM_RBUTTONDOWN, Win.WM_MBUTTONDOWN, Win.WM_LBUTTONDBLCLK]
        if let r = reading, r.dismissedAt == nil, presses.contains(message), !onMoon {
            r.dismiss()
            runReading()
            return r.contains(x, y)
        }
        guard onMoon, dialog == nil, menu == nil, palette == nil else { return false }
        if message == Win.WM_LBUTTONUP {
            if let r = reading, r.dismissedAt == nil { r.dismiss() } else { reading = QuantumMoon.nextReading() }
            runReading()
        }
        return message == Win.WM_LBUTTONDOWN || message == Win.WM_LBUTTONUP || message == Win.WM_LBUTTONDBLCLK
    }

    /// Draws the reading about sixty times a second while it moves.
    private func runReading() {
        _ = SetTimer(hwnd, Self.readingTimer, 16, nil)
        invalidate()
    }

    private func readingTick() {
        guard let r = reading else { _ = KillTimer(hwnd, Self.readingTimer); return }
        // The moon moved on, or the theme changed: the script goes with it.
        if !QuantumMoon.at(.folders) { r.dismiss() }
        if r.finished {
            reading = nil
            _ = KillTimer(hwnd, Self.readingTimer)
        } else if !r.animating {
            // All typed out: nothing moves until it's put away.
            _ = KillTimer(hwnd, Self.readingTimer)
        }
        invalidate()
    }

    private func drawReading(on target: Canvas) {
        guard let r = reading else { return }
        if let moon = QuantumMoon.at(.folders) ? chrome(on: target, layout: layout).moonRect() : nil { readingAnchor = moon }
        guard let anchor = readingAnchor else { return }
        r.place(moon: anchor, width: Float(clientWidth), scale: scale, canvas: target)
        r.draw(on: target)
    }

    // MARK: - Touch

    /// Wheel movement over a tab's pages not yet a whole line.
    private var pageWheelRemainder: Double = 0

    /// A finger on the screen, held back from being a press until it's known to be a tap rather than a drag.
    private var touch: TouchScroll?

    /// A finger dragged scrolls what's under it (see `TouchScroll`), and a tap clicks. True when it's taken the message.
    private func touchMouse(_ message: UINT, _ lParam: LPARAM) -> Bool {
        switch message {
        case Win.WM_LBUTTONDOWN where TouchScroll.fromTouch:
            let (x, y) = clientPoint(lParam)
            if let t = stripTouchStart(x: x, y: y, lParam: lParam) {
                stripTouch = t
                SetCapture(hwnd)
                return true
            }
            guard let (stepPixels, apply) = touchTarget(x: x, y: y, lParam: lParam) else { return false }
            touch = TouchScroll(at: lParam, stepPixels: stepPixels, apply: apply)
            SetCapture(hwnd)
            return true
        case Win.WM_MOUSEMOVE:
            if stripTouch != nil {
                stripTouchMoved(lParam)
                return true
            }
            guard touch != nil else { return false }
            touch!.moved(to: lParam, slop: 8 * scale)
            invalidate()
            return true
        case Win.WM_LBUTTONUP:
            if let t = stripTouch {
                stripTouch = nil
                stripTouchEnded(t, lParam)
                return true
            }
            guard let t = touch else { return false }
            touch = nil
            ReleaseCapture()
            if !t.dragging {
                clientMouse(Win.WM_LBUTTONDOWN, Win.MK_LBUTTON, t.start)
                clientMouse(Win.WM_LBUTTONUP, 0, t.start)
            }
            return true
        default:
            return false
        }
    }

    /// A finger on a strip of sub-tabs, which is told apart by which way it goes first. Up or down from a sub-tab picks it
    /// up, to drag to the tab bar or the other column. Sideways on the active sub-tab (or on any, when they all fit, as
    /// there's nothing to scroll) picks it up to put it somewhere else along the strip. Sideways anywhere else scrolls the
    /// strip, when its sub-tabs don't all fit. Not moving, it's a tap.
    private enum StripGesture { case undecided, drag, scroll, none }
    private struct StripTouch {
        let pane: TerminalPane
        let index: Int?
        let start: LPARAM
        let x: Float, y: Float
        var lastX: Float
        var gesture = StripGesture.undecided
    }
    private var stripTouch: StripTouch?

    /// A finger going down on a sub-tab, or between them; not on a close button, an arrow or the terminal button, which a
    /// finger taps as a mouse clicks.
    private func stripTouchStart(x: Float, y: Float, lParam: LPARAM) -> StripTouch? {
        guard !panes.isEmpty, dialog == nil, menu == nil, palette == nil, layout.part(atX: x, y: y) == .terminal else { return nil }
        let under = pane(atX: x)
        guard let strip = editorStrip(for: under), strip.strip.contains(x, y) else { return nil }
        switch strip.part(atX: x, y: y) {
        case .tab(let i)?: return StripTouch(pane: under, index: i, start: lParam, x: x, y: y, lastX: x)
        case nil: return StripTouch(pane: under, index: nil, start: lParam, x: x, y: y, lastX: x)
        default: return nil
        }
    }

    private func stripTouchMoved(_ lParam: LPARAM) {
        guard var t = stripTouch else { return }
        let (x, y) = clientPoint(lParam)
        if t.gesture == .undecided {
            let dx = x - t.x, dy = y - t.y
            guard max(abs(dx), abs(dy)) >= 8 * scale else { return }
            let overflows = editorStrip(for: t.pane)?.overflows ?? false
            if let i = t.index, abs(dy) > abs(dx) || i == t.pane.activeEditor || !overflows {
                t.gesture = .drag
                if t.pane !== activePane, let k = panes.firstIndex(where: { $0 === t.pane }) { activate(k) }
                var press = (pane: t.pane, index: i, x: t.x, y: t.y, dragging: false)
                beginStripDrag(&press)
            } else {
                t.gesture = overflows ? .scroll : .none
            }
            t.lastX = x
        }
        switch t.gesture {
        case .drag: _ = stripDragMouse(Win.WM_MOUSEMOVE, x: x, y: y)
        case .scroll:
            // The sub-tabs follow the finger.
            scrollStrip(t.pane, by: t.lastX - x)
            t.lastX = x
        default: break
        }
        stripTouch = t
    }

    private func stripTouchEnded(_ t: StripTouch, _ lParam: LPARAM) {
        let (x, y) = clientPoint(lParam)
        switch t.gesture {
        case .undecided:
            ReleaseCapture()
            clientMouse(Win.WM_LBUTTONDOWN, Win.MK_LBUTTON, t.start)
            clientMouse(Win.WM_LBUTTONUP, 0, t.start)
        case .drag:
            _ = stripDragMouse(Win.WM_LBUTTONUP, x: x, y: y)
        default:
            ReleaseCapture()
        }
        invalidate()
    }

    /// What a finger at a point would scroll: how far it moves per step, and the step. Nil where nothing scrolls (the tab
    /// bar, the status bar, a question, a strip of sub-tabs), so a finger there presses and drags as a mouse would.
    private func touchTarget(x: Float, y: Float, lParam: LPARAM) -> (Float, (Int) -> Void)? {
        guard !panes.isEmpty, dialog == nil else { return nil }
        if let menu {
            guard menu.frame.contains(x, y) else { return nil }
            return (1, { [weak self] in self?.menu?.scrollBy(-Float($0)) })
        }
        if palette != nil { return ((34 * scale).rounded(), { [weak self] in self?.palette?.scroll(by: -$0) }) }
        let part = layout.part(atX: x, y: y)
        if part == .leftSidebar || part == .rightSidebar {
            let isLeft = part == .leftSidebar
            // On the row that's selected already, a finger picks it up to drag, as a mouse would: tap a file, then drag
            // it. Anywhere else, the list scrolls.
            let sidebar = isLeft ? left : right, l = sidebarLayout(sidebar)
            if let i = l.visibleRow(atY: y).map({ $0 + sidebar.tree.scrollTop }), sidebar.tree.rows.indices.contains(i),
               sidebar.tree.rows[i].entry.path == sidebar.tree.selection { return nil }
            return ((22 * scale).rounded(), { [weak self] steps in
                guard let self else { return }
                let sidebar = isLeft ? self.left : self.right
                sidebar.tree.scroll(by: -steps, rowsShowing: self.sidebarLayout(sidebar).rowsShowing)
            })
        }
        guard part == .terminal else { return nil }
        let under = pane(atX: x), split = editorSplit(for: under)
        if let editor = split.editor, editor.contains(x, y) || !split.showsTerminal {
            guard let page = split.page, page.contains(x, y), under.panel != nil else { return nil }
            return (under.lineHeight, { [weak self, weak under] lines in
                guard let self, let under, let panel = under.panel, let page = self.editorSplit(for: under).page else { return }
                panel.scroll(lines: lines, x: x, y: y, in: page, scale: self.scale)
            })
        }
        return (under.lineHeight, { [weak under] in under?.touchScroll(lines: $0, at: lParam) })
    }

    private func clientMouse(_ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) {
        guard !panes.isEmpty else { return }
        let (x, y) = clientPoint(lParam)
        if moonMouse(message, x: x, y: y) { return }
        if dialog != nil {
            dialogMouse(message, x: x, y: y)
            return
        }
        if menu == nil, palette == nil, !notices.isEmpty,
           notices.mouse(message, x: x, y: y, canvas: canvas, windowWidth: Float(clientWidth), top: layout.tabBarHeight, scale: scale) {
            invalidate()
            return
        }
        if CornerNoticeStack.changed { invalidate() }
        if menu != nil {
            menuMouse(message, x: x, y: y)
            return
        }
        if palette != nil {
            paletteMouse(message, x: x, y: y)
            return
        }
        let part = layout.part(atX: x, y: y)
        // The line between a tab's pages and its terminal, while it's dragged, wherever the pointer goes.
        if draggingEditorLine != nil {
            _ = editorMouse(message, part: part, x: x, y: y)
            return
        }
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
        if tabDragMouse(message, x: x, y: y) { return }
        if stripDragMouse(message, x: x, y: y) { return }
        if chipDragMouse(message, x: x, y: y) { return }
        if part == .statusBar && !terminalHasMouse && statusBarMouse(message, x: x, y: y) { return }
        if part != .statusBar && hoveredCrumb != nil {
            hoveredCrumb = nil
            invalidate()
        }
        if sidebarMouse(message, part: part, x: x, y: y) { return }
        if part == .terminal && !terminalHasMouse && lostBarMouse(message, x: x, y: y) { return }
        if part == .terminal && !terminalHasMouse && pane(atX: x).findMouse(message, x: x, y: y) {
            if message == Win.WM_LBUTTONDOWN { focusTerminal() }
            invalidate()
            return
        }
        let under = pane(atX: x)
        // The pages above a tab's terminal, their strip, and the line between.
        if editorMouse(message, part: part, x: x, y: y) { return }
        if message == Win.WM_LBUTTONDOWN || message == Win.WM_RBUTTONDOWN || message == Win.WM_MBUTTONDOWN || message == Win.WM_LBUTTONDBLCLK {
            terminalHasMouse = part == .terminal
            if part == .terminal {
                // A press in the other column gives it the keyboard.
                if under !== activePane, let i = panes.firstIndex(where: { $0 === under }) { activate(i) }
                setEditorFocus(false, in: under)
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
            if case .chip(let first) = part, let g = panes[first].group, let chip = layout.chip(first) {
                chipPress = (g, x - chip.x, x, false)
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
                case .shell: showShellMenu()
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
            // Right-click on +: which shell the new tab runs.
            if part == .newTab { showNewTabShells(column: 0) }
            if part == .newTabRight { showNewTabShells(column: 1) }
            if part == .shell { showShellMenu() }
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
        visiblePanes.forEach { refreshGit($0) }
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
        if !panes.isEmpty {
            setEditorFocus(false, in: activePane)
            activePane.setFocused(false)
        }
        invalidate()
    }

    private func focusTerminal() {
        guard sidebarHasFocus else { return }
        left.isFocused = false
        right.isFocused = false
        if !panes.isEmpty { setEditorFocus(false, in: activePane) }
        if !panes.isEmpty { activePane.setFocused(isFocused) }
        invalidate()
    }

    /// A folder opens or closes, and a file shows above the terminal with the keyboard (Space, or Ctrl+Down).
    private func activate(_ entry: FileEntry, in sidebar: FileSidebar) {
        if entry.isDirectory { sidebar.tree.toggle(entry.path) } else { showFile(entry.path, in: pane(for: sidebar), remote: remoteIfUnix(entry.path, sidebar), focus: true) }
    }

    private func remoteIfUnix(_ path: String, _ sidebar: FileSidebar) -> RemoteConnection? { AnyPath.isUnix(path) ? remote(for: sidebar) : nil }

    /// A file shown above a tab's terminal, as on the Mac: a sub-tab of its own, or the one it has already. From this PC,
    /// or from the ssh host a sidebar shows.
    /// `line` (from 1) in view, with `text` (a search's query) selected on it.
    func showFile(_ path: String, in pane: TerminalPane, remote: RemoteConnection? = nil, line: Int? = nil, text: String? = nil, focus: Bool = true) {
        if AnyPath.isUnix(path) && remote == nil { return fileProblem() }
        let key = "file\n" + (remote.map { "\(ObjectIdentifier($0).hashValue)" } ?? "local") + "\n" + path
        if let i = pane.editors.firstIndex(where: { $0.key == key }) {
            pane.activeEditor = i
            revealActiveSubTab(pane)
            if let line, let panel = pane.editors[i].panel as? FileEditorPanel { panel.reveal(line: line, text: text) }
            if focus { setEditorFocus(true, in: pane) }
            invalidate()
            return
        }
        let name = AnyPath.name(path), folder = AnyPath.parent(path) ?? ""
        let panel = FileEditorPanel(path: path, name: name, folder: folder, isLocal: remote == nil, read: { limit, done in
            if let remote { Self.readRemote(path, remote, limit: min(limit, 4 * 1024 * 1024), done) } else { Self.readLocal(path, limit: limit, done) }
        }, write: { data, done in
            if let remote { Self.writeRemote(path, remote, data, done) } else { Self.writeLocal(path, data, done) }
        }, signature: { done in
            if let remote { Self.remoteSignature(path, remote, done) } else { Self.localSignature(path, done) }
        }, readFrom: remote != nil ? nil : { offset, done in Self.readLocal(path, from: offset, done) })
        panel.invalidate = { [weak self] in self?.invalidate() }
        panel.post = { [weak self] work in self?.runOnWindowThread(work) }
        panel.close = { [weak self, weak panel] in if let self, let panel, let pane = self.owner(of: panel) { self.closeEditor(panel, in: pane) } }
        panel.copy = { [weak pane] text in pane?.setClipboard(text) }
        panel.paste = { [weak pane] in pane?.clipboardText() }
        panel.openPreview = { [weak self, weak panel] in if let self, let panel, let pane = self.owner(of: panel) { self.showPreview(path, in: pane, remote: remote) } }
        panel.cellSize = (canvas.metrics.cellWidth, canvas.metrics.cellHeight)
        panel.showMenu = { [weak self] items, r in
            guard let self else { return }
            self.openMenu(items, x: r.x, y: r.maxY + 4 * self.scale, above: false)
        }
        panel.askText = { [weak self] placeholder, action, done in self?.askForText(placeholder: placeholder, action: action, done) }
        panel.pickFile = { [weak self] title in self?.pickOneFile(title: title) }
        panel.openFolder = { [weak self] path in self?.onOpenFile(path) }
        if let line { panel.reveal(line: line, text: text) }
        openEditor(EditorItem(key: key, title: name, glyph: FileKind(name: name).glyph, panel: panel), in: pane, focus: focus)
    }

    /// Up to `limit` bytes of a file on this PC, off the window's thread; and whether there was more.
    static func readLocal(_ path: String, limit: Int, _ done: @escaping (Data?, Bool) -> Void) {
        Thread.detachNewThread {
            guard let handle = FileHandle(forReadingAtPath: path) else { return done(nil, false) }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: limit + 1) else { return done(Data(), false) }
            done(data.prefix(limit), data.count > limit)
        }
    }

    /// A file on this PC as Core's FileSync knows it: its modified time and size, off the window's thread (a network drive
    /// can be slow to answer). Nil when it isn't there.
    static func localSignature(_ path: String, _ done: @escaping (Bool, String?) -> Void) {
        Thread.detachNewThread {
            var data = WIN32_FILE_ATTRIBUTE_DATA()
            let found = wide(path).withUnsafeBufferPointer { GetFileAttributesExW($0.baseAddress, GetFileExInfoStandard, &data) }
            guard found, data.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) == 0 else { return done(true, nil) }
            let written = UInt64(data.ftLastWriteTime.dwHighDateTime) << 32 | UInt64(data.ftLastWriteTime.dwLowDateTime)
            let size = UInt64(data.nFileSizeHigh) << 32 | UInt64(data.nFileSizeLow)
            done(true, "\(written) \(size)")
        }
    }

    /// A file on an ssh host: one look over the sidebar's connection (see FileSync.statScript). Not answered when the
    /// connection can't say.
    private static func remoteSignature(_ path: String, _ remote: RemoteConnection, _ done: @escaping (Bool, String?) -> Void) {
        guard remote.state == .ready else { return done(false, nil) }
        remote.run(FileSync.statScript([path]), timeout: 8) { text, code in
            guard let text, code == 0, let found = FileSync.parseStats(text, paths: [path])[path] else { return done(false, nil) }
            done(true, found)
        }
    }

    /// The bytes of a file on this PC from `offset` to its end, and its size: for following one that grows.
    static func readLocal(_ path: String, from offset: Int, _ done: @escaping (Data?, Int) -> Void) {
        Thread.detachNewThread {
            guard let handle = FileHandle(forReadingAtPath: path) else { return done(nil, 0) }
            defer { try? handle.close() }
            guard let size = try? handle.seekToEnd(), Int(size) >= offset, (try? handle.seek(toOffset: UInt64(offset))) != nil,
                  let data = try? handle.readToEnd() else { return done(nil, 0) }
            done(data, Int(size))
        }
    }

    /// Writes a file on this PC, in place (so it keeps its permissions and links), off the window's thread.
    static func writeLocal(_ path: String, _ data: Data, _ done: @escaping (String?) -> Void) {
        Thread.detachNewThread {
            do {
                try data.write(to: URL(fileURLWithPath: path))
                done(nil)
            } catch {
                done(error.localizedDescription)
            }
        }
    }

    /// Writes a file on an ssh host over the sidebar's connection, as base64 that the host decodes into a file beside it,
    /// then moves into place, so a dropped connection never leaves it half written.
    private static func writeRemote(_ path: String, _ remote: RemoteConnection, _ data: Data, _ done: @escaping (String?) -> Void) {
        guard data.count <= 4 * 1024 * 1024 else { return done("files over 4 MB can't be saved on an ssh host yet") }
        let q = RemoteConnection.quote(path), temp = RemoteConnection.quote(path + ".solanum-saving")
        let script = "base64 -d > \(temp) <<'SOLANUM_EOF'\n\(data.base64EncodedString(options: .lineLength76Characters))\nSOLANUM_EOF\n"
            + "cat \(temp) > \(q) && rm -f \(temp)"
        remote.run(script, timeout: 60) { _, code in done(code == 0 ? nil : "the host said no (exit \(code))") }
    }

    /// A Markdown file rendered, in a sub-tab of its own beside its editor, as on the Mac.
    func showPreview(_ path: String, in pane: TerminalPane, remote: RemoteConnection? = nil) {
        if AnyPath.isUnix(path) && remote == nil { return fileProblem() }
        let key = "preview\n" + (remote.map { "\(ObjectIdentifier($0).hashValue)" } ?? "local") + "\n" + path
        if focusEditor(key, in: pane) { return }
        let name = AnyPath.name(path)
        let panel = MarkdownPreviewPanel(path: path, name: name) { limit, done in
            if let remote { Self.readRemote(path, remote, limit: limit, done) } else { Self.readLocal(path, limit: limit, done) }
        }
        panel.invalidate = { [weak self] in self?.invalidate() }
        panel.post = { [weak self] work in self?.runOnWindowThread(work) }
        panel.close = { [weak self, weak panel] in if let self, let panel, let pane = self.owner(of: panel) { self.closeEditor(panel, in: pane) } }
        panel.cellSize = (canvas.metrics.cellWidth, canvas.metrics.cellHeight)
        panel.copy = { [weak self] text in self?.activePane.setClipboard(text) }
        panel.paste = { [weak self] in self?.activePane.clipboardText() }
        panel.openLink = { [weak self, weak panel] target in
            guard let self else { return }
            let pane = panel.flatMap { self.owner(of: $0) }
            if target.contains("://") || target.hasPrefix("mailto:") { return self.onOpenURL(target) }
            // A file beside it: in the editor (or its preview, for Markdown).
            let file = String(target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            guard !file.isEmpty, let pane else { return }
            let full = AnyPath.isUnix(path) ? AnyPath.join(AnyPath.parent(path) ?? "", file)
                : WindowsPath.join(AnyPath.parent(path) ?? "", file.replacingOccurrences(of: "/", with: "\\"))
            if MarkdownDoc.isMarkdown(path: full) { self.showPreview(full, in: pane, remote: remote) } else { self.showFile(full, in: pane, remote: remote) }
        }
        openEditor(EditorItem(key: key, title: "Preview " + name, glyph: 0xE8A1, panel: panel), in: pane)
    }

    /// The same from an ssh host, over the sidebar's connection: its size, then its bytes in base64.
    private static func readRemote(_ path: String, _ remote: RemoteConnection, limit: Int, _ done: @escaping (Data?, Bool) -> Void) {
        let q = RemoteConnection.quote(path)
        remote.run("wc -c < \(q) && head -c \(limit) -- \(q) | base64", timeout: 60) { text, code in
            guard let text, code == 0 else { return done(nil, false) }
            let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            let total = Int(parts.first?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
            let data = parts.count > 1 ? Data(base64Encoded: String(parts[1]), options: .ignoreUnknownCharacters) : Data()
            done(data, total > limit)
        }
    }

    /// Takes the mouse when it's on a sidebar or its edge. Otherwise false, and it's someone else's.
    private func sidebarMouse(_ message: UINT, part: WindowPart, x: Float, y: Float) -> Bool {
        if let edge = draggingEdge {
            switch message {
            case Win.WM_MOUSEMOVE where edge == .columnDivider:
                splitFraction = layout.splitFraction(atX: x)
                layoutChanged()
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
        if message == Win.WM_LBUTTONDBLCLK && part == .columnDivider {
            // A double click puts the columns back to halves.
            splitFraction = 0.5
            layoutChanged()
            return true
        }
        if message == Win.WM_LBUTTONDOWN && (part == .leftEdge || part == .rightEdge || part == .columnDivider) {
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
                    let name = AnyPath.name(press.entry.path)
                    dragGhost = DragGhost(title: name, glyph: press.entry.isDirectory ? 0xE8B7 : FileKind(name: name).glyph, x: x, y: y,
                                          grabX: 16 * scale, grabY: 14 * scale)
                }
                dragGhost?.x = x
                dragGhost?.y = y
                [left, right].forEach { $0.dropFolder = nil }
                if case .folder(let over, let folder)? = dropSpot(atX: x, y: y) { over.dropFolder = folder }
                fileDragPoint = (x, y)
                invalidate()
                return true
            case Win.WM_LBUTTONUP:
                rowPress = nil
                fileDragPoint = nil
                dragGhost = nil
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
                } else if press.entry.path != FileTree.newItemPath {
                    // A click on a file shows it above the terminal, as on the Mac. The keyboard stays here.
                    let target = pane(for: press.sidebar), before = target.editors.count
                    showFile(press.entry.path, in: target, remote: remoteIfUnix(press.entry.path, press.sidebar), focus: false)
                    clickOpened = target.editors.count > before
                        ? (target.id, ObjectIdentifier(target.editors[target.editors.count - 1].panel), press.entry.path, Date()) : nil
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
            } else {
                // A double click gives the file a tab of its own, as on the Mac. Its first click showed it above this tab's
                // terminal: that's undone, so it isn't in both places.
                if let opened = clickOpened, opened.path == row.entry.path, Date().timeIntervalSince(opened.at) < 1.5,
                   let source = panes.first(where: { $0.id == opened.pane }),
                   let i = source.editors.firstIndex(where: { ObjectIdentifier($0.panel) == opened.panel }), !source.editors[i].panel.hasUnsavedChanges {
                    _ = detachEditor(at: i, from: source)
                }
                clickOpened = nil
                openFileTab(row.entry.path, remote: remoteIfUnix(row.entry.path, sidebar), column: pane(for: sidebar).column)
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
        case .newFile, .newFolder:
            // In the folder picked (or the picked file's), else the one the sidebar shows, as on the Mac.
            let picked = sidebar.tree.selection.flatMap { path in sidebar.tree.rows.first { $0.entry.path == path }?.entry }
            if let folder = targetFolder(picked, in: sidebar) { beginNew(folder: button == .newFolder, in: folder, sidebar) }
        case .refresh: sidebar.tree.refresh()
        case .search: showSearch(from: sidebar)
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



    // MARK: - Git

    /// Where a tab's git commands run: its folder here, or over ssh the host's, once the sidebar's connection is up.
    private func gitPlace(for pane: TerminalPane, top: Bool = false) -> GitPlace? {
        if pane.sshArguments != nil {
            guard let r = pane.remote, r.state == .ready, let dir = pane.remoteTerminalFolder ?? r.home else { return nil }
            return GitPlace(dir: top ? pane.git?.root ?? dir : dir, remote: r)
        }
        guard let dir = pane.terminal.cwd else { return nil }
        return GitPlace(dir: top ? pane.git.map { GitPlace(dir: "", remote: nil).localPath($0.root) } ?? dir : dir, remote: nil)
    }

    /// Reads the tab's repository state again, at most every few seconds unless `now`.
    private func refreshGit(_ pane: TerminalPane, now: Bool = false) {
        guard let place = gitPlace(for: pane) else {
            if pane.git != nil { pane.git = nil; invalidate() }
            pane.gitKey = nil
            return
        }
        if place.key != pane.gitKey {
            pane.gitKey = place.key
            pane.git = nil
            pane.gitCheckedAt = .distantPast
        }
        guard now || Date().timeIntervalSince(pane.gitCheckedAt) > 4 else { return }
        pane.gitCheckedAt = Date()
        let key = place.key
        place.run(GitInfo.statusScript, timeout: 15) { [weak self, weak pane] status, out, _ in
            let info = status == 0 ? GitInfo(statusOutput: out) : nil
            self?.runOnWindowThread {
                guard let self, let pane, pane.gitKey == key, info != pane.git else { return }
                pane.git = info
                self.invalidate()
            }
        }
    }

    func paneCommandFinished(_ pane: TerminalPane) {
        guard visiblePanes.contains(where: { $0 === pane }) else { return }
        refreshGit(pane, now: true)
    }

    /// Where a git menu goes: above the part of the status bar it came from.
    private var gitMenuAnchor: UIRect?

    /// Runs a git command for the tab, saying what's going on in the status bar; on failure, what git said, with an offer
    /// to run it in the terminal, where a password or passphrase can be typed.
    private func performGit(_ label: String, _ script: String, typed: String, for pane: TerminalPane, recover: ((String) -> Bool)? = nil) {
        guard let place = gitPlace(for: pane) else { return fileProblem() }
        pane.gitBusy = label
        invalidate()
        place.run(script, timeout: 300, errors: true) { [weak self, weak pane] status, out, err in
            self?.runOnWindowThread {
                guard let self, let pane else { return }
                pane.gitBusy = nil
                self.refreshGit(pane, now: true)
                pane.panel?.reload()
                guard status != 0 else { return self.invalidate() }
                let said = (err.isEmpty ? String(decoding: out, as: UTF8.self) : err).trimmingCharacters(in: .whitespacesAndNewlines)
                if recover?(said) == true { return }
                self.showGitProblem("\(typed) didn't work", said, typed: typed, for: pane)
            }
        }
    }

    private func showGitProblem(_ title: String, _ output: String, typed: String?, for pane: TerminalPane) {
        var items = [MenuItem(title: title, isEnabled: false)]
        for line in output.split(whereSeparator: \.isNewline).suffix(8) { items.append(MenuItem(title: "    " + String(line.prefix(110)), isEnabled: false)) }
        items.append(.separator)
        if let typed {
            let lock = GitInfo.leftoverLock(in: output)
            items.append(MenuItem(title: lock == nil ? "Run in Terminal" : "Remove the Lock in Terminal") { [weak pane] in
                // Removing a lock is only safe if no other git is running there, so that one waits for Enter.
                if let lock { pane?.typeCommand("rm -f \(RemoteConnection.quote(lock)) && \(typed)") } else { pane?.typeCommand(typed) }
            })
        }
        items.append(MenuItem(title: "OK") {})
        let a = gitMenuAnchor ?? layout.statusBar
        openMenu(items, x: a.x, y: a.y - 2 * scale, above: true)
    }

    private func gitClick(_ part: GitPart, at spot: UIRect) {
        gitMenuAnchor = spot
        let pane = activePane
        guard let info = pane.git else { return }
        switch part {
        case .branch: showBranches(for: pane)
        case .sync:
            var items: [MenuItem] = []
            if let upstream = info.upstream {
                items.append(MenuItem(title: "Tracking \(upstream)", isEnabled: false))
                items.append(MenuItem(title: info.behind > 0 ? "Pull (\(info.behind) incoming)" : "Pull") { [weak self, weak pane] in
                    pane.map { self?.performGit("Pulling…", "git pull", typed: "git pull", for: $0) }
                })
                items.append(MenuItem(title: info.ahead > 0 ? "Push (\(info.ahead) outgoing)" : "Push") { [weak self, weak pane] in
                    pane.map { self?.performGit("Pushing…", "git push", typed: "git push", for: $0) }
                })
                items.append(MenuItem(title: "Sync (Pull, then Push)") { [weak self, weak pane] in
                    pane.map { self?.performGit("Syncing…", "git pull && git push", typed: "git pull && git push", for: $0) }
                })
            } else if !info.detached {
                items.append(MenuItem(title: "Publish Branch") { [weak self, weak pane] in
                    pane.map { self?.performGit("Publishing…", "r=$(git remote | head -n 1)\n[ -n \"$r\" ] || { echo \"This repository has no remote to publish to.\" >&2; exit 1; }\ngit push -u \"$r\" HEAD",
                                                typed: "git push -u origin HEAD", for: $0) }
                })
            }
            items.append(.separator)
            items.append(MenuItem(title: "Fetch") { [weak self, weak pane] in
                pane.map { self?.performGit("Fetching…", "git fetch --all --prune", typed: "git fetch --all --prune", for: $0) }
            })
            items.append(MenuItem(title: "Show Git Graph") { [weak self] in self?.showGitGraph() })
            openMenu(items, x: spot.x, y: spot.y - 2 * scale, above: true)
        case .changes:
            var items = [MenuItem(title: "\(info.changes.count) changed file\(info.changes.count == 1 ? "" : "s")", isEnabled: false)]
            let place = gitPlace(for: pane)
            for c in info.changes.prefix(40) {
                let letter = GitLook.badge(c.code).letter
                let full = place.map { p in p.onHost ? AnyPath.join(info.root, c.path) : WindowsPath.join(p.localPath(info.root), c.path.replacingOccurrences(of: "/", with: "\\")) }
                // A host's files and deleted ones have nothing here to open.
                items.append(MenuItem(title: "\(letter)   \(c.path)", isEnabled: c.code != "D" && place?.onHost == false) { [weak self] in
                    if let full, let self { self.showFile(full, in: self.activePane) }
                })
            }
            if info.changes.count > 40 { items.append(MenuItem(title: "…and \(info.changes.count - 40) more", isEnabled: false)) }
            items.append(.separator)
            var show = MenuItem(title: "Show Git Changes") { [weak self] in self?.showGitChanges() }
            show.shortcut = "Ctrl+Shift+S"
            items.append(show)
            openMenu(items, x: spot.x, y: spot.y - 2 * scale, above: true)
        }
    }

    /// The branches, most recently committed to first, in the palette; picking one switches to it.
    private func showBranches(for pane: TerminalPane) {
        guard let place = gitPlace(for: pane), let info = pane.git else { return }
        place.run(GitBranch.script, timeout: 20) { [weak self, weak pane] status, out, _ in
            let branches = status == 0 ? GitBranch.parse(out) : []
            self?.runOnWindowThread {
                guard let self, let pane else { return }
                var items = [
                    PaletteItem(title: "Show Git Graph", category: "every branch's history", shortcut: "Ctrl+Shift+G") { [weak self] in self?.showGitGraph() },
                    PaletteItem(title: "Show Git Changes", category: "what's changed", shortcut: "Ctrl+Shift+S") { [weak self] in self?.showGitChanges() },
                    PaletteItem(title: "Create New Branch…", category: "from \(info.branch)") { [weak self, weak pane] in pane.map { self?.askForBranchName(for: $0) } },
                    PaletteItem(title: "Fetch", category: "update remote branches") { [weak self, weak pane] in
                        pane.map { self?.performGit("Fetching…", "git fetch --all --prune", typed: "git fetch --all --prune", for: $0) }
                    },
                ]
                let locals = branches.filter { !$0.isRemote }, remotes = branches.filter(\.isRemote)
                if !locals.isEmpty { items.append(.header("Branches")) }
                for b in locals {
                    let current = !info.detached && b.name == info.branch
                    items.append(PaletteItem(title: b.name, category: current ? "current · \(b.date)" : b.date) { [weak self, weak pane] in
                        if !current, let pane { self?.switchBranch(b.name, tracking: false, for: pane) }
                    })
                }
                if !remotes.isEmpty { items.append(.header("Remote branches")) }
                for b in remotes {
                    items.append(PaletteItem(title: b.name, category: b.date) { [weak self, weak pane] in pane.map { self?.switchBranch(b.name, tracking: true, for: $0) } })
                }
                self.palette = PaletteModel(items: items, placeholder: "Switch branch (on \(info.branch))…", icon: 0xE8AB, emptyMessage: "No branch by that name")
                self.hoveredPaletteRow = nil
                self.activePane.setFocused(false)
                self.invalidate()
            }
        }
    }

    private func switchBranch(_ branch: String, tracking: Bool, for pane: TerminalPane) {
        let q = RemoteConnection.quote(branch)
        let script = tracking ? "git switch --track \(q)" : "git switch \(q)"
        let local = tracking ? String(branch.split(separator: "/", maxSplits: 1).last ?? Substring(branch)) : branch
        performGit("Switching…", script, typed: tracking ? "git switch --track \(branch)" : "git switch \(branch)", for: pane) { [weak self, weak pane] said in
            // Changes in the way: offer to stash them first, as VS Code does.
            guard said.contains("would be overwritten") || said.contains("commit your changes or stash them"), let self, let pane else { return false }
            let a = self.gitMenuAnchor ?? self.layout.statusBar
            self.openMenu([
                MenuItem(title: "Your changes would be overwritten by switching to \(local).", isEnabled: false),
                .separator,
                MenuItem(title: "Stash Changes and Switch") { [weak self, weak pane] in
                    guard let pane else { return }
                    self?.performGit("Switching…", "git stash push -m \(RemoteConnection.quote("Solanum: before switching to \(local)")) && \(script)",
                                     typed: "git stash && git switch \(local)", for: pane)
                },
                MenuItem(title: "Cancel") {},
            ], x: a.x, y: a.y - 2 * self.scale, above: true)
            return true
        }
    }

    /// Asks for a new branch's name in the palette: Enter creates it from here and switches to it.
    private func askForBranchName(for pane: TerminalPane) {
        let from = pane.git?.branch ?? "HEAD"
        palette = PaletteModel(query: "", placeholder: "New branch name, from \(from)", icon: 0xE8AB, emptyMessage: "Type the new branch's name") { [weak self, weak pane] typed in
            let name = typed.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, let pane else { return [] }
            return [PaletteItem(title: "Create Branch “\(name)”", category: "from \(from), and switch to it", shortcut: "Enter") { [weak self] in
                self?.performGit("Creating branch…", "git switch -c \(RemoteConnection.quote(name))", typed: "git switch -c \(name)", for: pane)
            }]
        }
        activePane.setFocused(false)
        invalidate()
    }

    /// Git Changes or Git Graph above the active tab's terminal, at its repository's top folder.
    func showGitChanges() {
        let pane = activePane
        guard let place = gitPlace(for: pane, top: true) else { return fileProblem() }
        let key = "changes\n" + place.key
        if focusEditor(key, in: pane) { return }
        let panel = GitChangesPanel(place: place)
        wire(panel, in: pane)
        openEditor(EditorItem(key: key, title: "Git Changes", glyph: EditorItem.Glyph.changes, panel: panel), in: pane)
    }

    func showGitGraph() {
        let pane = activePane
        guard let place = gitPlace(for: pane, top: true) else { return fileProblem() }
        let key = "graph\n" + place.key
        if focusEditor(key, in: pane) { return }
        let panel = GitGraphPanel(place: place)
        panel.invalidate = { [weak self] in self?.invalidate() }
        panel.post = { [weak self] work in self?.runOnWindowThread(work) }
        panel.copy = { [weak pane] text in pane?.setClipboard(text) }
        panel.close = { [weak self, weak panel] in if let self, let panel, let pane = self.owner(of: panel) { self.closeEditor(panel, in: pane) } }
        panel.openCommit = { [weak self, weak pane] hash, subject in pane.map { self?.showCommit(hash, subject: subject, place: place, in: $0) } }
        panel.showMenu = { [weak self] items, r in
            guard let self else { return }
            self.openMenu(items, x: r.x, y: r.maxY + 4 * self.scale, above: false)
        }
        panel.pickFromList = { [weak self] placeholder, choices, done in self?.pickFromList(placeholder, choices, done) }
        panel.paste = { [weak pane] in pane?.clipboardText() }
        openEditor(EditorItem(key: key, title: "Git Graph", glyph: EditorItem.Glyph.graph, panel: panel), in: pane)
    }

    /// One commit's files and changes, as the Mac's Git page shows them, in a sub-tab of its own.
    func showCommit(_ hash: String, subject: String, place: GitPlace, in pane: TerminalPane) {
        let key = "commit\n" + hash + "\n" + place.key
        if focusEditor(key, in: pane) { return }
        let panel = GitCommitPanel(place: place, hash: hash)
        panel.invalidate = { [weak self] in self?.invalidate() }
        panel.post = { [weak self] work in self?.runOnWindowThread(work) }
        panel.copy = { [weak pane] text in pane?.setClipboard(text) }
        panel.cellSize = (canvas.metrics.cellWidth, canvas.metrics.cellHeight)
        panel.close = { [weak self, weak panel] in if let self, let panel, let pane = self.owner(of: panel) { self.closeEditor(panel, in: pane) } }
        let title = String(hash.prefix(7)) + (subject.isEmpty ? "" : " " + subject)
        openEditor(EditorItem(key: key, title: title, glyph: EditorItem.Glyph.commit, panel: panel), in: pane)
    }

    private func wire(_ panel: GitChangesPanel, in pane: TerminalPane) {
        panel.invalidate = { [weak self] in self?.invalidate() }
        panel.post = { [weak self] work in self?.runOnWindowThread(work) }
        panel.statusChanged = { [weak self, weak pane] in pane.map { self?.refreshGit($0, now: true) } }
        panel.close = { [weak self, weak panel] in if let self, let panel, let pane = self.owner(of: panel) { self.closeEditor(panel, in: pane) } }
        panel.cellSize = (canvas.metrics.cellWidth, canvas.metrics.cellHeight)
        panel.confirm = { [weak self] question, button, run in
            self?.ask(DialogModel(title: button + "?", message: question, primary: button, run: run))
        }
    }

    // MARK: - Session and restart

    /// Set once Restart has saved (or, starting fresh, cleared) the session, so closing doesn't write it again.
    private var sessionHandled = false

    private func currentSession() -> SavedSession {
        var groups: [TabGroup] = []
        let tabs = panes.map { pane -> SavedSession.Tab in
            var group: Int?
            if let g = pane.group {
                if let i = groups.firstIndex(where: { $0 === g }) { group = i } else { groups.append(g); group = groups.count - 1 }
            }
            // A tab on an ssh host comes back on this PC, with what it showed.
            var tab = SavedSession.Tab(folder: pane.sshArguments == nil ? pane.terminal.cwd : nil, title: pane.customTitle, column: pane.column,
                                       group: group, text: pane.terminal.restorableText(maxLines: SavedSession.lines),
                                       resume: pane.resumeCommand ?? pane.resumeOnShow)
            if let shell = pane.shell, shell != Shells.defaultShell { tab.shell = shell.id }
            // Its files on this PC, and their previews, as on the Mac (an ssh host's, and git's pages, aren't kept).
            var pages: [SavedSession.Page] = [], active: Int?
            for (i, item) in pane.editors.enumerated() {
                let parts = item.key.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3, parts[1] == "local", parts[0] == "file" || parts[0] == "preview" else { continue }
                if i == pane.activeEditor { active = pages.count }
                pages.append(SavedSession.Page(path: String(parts[2]), preview: parts[0] == "preview" ? true : nil))
            }
            if !pages.isEmpty {
                tab.pages = pages
                tab.activePage = active
                tab.terminalHidden = pane.showsTerminal ? nil : true
                tab.editorFraction = pane.editorFraction
            }
            return tab
        }
        var session = SavedSession(tabs: tabs, groups: groups.map { .init(name: $0.name, color: $0.color.rawValue, collapsed: $0.collapsed) },
                                   active: activeIndex, splitFraction: splitFraction)
        session.maximized = IsZoomed(hwnd)
        var placement = WINDOWPLACEMENT()
        placement.length = UINT(MemoryLayout<WINDOWPLACEMENT>.size)
        if GetWindowPlacement(hwnd, &placement) {
            let r = placement.rcNormalPosition
            session.frame = [r.left, r.top, r.right, r.bottom]
        }
        return session
    }

    func saveSession() {
        if panes.isEmpty { SavedSession.clear() } else { currentSession().save() }
    }

    /// The tabs, groups, split and frame of a saved session.
    private func restore(_ session: SavedSession) {
        if let f = session.frame, f.count == 4, f[2] > f[0], f[3] > f[1] {
            SetWindowPos(hwnd, nil, f[0], f[1], f[2] - f[0], f[3] - f[1], Win.SWP_NOZORDER | Win.SWP_NOACTIVATE)
        }
        splitFraction = session.splitFraction
        let groups = session.groups.map { saved -> TabGroup in
            let g = TabGroup(color: TabGroupColor(rawValue: saved.color) ?? .blue)
            g.name = saved.name
            g.collapsed = saved.collapsed
            return g
        }
        for tab in session.tabs {
            // A folder that's gone starts the shell where it would otherwise.
            let folder = tab.folder.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
            guard addPane(cwd: folder, restoring: tab.text, column: tab.column, shell: Shells.option(tab.shell)) else { continue }
            panes.last?.customTitle = tab.title
            panes.last?.resumeOnShow = tab.resume
            panes.last?.group = tab.group.flatMap { groups.indices.contains($0) ? groups[$0] : nil }
            // Its files come back above its terminal, those that are still there, the one that was showing showing; a
            // file tab comes back as one.
            let pane = activePane
            let pages = tab.pages ?? tab.file.map { [SavedSession.Page(path: $0, preview: nil)] } ?? []
            var shown: Int?
            for (i, page) in pages.enumerated() where FileManager.default.fileExists(atPath: page.path) {
                if page.preview == true { showPreview(page.path, in: pane) } else { showFile(page.path, in: pane, focus: false) }
                if i == tab.activePage { shown = pane.editors.count - 1 }
            }
            if !pane.editors.isEmpty {
                pane.activeEditor = shown ?? pane.editors.count - 1
                if let fraction = tab.editorFraction { pane.editorFraction = fraction }
                if tab.terminalHidden == true || (tab.pages == nil && tab.file != nil) {
                    pane.showsTerminal = false
                    setEditorFocus(true, in: pane)
                } else {
                    setEditorFocus(false, in: pane)
                }
            }
        }
        normalizeColumns()
        if panes.indices.contains(session.active) { activate(session.active) }
        layoutChanged()
    }

    /// Asks first, as restarting stops what's running in the tabs (agents and ssh sessions carry on in the new one).
    func confirmRestart(fresh: Bool) {
        ask(fresh ? DialogModel(title: "Restart Solanum fresh?", message: "Everything open now closes, and Solanum starts again with a single new tab.",
                                primary: "Restart Fresh") { [weak self] in self?.restart(fresh: true) }
                  : DialogModel(title: "Restart Solanum?", message: "Your tabs, groups and splits come back as they are, and Claude Code, other agents and ssh sessions carry on where they were.",
                                primary: "Restart") { [weak self] in self?.restart(fresh: false) })
    }

    // MARK: - Questions

    /// A question asked over the window, Windows 11's way (see DialogView).
    private var dialog: DialogModel?

    func ask(_ question: DialogModel) {
        closeMenu()
        if palette != nil { closePalette() }
        dialog = question
        invalidate()
    }

    /// The button picked: the main one, then (when there is one) the other, then Cancel.
    private func answer(_ button: Int) {
        guard let current = dialog else { return }
        dialog = nil
        invalidate()
        if button == 0 { current.run() } else if button == 1, let other = current.other { other.run() }
    }

    private func dialogMouse(_ message: UINT, x: Float, y: Float) {
        guard var current = dialog else { return }
        let hit = DialogLayout(current, width: Float(clientWidth), height: Float(clientHeight), scale: scale, canvas: canvas).button(atX: x, y: y)
        switch message {
        case Win.WM_MOUSEMOVE: current.hovered = hit
        case Win.WM_LBUTTONDOWN, Win.WM_LBUTTONDBLCLK: current.pressed = hit
        case Win.WM_LBUTTONUP:
            if let hit, hit == current.pressed { return answer(hit) }
            current.pressed = nil
        default: break
        }
        if current.hovered != dialog?.hovered || current.pressed != dialog?.pressed {
            dialog = current
            invalidate()
        }
    }

    private func dialogKey(_ key: Int32) -> Bool {
        switch key {
        case Win.VK_RETURN, Win.VK_SPACE: answer(0)
        case Win.VK_ESCAPE: answer(Int.max)
        default: break
        }
        return true
    }

    /// For tests.
    var dialogTitle: String? { dialog?.title }

    /// Ctrl+Shift+R, as the Mac's Shift-Command-R: saves what's open, starts Solanum.exe (the newest build) and closes,
    /// so everything comes back in it. Fresh (Ctrl+Alt+Shift+R) brings nothing back.
    func restart(fresh: Bool) {
        if fresh { SavedSession.clear() } else { saveSession() }
        sessionHandled = true
        guard AppRestart.launch() else {
            sessionHandled = false
            return fileProblem()
        }
        PostMessageW(hwnd, Win.WM_CLOSE, 0, 0)
    }

    // MARK: - Jump to Prompt

    /// Ctrl+J, as the Mac's Command-J: the prompts sent to Claude Code in this tab, newest first, to search and jump
    /// to; then the commands run there.
    func showSentPrompts() {
        let pane = activePane
        let prompts = pane.sentPrompts(), commands = pane.finishedCommands()
        guard !prompts.isEmpty || !commands.isEmpty else { return fileProblem() }
        var items: [PaletteItem] = []
        if !prompts.isEmpty { items.append(.header("Prompts")) }
        for p in prompts.reversed() {
            let first = p.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? p.text
            items.append(PaletteItem(title: first, category: p.detail) { [weak self, weak pane] in self?.jump(to: p.stop, in: pane) })
        }
        if !commands.isEmpty { items.append(.header("Commands")) }
        for c in commands.reversed() {
            items.append(PaletteItem(title: c.command, category: c.failed ? "failed" : "") { [weak self, weak pane] in self?.jump(to: c.stop, in: pane) })
        }
        palette = PaletteModel(items: items, placeholder: prompts.isEmpty ? "Jump to command…" : "Jump to prompt…", icon: 0xE721, emptyMessage: "Nothing sent matches")
        hoveredPaletteRow = nil
        pane.setFocused(false)
        invalidate()
    }

    private func jump(to stop: TerminalPane.BlockStop, in pane: TerminalPane?) {
        guard let pane else { return }
        setEditorFocus(false, in: pane)
        pane.select(stop)
    }

    // MARK: - Pages above the terminal

    /// The column a tab is shown in, pages and terminal together.
    private func columnArea(for pane: TerminalPane) -> UIRect { isSplit && pane.column == 1 ? rightTerminalArea : terminalArea }

    func editorSplit(for pane: TerminalPane) -> EditorSplit {
        EditorSplit(column: columnArea(for: pane), scale: scale, hasEditors: !pane.editors.isEmpty, showsTerminal: pane.showsTerminal,
                    fraction: pane.editorFraction)
    }

    private func editorStrip(for pane: TerminalPane, on target: Canvas? = nil) -> EditorStrip? {
        guard let strip = editorSplit(for: pane).strip else { return nil }
        return EditorStrip(canvas: target ?? canvas, strip: strip, scale: scale, items: pane.editors, scroll: pane.stripScroll)
    }

    /// Scrolls a tab's sub-tabs along by `pixels` (positive goes further along), as far as there is.
    private func scrollStrip(_ pane: TerminalPane, by pixels: Float) {
        guard let strip = editorStrip(for: pane) else { return }
        pane.stripScroll = min(max(min(pane.stripScroll, strip.maxScroll) + pixels, 0), strip.maxScroll)
        invalidate()
    }

    /// Brings the active sub-tab into view, when they don't all fit.
    private func revealActiveSubTab(_ pane: TerminalPane) {
        guard let strip = editorStrip(for: pane) else { return }
        pane.stripScroll = strip.revealing(pane.activeEditor)
    }

    /// Goes back to a page that's open already, with the keyboard. False if it isn't open.
    private func focusEditor(_ key: String, in pane: TerminalPane) -> Bool {
        guard let i = pane.editors.firstIndex(where: { $0.key == key }) else { return false }
        pane.activeEditor = i
        revealActiveSubTab(pane)
        setEditorFocus(true, in: pane)
        invalidate()
        return true
    }

    /// Opens a page above the tab's terminal, after the others, and gives it the keyboard unless `focus` is false.
    /// `reload` is false for a page moving from another tab, which keeps what it has (edits not yet saved among them).
    private func openEditor(_ item: EditorItem, in pane: TerminalPane, focus: Bool = true, reload: Bool = true) {
        let first = pane.editors.isEmpty
        pane.editors.append(item)
        pane.activeEditor = pane.editors.count - 1
        if first { pane.showsTerminal = true }
        revealActiveSubTab(pane)
        if focus { setEditorFocus(true, in: pane) }
        if reload { item.panel.reload() }
        // The terminal gives up room to the pages the first time they come.
        if first { layoutChanged() } else { invalidate() }
    }

    /// Closes a page; the one before it shows, or with none left the terminal has the column again.
    func closeEditor(_ panel: ColumnPanel, in pane: TerminalPane) {
        guard let i = pane.editors.firstIndex(where: { $0.panel === panel }) else { return }
        closeEditor(at: i, in: pane)
    }

    private func closeEditor(at i: Int, in pane: TerminalPane, force: Bool = false) {
        guard pane.editors.indices.contains(i) else { return }
        let item = pane.editors[i]
        if !force, item.panel.hasUnsavedChanges {
            pane.activeEditor = i
            let panel = item.panel
            ask(DialogModel(title: "Save changes to \(item.title)?", message: "Your changes will be lost if you don't save them.", primary: "Save",
                            other: ("Don't Save", { [weak self, weak pane, weak panel] in
                                if let self, let pane, let panel, let k = pane.editors.firstIndex(where: { $0.panel === panel }) { self.closeEditor(at: k, in: pane, force: true) }
                            })) { [weak self, weak pane, weak panel] in
                panel?.save { saved in
                    if saved, let self, let pane, let panel, let k = pane.editors.firstIndex(where: { $0.panel === panel }) { self.closeEditor(at: k, in: pane, force: true) }
                }
            })
            return
        }
        pane.editors.remove(at: i)
        if pane.editors.isEmpty {
            pane.activeEditor = 0
            // A file tab left with nothing closes, as on the Mac.
            if !pane.showsTerminal, let k = panes.firstIndex(where: { $0 === pane }) { return closeTab(k) }
            pane.showsTerminal = true
            setEditorFocus(false, in: pane)
            layoutChanged()
            return
        }
        if i < pane.activeEditor || pane.activeEditor >= pane.editors.count { pane.activeEditor = max(pane.activeEditor - 1, 0) }
        invalidate()
    }

    /// Hides or shows the terminal under the pages. With it hidden the keyboard stays with the pages.
    private func toggleTerminal(in pane: TerminalPane) {
        guard !pane.editors.isEmpty else { return }
        pane.showsTerminal.toggle()
        setEditorFocus(!pane.showsTerminal, in: pane)
        layoutChanged()
    }

    // MARK: - File tabs

    /// The tab a page is open in, wherever it's moved since it was opened.
    func owner(of panel: ColumnPanel) -> TerminalPane? { panes.first { pane in pane.editors.contains { $0.panel === panel } } }

    /// Where a new file tab goes in a column, unless it's said: just after the active tab when that's in the column, as
    /// on the Mac; else at the column's end.
    private func fileTabIndex(column: Int) -> Int? { activePane.column == column ? activeIndex + 1 : nil }

    /// A tab of its own for a file, as on the Mac: just the file, its terminal hidden (the button at the right of its
    /// strip shows it). The shell starts in the file's folder, on this PC.
    func openFileTab(_ path: String, remote: RemoteConnection? = nil, column: Int, at index: Int? = nil) {
        if AnyPath.isUnix(path) && remote == nil { return fileProblem() }
        let folder = remote == nil ? AnyPath.parent(path) : nil
        guard addPane(at: index ?? fileTabIndex(column: column), cwd: folder, column: column) else { return }
        let pane = activePane
        showFile(path, in: pane, remote: remote, focus: true)
        becomeFileTab(pane)
    }

    /// Hides a tab's terminal under its pages, the keyboard with them.
    private func becomeFileTab(_ pane: TerminalPane) {
        pane.showsTerminal = false
        setEditorFocus(true, in: pane)
        layoutChanged()
        detailsChanged()
    }

    /// Takes a page out of its tab, unsaved edits and all, to go somewhere else. A file tab left with nothing closes.
    private func detachEditor(at i: Int, from pane: TerminalPane) -> EditorItem? {
        guard pane.editors.indices.contains(i) else { return nil }
        let item = pane.editors.remove(at: i)
        if pane.editors.isEmpty {
            pane.activeEditor = 0
            if !pane.showsTerminal, let k = panes.firstIndex(where: { $0 === pane }) {
                closeTab(k)
            } else {
                pane.showsTerminal = true
                setEditorFocus(false, in: pane)
            }
        } else if i < pane.activeEditor || pane.activeEditor >= pane.editors.count {
            pane.activeEditor = max(pane.activeEditor - 1, 0)
        }
        return item
    }

    /// A page's sub-tab dragged to a tab strip: a file tab of its own there.
    private func moveEditorToOwnTab(at i: Int, from pane: TerminalPane, column: Int, at index: Int?) {
        // A file tab's only page is in a tab of its own already.
        if !pane.showsTerminal && pane.editors.count == 1 && pane.column == column { return }
        guard let item = pane.editors.indices.contains(i) ? pane.editors[i] : nil else { return }
        let folder = item.key.hasPrefix("file\nlocal\n") ? AnyPath.parent(String(item.key.dropFirst(11))) : pane.terminal.cwd
        guard addPane(at: index ?? fileTabIndex(column: column), cwd: folder, column: column) else { return }
        let tab = activePane
        _ = detachEditor(at: i, from: pane)
        openEditor(item, in: tab, focus: true, reload: false)
        becomeFileTab(tab)
    }

    /// A page's sub-tab dragged onto the other column's terminal: it goes above that column's tab's terminal.
    private func moveEditor(at i: Int, from pane: TerminalPane, into target: TerminalPane) {
        guard target !== pane, let item = detachEditor(at: i, from: pane) else { return }
        if let k = panes.firstIndex(where: { $0 === target }) { activate(k) }
        openEditor(item, in: target, focus: true, reload: false)
        layoutChanged()
    }

    /// A page's sub-tab held down, which may be dragged: along its strip, to put it somewhere else there; to a tab strip,
    /// for a file tab of its own; or over the other column's terminal, to go above it there. Let go without moving, it's
    /// a click, which the strip deals with.
    private var stripPress: (pane: TerminalPane, index: Int, x: Float, y: Float, dragging: Bool)?
    /// While one's dragged over the other column: that column, which lights up.
    private var editorDropColumn: Int?
    /// While one's dragged along its own strip: the sub-tab it would go in front of (the count, for the end).
    private var stripInsert: Int?

    /// Starts dragging the sub-tab held down: it lifts, and a copy of it follows the pointer from where it was grabbed.
    private func beginStripDrag(_ press: inout (pane: TerminalPane, index: Int, x: Float, y: Float, dragging: Bool)) {
        press.dragging = true
        stripPress = press
        SetCapture(hwnd)
        guard press.pane.editors.indices.contains(press.index), let strip = editorStrip(for: press.pane) else { return }
        let item = press.pane.editors[press.index], r = strip.tabs[press.index].rect
        dragGhost = DragGhost(title: item.title, glyph: item.glyph, x: press.x, y: press.y, grabX: press.x - r.x, grabY: press.y - r.y)
    }

    private func stripDragMouse(_ message: UINT, x: Float, y: Float) -> Bool {
        guard var press = stripPress else { return false }
        switch message {
        case Win.WM_MOUSEMOVE:
            if !press.dragging {
                guard abs(x - press.x) > 4 * scale || abs(y - press.y) > 4 * scale else { return false }
                beginStripDrag(&press)
            }
            dragGhost?.x = x
            dragGhost?.y = y
            fileDragPoint = (x, y)
            stripInsert = nil
            editorDropColumn = nil
            if let strip = editorStrip(for: press.pane), let along = stripAlong(strip, x: x, y: y) {
                // Along its own strip: where it would go there. Near either end of sub-tabs that don't all fit, they
                // scroll that way.
                let v = strip.viewport, edge = 24 * scale
                if strip.overflows && x < v.x + edge { scrollStrip(press.pane, by: -12 * scale) }
                if strip.overflows && x > v.maxX - edge { scrollStrip(press.pane, by: 12 * scale) }
                stripInsert = editorStrip(for: press.pane)?.insertion(atX: along) ?? strip.insertion(atX: along)
            } else {
                editorDropColumn = editorDropPane(atX: x, y: y, from: press.pane)?.column
            }
            invalidate()
            return true
        case Win.WM_LBUTTONUP:
            stripPress = nil
            guard press.dragging else { return false }
            ReleaseCapture()
            let insert = stripInsert
            fileDragPoint = nil
            editorDropColumn = nil
            stripInsert = nil
            dragGhost = nil
            if let spot = tabBarSpot(atX: x, y: y) {
                moveEditorToOwnTab(at: press.index, from: press.pane, column: spot.column, at: spot.at)
            } else if let insert {
                moveSubTab(in: press.pane, from: press.index, to: insert)
            } else if let target = editorDropPane(atX: x, y: y, from: press.pane) {
                moveEditor(at: press.index, from: press.pane, into: target)
            }
            invalidate()
            return true
        default:
            return false
        }
    }

    /// Whether a point is along a strip (a little above or below it counts), and where along its sub-tabs.
    private func stripAlong(_ strip: EditorStrip, x: Float, y: Float) -> Float? {
        let s = strip.strip, slack = 14 * scale
        guard y >= s.y - slack, y <= s.maxY + slack, x >= s.x, x <= s.maxX else { return nil }
        return min(max(x, strip.viewport.x), strip.viewport.maxX)
    }

    /// Puts a sub-tab in front of the one at `insert` (or at the end), keeping the same one active.
    private func moveSubTab(in pane: TerminalPane, from i: Int, to insert: Int) {
        guard pane.editors.indices.contains(i), insert != i, insert != i + 1 else { return }
        let active = pane.editors.indices.contains(pane.activeEditor) ? pane.editors[pane.activeEditor] : nil
        let item = pane.editors.remove(at: i)
        pane.editors.insert(item, at: min(insert > i ? insert - 1 : insert, pane.editors.count))
        pane.activeEditor = active.flatMap { a in pane.editors.firstIndex { $0 === a } } ?? 0
        invalidate()
    }

    // MARK: - What's dragged, under the pointer

    /// A copy of what's dragged (a tab, a group's chip, a sub-tab, a sidebar's file), drawn under the pointer wherever it
    /// goes, held where it was grabbed, so it's plain what's being moved.
    struct DragGhost {
        var title: String
        var glyph: UInt16?
        var x: Float, y: Float
        /// Where in it the pointer has it.
        var grabX: Float, grabY: Float
        var color: UInt32? = nil
    }
    private var dragGhost: DragGhost?

    private func drawDragGhost(on target: Canvas) {
        guard let g = dragGhost else { return }
        let s = scale, c = target.raw, pixels = 11.5 * s, accent = g.color ?? TerminalPalette.accent
        let units = Array(g.title.utf16)
        let text = sol_canvas_measure_label(c, units, Int32(units.count), pixels, 0)
        let iconWidth: Float = g.glyph != nil ? 22 * s : 0
        let w = min(max(text + iconWidth + 28 * s, 90 * s), 280 * s).rounded(), h = (28 * s).rounded()
        let x = (g.x - min(max(g.grabX, 10 * s), w - 10 * s)).rounded(), y = (g.y - min(max(g.grabY, 6 * s), h - 6 * s)).rounded()
        // Lifted off the window: a shadow under it, and an accent edge.
        sol_canvas_fill_rounded(c, x + 2 * s, y + 5 * s, w, h, 8 * s, 0x000000, 0.22)
        sol_canvas_fill_rounded(c, x + 1 * s, y + 2 * s, w, h, 8 * s, 0x000000, 0.18)
        sol_canvas_fill_rounded(c, x, y, w, h, 7 * s, TerminalPalette.surface, 1)
        sol_canvas_fill_rounded(c, x, y, w, h, 7 * s, accent, 0.10)
        sol_canvas_stroke_rounded(c, x + 0.75 * s, y + 0.75 * s, w - 1.5 * s, h - 1.5 * s, 7 * s, accent, 0.9, 1.5 * s)
        var tx = x + 12 * s
        if let glyph = g.glyph {
            sol_canvas_draw_icon(c, tx - 2 * s, y, 18 * s, h, glyph, 10.5 * s, accent, 0.95)
            tx += iconWidth
        }
        sol_canvas_draw_label(c, tx, y, x + w - 10 * s - tx, h, units, Int32(units.count), pixels, 0, TerminalPalette.foreground, 1)
    }

    /// While split, the other column's tab, when a sub-tab's dragged over its terminal.
    private func editorDropPane(atX x: Float, y: Float, from pane: TerminalPane) -> TerminalPane? {
        guard isSplit, layout.part(atX: x, y: y) == .terminal else { return nil }
        let under = self.pane(atX: x)
        return under.column != pane.column ? under : nil
    }

    /// The keyboard to the pages or to the terminal. The terminal's cursor shows hollow while the pages have it.
    func setEditorFocus(_ on: Bool, in pane: TerminalPane) {
        let wanted = !pane.editors.isEmpty && (on || !pane.showsTerminal)
        if pane.editorFocused != wanted {
            pane.editorFocused = wanted
            invalidate()
        }
        // The page and a sidebar don't both have the keyboard.
        if wanted && on && sidebarHasFocus {
            left.isFocused = false
            right.isFocused = false
        }
        if pane === activePane { pane.setFocused(isFocused && !wanted && !sidebarHasFocus) }
    }

    /// While the line between the pages and the terminal is dragged: the tab it belongs to.
    private weak var draggingEditorLine: TerminalPane?
    private var hoveredStrip: (pane: UInt, part: EditorStrip.Part)?

    /// The pointer has left a tab's pages: nothing there stays hovered.
    private func leaveEditors() {
        for pane in visiblePanes { pane.panel?.mouseLeft() }
        if hoveredStrip != nil {
            hoveredStrip = nil
            invalidate()
        }
    }

    /// The mouse over a tab's pages, their strip or the line under them. True if it dealt with it.
    private func editorMouse(_ message: UINT, part: WindowPart, x: Float, y: Float) -> Bool {
        if let pane = draggingEditorLine {
            if message == Win.WM_MOUSEMOVE {
                pane.editorFraction = editorSplit(for: pane).fraction(atY: y)
                invalidate()
            } else if message == Win.WM_LBUTTONUP {
                draggingEditorLine = nil
                ReleaseCapture()
                layoutChanged()
            }
            return true
        }
        guard !terminalHasMouse, part == .terminal else {
            leaveEditors()
            return false
        }
        let under = pane(atX: x), split = editorSplit(for: under)
        guard let editor = split.editor else {
            leaveEditors()
            return false
        }
        if let line = split.divider, line.contains(x, y) {
            leaveEditors()
            if message == Win.WM_LBUTTONDOWN {
                draggingEditorLine = under
                SetCapture(hwnd)
            }
            return true
        }
        guard editor.contains(x, y) else {
            leaveEditors()
            return false
        }
        let presses = [Win.WM_LBUTTONDOWN, Win.WM_RBUTTONDOWN, Win.WM_MBUTTONDOWN, Win.WM_LBUTTONDBLCLK]
        if presses.contains(message) {
            // A press on a tab's pages gives them the keyboard (and its column, while split).
            if under !== activePane, let i = panes.firstIndex(where: { $0 === under }) { activate(i) }
            setEditorFocus(true, in: under)
        }
        if message == Win.WM_MOUSEMOVE { setHovered(.terminal, nonClient: false) }
        if let strip = editorStrip(for: under), strip.strip.contains(x, y) {
            under.panel?.mouseLeft()
            let stripPart = strip.part(atX: x, y: y)
            let before = hoveredStrip
            hoveredStrip = stripPart.map { (under.id, $0) }
            if before?.pane != hoveredStrip?.pane || before?.part != hoveredStrip?.part { invalidate() }
            switch (message, stripPart) {
            case (Win.WM_LBUTTONDOWN, .tab(let i)?):
                // Held, it may be dragged off the strip (see `stripDragMouse`).
                stripPress = (under, i, x, y, false)
            case (Win.WM_LBUTTONUP, .tab(let i)?):
                under.activeEditor = i
                revealActiveSubTab(under)
                invalidate()
            case (Win.WM_LBUTTONUP, .scrollLeft?), (Win.WM_LBUTTONUP, .scrollRight?):
                // A sub-tab's width or so at a time, as the tab bar's arrows go.
                scrollStrip(under, by: (stripPart == .scrollLeft ? -1 : 1) * 160 * scale)
            case (Win.WM_LBUTTONUP, .close(let i)?), (Win.WM_MBUTTONUP, .tab(let i)?), (Win.WM_MBUTTONUP, .close(let i)?):
                closeEditor(at: i, in: under)
            case (Win.WM_LBUTTONUP, .terminal?):
                toggleTerminal(in: under)
            default: break
            }
            return true
        }
        if hoveredStrip != nil {
            hoveredStrip = nil
            invalidate()
        }
        if let panel = under.panel, let page = split.page {
            _ = panel.mouse(message, x: x, y: y, in: page, scale: scale)
        }
        return true
    }

    /// Draws a tab's pages (strip and active page), its terminal, and the line between.
    private func drawColumn(_ pane: TerminalPane, on target: Canvas, snapshot: Bool) {
        let split = editorSplit(for: pane)
        if split.showsTerminal || pane.editors.isEmpty {
            if snapshot {
                target.terminalArea = area(for: pane)
                var renderer = TerminalRenderer(canvas: target, terminal: pane.terminal)
                renderer.scrollOffset = pane.scrollOffset
                renderer.focused = pane === activePane && !pane.editorFocused
                renderer.drawContents()
                pane.drawOverlays(on: target)
            } else {
                pane.draw(cursorShown: pane === activePane ? cursorShown : true, style: cursorStyleCode)
            }
        }
        guard let editor = split.editor, let strip = editorStrip(for: pane, on: target) else { return }
        sol_canvas_backdrop_rect(target.raw, editor.x, editor.y, editor.width, editor.height, TerminalPalette.background)
        if let page = split.page, let panel = pane.panel {
            panel.draw(on: target, in: page, scale: scale)
        }
        let held = stripPress.flatMap { $0.dragging && $0.pane === pane ? $0 : nil }
        strip.draw(active: pane.activeEditor, hovered: hoveredStrip?.pane == pane.id ? hoveredStrip?.part : nil, showsTerminal: pane.showsTerminal,
                   focused: pane.editorFocused && pane === activePane, dragged: held?.index, marker: held == nil ? nil : stripInsert)
        if split.showsTerminal {
            Self.drawBand(UIRect(x: editor.x, y: editor.maxY, width: editor.width, height: split.bandHeight), vertical: false, on: target, scale: scale,
                          active: draggingEditorLine === pane)
        }
    }

    // MARK: - Search in Project Folder

    private struct Search {
        let folder: String
        let place: GitPlace
        var query = ""
        var results: [WorkspaceMatch] = []
        var running = false
        /// It hit the time limit.
        var stopped = false
        var generation = 0
    }
    private var search: Search?

    /// Ctrl+Shift+F: the text of the files under the folder the sidebar is on (or the terminal's), as on the Mac.
    /// `from`: the sidebar whose magnifying glass was pressed, which searches its own folder.
    func showSearch(from pressed: FileSidebar? = nil) {
        let pane = pressed.map { self.pane(for: $0) } ?? activePane
        let sidebar = pressed ?? (pane.column == 1 && rightIsShowing ? right : left)
        let onHost = pane.sshArguments != nil
        let folder = (sidebar.isVisible ? sidebar.tree.root : nil).flatMap { AnyPath.isUnix($0) == onHost ? $0 : nil }
            ?? (onHost ? pane.remoteFolder : pane.terminal.cwd)
        guard let folder else { return fileProblem() }
        let place = GitPlace(dir: folder, remote: onHost ? pane.remote : nil)
        guard !onHost || place.remote?.state == .ready else { return fileProblem() }
        search = Search(folder: folder, place: place)
        palette = PaletteModel(query: "", placeholder: "Search in \(AnyPath.name(folder))…", icon: 0xE721,
                               emptyMessage: "Type to search the files in \(AnyPath.name(folder))") { [weak self] typed in self?.searchRows(typed) ?? [] }
        activePane.setFocused(false)
        invalidate()
    }

    /// As the Mac's: a header for each file and its matching lines under it, the query highlighted by being selected
    /// when one's opened, and a count of results and files.
    private func searchRows(_ typed: String) -> [PaletteItem] {
        guard var s = search else { return [] }
        let query = typed.trimmingCharacters(in: .whitespaces)
        if query != s.query {
            s.query = query
            s.results = []
            s.generation += 1
            s.running = query.count >= 2
            s.stopped = false
            search = s
            if query.count >= 2 { startSearch(query, generation: s.generation) }
        }
        let shown = AnyPath.name(s.folder)
        guard !query.isEmpty else { return [] }
        guard query.count >= 2 else { return [.header("Keep typing\u{2026}")] }
        let folder = s.folder, remote = s.place.remote
        let matches = Array(s.results.prefix(WorkspaceMatch.limit))
        var rows: [PaletteItem] = []
        var last: String?
        for m in matches {
            if m.path != last {
                var header = PaletteItem.header(m.path)
                header.keepsCase = true
                rows.append(header)
                last = m.path
            }
            rows.append(PaletteItem(title: WorkspaceMatch.excerpt(m.text, query: query), category: "line \(m.line)") { [weak self] in
                guard let self else { return }
                let path = remote != nil ? AnyPath.join(folder, m.path) : WindowsPath.join(folder, m.path.replacingOccurrences(of: "/", with: "\\"))
                self.showFile(path, in: self.activePane, remote: remote, line: m.line, text: query)
            })
        }
        let files = Set(matches.map(\.path)).count
        let count = s.results.count > matches.count ? "The first \(matches.count) results"
            : s.running ? "Searching\u{2026} \(matches.count) so far"
            : s.stopped ? "\(matches.count), stopped after 20 seconds"
            : "\(matches.count) result\(matches.count == 1 ? "" : "s")"
        if rows.isEmpty {
            return [.header(s.running ? "Searching\u{2026}" : s.stopped ? "Nothing found before the 20 second limit"
                            : "Nothing in \(shown) has \u{201C}\(query)\u{201D}")]
        }
        rows.insert(.header("\(count) in \(files) file\(files == 1 ? "" : "s") \u{00B7} \(shown)"), at: 0)
        return rows
    }

    /// After a moment without typing, so each key doesn't start a search of its own. Stopped after 20 seconds, as on the Mac.
    private func startSearch(_ query: String, generation: Int) {
        Thread.detachNewThread { [weak self] in
            Thread.sleep(forTimeInterval: 0.18)
            self?.runOnWindowThread {
                guard let self, let s = self.search, s.generation == generation else { return }
                let script = s.place.onHost ? WorkspaceMatch.remoteScript(query: query) : WorkspaceMatch.localScript(query: query, dir: GitPlace.shPath(s.folder))
                // The local script goes to its folder itself.
                let place = s.place.onHost ? s.place : GitPlace(dir: s.folder, remote: nil)
                let started = Date()
                place.run(script, timeout: 20) { [weak self] status, out, _ in
                    let found = WorkspaceMatch.parse(out)
                    let stopped = status == 124 || (status != 0 && status != 1 && Date().timeIntervalSince(started) >= 19.5)
                    self?.runOnWindowThread {
                        guard let self, var s = self.search, s.generation == generation else { return }
                        s.results = found
                        s.running = false
                        s.stopped = stopped
                        self.search = s
                        self.palette?.refresh()
                        self.invalidate()
                    }
                }
            }
        }
    }

    // MARK: - Send to Chat

    /// Ctrl+Alt+S, as the Mac's Option-Command-S: the picked (or last) command and what it printed, to an agent's chat.
    /// The menu has the chats running in any window, this one's first, then a new chat with each agent on this PC.
    func showSendToChat() {
        guard !panes.isEmpty, let text = activePane.chatTranscript else { return fileProblem() }
        let from = activePane
        InstalledAgents.shared.refresh(post: { [weak self] work in self?.runOnWindowThread(work) })
        var items: [MenuItem] = []
        let others = Self.windows.values.filter { $0 !== self }
        let chats = ([self] + others).flatMap { window in window.panes.compactMap { p in p.agent.map { (window, p, $0) } } }
            .filter { $0.2.status != .failed }
        if !chats.isEmpty { items.append(MenuItem(title: "Active Chats", isEnabled: false)) }
        for (window, pane, info) in chats {
            var notes = ""
            if pane === from { notes += " (this tab)" }
            // A question on screen could take the paste as its answer.
            if info.status == .waiting { notes += " \u{00B7} waiting for you" }
            let title = pane.tabTitle.drop { !$0.isLetter && !$0.isNumber }
            var item = MenuItem(title: (title.isEmpty ? info.kind.name : String(title)) + notes, isEnabled: info.status != .waiting) { [weak window, weak pane] in
                guard let window, let pane else { return }
                pane.sendToChat(text)
                window.goTo(pane)
            }
            item.swatch = pane.group.map { $0.color.rgb }
            items.append(item)
        }
        let kinds = InstalledAgents.shared.kinds
        if !items.isEmpty && !kinds.isEmpty { items.append(.separator) }
        for kind in kinds {
            items.append(MenuItem(title: "New \(kind.name) Chat" + (from.sshArguments == nil ? "" : " on This PC")) { [weak self, weak from] in
                guard let self, let from else { return }
                self.startChat(kind, text: text, from: from)
            })
        }
        if items.isEmpty {
            items.append(MenuItem(title: InstalledAgents.shared.scanned ? "No agents found" : "Looking for agents\u{2026}", isEnabled: false))
        }
        let area = self.area(for: from)
        openMenu(items, x: area.x + 16 * scale, y: area.y + area.height / 3, above: false)
    }

    /// A new tab running the agent, in the sending tab's folder (when it's on this PC); the text follows once it's ready.
    private func startChat(_ kind: AgentKind, text: String, from pane: TerminalPane) {
        let cwd = pane.sshArguments == nil ? pane.terminal.cwd : nil
        guard addPane(cwd: cwd, column: pane.column) else { return fileProblem() }
        let chat = activePane
        chat.pendingCommand = kind.command
        chat.pasteWhenAgentReady(text)
        invalidate()
    }

    // MARK: - Text size, full screen, Command History and snippets

    /// Ctrl+= and Ctrl+- a point bigger or smaller, Ctrl+0 back to the default: kept in Settings, for every window.
    func adjustTextSize(_ d: Int) {
        let now = AppSettings.shared.fontSize
        let next = d == 0 ? 11 : min(max((now + Double(d)).rounded(), 6), 40)
        guard next != now else { return }
        AppSettings.shared.set("font-size", next == next.rounded() ? String(Int(next)) : String(next))
    }

    private var keepAwakeHovered = false
    /// The minute Keep Awake's time left was last drawn at, to draw it again as it counts down.
    private var keepAwakeShown: String?

    /// Where the window was before full screen, to go back to.
    private var fullScreenRestore: WINDOWPLACEMENT?

    /// F11: the window over the whole display, the taskbar too; again, back as it was.
    func toggleFullScreen() {
        if var placement = fullScreenRestore {
            fullScreenRestore = nil
            SetWindowPlacement(hwnd, &placement)
            SetWindowPos(hwnd, nil, 0, 0, 0, 0, UINT(SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED))
            invalidate()
            return
        }
        var placement = WINDOWPLACEMENT()
        placement.length = UINT(MemoryLayout<WINDOWPLACEMENT>.size)
        guard GetWindowPlacement(hwnd, &placement) else { return }
        var info = MONITORINFO()
        info.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)
        guard GetMonitorInfoW(MonitorFromWindow(hwnd, DWORD(MONITOR_DEFAULTTONEAREST)), &info) else { return }
        fullScreenRestore = placement
        // Not maximized: Windows' maximized state keeps the taskbar showing.
        if IsZoomed(hwnd) { ShowWindow(hwnd, Win.SW_RESTORE) }
        let r = info.rcMonitor
        SetWindowPos(hwnd, nil, r.left, r.top, r.right - r.left, r.bottom - r.top, UINT(SWP_FRAMECHANGED | SWP_NOOWNERZORDER))
        invalidate()
    }

    var isFullScreen: Bool { fullScreenRestore != nil }

    /// The palette is showing Command History.
    private var paletteIsHistory = false

    /// Ctrl+Shift+H, as the Mac's Control-H: past commands, searched as typed. Enter puts one at the prompt to edit,
    /// Ctrl+Enter runs it.
    func showCommandHistory() {
        guard !panes.isEmpty else { return }
        let pane = activePane
        guard pane.canTakeCommand else { return fileProblem() }
        // What's been run in Solanum's tabs, oldest first, for shells whose history file isn't written as they go.
        let session = panes.flatMap { $0.terminal.blocks.filter { $0.state == .finished || $0.state == .running }.map(\.command) }
        pane.commandHistory(also: session) { [weak self, weak pane] entries in
            guard let self, let pane, self.activePane === pane else { return }
            let items = entries.map { command -> PaletteItem in
                var item = PaletteItem(title: command.replacingOccurrences(of: "\n", with: " \u{23CE} ")) { [weak self] in
                    self?.putCommand(command, run: false)
                }
                item.alternate = { [weak self] in self?.putCommand(command, run: true) }
                return item
            }
            let place = pane.sshHost.map { "on \($0)" } ?? "history"
            self.palette = PaletteModel(items: items, placeholder: "Search \(place): Enter to edit, Ctrl+Enter to run", icon: 0xE81C,
                                        emptyMessage: entries.isEmpty ? "No history yet" : "No matching commands")
            self.paletteIsHistory = true
            self.activePane.setFocused(false)
            self.invalidate()
        }
    }

    private func putCommand(_ command: String, run: Bool) {
        guard !panes.isEmpty else { return }
        focusTerminal()
        if !activePane.putCommand(command, run: run) { fileProblem() }
        invalidate()
    }

    /// The picked (or last) command, saved under a name typed in the palette.
    private func saveCommandAsSnippet() {
        guard !panes.isEmpty, let command = activePane.commandForSnippet else { return fileProblem() }
        askForText(placeholder: "A name for \u{201C}\(command.prefix(60))\u{201D}", action: "Save Snippet") { name in
            SnippetStore.shared.load()
            SnippetStore.shared.add(Snippet(name: name, command: command))
        }
    }

    // MARK: - A long list to pick from, in the palette

    /// The palette over `choices`, narrowed as you type (a choice starting "#" is a header); Enter picks one.
    private func pickFromList(_ placeholder: String, _ choices: [String], _ done: @escaping (String) -> Void) {
        let items = choices.map { c -> PaletteItem in
            c.hasPrefix("#") ? .header(String(c.dropFirst())) : PaletteItem(title: c) { done(c) }
        }
        palette = PaletteModel(items: items, placeholder: placeholder, icon: 0xE71C, emptyMessage: "Nothing matches")
        if !panes.isEmpty { activePane.setFocused(false) }
        invalidate()
    }

    // MARK: - A line of text, asked for in the palette

    /// The palette as a one-line question (a log marker's text): Enter takes what's typed.
    private func askForText(placeholder: String, action: String, _ done: @escaping (String) -> Void) {
        palette = PaletteModel(query: "", placeholder: placeholder, icon: 0xE790, emptyMessage: "Type it, then press Enter") { typed in
            let text = typed.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return [] }
            return [PaletteItem(title: "\(action): \u{201C}\(text)\u{201D}") { done(text) }]
        }
        activePane.setFocused(false)
        invalidate()
    }

    /// Windows' Open dialog for one file; nil when cancelled, and always in tests.
    private func pickOneFile(title: String) -> String? {
        guard !isTesting else { return nil }
        var buffer = [UInt16](repeating: 0, count: 4096)
        var titleText = wide(title)
        let picked = buffer.withUnsafeMutableBufferPointer { file -> Bool in
            titleText.withUnsafeMutableBufferPointer { t -> Bool in
                var info = OPENFILENAMEW()
                info.lStructSize = DWORD(MemoryLayout<OPENFILENAMEW>.size)
                info.hwndOwner = hwnd
                info.lpstrFile = file.baseAddress
                info.nMaxFile = DWORD(file.count)
                info.lpstrTitle = UnsafePointer(t.baseAddress)
                info.Flags = DWORD(OFN_EXPLORER | OFN_FILEMUSTEXIST | OFN_NOCHANGEDIR)
                return GetOpenFileNameW(&info)
            }
        }
        guard picked, let end = buffer.firstIndex(of: 0), end > 0 else { return nil }
        return String(decoding: buffer[..<end], as: UTF16.self)
    }

    // MARK: - Links

    /// A web link goes to the browser, a file to the app it opens in. Tests look without opening.
    var onOpenURL: (String) -> Void = { url in
        _ = wide(url).withUnsafeBufferPointer { ShellExecuteW(nil, nil, $0.baseAddress, nil, nil, 1) }
    }

    func openLink(_ target: String, isURL: Bool) {
        if isURL { onOpenURL(target) } else { onOpenFile(target) }
    }

    // MARK: - Files in the sidebars

    /// Files cut or copied on an ssh host, which Windows' clipboard can't carry; this PC's go on that clipboard, so
    /// Explorer can paste them too. They count while the clipboard hasn't changed since.
    private var hostClipboard: (paths: [String], cut: Bool, remote: RemoteConnection, sequence: DWORD)?
    /// A press on a sidebar's row, which may turn into dragging it.
    private var rowPress: (sidebar: FileSidebar, entry: FileEntry, x: Float, y: Float, dragging: Bool)?
    /// The page a click on a sidebar's file last opened (its tab and the page), and when: a double click right after moves
    /// the file to a tab of its own instead.
    private var clickOpened: (pane: UInt, panel: ObjectIdentifier, path: String, at: Date)?

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
            } else {
                item("Open", "Space") { [weak self] in self?.showFile(entry.path, in: self!.pane(for: sidebar), remote: self?.remoteIfUnix(entry.path, sidebar)) }
                if MarkdownDoc.isMarkdown(path: entry.path) {
                    item("Open Preview") { [weak self] in
                        guard let self else { return }
                        self.showPreview(entry.path, in: self.pane(for: sidebar), remote: self.remoteIfUnix(entry.path, sidebar))
                    }
                }
                if !onHost { item("Open in Default App") { [weak self] in self?.onOpenFile(entry.path) } }
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
    private enum DropSpot { case folder(FileSidebar, String), terminal(TerminalPane), tabBar(column: Int, at: Int) }

    /// Over a column's tab strip: the column, and the tab a drop would go in front of (the column's end, past the last).
    private func tabBarSpot(atX x: Float, y: Float) -> (column: Int, at: Int)? {
        let l = layout
        guard !panes.isEmpty, y < l.tabBarHeight else { return nil }
        let column = l.isSplit && x >= l.divider ? 1 : 0, v = l.tabViewport(column: column)
        guard x >= v.x && x <= v.maxX else { return nil }
        let range = l.tabRange(column: column)
        return (column, range.first { l.tab($0).x + l.tab($0).width / 2 > x } ?? range.upperBound)
    }

    /// Where a file dragged over the tab strip would get its tab: a bar there, as for a tab dragged.
    private func tabBarMarker(_ spot: (column: Int, at: Int)) -> (x: Float, color: UInt32) {
        let l = layout, range = l.tabRange(column: spot.column), gap = 3 * scale
        let x = spot.at < range.upperBound ? l.tab(spot.at).x - gap / 2 : (range.isEmpty ? l.tabViewport(column: spot.column).x : l.tab(range.upperBound - 1).maxX + gap / 2)
        return (x, TerminalPalette.accent)
    }

    /// While a sidebar's file or a page's sub-tab is dragged: where the pointer is, for the marker on the tab strip.
    private var fileDragPoint: (x: Float, y: Float)?

    private func dropSpot(atX x: Float, y: Float) -> DropSpot? {
        if let spot = tabBarSpot(atX: x, y: y) { return .tabBar(column: spot.column, at: spot.at) }
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
        case .tabBar(let column, let at):
            // Each file in a file tab of its own, in order from where it was let go; a folder on this PC in a terminal tab
            // there, as on the Mac.
            var at = at
            for path in paths {
                let isUnix = AnyPath.isUnix(path)
                var isFolder: ObjCBool = false
                let folder = isUnix ? source?.tree.rows.first(where: { $0.entry.path == path })?.entry.isDirectory ?? false
                    : FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) && isFolder.boolValue
                if folder {
                    guard !isUnix, addPane(at: at, cwd: path, column: column) else { continue }
                } else {
                    let before = panes.count
                    openFileTab(path, remote: isUnix ? source.flatMap { remote(for: $0) } : nil, column: column, at: at)
                    guard panes.count > before else { continue }
                }
                at += 1
            }
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
        let handle = HDROP(OpaquePointer(raw))
        var point = POINT()
        _ = DragQueryPoint(handle, &point)
        let paths = FileOps.paths(in: handle)
        DragFinish(handle)
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
        let onAwake = bar.keepAwakeSpot().contains(x, y)
        if onAwake != keepAwakeHovered { keepAwakeHovered = onAwake; invalidate() }
        if onAwake && message == Win.WM_LBUTTONUP {
            KeepAwake.stop()
            return true
        }
        if onAwake { return message != Win.WM_MOUSEMOVE }
        var git: (column: Int, part: GitPart, rect: UIRect)?
        for column in isSplit ? [0, 1] : [0] {
            if let g = bar.gitSpots(column: column).first(where: { $0.rect.contains(x, y) }) { git = (column, g.part, g.rect) }
        }
        if message == Win.WM_MOUSEMOVE, git?.column != hoveredGit?.column || git?.part != hoveredGit?.part {
            hoveredGit = git.map { (column: $0.column, part: $0.part) }
            invalidate()
        }
        if let git, message == Win.WM_LBUTTONUP {
            let owner = git.column == 0 ? leftActivePane : rightActivePane ?? activePane
            if owner !== activePane, let i = panes.firstIndex(where: { $0 === owner }) { activate(i) }
            gitClick(git.part, at: git.rect)
            return true
        }
        if git != nil { return message != Win.WM_MOUSEMOVE }
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
        // As on the Mac: Settings' Appearance page, for your own themes and the rest.
        all += [.separator, MenuItem(title: "Open Theme Settings") { SettingsWindow.shared.show(.appearance) }]
        let width = MenuView.width(for: all, canvas: canvas, scale: scale)
        openMenu(all, x: spot.maxX - width, y: spot.y - 2 * scale, above: true)
    }

    var themeSpotRect: UIRect { chrome(on: canvas, layout: layout).themeSpot() }
    var keepAwakeSpotRect: UIRect { chrome(on: canvas, layout: layout).keepAwakeSpot() }

    // MARK: - Dragging tabs

    /// While a tab is dragged: a group's chip it's over (it would join that group), the column it would move to when it's
    /// over the terminals (shown with an overlay, as on the Mac), and whether it's past its group's end (it would leave).
    private var tabDropChip: TabGroup?
    private var tabSplitTarget: Int?
    /// While split, the other column's strip a dragged tab is over: that column, and the tab it would go in front of.
    private var tabStripTarget: (column: Int, at: Int)?
    private var tabLeavesGroup = false
    /// The group a dragged tab started in: it leaves it as soon as it's away from that group's tabs, and is back in it
    /// when it returns among them, so it never shows as a group of its own.
    private var tabHomeGroup: TabGroup?

    /// After a dragged tab has moved: in its group while it's beside one of the group's tabs, otherwise in none.
    private func regroupDragged(_ i: Int) {
        guard let home = tabHomeGroup, panes.indices.contains(i) else { return }
        let column = panes[i].column
        func member(_ k: Int) -> Bool { panes.indices.contains(k) && k != i && panes[k].group === home && panes[k].column == column }
        panes[i].group = member(i - 1) || member(i + 1) ? home : nil
    }

    /// A press, move or release while a tab is held. True if it dealt with the mouse.
    private func tabDragMouse(_ message: UINT, x: Float, y: Float) -> Bool {
        guard var press = tabPress else { return false }
        switch message {
        case Win.WM_MOUSEMOVE:
            if !press.dragging {
                guard abs(x - press.startX) > 4 * scale else { return true }
                press.dragging = true
                SetCapture(hwnd)
            }
            let l = layout, pane = panes[press.index], column = l.column(ofTab: press.index), v = l.tabViewport(column: column), w = l.tabWidth(column: column)
            let range = l.tabRange(column: column)
            draggedX = min(max(x - press.grab, v.x), max(v.maxX - w, v.x))
            tabDropChip = nil
            tabSplitTarget = nil
            tabStripTarget = nil
            tabLeavesGroup = false
            let overColumn = l.isSplit && x >= l.divider ? 1 : 0
            if y > l.tabBarHeight + 6 * scale && y < l.statusBar.y {
                // Down over the terminals. Split, the other column's (or, its last tab leaving, the whole window, one
                // column again); not split yet, the half it's over, which it would take, left or right.
                if l.isSplit {
                    if overColumn != pane.column { tabSplitTarget = overColumn }
                } else if panes.count > 1 {
                    tabSplitTarget = x < terminalArea.x + terminalArea.width / 2 ? 0 : 1
                }
            } else if l.isSplit && y <= l.tabBarHeight && overColumn != pane.column {
                // Over the other column's strip: it would go in there, where the bar shows.
                let target = l.tabRange(column: overColumn)
                tabStripTarget = (overColumn, target.first { l.tab($0).x + l.tab($0).width / 2 > x } ?? target.upperBound)
            } else if case .chip(let first) = l.part(atX: x, y: min(y, l.tabBarHeight - 2)), let g = panes[first].group, g !== pane.group,
                      l.column(ofTab: first) == column {
                // Over another group's chip: it would join that group.
                tabDropChip = g
            } else {
                // It trades places with a neighbor as it passes halfway over it, as on the Mac: a tab of its own group (or
                // one with none) by itself, another group as a whole, so it never lands inside one.
                if tabHomeGroup == nil { tabHomeGroup = pane.group }
                var moved = true, guardCount = 0
                while moved && guardCount < 64 {
                    moved = false
                    guardCount += 1
                    let floating = UIRect(x: draggedX, y: 0, width: w, height: 1), l = layout
                    func span(_ i: Int) -> ClosedRange<Int> {
                        panes[i].group == nil || panes[i].group === tabHomeGroup ? i...i : unitSpan(at: i)
                    }
                    if press.index + 1 < range.upperBound {
                        let next = span(press.index + 1), e = stripExtent(next, l)
                        if floating.maxX > (e.x + e.maxX) / 2 {
                            reorder { tabs in tabs.insert(tabs.remove(at: press.index), at: next.upperBound) }
                            press.index = next.upperBound
                            moved = true
                            regroupDragged(press.index)
                            continue
                        }
                    }
                    if press.index > range.lowerBound {
                        let before = span(press.index - 1), e = stripExtent(before, l)
                        if floating.x < (e.x + e.maxX) / 2 {
                            reorder { tabs in tabs.insert(tabs.remove(at: press.index), at: before.lowerBound) }
                            press.index = before.lowerBound
                            moved = true
                            regroupDragged(press.index)
                        }
                    }
                }
                // Past the end of its group (with nothing there to trade with): it would leave the group.
                if let g = pane.group, panes.filter({ $0.group === g }).count > 1 {
                    let slot = layout.tab(press.index), center = x - press.grab + w / 2
                    let isLast = press.index + 1 >= range.upperBound || panes[press.index + 1].group !== g
                    let isFirst = press.index == range.lowerBound || panes[press.index - 1].group !== g
                    if isLast && center > slot.maxX + w * 0.25 { tabLeavesGroup = true }
                    if isFirst && center < (layout.chip(press.index)?.x ?? slot.x) - w * 0.25 { tabLeavesGroup = true }
                }
            }
            // Away from its own strip, the tab lifts out of it and comes with the pointer, so it's plain what's held.
            dragGhost = ghostOffBar(y) || tabStripTarget != nil
                ? DragGhost(title: pane.tabTitle, glyph: nil, x: x, y: y, grabX: press.grab, grabY: 14 * scale, color: pane.group?.color.rgb) : nil
            tabPress = press
            invalidate()
            return true
        case Win.WM_LBUTTONUP:
            dragGhost = nil
            tabStripTarget = nil
            if press.dragging {
                ReleaseCapture()
                let pane = panes[press.index], l = layout
                let over = l.isSplit && y <= l.tabBarHeight ? (x >= l.divider ? 1 : 0) : pane.column
                let (chip, split, leaves) = (tabDropChip, tabSplitTarget, tabLeavesGroup)
                tabHomeGroup = nil
                tabPress = nil
                tabDropChip = nil
                tabSplitTarget = nil
                tabLeavesGroup = false
                if let split {
                    // Dropped on the terminals: into the other column; or, splitting the window, the half it was let go over.
                    if !isSplit && split == 0 { splitToLeft(pane) } else { moveToOtherColumn(pane) }
                } else if let chip {
                    add([pane], to: chip)
                } else if over != pane.column {
                    // Dropped on the other column's strip: into it, where it was let go.
                    let target = l.tabRange(column: over)
                    let at = target.first { l.tab($0).x + l.tab($0).width / 2 > x } ?? target.upperBound
                    moveToOtherColumn(pane, at: at > press.index ? at - 1 : at)
                } else if leaves {
                    pane.group = nil
                } else {
                    TabGroupOps.settle(pane, in: panes)
                }
            }
            tabPress = nil
            tabHomeGroup = nil
            invalidate()
            return press.dragging
        default:
            return false
        }
    }

    /// Where a dragged tab would land: a bar at its place (in its group's color while it's in one), past its group's end
    /// when it would leave it. None while it's over a chip or the terminals, which show it their own way.
    private var tabDropMarker: (x: Float, color: UInt32)? {
        guard let press = tabPress, press.dragging, tabDropChip == nil, tabSplitTarget == nil, panes.indices.contains(press.index) else { return nil }
        let l = layout, slot = l.tab(press.index), pane = panes[press.index], gap = 3 * scale
        guard tabLeavesGroup, let g = pane.group else {
            return (slot.x - gap / 2, pane.group?.color.rgb ?? TerminalPalette.accent)
        }
        let isFirst = press.index == 0 || panes[press.index - 1].group !== g || panes[press.index - 1].column != pane.column
        let first = panes.firstIndex { $0.group === g } ?? press.index
        return (isFirst && (l.chip(first).map { draggedX < $0.x } ?? false) ? (l.chip(press.index)?.x ?? slot.x) - gap * 2 : slot.maxX + gap * 2, TerminalPalette.accent)
    }

    /// Over the terminals while a tab is dragged (or a page's sub-tab, over the other column): where it would go, as on
    /// the Mac. The other column; the whole window, when the tab is the last in its column and the split would close;
    /// or, not split yet, the half it would take.
    private func drawSplitDrop(on target: Canvas) {
        guard let column = tabSplitTarget ?? editorDropColumn else { return }
        let l = layout
        var r = isSplit ? (column == 1 ? rightTerminalArea : terminalArea) : terminalArea
        let closesSplit = tabSplitTarget != nil && isSplit && tabPress.map { p in panes.indices.contains(p.index) && panes.filter { $0.column == panes[p.index].column }.count == 1 } == true
        if closesSplit {
            r = UIRect(x: terminalArea.x, y: terminalArea.y, width: rightTerminalArea.maxX - terminalArea.x, height: terminalArea.height)
        } else if !isSplit {
            let half = (r.width / 2).rounded()
            r = UIRect(x: column == 1 ? r.x + half : r.x, y: r.y, width: column == 1 ? r.width - half : half, height: r.height)
        }
        let inset = 8 * scale
        r = UIRect(x: r.x + inset, y: r.y + inset, width: max(r.width - inset * 2, 0), height: max(min(r.height, l.statusBar.y - r.y) - inset * 2, 0))
        sol_canvas_fill_rounded(target.raw, r.x, r.y, r.width, r.height, 10 * scale, TerminalPalette.accent, 0.16)
        sol_canvas_stroke_rounded(target.raw, r.x + 1, r.y + 1, r.width - 2, r.height - 2, 10 * scale, TerminalPalette.accent, 0.85, 2 * scale)
    }

    // MARK: - Dragging group chips

    /// A press on a group's chip, which may turn into dragging the group (chip and tabs) along the strip: it follows the
    /// pointer, a bar shows where it would land, and it moves there when let go, as on the Mac.
    private var chipPress: (group: TabGroup, grab: Float, startX: Float, dragging: Bool)?
    private var chipDragX: Float = 0
    /// The tab the dragged group would land in front of (the column's end index for the end).
    private var chipInsertBefore: Int?

    /// A press, move or release while a chip is held. True if it dealt with the mouse; a press let go without moving is
    /// still a click, which collapses or expands the group.
    private func chipDragMouse(_ message: UINT, x: Float, y: Float) -> Bool {
        guard var press = chipPress else { return false }
        switch message {
        case Win.WM_MOUSEMOVE:
            if !press.dragging {
                guard abs(x - press.startX) > 4 * scale else { return true }
                press.dragging = true
                chipPress = press
                SetCapture(hwnd)
            }
            chipDragX = x
            chipInsertBefore = groupInsertion(press.group, blockX: x - press.grab)
            dragGhost = ghostOffBar(y) ? DragGhost(title: groupGhostTitle(press.group), glyph: nil, x: x, y: y, grabX: press.grab, grabY: 14 * scale,
                                                   color: press.group.color.rgb) : nil
            invalidate()
            return true
        case Win.WM_LBUTTONUP:
            chipPress = nil
            guard press.dragging else { return false }
            ReleaseCapture()
            pressed = nil
            dragGhost = nil
            if let at = chipInsertBefore { moveGroup(press.group, before: at) }
            chipInsertBefore = nil
            invalidate()
            return true
        default:
            return false
        }
    }

    /// Whether the pointer's gone far enough above or below the tab bar that what's dragged along it should follow it there.
    private func ghostOffBar(_ y: Float) -> Bool { y > layout.tabBarHeight + 4 * scale || y < 0 }

    private func groupGhostTitle(_ g: TabGroup) -> String {
        let n = panes.filter { $0.group === g }.count
        let tabs = n == 1 ? "1 tab" : "\(n) tabs"
        return g.name.isEmpty ? tabs : g.name + "  ·  " + tabs
    }

    /// The tabs a tab moves with: its group's, or just itself.
    private func unitSpan(at i: Int) -> ClosedRange<Int> {
        guard let g = panes[i].group else { return i...i }
        let column = panes[i].column
        var a = i, b = i
        while a > 0, panes[a - 1].group === g, panes[a - 1].column == column { a -= 1 }
        while b + 1 < panes.count, panes[b + 1].group === g, panes[b + 1].column == column { b += 1 }
        return a...b
    }

    /// Where a run of tabs is in the strip, chip and all.
    private func stripExtent(_ r: ClosedRange<Int>, _ l: WindowLayout) -> (x: Float, maxX: Float) {
        let last = l.tab(r.upperBound)
        return (l.chip(r.lowerBound)?.x ?? l.tab(r.lowerBound).x, last.x + last.width)
    }

    /// The group's tabs, and the other runs (a tab, or a whole group) in its column, in order.
    private func columnUnits(of g: TabGroup) -> (me: ClosedRange<Int>, others: [ClosedRange<Int>], end: Int)? {
        guard let f = panes.firstIndex(where: { $0.group === g }) else { return nil }
        let me = unitSpan(at: f), range = layout.tabRange(column: panes[f].column)
        var others: [ClosedRange<Int>] = []
        var i = range.lowerBound
        while i < range.upperBound {
            let u = unitSpan(at: i)
            if u != me { others.append(u) }
            i = u.upperBound + 1
        }
        return (me, others, range.upperBound)
    }

    /// The tab the group, its left edge dragged to `blockX`, would land in front of: the first run whose middle is past it.
    private func groupInsertion(_ g: TabGroup, blockX: Float) -> Int? {
        guard let units = columnUnits(of: g) else { return nil }
        let l = layout
        for u in units.others {
            let e = stripExtent(u, l)
            if blockX < (e.x + e.maxX) / 2 { return u.lowerBound }
        }
        return units.end
    }

    /// Moves a group's tabs in front of tab `at` (or to the end of their column).
    private func moveGroup(_ g: TabGroup, before at: Int) {
        guard let units = columnUnits(of: g) else { return }
        let me = units.me
        guard at != me.lowerBound, at != me.upperBound + 1 else { return }
        reorder { tabs in
            let block = Array(tabs[me])
            tabs.removeSubrange(me)
            tabs.insert(contentsOf: block, at: at > me.upperBound ? at - me.count : at)
        }
    }

    /// The dragged group as drawn, and the bar where it would land.
    private var chipDragShape: (lifted: (first: Int, last: Int, dx: Float), marker: (x: Float, color: UInt32)?)? {
        guard let press = chipPress, press.dragging, let units = columnUnits(of: press.group) else { return nil }
        let l = layout, dx = chipDragX - press.startX, gap = 3 * scale
        var marker: (x: Float, color: UInt32)?
        if let at = chipInsertBefore, at != units.me.lowerBound, at != units.me.upperBound + 1 {
            let x = at < units.end ? stripExtent(unitSpan(at: at), l).x - gap : (units.others.last.map { stripExtent($0, l).maxX } ?? 0) + gap
            marker = (x, press.group.color.rgb)
        }
        return ((units.me.lowerBound, units.me.upperBound, dx), marker)
    }

    /// Presses a tab and drags it to a point anywhere in the window (onto a chip, or down over the terminals), as the mouse
    /// would. `check` runs while it's held there, before it's let go.
    func dragTab(_ i: Int, toX x: Float, y: Float, check: (() -> Void)? = nil) {
        let r = layout.tab(i)
        func at(_ px: Float, _ py: Float) -> LPARAM { LPARAM(Int(px) & 0xFFFF) | (LPARAM(Int(py) & 0xFFFF) << 16) }
        _ = SendMessageW(hwnd, Win.WM_LBUTTONDOWN, 1, at(r.x + 20, r.midY))
        _ = SendMessageW(hwnd, Win.WM_MOUSEMOVE, 1, at(x, r.midY))
        _ = SendMessageW(hwnd, Win.WM_MOUSEMOVE, 1, at(x, y))
        check?()
        _ = SendMessageW(hwnd, Win.WM_LBUTTONUP, 0, at(x, y))
    }

    /// What a drag shows while it's held: the overlay's column, a chip lit up, and the landing bar. For tests.
    var dragShows: (split: Int?, chip: Bool, marker: Bool) {
        (tabSplitTarget, tabDropChip != nil, tabDropMarker != nil || chipDragShape?.marker != nil)
    }

    /// Presses a group's chip and drags it to a position, as the mouse would.
    func dragChip(_ first: Int, toX x: Float) {
        guard let r = layout.chip(first) else { return }
        let y = Int(r.midY)
        func at(_ px: Int) -> LPARAM { LPARAM(px & 0xFFFF) | (LPARAM(y & 0xFFFF) << 16) }
        _ = SendMessageW(hwnd, Win.WM_LBUTTONDOWN, 1, at(Int(r.x + 5)))
        _ = SendMessageW(hwnd, Win.WM_MOUSEMOVE, 1, at(Int(x)))
        _ = SendMessageW(hwnd, Win.WM_LBUTTONUP, 0, at(Int(x)))
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
        // Explorer's keys for files, and the Mac's: Enter renames as Return does there (F2 too), Ctrl+Down opens as
        // Command-Down does, and Space opens.
        switch key {
        case Win.VK_F2 where !ctrl && !alt, Win.VK_RETURN where !ctrl && !alt && !shift:
            if let selected { beginRename(selected, sidebar) }
            return true
        case Win.VK_DOWN where ctrl && !alt:
            if let i = tree.selectedIndex { activate(tree.rows[i].entry, in: sidebar) }
            invalidate()
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
            // Space, or Enter with Ctrl or Shift.
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
        ("Solanum", [("Settings…", "Ctrl+,"), ("Command Palette…", "Ctrl+Shift+P"), ("Restart, bringing everything back", "Ctrl+Shift+R"),
                     ("Restart Fresh", "Ctrl+Alt+Shift+R")]),
        ("Shell", [("New Tab", "Ctrl+T"), ("New Tab in Group", "Ctrl+Alt+T"), ("Reopen Closed Tab", "Ctrl+Shift+T"), ("Go to Folder…", "Ctrl+Shift+O"),
                   ("Split Right", "Ctrl+Alt+D"), ("Move Tab to Other Split", "Ctrl+Shift+D"), ("Close Split", "Ctrl+Alt+W"), ("Close Tab", "Ctrl+W"),
                   ("Close Tab (also)", "Ctrl+Shift+W"), ("Rename Tab…", "Ctrl+Shift+I"), ("Add Tab to New Group", "Ctrl+Alt+G")]),
        ("Tabs", [("Pick another tab", "Ctrl+Click"), ("Pick the tabs between", "Shift+Click"), ("Collapse or expand a group", "Click its chip"),
                  ("Move a group", "Drag its chip")]),
        ("Commands", [("Previous Command or Prompt", "Ctrl+Up"), ("Next Command or Prompt", "Ctrl+Down"), ("Jump to Prompt…", "Ctrl+J"),
                      ("Copy Command (nothing selected)", "Ctrl+Shift+C"), ("Copy Command and Output", "Ctrl+Alt+C"), ("Run Command Again", "Ctrl+Alt+R")]),
        ("Edit", [("Copy (with something selected)", "Ctrl+C"), ("Stop the program (with nothing selected)", "Ctrl+C"), ("Cut (in the line being typed)", "Ctrl+X"),
                  ("Paste", "Ctrl+V"), ("Paste (also)", "Shift+Insert"), ("Undo (PowerShell and Claude Code)", "Ctrl+Z")]),
        ("Prompts", [("New Line (shells and Claude Code)", "Shift+Enter"), ("Paste an Image (Claude Code)", "Ctrl+V"), ("Jump to Prompt…", "Ctrl+J")]),
        ("Find and Git", [("Search in Project Folder…", "Ctrl+Shift+F"), ("Show Git Graph", "Ctrl+Shift+G"), ("Show Git Changes", "Ctrl+Shift+S"),
                          ("Open a Link", "Ctrl+Click")]),
        ("Pages", [("Close the page with the keyboard", "Ctrl+W"), ("Back to the terminal", "Click it")]),
        ("View", [("Toggle File Sidebar", "Ctrl+B"), ("Toggle Right Sidebar (split)", "Ctrl+Alt+B"), ("Pin Sidebar Folder", "Ctrl+Shift+B"), ("Scroll Back a Page", "Shift+PageUp"), ("Scroll Forward a Page", "Shift+PageDown")]),
        ("Window", [("Next Tab", "Ctrl+Tab"), ("Previous Tab", "Ctrl+Shift+Tab"), ("Go to Tab 1 to 9", "Ctrl+1"), ("Close Window", "Alt+F4")]),
    ]

    // MARK: - Command palette

    var isPaletteOpen: Bool { palette != nil }
    var paletteRows: [PaletteItem] { palette?.rows ?? [] }
    /// Enter in the palette, for tests.
    func pressPaletteEnterForTest() { _ = paletteKey(Win.VK_RETURN, ctrl: false) }
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
            PaletteItem(title: "Change Default Shell\u{2026}", category: "Shell") { [weak self] in self?.showDefaultShellMenu() },
            PaletteItem(title: "Reopen Closed Tab", category: "Shell", shortcut: "Ctrl+Shift+T") { [weak self] in self?.reopenClosedTab() },
            PaletteItem(title: "Go to Folder…", category: "Shell", shortcut: "Ctrl+Shift+O") { [weak self] in self?.showGoToFolder() },
            PaletteItem(title: "Split Right", category: "Shell", shortcut: "Ctrl+Alt+D") { [weak self] in self?.splitRight() },
            PaletteItem(title: "Search in Project Folder…", category: "Find", shortcut: "Ctrl+Shift+F") { [weak self] in self?.showSearch() },
            PaletteItem(title: "Show Git Changes", category: "Git", shortcut: "Ctrl+Shift+S") { [weak self] in self?.showGitChanges() },
            PaletteItem(title: "Show Git Graph", category: "Git", shortcut: "Ctrl+Shift+G") { [weak self] in self?.showGitGraph() },
            PaletteItem(title: "Switch Branch…", category: "Git") { [weak self] in self.map { $0.showBranches(for: $0.activePane) } },
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
            PaletteItem(title: "Jump to Prompt…", category: "Commands", shortcut: "Ctrl+J") { [weak self] in self?.showSentPrompts() },
            PaletteItem(title: "Previous Command or Prompt", category: "Commands", shortcut: "Ctrl+Up") { [weak self] in self?.activePane.selectPreviousStop() },
            PaletteItem(title: "Next Command or Prompt", category: "Commands", shortcut: "Ctrl+Down") { [weak self] in self?.activePane.selectNextStop() },
            PaletteItem(title: "Copy Command", category: "Commands", shortcut: "Ctrl+Shift+C") { [weak self] in self?.activePane.copyStopCommand() },
            PaletteItem(title: "Copy Command and Output", category: "Commands", shortcut: "Ctrl+Alt+C") { [weak self] in self?.activePane.copyStopWithOutput() },
            PaletteItem(title: "Run Command Again", category: "Commands", shortcut: "Ctrl+Alt+R") { [weak self] in self?.activePane.rerunStop() },
            PaletteItem(title: "Clear Buffer", category: "Commands", shortcut: "Ctrl+Shift+K") { [weak self] in
                guard let self, !self.panes.isEmpty else { return }
                if !self.activePane.clearBuffer() { self.fileProblem() }
            },
            PaletteItem(title: "Command History\u{2026}", category: "Commands", shortcut: "Ctrl+Shift+H") { [weak self] in self?.showCommandHistory() },
            PaletteItem(title: "Send to Chat\u{2026}", category: "Commands", shortcut: "Ctrl+Alt+S") { [weak self] in self?.showSendToChat() },
            PaletteItem(title: "Collapse / Expand Output", category: "Commands", shortcut: "Ctrl+Shift+E") { [weak self] in
                guard let self, !self.panes.isEmpty else { return }
                if !self.activePane.toggleCollapse() { self.fileProblem() }
            },
            PaletteItem(title: "Collapse All Outputs", category: "Commands") { [weak self] in self?.activePane.setAllCollapsed(true) },
            PaletteItem(title: "Expand All Outputs", category: "Commands") { [weak self] in self?.activePane.setAllCollapsed(false) },
            PaletteItem(title: "Save Command as Snippet\u{2026}", category: "Commands") { [weak self] in self?.saveCommandAsSnippet() },
            PaletteItem(title: "Edit Snippets", category: "Snippets") { [weak self] in
                guard let self, !self.panes.isEmpty else { return }
                SnippetStore.shared.load()
                self.showFile(SnippetStore.shared.fileURL.path, in: self.activePane)
            },
            PaletteItem(title: "Refresh Tab", category: "View") { [weak self] in self?.activePane.refreshDisplay() },
            PaletteItem(title: KeepAwake.secondsLeft.map { "Stop Keeping Awake (\(KeepAwake.shortDuration($0)) left)" }
                            ?? "Keep Awake (\(KeepAwake.shortDuration(AppSettings.shared.keepAwakeSeconds)))",
                        category: "Solanum", shortcut: "Ctrl+Shift+A") { KeepAwake.toggle() },
            PaletteItem(title: "Bigger Text", category: "View", shortcut: "Ctrl+=") { [weak self] in self?.adjustTextSize(1) },
            PaletteItem(title: "Smaller Text", category: "View", shortcut: "Ctrl+-") { [weak self] in self?.adjustTextSize(-1) },
            PaletteItem(title: "Default Text Size", category: "View", shortcut: "Ctrl+0") { [weak self] in self?.adjustTextSize(0) },
            PaletteItem(title: fullScreenRestore == nil ? "Enter Full Screen" : "Exit Full Screen", category: "Window", shortcut: "F11") { [weak self] in
                self?.toggleFullScreen()
            },
            PaletteItem(title: "Scroll to Top", category: "View") { [weak self] in self?.activePane.scrollToTop() },
            PaletteItem(title: "Scroll to Bottom", category: "View") { [weak self] in self?.activePane.scrollToBottom() },
            PaletteItem(title: "Settings…", category: "Solanum", shortcut: "Ctrl+,") { SettingsWindow.shared.show() },
            PaletteItem(title: "Open Config File", category: "Solanum") {
                guard let url = AppSettings.fileURL else { return }
                _ = wide(url.path).withUnsafeBufferPointer { ShellExecuteW(nil, nil, $0.baseAddress, nil, nil, 1) }
            },
            PaletteItem(title: "Reload Config", category: "Solanum") { AppSettings.shared.reloadIfChanged() },
            PaletteItem(title: "Restart Solanum", category: "Solanum", shortcut: "Ctrl+Shift+R") { [weak self] in self?.confirmRestart(fresh: false) },
            PaletteItem(title: "Restart Fresh", category: "Solanum", shortcut: "Ctrl+Alt+Shift+R") { [weak self] in self?.confirmRestart(fresh: true) },
                        PaletteItem(title: "Minimize", category: "Window") { [weak self] in self?.pressCaptionButton(.minimize) },
            PaletteItem(title: IsZoomed(hwnd) ? "Restore" : "Maximize", category: "Window") { [weak self] in self?.pressCaptionButton(.maximize) },
            PaletteItem(title: "Close Window", category: "Window", shortcut: "Alt+F4") { [weak self] in self?.pressCaptionButton(.close) },
        ]
        if isSplit {
            items.append(PaletteItem(title: "Close Split", category: "Shell", shortcut: "Ctrl+Alt+W") { [weak self] in self?.closeSplit() })
            items.append(PaletteItem(title: "Focus Other Split", category: "Window") { [weak self] in self?.focusOtherColumn() })
            items.append(PaletteItem(title: "Toggle Right Sidebar", category: "View", shortcut: "Ctrl+Alt+B") { [weak self] in self.map { $0.toggleSidebar($0.right) } })
        }
        // Snippets: each put at the prompt to edit, or with Ctrl+Enter run.
        SnippetStore.shared.load()
        for snippet in SnippetStore.shared.snippets {
            var item = PaletteItem(title: snippet.name, category: "Snippets") { [weak self] in self?.putCommand(snippet.command, run: false) }
            item.alternate = { [weak self] in self?.putCommand(snippet.command, run: true) }
            items.append(item)
        }
        // Each shell here: a new tab with it, or this tab started again in it.
        let current = panes.isEmpty ? nil : activePane.shell
        for shell in Shells.available {
            items.append(PaletteItem(title: "New Tab: \(shell.name)", category: "Shell") { [weak self] in self?.newTab(shell: shell) })
        }
        for shell in Shells.available where shell != current {
            items.append(PaletteItem(title: "Switch Tab to \(shell.name)", category: "Shell") { [weak self] in
                guard let self, !self.panes.isEmpty else { return }
                self.switchShell(of: self.activePane, to: shell)
            })
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
        paletteIsHistory = false
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
    private func paletteKey(_ key: Int32, ctrl: Bool, shift: Bool = false) -> Bool {
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
        // Shift selects as the caret goes; Ctrl goes a word at a time.
        case Win.VK_LEFT where ctrl: palette.moveCaret(to: palette.wordBoundary(from: palette.caret, forward: false), extend: shift)
        case Win.VK_RIGHT where ctrl: palette.moveCaret(to: palette.wordBoundary(from: palette.caret, forward: true), extend: shift)
        case Win.VK_LEFT: palette.moveCaret(by: -1, extend: shift)
        case Win.VK_RIGHT: palette.moveCaret(by: 1, extend: shift)
        case Win.VK_HOME: palette.moveCaret(to: 0, extend: shift)
        case Win.VK_END: palette.moveCaret(to: palette.query.count, extend: shift)
        case 0x41 where ctrl: palette.selectAll()
        case 0x43 where ctrl: paletteCopy(cut: false)
        case 0x58 where ctrl: paletteCopy(cut: true)
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

    /// Copies what's selected in the palette's field; `cut` takes it out too.
    private func paletteCopy(cut: Bool) {
        guard let palette, let text = palette.selectedText else { return }
        activePane.setClipboard(text)
        if cut { palette.deleteSelection() }
        invalidate()
    }

    /// Whether a drag in the palette's field is selecting text.
    private var paletteSelecting = false

    /// The character in the palette's field nearest a point: where a click puts the caret.
    private func paletteIndex(atX x: Float) -> Int {
        guard let palette else { return 0 }
        let f = paletteLayout.field, pixels = 15 * scale, chars = Array(palette.query)
        func width(_ n: Int) -> Float {
            let units = Array(String(chars[..<n]).utf16)
            return sol_canvas_measure_label(canvas.raw, units, Int32(units.count), pixels, 0)
        }
        // The text slides left with a long query, as PaletteView draws it.
        let shift = max(width(palette.caret) - f.width + 4 * scale, 0).rounded()
        let target = x - f.x + shift
        var best = 0, bestDistance = Float.greatestFiniteMagnitude
        for n in 0...chars.count {
            let d = abs(width(n) - target)
            if d < bestDistance { best = n; bestDistance = d }
        }
        return best
    }

    /// Right-click in the field: Cut, Copy, Paste, Delete and Select All, as Windows' fields have.
    private func paletteFieldMenu(x: Float, y: Float) {
        guard let palette else { return }
        let has = palette.selection != nil
        openMenu([
            MenuItem(title: "Cut", isEnabled: has, shortcut: "Ctrl+X") { [weak self] in self?.paletteCopy(cut: true) },
            MenuItem(title: "Copy", isEnabled: has, shortcut: "Ctrl+C") { [weak self] in self?.paletteCopy(cut: false) },
            MenuItem(title: "Paste", isEnabled: activePane.clipboardText() != nil, shortcut: "Ctrl+V") { [weak self] in
                guard let self, let text = self.activePane.clipboardText() else { return }
                self.palette?.insert(text)
                self.invalidate()
            },
            MenuItem(title: "Delete", isEnabled: has, shortcut: "Del") { [weak self] in self?.palette?.deleteSelection(); self?.invalidate() },
            .separator,
            MenuItem(title: "Select All", isEnabled: !palette.query.isEmpty, shortcut: "Ctrl+A") { [weak self] in self?.palette?.selectAll(); self?.invalidate() },
        ], x: x, y: y, above: false)
    }

    private func paletteMouse(_ message: UINT, x: Float, y: Float) {
        guard let palette else { return }
        let l = paletteLayout
        let row = l.visibleRow(atX: x, y: y).map { $0 + palette.scrollTop }
        // In the field: click to place the caret, drag or Shift+click to select, double-click for a word.
        let inField = UIRect(x: l.field.x - 4 * scale, y: l.field.y, width: l.field.width + 8 * scale, height: l.field.height).contains(x, y)
        switch message {
        case Win.WM_LBUTTONDOWN where inField:
            palette.moveCaret(to: paletteIndex(atX: x), extend: isDown(Win.VK_SHIFT))
            paletteSelecting = true
            SetCapture(hwnd)
            invalidate()
            return
        case Win.WM_LBUTTONDBLCLK where inField:
            palette.selectWord(at: max(paletteIndex(atX: x) - (paletteIndex(atX: x) == palette.query.count ? 1 : 0), 0))
            paletteSelecting = false
            invalidate()
            return
        case Win.WM_MOUSEMOVE where paletteSelecting:
            palette.moveCaret(to: paletteIndex(atX: x), extend: true)
            invalidate()
            return
        case Win.WM_LBUTTONUP where paletteSelecting:
            paletteSelecting = false
            ReleaseCapture()
            return
        case Win.WM_RBUTTONDOWN where inField:
            return
        case Win.WM_RBUTTONUP where inField:
            paletteFieldMenu(x: x, y: y)
            return
        default:
            break
        }
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
        if dialog != nil { return dialogKey(key) }
        if menu != nil { return menuKey(key) }
        if notices.hasFocusedField {
            let used = notices.key(key, ctrl: ctrl)
            invalidate()
            if used { return true }
        }
        if !panes.isEmpty, activePane.hasQuestion { return activePane.questionKey(key, ctrl: ctrl) }
        if naming != nil { return namingKey(key, ctrl: ctrl) }
        // Find's toggles, as VS Code's (Alt+C case, Alt+W whole words, Alt+R regular expressions), in whichever bar is open
        // where the keyboard is: the terminal's, or the Markdown preview's (the file editor's is below).
        if alt && !ctrl && !shift && palette == nil && !panes.isEmpty && editingSidebar == nil {
            if let preview = activePane.focusedPanel as? MarkdownPreviewPanel, preview.findAltKey(key) { return true }
            if !activePane.editorFocused, activePane.findAltKey(key) { return true }
        }
        // The terminal's find bar, while it has the keyboard; the app's own Ctrl keys still work.
        if palette == nil, editingSidebar == nil, !panes.isEmpty, activePane.findFocused, !activePane.editorFocused,
           let used = activePane.findKey(key, shift: shift, ctrl: ctrl) { return used }
        // Ctrl+F, as the Mac's ⌘F: find in the file that has the keyboard, else in the terminal. From a sidebar, in the
        // file it's showing, if there is one.
        if ctrl && !alt && !shift && key == 0x46 && palette == nil && !panes.isEmpty && editingSidebar == nil {
            if let file = activePane.focusedPanel as? FileEditorPanel {
                file.showFind(replace: false)
            } else if let preview = activePane.focusedPanel as? MarkdownPreviewPanel {
                preview.showFind()
            } else if focusedSidebar != nil, activePane.panel is FileEditorPanel || activePane.panel is MarkdownPreviewPanel {
                left.isFocused = false
                right.isFocused = false
                setEditorFocus(true, in: activePane)
                if let file = activePane.panel as? FileEditorPanel { file.showFind(replace: false) }
                if let preview = activePane.panel as? MarkdownPreviewPanel { preview.showFind() }
            } else if activePane.focusedPanel == nil {
                focusTerminal()
                activePane.showFind()
            } else {
                return true
            }
            invalidate()
            return true
        }
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
        // Text size, as Windows Terminal and the Mac's Command-plus, minus and zero: Ctrl+=, Ctrl+- and Ctrl+0.
        if ctrl && !alt && palette == nil && (key == 0xBB || key == 0x6B) { adjustTextSize(1); return true }
        if ctrl && !alt && palette == nil && (key == 0xBD || key == 0x6D) { adjustTextSize(-1); return true }
        if ctrl && !alt && !shift && palette == nil && (key == 0x30 || key == 0x60) { adjustTextSize(0); return true }
        // F11: full screen, as Windows' own apps have it (the Mac's Control-Command-F).
        if key == 0x7A && !ctrl && !alt && !shift { toggleFullScreen(); return true }
        // Collapse / Expand Output: Ctrl+Shift+E, as the Mac's Shift-Command-E.
        if ctrl && shift && !alt && key == 0x45 && palette == nil && !panes.isEmpty && !activePane.editorFocused {
            if !activePane.toggleCollapse() { fileProblem() }
            invalidate()
            return true
        }
        // Send to Chat: Ctrl+Alt+S, as the Mac's Option-Command-S.
        if ctrl && alt && !shift && key == 0x53 && palette == nil && !panes.isEmpty {
            showSendToChat()
            return true
        }
        // Keep Awake: Ctrl+Shift+A, as the Mac's Shift-Command-A; again ends it.
        if ctrl && shift && !alt && key == 0x41 && palette == nil {
            KeepAwake.toggle()
            return true
        }
        // Clear Buffer (Ctrl+Shift+K, the Mac's Command-K) and Command History (Ctrl+Shift+H, its Control-H): programs keep
        // Ctrl+K and Ctrl+H themselves.
        if ctrl && shift && !alt && key == 0x4B && palette == nil && !panes.isEmpty {
            if !activePane.clearBuffer() { fileProblem() }
            invalidate()
            return true
        }
        if ctrl && shift && !alt && key == 0x48 && !panes.isEmpty {
            if palette?.isLive == false && paletteIsHistory { closePalette() } else { showCommandHistory() }
            return true
        }
        // Search in Project Folder, as the Mac's Shift-Command-F.
        if ctrl && shift && !alt && key == 0x46 {
            if palette?.isLive == true { closePalette() } else { showSearch() }
            return true
        }
        // Restart, and Restart Fresh, as the Mac's Shift-Command-R and Option-Shift-Command-R.
        if ctrl && shift && key == 0x52 {
            confirmRestart(fresh: alt)
            return true
        }
        // Jump to Prompt: Ctrl+J, as the Mac's Command-J (Shift+Enter makes the new line Ctrl+J used to), and Ctrl+Shift+J
        // as before.
        if ctrl && !alt && key == 0x4A {
            if palette?.isLive == true { closePalette() } else { showSentPrompts() }
            return true
        }
        // Git Graph and Git Changes, as the Mac's Control-Command-G and S; again with the page in front closes it.
        // Programs keep Ctrl+G and Ctrl+S: a terminal sends Ctrl+Shift+S as Ctrl+S, which only the app can tell apart.
        if ctrl && shift && !alt && (key == 0x47 || key == 0x53) {
            let graph = key == 0x47
            if activePane.editorFocused, let panel = activePane.panel, graph ? panel is GitGraphPanel : panel is GitChangesPanel {
                closeEditor(panel, in: activePane)
            } else if graph {
                showGitGraph()
            } else {
                showGitChanges()
            }
            return true
        }
        if palette != nil { return paletteKey(key, ctrl: ctrl, shift: shift) }
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
                // As the Mac's Command-W: the page with the keyboard, or else the tab.
                if activePane.editorFocused, let panel = activePane.panel { closeEditor(panel, in: activePane) } else { closeTab(activeIndex) }
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
        if let editor = activePane.focusedPanel as? FileEditorPanel, alt && !ctrl {
            if key == 0x5A && !shift { editor.toggleWrap(); return true }
            if key == 0x46 && shift { editor.beautify(); return true }
            // Find's toggles, as VS Code's: Alt+C case, Alt+W whole words, Alt+R regular expressions.
            if !shift && editor.findAltKey(key) { return true }
        }
        if let panel = activePane.focusedPanel {
            // Keys the app doesn't claim are the page's, while it has the keyboard.
            if !alt && panel.key(key, shift: shift, ctrl: ctrl) { return true }
            return ctrl || alt
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
    var activeGit: GitInfo? { activePane.git }
    var activeGitBusy: String? { activePane.gitBusy }
    var activePanel: ColumnPanel? { activePane.panel }
    func gitSpot(_ part: GitPart) -> UIRect? { chrome(on: canvas, layout: layout).gitSpots().first { $0.part == part }?.rect }
    func refreshGitForTest() { refreshGit(activePane, now: true) }
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

    /// Drags the band between the columns so its middle is at `x`.
    func dragColumnBand(to x: Float) {
        guard let band = layout.columnBand else { return }
        let y = Int(band.midY)
        func at(_ px: Int) -> LPARAM { LPARAM(px & 0xFFFF) | (LPARAM(y & 0xFFFF) << 16) }
        _ = SendMessageW(hwnd, Win.WM_LBUTTONDOWN, 1, at(Int(band.x + band.width / 2)))
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
            window = TerminalWindow(commandLine: settings.shellCommandLine, cols: settings.windowColumns, rows: settings.windowRows,
                                    session: SavedSession.load(), failure: &failure)
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
