import CCanvas
import Foundation
import WinSDK

/// Aliases on Windows, kept as on the Mac in aliases.json beside the settings, and written out as PowerShell that the
/// hook reads again before each prompt, so changes reach open tabs.
enum AliasFile {
    static var url: URL? { AppSettings.folder?.appendingPathComponent("aliases.json") }
    /// The PowerShell a tab's hook reads: beside the settings, or for tests, in the temporary folder.
    static var scriptURL: URL {
        AppSettings.folder?.appendingPathComponent("aliases.ps1")
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("solanum-aliases-\(ProcessInfo.processInfo.processIdentifier).ps1")
    }
    /// Kept in memory when there's no file, for tests.
    private static var memory: [CommandAlias]?

    static func load() -> [CommandAlias] {
        if let memory { return memory }
        if let url, let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([CommandAlias].self, from: data) { return list }
        // The first time, the one everyone starts with.
        let start = [CommandAlias(name: "c", command: "claude")]
        save(start)
        return start
    }

    static func save(_ list: [CommandAlias]) {
        try? FileManager.default.createDirectory(at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? CommandAlias.powerShell(list).write(to: scriptURL, atomically: true, encoding: .utf8)
        guard let url else {
            memory = list
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        try? encoder.encode(list).write(to: url, options: .atomic)
    }
}

/// Settings, as a window of its own, like the Mac's: pages down the side, each a column of cards.
final class SettingsWindow {
    enum Page: Int, CaseIterable {
        case system, preferences, appearance, text, shortcuts, aliases

        var title: String {
            switch self {
            case .system: return "System"
            case .preferences: return "Preferences"
            case .appearance: return "Appearance"
            case .text: return "Text & Size"
            case .shortcuts: return "Shortcuts"
            case .aliases: return "Aliases"
            }
        }

        var glyph: UInt16 {
            switch self {
            case .system: return 0xE946
            case .preferences: return 0xE713
            case .appearance: return 0xE790
            case .text: return 0xE8D2
            case .shortcuts: return 0xE765
            case .aliases: return 0xE943
            }
        }
    }

    enum Control {
        case toggle(get: () -> Bool, set: (Bool) -> Void)
        case choice(options: [String], get: () -> String, set: (String) -> Void)
        case field(id: String, get: () -> String, placeholder: String, width: Float, commit: (String) -> Void)
        case value(String)
        case keys([String])
        case button(String, () -> Void)
        /// A color's hex, to type, and its swatch, which opens the picker; `alpha` where it may be see-through.
        case color(id: String, get: () -> String, alpha: Bool, set: (String) -> Void)
        /// A switch for the background's second color, and that color.
        case gradient(get: () -> String?, set: (String?) -> Void)
        /// A value dragged along a track, shown beside it as `format` has it, as on the Mac (ValueSlider there).
        case slider(min: Double, max: Double, get: () -> Double, set: (Double) -> Void, format: (Double) -> String)
        case none
    }

    struct Row {
        var glyph: UInt16?
        var title: String
        var detail: String?
        var control: Control
    }

    enum Block {
        case header(String)
        case card([Row])
        /// Theme cards: Solanum's and your own (with the New Theme card last), or VS Code's.
        case themes(vsCode: Bool)
        case links([(String, () -> Void)])
        case note(String)
        case aliases
        /// The theme being edited, as its card.
        case themePreview
        /// Its 16 terminal colors, normal over bright.
        case palette
    }

    /// What's drawn where, worked out once per frame, and used for clicks too.
    enum Piece {
        case title(String, UIRect)
        case header(String, UIRect)
        case card(UIRect)
        case divider(UIRect)
        case row(Row, UIRect, detailHeight: Float)
        case control(Control, UIRect)
        case theme(ThemeSpec, UIRect)
        case newTheme(UIRect)
        case link(String, UIRect, () -> Void)
        case note(String, UIRect)
        case removeAlias(Int, UIRect)
        case preview(ThemeSpec, UIRect)
        case palette(UIRect)
    }

    static let shared = SettingsWindow()
    private static let className = wide("SolanumSettingsWindow")
    private(set) var hwnd: HWND?
    private var canvas: Canvas!
    private(set) var page = Page.system
    private var scroll: Float = 0
    private var width = 0, height = 0
    private var hovered: (x: Float, y: Float)?
    private var menu: MenuModel?
    /// The field being typed in, and what's in it so far.
    private(set) var editing: (id: String, state: TextFieldState, commit: (String) -> Void)?
    private var aliases: [CommandAlias] = []
    private var touch: TouchScroll?
    /// The custom theme open in the editor (Appearance › Edit Theme), as on the Mac, and its colors as they're changed.
    private(set) var editingTheme: URL?
    private(set) var draft: ThemeSpec?
    /// The edited theme as its file has it: what Reset goes back to, and what tells whether there's anything to save.
    private(set) var savedTheme: ThemeSpec?
    /// A question asked over the window: whether to save before leaving the editor, or to delete a theme.
    private(set) var dialog: DialogModel?
    /// The background's second color while its switch is off, so turning it back on brings the same one.
    private var gradientMemory = "#000000"
    private(set) var picker: ColorPicker?
    /// The picker a click just closed, so a click on its own swatch closes it rather than opening it again.
    private var justClosedPicker: String?
    /// Shows the draft in every window a moment after a burst of changes (dragging in the picker) settles.
    private static let draftTimer: UINT_PTR = 1
    /// The slider being dragged: where its track is, and what it sets.
    private var sliding: (track: UIRect, min: Double, max: Double, set: (Double) -> Void)?

    private var dpi: Float { hwnd.map { Float(GetDpiForWindow($0)) } ?? 96 }
    var scale: Float { dpi / 96 }

    // MARK: Showing it

    func show(_ page: Page? = nil, activate: Bool = true) {
        if let page {
            if editingTheme != nil {
                // Unsaved changes are asked about first, over the window, once it's showing.
                if isDirty {
                    confirmLeavingTheme { [weak self] in self?.showPage(page) }
                } else {
                    leaveEditor()
                    self.page = page
                    scroll = 0
                }
            } else {
                self.page = page
                scroll = 0
            }
        }
        aliases = AliasFile.load()
        if let hwnd {
            ShowWindow(hwnd, activate ? Win.SW_SHOW : Win.SW_SHOWNOACTIVATE)
            if activate { SetForegroundWindow(hwnd) }
            invalidate()
            return
        }
        guard Self.registerClass() else { return }
        let created = Self.className.withUnsafeBufferPointer { name in
            wide("Settings").withUnsafeBufferPointer { title in
                CreateWindowExW(0, name.baseAddress, title.baseAddress, Win.WS_OVERLAPPEDWINDOW, Win.CW_USEDEFAULT, Win.CW_USEDEFAULT,
                                900, 680, nil, nil, GetModuleHandleW(nil), nil)
            }
        }
        guard let created else { return }
        hwnd = created
        Self.current = self
        sol_use_dark_titlebar(UnsafeMutableRawPointer(created))
        guard let canvas = Canvas(window: UnsafeMutableRawPointer(created), fontPixels: 13 * scale) else { return }
        self.canvas = canvas
        let size = (Int32(900 * scale), Int32(680 * scale))
        SetWindowPos(created, nil, 0, 0, size.0, size.1, Win.SWP_NOMOVE | Win.SWP_NOZORDER | Win.SWP_NOACTIVATE)
        AppSettings.shared.onChange.append { [weak self] in self?.invalidate() }
        ShowWindow(created, activate ? Win.SW_SHOW : Win.SW_SHOWNOACTIVATE)
    }

    func close() { if let hwnd { PostMessageW(hwnd, Win.WM_CLOSE, 0, 0) } }
    var isOpen: Bool { hwnd != nil }

    private static var current: SettingsWindow?

    private static func registerClass() -> Bool {
        var info = WNDCLASSEXW()
        info.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
        info.lpfnWndProc = { hwnd, message, wParam, lParam in
            if let window = SettingsWindow.current, window.hwnd == hwnd { return window.handle(message, wParam, lParam) }
            return DefWindowProcW(hwnd, message, wParam, lParam)
        }
        info.hInstance = GetModuleHandleW(nil)
        info.hCursor = LoadCursorW(nil, Win.arrowCursor)
        info.hIcon = LoadIconW(GetModuleHandleW(nil), Win.appIcon)
        return className.withUnsafeBufferPointer { name in
            info.lpszClassName = name.baseAddress
            // Registered already is fine: the window is made again after it's closed.
            return RegisterClassExW(&info) != 0 || GetLastError() == 1410
        }
    }

    private func invalidate() { if let hwnd { InvalidateRect(hwnd, nil, false) } }

    private func handle(_ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
        guard let hwnd else { return 0 }
        switch message {
        case Win.WM_PAINT:
            var ps = PAINTSTRUCT()
            _ = BeginPaint(hwnd, &ps)
            if sol_canvas_begin(canvas.raw, TerminalPalette.background) >= 0 {
                draw(on: canvas)
                _ = sol_canvas_end(canvas.raw)
            }
            EndPaint(hwnd, &ps)
            return 0
        case Win.WM_ERASEBKGND:
            return 1
        case Win.WM_SIZE:
            width = Int(lParam & 0xFFFF)
            height = Int((lParam >> 16) & 0xFFFF)
            sol_canvas_resize(canvas.raw, Int32(width), Int32(height))
            clampScroll()
            invalidate()
            return 0
        case Win.WM_DPICHANGED:
            canvas.setFontPixels(13 * scale)
            let suggested = UnsafePointer<RECT>(bitPattern: Int(lParam))!.pointee
            SetWindowPos(hwnd, nil, suggested.left, suggested.top, suggested.right - suggested.left, suggested.bottom - suggested.top,
                         Win.SWP_NOZORDER | Win.SWP_NOACTIVATE)
            return 0
        case Win.WM_MOUSEMOVE, Win.WM_LBUTTONDOWN, Win.WM_LBUTTONUP:
            let x = Float(Int16(truncatingIfNeeded: lParam & 0xFFFF)), y = Float(Int16(truncatingIfNeeded: (lParam >> 16) & 0xFFFF))
            // A finger dragged scrolls the page (or an open menu), and a tap clicks; see `TouchScroll`.
            // With the color picker open a finger drags in it instead, as the mouse does.
            if message == Win.WM_LBUTTONDOWN && TouchScroll.fromTouch && picker == nil && dialog == nil && !onSlider(x: x, y: y) && (x >= sidebarWidth || menu != nil) {
                touch = TouchScroll(at: lParam, stepPixels: 1) { [weak self] pixels in
                    guard let self else { return }
                    if let menu = self.menu { menu.scrollBy(-Float(pixels)) } else { self.scroll -= Float(pixels); self.clampScroll() }
                    self.invalidate()
                }
                SetCapture(hwnd)
                return 0
            }
            if touch != nil && message == Win.WM_MOUSEMOVE {
                touch!.moved(to: lParam, slop: 8 * scale)
                return 0
            }
            if let t = touch, message == Win.WM_LBUTTONUP {
                touch = nil
                ReleaseCapture()
                if !t.dragging {
                    mouse(Win.WM_LBUTTONDOWN, x: x, y: y)
                    mouse(Win.WM_LBUTTONUP, x: x, y: y)
                }
                return 0
            }
            mouse(message, x: x, y: y)
            return 0
        case Win.WM_SETCURSOR where LRESULT(lParam & 0xFFFF) == Win.HTCLIENT:
            // The I-beam over a field that's typed in; the arrow everywhere else, an open menu included.
            var point = POINT()
            GetCursorPos(&point)
            ScreenToClient(hwnd, &point)
            let x = Float(point.x), y = Float(point.y)
            var onField = false
            if dialog != nil || footer?.contains(x, y) == true {
                onField = false
            } else if let picker, menu == nil, picker.frame.contains(x, y) {
                if case .hexField = picker.part(atX: x, y: y) { onField = true }
            } else if menu == nil, canvas != nil, x >= sidebarWidth {
                for piece in pieces(canvas, width: width, height: height) {
                    guard case .control(let control, let r) = piece, r.contains(x, y) else { continue }
                    switch control {
                    case .field: onField = true
                    case .color: onField = x < swatchRect(r).x
                    case .gradient(let get, _): onField = get() != nil && x >= r.maxX - Self.colorWidth * scale && x < swatchRect(r).x
                    default: break
                    }
                    break
                }
            }
            SetCursor(LoadCursorW(nil, onField ? Win.ibeamCursor : Win.arrowCursor))
            return 1
        case Win.WM_RBUTTONUP:
            let x = Float(Int16(truncatingIfNeeded: lParam & 0xFFFF)), y = Float(Int16(truncatingIfNeeded: (lParam >> 16) & 0xFFFF))
            if menu == nil, x >= sidebarWidth { rightClick(x: x, y: y) }
            return 0
        case Win.WM_MOUSEWHEEL:
            let notches = Float(Int16(truncatingIfNeeded: (wParam >> 16) & 0xFFFF)) / Float(Win.WHEEL_DELTA)
            if dialog != nil { return 0 }
            if let menu { menu.scrollBy(-notches * menu.rowHeight * 2) } else {
                // The picker stays with its swatch, so it closes rather than being left behind.
                if picker != nil { commitEditing(); picker = nil }
                scroll -= notches * 60 * scale
                clampScroll()
            }
            invalidate()
            return 0
        case Win.WM_TIMER where wParam == Self.draftTimer:
            KillTimer(hwnd, Self.draftTimer)
            publishDraft()
            return 0
        case Win.WM_CLOSE where isDirty:
            // As on the Mac: save, don't save, or stay.
            confirmLeavingTheme { [weak self] in if let hwnd = self?.hwnd { DestroyWindow(hwnd) } }
            return 0
        case Win.WM_KEYDOWN:
            key(Int32(truncatingIfNeeded: wParam))
            return 0
        case Win.WM_CHAR:
            let unit = UInt16(truncatingIfNeeded: wParam)
            if var field = editing, unit >= 0x20, unit != 0x7F, let scalar = Unicode.Scalar(unit) {
                field.state.insert(String(Character(scalar)))
                editing = field
                invalidate()
            }
            return 0
        case Win.WM_DESTROY:
            commitEditing()
            // Unsaved changes were asked about; whatever's left goes.
            leaveEditor()
            dialog = nil
            picker = nil
            self.hwnd = nil
            canvas = nil
            menu = nil
            return 0
        default:
            return DefWindowProcW(hwnd, message, wParam, lParam)
        }
    }

    // MARK: What's on each page

    private func blocks(_ page: Page) -> [Block] {
        let s = AppSettings.shared
        func toggle(_ key: String, _ value: @escaping () -> Bool) -> Control {
            .toggle(get: value, set: { s.set(key, $0) })
        }
        func number(_ key: String, _ value: @escaping () -> String, placeholder: String, width: Float = 80) -> Control {
            .field(id: key, get: value, placeholder: placeholder, width: width, commit: { text in
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || Double(trimmed) != nil { s.set(key, trimmed.isEmpty ? (AppSettings.defaults[key] ?? "") : trimmed) }
            })
        }
        let later = "Not on Windows yet. Saved for when it is."
        switch page {
        case .system:
            let exe = CommandLine.arguments.first ?? ""
            let built = ((try? FileManager.default.attributesOfItem(atPath: exe))?[.modificationDate] as? Date).map { "\($0)" } ?? "Unknown"
            var version = OSVERSIONINFOW()
            version.dwOSVersionInfoSize = DWORD(MemoryLayout<OSVERSIONINFOW>.size)
            let windows = ProcessInfo.processInfo.operatingSystemVersion
            _ = version
            return [
                .header("About"),
                .card([Row(title: "Version", control: .value("Solanum for Windows (windows-compat)")),
                       Row(title: "Built", control: .value(built)),
                       Row(title: "Installed at", control: .value(exe)),
                       Row(title: "Windows", control: .value("\(windows.majorVersion).\(windows.minorVersion).\(windows.patchVersion)"))]),
                .header("Settings File"),
                .card([Row(glyph: 0xE8A5, title: "Config file", detail: AppSettings.fileURL?.path ?? "Not saved in tests",
                           control: .button("Open", { if let url = AppSettings.fileURL { _ = wide(url.path).withUnsafeBufferPointer { ShellExecuteW(nil, nil, $0.baseAddress, nil, nil, 1) } } }))]),
                .header("Software Update"),
                .card([Row(glyph: 0xE895, title: "Updates", detail: "Solanum for Windows doesn't update itself yet: pull the branch and run build.ps1.", control: .none)]),
            ]
        case .preferences:
            return [
                .header("Window Size"),
                .card([Row(glyph: 0xE7F4, title: "Columns", detail: "A new window's width, in characters.", control: number("window-columns", { "\(s.windowColumns)" }, placeholder: "110")),
                       Row(glyph: 0xE7F4, title: "Rows", detail: "And its height, in lines.", control: number("window-rows", { "\(s.windowRows)" }, placeholder: "32"))]),
                .links([("Reset to Default", { s.set("window-columns", "110"); s.set("window-rows", "32") })]),
                .header("Tabs"),
                .card([Row(glyph: 0xECCD, title: "New tabs open in", detail: "Where Ctrl+T starts.",
                           control: .choice(options: ["Current Folder", "Home Folder"], get: { s.newTabFolder == "home" ? "Home Folder" : "Current Folder" },
                                            set: { s.set("new-tab-folder", $0 == "Home Folder" ? "home" : "current") })),
                       Row(glyph: 0xEA8F, title: "Notify after (seconds)",
                           detail: "A card in the window's corner when a command or an agent in a tab you're not watching ran at least this long. 0 turns it off.",
                           control: number("notify-after-seconds", { s.file["notify-after-seconds"] ?? "10" }, placeholder: "10")),
                       Row(glyph: 0xE767, title: "Bell sound", detail: "Play the alert sound when a program rings the bell. It always flashes the taskbar.",
                           control: toggle("audible-bell") { s.audibleBell }),
                       Row(glyph: 0xE81C, title: "Lines kept per tab", detail: "Older output is dropped past this.",
                           control: number("scrollback-lines", { "\(s.scrollback)" }, placeholder: "10000", width: 90))]),
                .header("Shell"),
                .card([Row(glyph: 0xE756, title: "Shell", detail: "Empty for PowerShell. A command line works too, such as cmd.exe. New tabs use it.",
                           control: .field(id: "shell", get: { s.shell }, placeholder: "PowerShell", width: 220, commit: { s.set("shell", $0.trimmingCharacters(in: .whitespaces)) })),
                       Row(glyph: 0xE943, title: "Shell integration", detail: "Marks prompts and commands, and follows the current folder, in PowerShell.",
                           control: toggle("shell-integration") { s.shellIntegration })]),
                .header("ssh"),
                .card([Row(glyph: 0xE72E, title: "Remember ssh passwords for the sidebar",
                           detail: "Solanum asks for an ssh password itself, and keeps it while the session lasts so the sidebar can sign in too. Only in memory, encrypted, and never saved. ssh keys need none of this.",
                           control: toggle("remember-ssh-passwords") { s.rememberSSHPasswords })]),
                .header("Keep Awake"),
                .card([Row(glyph: 0xEC32, title: "Keep awake for (seconds)", detail: "How long Ctrl+Shift+A keeps this PC and its display awake. The default, 28800, is 8 hours.",
                           control: number("keep-awake-seconds", { s.file["keep-awake-seconds"] ?? "28800" }, placeholder: "28800", width: 90))]),
                .header("Sessions"),
                .card([Row(glyph: 0xE8F1, title: "Reopen windows and tabs", detail: later, control: toggle("restore-session") { s.file.bool("restore-session", true) }),
                       Row(glyph: 0xE81C, title: "Include recent output", detail: later, control: toggle("restore-scrollback") { s.file.bool("restore-scrollback", true) }),
                       Row(glyph: 0xE72C, title: "Continue coding agents", detail: later, control: toggle("continue-agents") { s.file.bool("continue-agents", true) }),
                       Row(glyph: 0xE711, title: "Ask before closing with something running", detail: later, control: toggle("confirm-quit") { s.file.bool("confirm-quit", true) })]),
            ]
        case .appearance where draft != nil:
            return editorBlocks()
        case .appearance:
            // As on the Mac: Solanum's themes and your own, then VS Code's; the window; the status bar.
            return [
                .themes(vsCode: false),
                .header("VS Code"),
                .themes(vsCode: true),
                .header("File Icons"),
                .card([Row(glyph: 0xE8B7, title: "Icon pack",
                           detail: IconPacks.downloading.map { "Downloading \($0)\u{2026}" } ?? IconPacks.flavorNote
                               ?? "For the sidebars, file tabs and git pages. VS Code icon themes work.",
                           control: .choice(options: ["Solanum"] + IconPacks.installed.map(\.label),
                                            get: { IconPacks.label(for: IconPacks.shownID) ?? "Solanum" },
                                            set: { label in
                                                let id = IconPacks.installed.first { $0.label == label }?.id ?? IconPackCatalog.solanumID
                                                // The one already showing changes nothing: Latte shouldn't replace the dark flavor picked.
                                                guard id != IconPacks.shownID else { return }
                                                s.set("file-icons", id)
                                            }))]),
                .links([(IconPacks.downloading == nil ? "Download\u{2026}" : "Downloading\u{2026}", { [weak self] in self?.showIconDownloads() }),
                        ("Import Icon Pack\u{2026}", { [weak self] in self?.importIconPack() }),
                        ("Open Icon Packs Folder", { IconPacks.openFolder() })]),
                .header("Window"),
                .card([Row(glyph: 0xE793, title: "Background opacity", detail: "How much of the desktop shows through.",
                           control: .slider(min: 0.5, max: 1, get: { s.opacity }, set: { s.set("background-opacity", String(format: "%.2f", $0)) },
                                            format: { "\(Int(($0 * 100).rounded()))%" })),
                       Row(glyph: 0xE727, title: "Blur behind the window", detail: "Frosted glass when the background is see-through.",
                           control: toggle("background-blur") { s.blur }),
                       Row(glyph: 0xE91B, title: "Shows through",
                           detail: "Your wallpaper looks the same whether Solanum is in front or not; windows behind shows whatever is there.",
                           control: .choice(options: ["Your Wallpaper", "Windows Behind"], get: { s.showsWallpaper ? "Your Wallpaper" : "Windows Behind" },
                                            set: { s.set("see-through", $0 == "Windows Behind" ? "windows" : "wallpaper") })),
                       Row(glyph: 0xE7B3, title: "Keep text readable on light themes", detail: later,
                           control: toggle("minimum-contrast") { s.file.bool("minimum-contrast", true) }),
                       Row(glyph: 0xE7F4, title: "Padding", detail: "Space between the text and the window edge, in points.",
                           control: number("padding", { s.file["padding"] ?? "6" }, placeholder: "6"))]),
                .header("Status Bar"),
                .card([Row(glyph: 0xE774, title: "Theme icon", detail: "An icon beside the theme name in the status bar; Outer Wilds themes show their planet. Off shows just the name.",
                           control: toggle("theme-icon") { s.themeIcon })]),
                .links([("Open Themes Folder", { Self.openThemesFolder() }),
                        ("Open Config File", { if let url = AppSettings.fileURL { _ = wide(url.path).withUnsafeBufferPointer { ShellExecuteW(nil, nil, $0.baseAddress, nil, nil, 1) } } }),
                        ("Import Theme…", { [weak self] in self?.importTheme() })]),
                .note("New Theme copies the one you're using and opens it in the editor, where every color changes as you pick it; "
                      + "the pencil on your own themes opens it again. Each is a JSON file in the themes folder, and a Mac theme file "
                      + "works here as it is, as does a Windows Terminal color scheme or a VS Code color theme. Right-click a theme for more."),
            ]
        case .text:
            return [
                .header("Font"),
                .card([Row(glyph: 0xE8D2, title: "Font", detail: "Any monospaced font installed. Empty for Cascadia Mono, else Consolas.",
                           control: .field(id: "font-family", get: { s.fontFamily }, placeholder: "Cascadia Mono", width: 220, commit: { s.set("font-family", $0.trimmingCharacters(in: .whitespaces)) })),
                       Row(glyph: 0xE8E9, title: "Size", detail: "In points.", control: number("font-size", { s.file["font-size"] ?? "11" }, placeholder: "11")),
                       Row(glyph: 0xE8E4, title: "Line height", detail: "A multiple of the size.", control: number("line-height", { s.file["line-height"] ?? "1.2" }, placeholder: "1.2"))]),
                .header("Cursor"),
                .card([Row(glyph: 0xE8AC, title: "Style",
                           control: .choice(options: ["Bar", "Block", "Underline"], get: { s.cursorStyle.capitalized }, set: { s.set("cursor-style", $0.lowercased()) })),
                       Row(glyph: 0xE706, title: "Blink", control: toggle("cursor-blink") { s.cursorBlink })]),
                .header("Text"),
                .card([Row(glyph: 0xE8DD, title: "Bold is bright", detail: "Bold text in the first eight colors takes their bright ones, as older terminals did.",
                           control: toggle("bold-is-bright") { s.boldIsBright })]),
                .header("Keyboard & Mouse"),
                .card([Row(glyph: 0xE8C8, title: "Copy on select", detail: "Selecting text copies it right away.", control: toggle("copy-on-select") { s.copyOnSelect }),
                       Row(glyph: 0xE962, title: "Scroll speed", detail: "Lines per mouse-wheel notch, in the terminal and in files, previews and git pages; touchpads move in proportion. Lower is slower, such as 1 or 0.5.",
                           control: number("scroll-speed", { s.file["scroll-speed"] ?? "3" }, placeholder: "3"))]),
            ]
        case .shortcuts:
            return TerminalWindow.shortcutGroups.flatMap { group -> [Block] in
                [.header(group.title), .card(group.items.map { Row(title: $0.title, control: .keys($0.keys.split(separator: "+").map(String.init))) })]
            } + [.note("Ctrl stands in for the Mac's Command key, Alt for Option. A key Solanum takes is its own in every program.")]
        case .aliases:
            return [.note("Short names for longer commands, in PowerShell tabs. Changes reach open tabs at their next prompt."), .aliases]
        }
    }

    /// Appearance › Edit Theme, as on the Mac (ThemeEditor there): the theme as its card, its name, its base colors, its 16
    /// terminal colors, and what else can be done with it.
    private func editorBlocks() -> [Block] {
        func color(_ id: String, alpha: Bool = false, _ get: @escaping (ThemeSpec) -> String,
                   _ set: @escaping (ThemeSpec, String) -> ThemeSpec) -> Control {
            .color(id: id, get: { [weak self] in self?.draft.map(get) ?? "#000000" }, alpha: alpha, set: { [weak self] hex in
                guard let self, let d = self.draft else { return }
                self.draftChanged(set(d, hex))
            })
        }
        let gradient = Control.gradient(get: { [weak self] in self?.draft?.background2 }, set: { [weak self] hex in
            guard let self, let d = self.draft else { return }
            if let old = d.background2 { self.gradientMemory = old }
            self.draftChanged(d.with(background2: .some(hex)))
        })
        let name = Control.field(id: "theme-name", get: { [weak self] in self?.draft?.name ?? "" }, placeholder: "My Theme", width: 220,
                                 commit: { [weak self] text in
                                     guard let self, let d = self.draft else { return }
                                     let trimmed = text.trimmingCharacters(in: .whitespaces)
                                     if !trimmed.isEmpty && trimmed != d.name { self.draftChanged(d.with(name: trimmed)) }
                                 })
        return [
            .links([("‹ All Themes", { [weak self] in self?.closeEditor() })]),
            .themePreview,
            .header("Name"),
            .card([Row(glyph: 0xE70F, title: "Theme name", detail: "Shown on its card and in the Theme menu.", control: name)]),
            .header("Base colors"),
            .card([
                Row(glyph: 0xE771, title: "Background", control: color("background", { $0.background }) { $0.with(background: $1) }),
                Row(glyph: 0xE706, title: "Gradient", detail: "Fade the background toward a second color at the bottom.", control: gradient),
                Row(glyph: 0xE8D2, title: "Text", control: color("foreground", { $0.foreground }) { $0.with(foreground: $1) }),
                Row(glyph: 0xE790, title: "Accent", detail: "Tab underline, highlights and markers.",
                    control: color("accent", { $0.accent }) { $0.with(accent: $1) }),
                Row(glyph: 0xE8AC, title: "Cursor", control: color("cursor", { $0.cursor ?? $0.accent }) { $0.with(cursor: .some($1)) }),
                Row(glyph: 0xE8B3, title: "Selection", detail: "Usually see-through so the text stays readable.",
                    control: color("selection", alpha: true, { $0.selection ?? HSVColor.hex(HexColor($0.accent)?.rgb ?? 0xA584E8, alpha: 0.3) }) {
                        $0.with(selection: .some($1))
                    }),
            ]),
            .header("Background picture"),
            .card(pictureRows()),
            .header("Terminal colors"),
            .palette,
            .links([("Duplicate", { [weak self] in self?.duplicateEditedTheme() }),
                    (Self.deleteTitle, { [weak self] in self?.deleteEditedTheme() })]),
        ]
    }

    /// A photo behind the theme, blurred and tinted with its background color as the wallpaper is.
    private func pictureRows() -> [Row] {
        let image = draft?.image
        let name = image.map { URL(fileURLWithPath: $0.file).lastPathComponent }
        var rows = [Row(glyph: 0xEB9F, title: "Picture",
                        detail: name.map { "\($0), copied into the themes folder." } ?? "Any photo, behind the terminal, the tabs and the sidebars.",
                        control: .button(image == nil ? "Choose…" : "Change…", { [weak self] in self?.chooseThemePicture() }))]
        guard image != nil else { return rows }
        func change(_ edit: @escaping (inout ThemeImage) -> Void) -> (Double) -> Void {
            { [weak self] value in
                guard let self, let d = self.draft, var picture = d.image else { return }
                _ = value
                edit(&picture)
                self.draftChanged(d.with(image: .some(picture)))
            }
        }
        rows.append(Row(glyph: 0xE727, title: "Blur", detail: "Softens the picture so text reads over it.",
                        control: .slider(min: 0, max: 60, get: { [weak self] in self?.draft?.image?.blur ?? 0 },
                                         set: { v in change { $0.blur = v.rounded() }(v) },
                                         format: { "\(Int($0.rounded())) px" })))
        rows.append(Row(glyph: 0xE790, title: "Background color over it", detail: "How much of the theme's background covers the picture.",
                        control: .slider(min: 0, max: 0.95, get: { [weak self] in self?.draft?.image?.tint ?? 0 },
                                         set: { v in change { $0.tint = v }(v) },
                                         format: { "\(Int(($0 * 100).rounded()))%" })))
        rows.append(Row(glyph: 0xE74D, title: "Remove the picture", detail: "Back to the background color alone. The file stays in the themes folder.",
                        control: .button("Remove", { [weak self] in
                            guard let self, let d = self.draft else { return }
                            self.draftChanged(d.with(image: .some(nil)))
                        })))
        return rows
    }

    private func chooseThemePicture() {
        guard let d = draft, let path = ThemeFiles.pickImage(owner: hwnd) else { return }
        guard let file = ThemeFiles.importImage(path, for: savedTheme?.name ?? d.name) else { _ = MessageBeep(UINT(bitPattern: -1)); return }
        let old = d.image
        draftChanged(d.with(image: .some(ThemeImage(file: file, blur: old?.blur ?? 24, tint: old?.tint ?? 0.7))))
    }

    /// Theme pictures as small images to draw on the cards, by canvas and file.
    private var thumbnails: [String: Int32] = [:]

    private func thumbnail(_ image: ThemeImage, on target: Canvas) -> Int32? {
        guard let url = ThemeFiles.imageURL(image) else { return nil }
        let key = "\(ObjectIdentifier(target))|\(url.path)"
        if let known = thumbnails[key] { return known >= 0 ? known : nil }
        let made = wide(url.path).withUnsafeBufferPointer { sol_canvas_load_image_file(target.raw, $0.baseAddress, 480) }
        thumbnails[key] = made
        return made >= 0 ? made : nil
    }

    // MARK: Icon packs

    /// The link last clicked, for a menu that opens under it (Download…).
    private var pressedLink: UIRect?

    /// The packs to download, as on the Mac, in a menu under the link.
    private func showIconDownloads() {
        guard IconPacks.downloading == nil, let r = pressedLink, canvas != nil else { return }
        let items = IconPackCatalog.packs.map { pack in
            MenuItem(title: pack.label) { [weak self] in
                IconPacks.download(pack.label, pack.source, post: { work in TerminalWindow.onAnyWindowThread(work) },
                                   changed: { self?.invalidate() }) { problem in
                    guard let problem else { return }
                    self?.ask(DialogModel(title: "Couldn't install \(pack.label)", message: problem, primary: "OK", cancel: "Close") {})
                }
            }
        }
        menu = MenuModel(items: items, anchorX: r.x, anchorY: r.maxY + 4 * scale, above: false, width: MenuView.width(for: items, canvas: canvas, scale: scale),
                         window: UIRect(x: 0, y: 0, width: Float(width), height: Float(height)), scale: scale)
        invalidate()
    }

    /// A .vsix from VS Code's marketplace or Open VSX, picked with Windows' Open dialog, installed and put to use.
    private func importIconPack() {
        guard let path = ThemeFiles.pickFile(owner: hwnd, title: "Import Icon Pack", filter: "VS Code extensions (*.vsix)\u{0}*.vsix\u{0}All files\u{0}*.*\u{0}\u{0}") else { return }
        Thread.detachNewThread { [weak self] in
            var problem: String?
            var first: IconPackEntry?
            do { first = try IconPacks.install(from: path).first } catch let e as IconPacks.InstallError { problem = e.message } catch { problem = error.localizedDescription }
            TerminalWindow.onAnyWindowThread {
                IconPacks.reload()
                if let first { AppSettings.shared.set("file-icons", first.id) }
                self?.invalidate()
                if let problem {
                    let name = URL(fileURLWithPath: path).lastPathComponent
                    self?.ask(DialogModel(title: "Couldn't import \u{201C}\(name)\u{201D}", message: problem, primary: "OK", cancel: "Close") {})
                }
            }
        }
    }

    private static let deleteTitle = "Delete Theme…"
    /// The hex field and swatch of a color control, as on the Mac (ColorControl there).
    private static let colorWidth: Float = 152

    // MARK: Layout

    private var sidebarWidth: Float { (200 * scale).rounded() }

    private func label(_ target: Canvas, _ text: String, _ r: UIRect, pixels: Float, semibold: Bool = false, color: UInt32? = nil, alpha: Float = 1) {
        let units = Array(text.utf16)
        sol_canvas_draw_label(target.raw, r.x, r.y, r.width, r.height, units, Int32(units.count), pixels, semibold ? 1 : 0, color ?? TerminalPalette.foreground, alpha)
    }

    private func measure(_ target: Canvas, _ text: String, pixels: Float, semibold: Bool = false) -> Float {
        let units = Array(text.utf16)
        return sol_canvas_measure_label(target.raw, units, Int32(units.count), pixels, semibold ? 1 : 0)
    }

    private func paragraphHeight(_ target: Canvas, _ text: String, width: Float, pixels: Float) -> Float {
        let units = Array(text.utf16)
        return sol_canvas_paragraph(target.raw, 0, 0, width, units, Int32(units.count), pixels, 0, 0, 0, 1)
    }

    private func controlWidth(_ control: Control, _ target: Canvas) -> Float {
        let s = scale
        switch control {
        case .toggle: return 40 * s
        case .choice(let options, _, _): return max((options.map { measure(target, $0, pixels: 13 * s) }.max() ?? 0) + 44 * s, 130 * s)
        case .field(_, _, _, let width, _): return width * s
        case .value(let text): return min(measure(target, text, pixels: 13 * s) + 4 * s, 420 * s)
        case .keys(let keys): return keys.reduce(0) { $0 + measure(target, $1, pixels: 12 * s, semibold: true) + 18 * s + 6 * s }
        case .button(let title, _): return measure(target, title, pixels: 13 * s) + 28 * s
        case .color: return Self.colorWidth * s
        case .gradient: return (Self.colorWidth + 52) * s
        case .slider: return Self.sliderWidth * s
        case .none: return 0
        }
    }

    /// Lays out the page, from the top of its scrolled content, for drawing and for clicks alike.
    private func pieces(_ target: Canvas, width w: Int, height h: Int) -> [Piece] {
        let s = scale
        let left = sidebarWidth + 32 * s, contentWidth = min(Float(w) - left - 32 * s, 760 * s)
        var y = 28 * s - scroll
        let title = page == .appearance && draft != nil ? "Edit Theme" : page.title
        var out: [Piece] = [.title(title, UIRect(x: left, y: y, width: contentWidth, height: 34 * s))]
        y += 34 * s + 22 * s
        for block in blocks(page) {
            switch block {
            case .header(let text):
                out.append(.header(text.uppercased(), UIRect(x: left + 4 * s, y: y, width: contentWidth, height: 16 * s)))
                y += 16 * s + 10 * s
            case .card(let rows):
                let top = y
                var rowPieces: [Piece] = []
                for (i, row) in rows.enumerated() {
                    let cw = controlWidth(row.control, target)
                    let textLeft = left + (row.glyph != nil ? 60 : 18) * s
                    let textWidth = max(contentWidth - (textLeft - left) - cw - 36 * s, 80 * s)
                    let detailHeight = row.detail.map { paragraphHeight(target, $0, width: textWidth, pixels: 12 * s) } ?? 0
                    let rowHeight = max(52 * s, 20 * s + 22 * s + detailHeight)
                    let r = UIRect(x: left, y: y, width: contentWidth, height: rowHeight)
                    if i > 0 { rowPieces.append(.divider(UIRect(x: left + 16 * s, y: y, width: contentWidth - 32 * s, height: 1))) }
                    rowPieces.append(.row(row, r, detailHeight: detailHeight))
                    let controlHeight: Float = { if case .toggle = row.control { return 22 * s }; return 30 * s }()
                    rowPieces.append(.control(row.control, UIRect(x: r.maxX - 18 * s - cw, y: (r.midY - controlHeight / 2).rounded(), width: cw, height: controlHeight)))
                    y += rowHeight
                }
                out.append(.card(UIRect(x: left, y: top, width: contentWidth, height: y - top)))
                out += rowPieces
                y += 28 * s
            case .themes(let vsCode):
                // As many columns as fit, up to three, as on the Mac.
                let gap = (14 * s).rounded(), cardHeight = (128 * s).rounded()
                let columns = max(1, min(3, Int((contentWidth + gap) / (200 * s + gap))))
                let cardWidth = ((contentWidth - gap * Float(columns - 1)) / Float(columns)).rounded(.down)
                let settings = AppSettings.shared
                let themes = vsCode ? ThemeSpecs.vsCode.filter { v in !settings.customThemes.contains { $0.name == v.name } }
                    : [ThemeSpecs.solanumDefault] + ThemeSpecs.outerWilds + settings.customThemes
                let count = themes.count + (vsCode ? 0 : 1)
                func slot(_ i: Int) -> UIRect {
                    UIRect(x: left + Float(i % columns) * (cardWidth + gap), y: y + Float(i / columns) * (cardHeight + gap), width: cardWidth, height: cardHeight)
                }
                for (i, spec) in themes.enumerated() { out.append(.theme(spec, slot(i))) }
                if !vsCode { out.append(.newTheme(slot(themes.count))) }
                let rows = (count + columns - 1) / columns
                y += Float(rows) * cardHeight + Float(max(rows - 1, 0)) * gap + (vsCode ? 30 : 24) * s
            case .links(let links):
                var x = left + 4 * s
                for (title, action) in links {
                    let lw = measure(target, title, pixels: 13 * s, semibold: true)
                    out.append(.link(title, UIRect(x: x, y: y, width: lw, height: 20 * s), action))
                    x += lw + 18 * s
                }
                y += 20 * s + 28 * s
            case .note(let text):
                let nh = paragraphHeight(target, text, width: contentWidth - 8 * s, pixels: 12.5 * s)
                out.append(.note(text, UIRect(x: left + 4 * s, y: y, width: contentWidth - 8 * s, height: nh)))
                y += nh + 18 * s
            case .aliases:
                let top = y, rowHeight = 46 * s
                for (i, alias) in aliases.enumerated() {
                    if i > 0 { out.append(.divider(UIRect(x: left + 16 * s, y: y, width: contentWidth - 32 * s, height: 1))) }
                    let nameField = Control.field(id: "alias-name-\(i)", get: { alias.name }, placeholder: "name", width: 120, commit: { [weak self] text in
                        self?.updateAlias(i) { $0.name = text.trimmingCharacters(in: .whitespaces) }
                    })
                    let commandField = Control.field(id: "alias-command-\(i)", get: { alias.command }, placeholder: "command", width: (contentWidth - 230 * s) / s, commit: { [weak self] text in
                        self?.updateAlias(i) { $0.command = text }
                    })
                    out.append(.control(nameField, UIRect(x: left + 16 * s, y: y + 8 * s, width: 120 * s, height: 30 * s)))
                    out.append(.control(commandField, UIRect(x: left + 148 * s, y: y + 8 * s, width: contentWidth - 230 * s, height: 30 * s)))
                    out.append(.removeAlias(i, UIRect(x: left + contentWidth - 52 * s, y: y + 8 * s, width: 30 * s, height: 30 * s)))
                    y += rowHeight
                }
                if aliases.isEmpty { y += 8 * s }
                out.insert(.card(UIRect(x: left, y: top, width: contentWidth, height: max(y - top, 8 * s))), at: out.count - (aliases.count * 4 - (aliases.isEmpty ? 0 : 1)))
                y += 14 * s
                out.append(.link("Add Alias", UIRect(x: left + 4 * s, y: y, width: measure(target, "Add Alias", pixels: 13 * s, semibold: true), height: 20 * s), { [weak self] in
                    guard let self else { return }
                    self.aliases.append(CommandAlias(name: "", command: ""))
                    AliasFile.save(self.aliases)
                    self.editing = (id: "alias-name-\(self.aliases.count - 1)", state: TextFieldState(""), commit: { [weak self] text in
                        guard let self else { return }
                        self.updateAlias(self.aliases.count - 1) { $0.name = text.trimmingCharacters(in: .whitespaces) }
                    })
                    self.invalidate()
                }))
                y += 20 * s + 28 * s
            case .themePreview:
                if let draft {
                    out.append(.preview(draft, UIRect(x: left, y: y, width: min((300 * s).rounded(), contentWidth), height: (128 * s).rounded())))
                    y += (128 + 22) * s
                }
            case .palette:
                let r = UIRect(x: left, y: y, width: contentWidth, height: (212 * s).rounded())
                out.append(.palette(r))
                for i in 0..<16 {
                    let cell = paletteCell(i, in: r)
                    let field = Control.field(id: "ansi-hex-\(i)", get: { [weak self] in
                        self?.draft.map { String(format: "%06X", ThemeColors($0).ansi[i]) } ?? ""
                    }, placeholder: "RRGGBB", width: cell.width / s, commit: { [weak self] text in
                        guard let self, let d = self.draft else { return }
                        guard let hex = ColorPicker.parse(text, allowsAlpha: false) else {
                            if text.uppercased() != String(format: "%06X", ThemeColors(d).ansi[i]) { _ = MessageBeep(UINT(bitPattern: -1)) }
                            return
                        }
                        var ansi = ThemeColors(d).ansi.map { String(format: "#%06X", $0) }
                        ansi[i] = hex
                        self.draftChanged(d.with(ansi: ansi))
                    })
                    out.append(.control(field, UIRect(x: cell.x, y: cell.maxY + 4 * s, width: cell.width, height: 20 * s)))
                }
                y += r.height + 26 * s
            }
        }
        contentHeight = y + scroll + footerHeight
        return out
    }

    private var contentHeight: Float = 0

    /// The save bar's height while a theme is being edited, as on the Mac (ThemeSaveBar there).
    private var footerHeight: Float { editingTheme != nil && page == .appearance ? (56 * scale).rounded() : 0 }

    private var footer: UIRect? {
        let h = footerHeight
        return h > 0 ? UIRect(x: sidebarWidth, y: Float(height) - h, width: Float(width) - sidebarWidth, height: h) : nil
    }

    /// Reset and Save Changes, at the bar's right.
    private func footerButtons(_ target: Canvas) -> (reset: UIRect, save: UIRect)? {
        guard let bar = footer else { return nil }
        let s = scale, h = 30 * s, y = (bar.y + (bar.height - h) / 2).rounded()
        let left = sidebarWidth + 32 * s, right = left + min(Float(width) - left - 32 * s, 760 * s)
        let saveW = measure(target, "Save Changes", pixels: 13 * s, semibold: true) + 36 * s
        let resetW = measure(target, "Reset", pixels: 13 * s, semibold: true) + 36 * s
        let save = UIRect(x: right - saveW, y: y, width: saveW, height: h)
        return (UIRect(x: save.x - 10 * s - resetW, y: y, width: resetW, height: h), save)
    }

    private func clampScroll() {
        scroll = min(max(scroll, 0), max(contentHeight - Float(height) + 20 * scale, 0))
    }

    private func updateAlias(_ i: Int, _ change: (inout CommandAlias) -> Void) {
        guard aliases.indices.contains(i) else { return }
        change(&aliases[i])
        AliasFile.save(aliases)
        invalidate()
    }

    // MARK: Drawing

    private func draw(on target: Canvas) {
        let s = scale, fg = TerminalPalette.foreground
        let w = Float(width), h = Float(height)
        sol_canvas_fill_gradient(target.raw, 0, 0, w, h, TerminalPalette.background, TerminalPalette.backgroundBottom)
        let laid = pieces(target, width: width, height: height)
        sol_canvas_push_clip(target.raw, sidebarWidth, 0, w - sidebarWidth, h)
        for piece in laid { draw(piece, on: target) }
        drawFooter(on: target)
        if let picker {
            let typing = editing?.id == "picker-hex" ? editing : nil
            picker.draw(on: target, hexText: typing?.state.text, caretX: typing.map { measure(target, $0.state.beforeCaret, pixels: 13 * s) })
        }
        sol_canvas_pop_clip(target.raw)

        // The pages, down the side.
        sol_canvas_fill_rect(target.raw, 0, 0, sidebarWidth, h, TerminalPalette.chrome, 1)
        sol_canvas_fill_rect(target.raw, sidebarWidth - 1, 0, 1, h, fg, 0.10)
        for p in Page.allCases {
            let r = sidebarRow(p)
            let on = p == page, hover = hovered.map { r.contains($0.x, $0.y) } ?? false
            if on { sol_canvas_fill_rounded(target.raw, r.x, r.y, r.width, r.height, 6 * s, TerminalPalette.accent, 0.20) } else if hover { sol_canvas_fill_rounded(target.raw, r.x, r.y, r.width, r.height, 6 * s, fg, 0.06) }
            sol_canvas_draw_icon(target.raw, r.x + 8 * s, r.y, 20 * s, r.height, p.glyph, 13 * s, on ? TerminalPalette.accent : fg, on ? 1 : 0.7)
            label(target, p.title, UIRect(x: r.x + 36 * s, y: r.y, width: r.width - 40 * s, height: r.height), pixels: 13 * s, alpha: on ? 1 : 0.8)
        }
        if let menu { MenuView(canvas: target, menu: menu).draw() }
        if let dialog { DialogView(canvas: target, dialog: dialog, width: w, height: h, scale: s).draw() }
    }

    /// Pinned under the editor: whether anything's unsaved, then Reset and Save Changes, as on the Mac.
    private func drawFooter(on target: Canvas) {
        guard let bar = footer, let buttons = footerButtons(target) else { return }
        let s = scale, c = target.raw, fg = TerminalPalette.foreground, dirty = isDirty
        let fill = TerminalPalette.mix(TerminalPalette.isDark ? 0xFFFFFF : 0x000000, TerminalPalette.background, TerminalPalette.isDark ? 0.05 : 0.03)
        sol_canvas_fill_rect(c, bar.x, bar.y, bar.width, bar.height, fill, 0.97)
        sol_canvas_fill_rect(c, bar.x, bar.y, bar.width, 1, fg, 0.12)
        let left = sidebarWidth + 32 * s
        sol_canvas_fill_ellipse(c, left + 6 * s, bar.midY, 4 * s, 4 * s, dirty ? TerminalPalette.accent : fg, dirty ? 1 : 0.3)
        label(target, dirty ? "Unsaved changes" : "All changes saved", UIRect(x: left + 18 * s, y: bar.y, width: buttons.reset.x - left - 24 * s, height: bar.height),
              pixels: 12.5 * s, semibold: true, alpha: dirty ? 1 : 0.55)
        drawBarButton("Reset", buttons.reset, filled: false, enabled: dirty, on: target)
        drawBarButton("Save Changes", buttons.save, filled: true, enabled: dirty, on: target)
    }

    /// A button in the theme's colors: filled with the accent (the one to press), or outlined.
    private func drawBarButton(_ title: String, _ r: UIRect, filled: Bool, enabled: Bool, on target: Canvas) {
        let s = scale, c = target.raw, fg = TerminalPalette.foreground, hover = enabled && isHovered(r)
        let alpha: Float = enabled ? 1 : 0.35
        let ink: UInt32
        var inkAlpha: Float
        if filled {
            sol_canvas_fill_rounded(c, r.x, r.y, r.width, r.height, 7 * s, TerminalPalette.accent, alpha * (hover ? 0.88 : 1))
            ink = HexColor(rgb: TerminalPalette.accent).luminance > 0.55 ? 0x000000 : 0xFFFFFF
            inkAlpha = enabled ? 1 : 0.6
        } else {
            sol_canvas_fill_rounded(c, r.x, r.y, r.width, r.height, 7 * s, fg, hover ? 0.1 : 0.04)
            sol_canvas_stroke_rounded(c, r.x + 0.5, r.y + 0.5, r.width - 1, r.height - 1, 7 * s, fg, 0.25 * alpha, 1)
            ink = fg
            inkAlpha = enabled ? 0.9 : 0.35
        }
        let tw = measure(target, title, pixels: 13 * s, semibold: true)
        label(target, title, UIRect(x: r.x + (r.width - tw) / 2, y: r.y, width: tw + 2, height: r.height), pixels: 13 * s, semibold: true, color: ink, alpha: inkAlpha)
    }

    private func sidebarRow(_ p: Page) -> UIRect {
        let s = scale
        return UIRect(x: 10 * s, y: 18 * s + Float(p.rawValue) * 34 * s, width: sidebarWidth - 20 * s, height: 30 * s)
    }

    private func isHovered(_ r: UIRect) -> Bool { hovered.map { r.contains($0.x, $0.y) } ?? false }

    private func draw(_ piece: Piece, on target: Canvas) {
        let s = scale, fg = TerminalPalette.foreground
        switch piece {
        case .title(let text, let r):
            label(target, text, r, pixels: 24 * s, semibold: true)
        case .header(let text, let r):
            label(target, text, r, pixels: 11 * s, semibold: true, alpha: 0.45)
        case .card(let r):
            sol_canvas_fill_rounded(target.raw, r.x, r.y, r.width, r.height, 10 * s, fg, 0.05)
            sol_canvas_stroke_rounded(target.raw, r.x + 0.5, r.y + 0.5, r.width - 1, r.height - 1, 10 * s, fg, 0.08, 1)
        case .divider(let r):
            sol_canvas_fill_rect(target.raw, r.x, r.y, r.width, 1, fg, 0.07)
        case .row(let row, let r, let detailHeight):
            var textLeft = r.x + 18 * s
            if let glyph = row.glyph {
                let tile = UIRect(x: r.x + 16 * s, y: (r.midY - 15 * s).rounded(), width: 30 * s, height: 30 * s)
                sol_canvas_fill_rounded(target.raw, tile.x, tile.y, tile.width, tile.height, 7 * s, TerminalPalette.accent, 0.14)
                sol_canvas_draw_icon(target.raw, tile.x, tile.y, tile.width, tile.height, glyph, 13 * s, TerminalPalette.accent, 0.9)
                textLeft = r.x + 60 * s
            }
            let textTop = r.midY - (20 * s + (detailHeight > 0 ? detailHeight + 2 * s : 0)) / 2
            label(target, row.title, UIRect(x: textLeft, y: textTop, width: r.width * 0.6, height: 20 * s), pixels: 13.5 * s)
            if let detail = row.detail {
                let units = Array(detail.utf16)
                let cw = controlWidth(row.control, target)
                let textWidth = max(r.width - (textLeft - r.x) - cw - 36 * s, 80 * s)
                _ = sol_canvas_paragraph(target.raw, textLeft, textTop + 22 * s, textWidth, units, Int32(units.count), 12 * s, 0, fg, 0.55, 0)
            }
        case .control(let control, let r):
            drawControl(control, r, on: target)
        case .theme(let spec, let r):
            drawThemeCard(spec, r, on: target)
        case .newTheme(let r):
            drawNewThemeCard(r, on: target)
        case .link(let title, let r, _):
            // Deleting a theme is in red, as on the Mac.
            let tint = title == Self.deleteTitle ? TerminalPalette.ansi[1] : TerminalPalette.accent
            label(target, title, r, pixels: 13 * s, semibold: true, color: tint, alpha: isHovered(r) ? 1 : 0.85)
        case .preview(let spec, let r):
            drawThemeCard(spec, r, on: target, interactive: false)
        case .palette(let r):
            drawPalette(r, on: target)
        case .note(let text, let r):
            let units = Array(text.utf16)
            _ = sol_canvas_paragraph(target.raw, r.x, r.y, r.width, units, Int32(units.count), 12.5 * s, 0, fg, 0.55, 0)
        case .removeAlias(_, let r):
            if isHovered(r) { sol_canvas_fill_rounded(target.raw, r.x, r.y, r.width, r.height, 5 * s, fg, 0.10) }
            sol_canvas_draw_icon(target.raw, r.x, r.y, r.width, r.height, 0xE711, 10 * s, fg, 0.6)
        }
    }

    private func drawControl(_ control: Control, _ r: UIRect, on target: Canvas) {
        let s = scale, fg = TerminalPalette.foreground
        switch control {
        case .toggle(let get, _):
            let on = get()
            sol_canvas_fill_rounded(target.raw, r.x, r.y, r.width, r.height, r.height / 2, on ? TerminalPalette.accent : fg, on ? 1 : 0.18)
            let knob = r.height - 6 * s
            sol_canvas_fill_ellipse(target.raw, on ? r.maxX - 3 * s - knob / 2 : r.x + 3 * s + knob / 2, r.midY, knob / 2, knob / 2, on ? 0xFFFFFF : fg, on ? 1 : 0.8)
        case .choice(_, let get, _):
            sol_canvas_fill_rounded(target.raw, r.x, r.y, r.width, r.height, 6 * s, fg, isHovered(r) ? 0.12 : 0.08)
            label(target, get(), UIRect(x: r.x + 12 * s, y: r.y, width: r.width - 36 * s, height: r.height), pixels: 13 * s)
            sol_canvas_draw_icon(target.raw, r.maxX - 28 * s, r.y, 20 * s, r.height, 0xE70D, 9 * s, fg, 0.6)
        case .field(let id, let get, let placeholder, _, _):
            drawField(id: id, text: get(), placeholder: placeholder, r, small: id.hasPrefix("ansi-hex-"), on: target)
        case .color(let id, let get, _, _):
            drawColor(id: id, hex: get(), r, enabled: true, on: target)
        case .slider(let lo, let hi, let get, _, let format):
            let track = sliderTrack(r), value = get(), c = target.raw
            let f = Float(min(max((value - lo) / (hi - lo), 0), 1)), knobX = track.x + f * track.width
            sol_canvas_fill_rounded(c, track.x, track.midY - 2 * s, track.width, 4 * s, 2 * s, fg, 0.16)
            sol_canvas_fill_rounded(c, track.x, track.midY - 2 * s, knobX - track.x, 4 * s, 2 * s, TerminalPalette.accent, 1)
            let dragging = sliding != nil && isHovered(r)
            sol_canvas_fill_ellipse(c, knobX, track.midY + 0.5 * s, 8.5 * s, 8.5 * s, 0x000000, 0.25)
            if dragging || isHovered(r) { sol_canvas_fill_ellipse(c, knobX, track.midY, 9.5 * s, 9.5 * s, TerminalPalette.accent, 1) }
            sol_canvas_fill_ellipse(c, knobX, track.midY, 8 * s, 8 * s, 0xFFFFFF, 1)
            let text = format(value), tw = measure(target, text, pixels: 12.5 * s)
            label(target, text, UIRect(x: r.maxX - tw, y: r.y, width: tw + 2, height: r.height), pixels: 12.5 * s, alpha: 0.7)
        case .gradient(let get, _):
            let on = get()
            drawControl(.toggle(get: { on != nil }, set: { _ in }), UIRect(x: r.x, y: (r.midY - 11 * s).rounded(), width: 40 * s, height: 22 * s), on: target)
            let colorRect = UIRect(x: r.maxX - Self.colorWidth * s, y: r.y, width: Self.colorWidth * s, height: r.height)
            drawColor(id: "background2", hex: on ?? gradientMemory, colorRect, enabled: on != nil, on: target)
        case .value(let text):
            label(target, text, r, pixels: 13 * s, alpha: 0.7)
        case .keys(let keys):
            var x = r.x
            for key in keys {
                let kw = measure(target, key, pixels: 12 * s, semibold: true) + 18 * s
                sol_canvas_fill_rounded(target.raw, x, r.y + 3 * s, kw, r.height - 6 * s, 5 * s, fg, 0.09)
                sol_canvas_stroke_rounded(target.raw, x + 0.5, r.y + 3.5 * s, kw - 1, r.height - 7 * s, 5 * s, fg, 0.10, 1)
                label(target, key, UIRect(x: x + 9 * s, y: r.y, width: kw - 16 * s, height: r.height), pixels: 12 * s, semibold: true, alpha: 0.8)
                x += kw + 6 * s
            }
        case .button(let title, _):
            sol_canvas_fill_rounded(target.raw, r.x, r.y, r.width, r.height, 6 * s, fg, isHovered(r) ? 0.14 : 0.09)
            label(target, title, UIRect(x: r.x + 14 * s, y: r.y, width: r.width - 20 * s, height: r.height), pixels: 13 * s)
        case .none:
            break
        }
    }

    /// A text field, typed in when it's the one being edited.
    private func drawField(id: String, text shown: String, placeholder: String, _ r: UIRect, alpha: Float = 1, small: Bool = false, on target: Canvas) {
        let s = scale, fg = TerminalPalette.foreground
        if small { return drawSmallField(id: id, text: shown, r, on: target) }
        let editingThis = editing?.id == id
        sol_canvas_fill_rounded(target.raw, r.x, r.y, r.width, r.height, 5 * s, TerminalPalette.mix(0x000000, TerminalPalette.background, 0.25), alpha)
        sol_canvas_stroke_rounded(target.raw, r.x + 0.5, r.y + 0.5, r.width - 1, r.height - 1, 5 * s, editingThis ? TerminalPalette.accent : fg, editingThis ? 0.9 : 0.12 * alpha, 1)
        if editingThis { sol_canvas_fill_rect(target.raw, r.x + 4 * s, r.maxY - 2 * s, r.width - 8 * s, 2 * s, TerminalPalette.accent, 1) }
        let text = editingThis ? editing!.state.text : shown
        let inner = UIRect(x: r.x + 9 * s, y: r.y, width: r.width - 18 * s, height: r.height)
        if text.isEmpty { label(target, placeholder, inner, pixels: 13 * s, alpha: 0.35 * alpha) } else { label(target, text, inner, pixels: 13 * s, alpha: alpha) }
        if editingThis {
            let caretX = inner.x + measure(target, editing!.state.beforeCaret, pixels: 13 * s)
            sol_canvas_fill_rect(target.raw, caretX.rounded(), r.y + 7 * s, max(s.rounded(), 1), r.height - 14 * s, TerminalPalette.accent, 1)
        }
    }

    private static let sliderWidth: Float = 210

    /// The track a slider's knob runs along, leaving room for its value at the right.
    private func sliderTrack(_ r: UIRect) -> UIRect {
        let s = scale
        return UIRect(x: r.x + 9 * s, y: r.y, width: r.width - 9 * s - 52 * s, height: r.height)
    }

    private func onSlider(x: Float, y: Float) -> Bool {
        guard canvas != nil, menu == nil else { return false }
        for piece in pieces(canvas, width: width, height: height) {
            if case .control(.slider, let r) = piece, r.contains(x, y) { return true }
        }
        return false
    }

    /// The slider's value under the pointer, rounded to hundredths, which is what's saved.
    private func slide(toX x: Float) {
        guard let sliding else { return }
        let f = Double(min(max((x - sliding.track.x) / max(sliding.track.width, 1), 0), 1))
        sliding.set(((sliding.min + f * (sliding.max - sliding.min)) * 100).rounded() / 100)
        invalidate()
    }

    /// A hex under a palette swatch: smaller, in the terminal's font size, centered, as on the Mac.
    private func drawSmallField(id: String, text shown: String, _ r: UIRect, on target: Canvas) {
        let s = scale, fg = TerminalPalette.foreground, editingThis = editing?.id == id, c = target.raw
        sol_canvas_fill_rounded(c, r.x, r.y, r.width, r.height, 4 * s, TerminalPalette.mix(0x000000, TerminalPalette.background, 0.25), 1)
        sol_canvas_stroke_rounded(c, r.x + 0.5, r.y + 0.5, r.width - 1, r.height - 1, 4 * s, editingThis ? TerminalPalette.accent : fg,
                                  editingThis ? 0.9 : (isHovered(r) ? 0.25 : 0.1), 1)
        let text = editingThis ? editing!.state.text : shown, px = 10.5 * s
        let tw = measure(target, text, pixels: px), x = r.x + max((r.width - tw) / 2, 4 * s)
        label(target, text, UIRect(x: x, y: r.y, width: r.maxX - x - 2 * s, height: r.height), pixels: px, alpha: editingThis ? 1 : 0.75)
        if editingThis {
            let caretX = x + measure(target, editing!.state.beforeCaret, pixels: px)
            sol_canvas_fill_rect(c, caretX.rounded(), r.y + 4 * s, max(s.rounded(), 1), r.height - 8 * s, TerminalPalette.accent, 1)
        }
    }

    /// Where a color control's swatch is, at its right.
    private func swatchRect(_ r: UIRect) -> UIRect {
        let s = scale
        return UIRect(x: r.maxX - 46 * s, y: (r.midY - 13 * s).rounded(), width: 46 * s, height: 26 * s)
    }

    /// A color's hex, to type, and its swatch, as on the Mac: a ring in the accent on hover, and while its picker is open.
    private func drawColor(id: String, hex: String, _ r: UIRect, enabled: Bool, on target: Canvas) {
        let s = scale, c = target.raw, fg = TerminalPalette.foreground, dim: Float = enabled ? 1 : 0.4
        drawField(id: id + "-hex", text: hex.uppercased(), placeholder: "#RRGGBB", UIRect(x: r.x, y: r.y, width: 98 * s, height: r.height), alpha: dim, on: target)
        let sw = swatchRect(r), color = HexColor(hex) ?? HexColor(rgb: 0)
        if color.alpha < 1 { drawChecks(sw, radius: 6 * s, on: target) }
        sol_canvas_fill_rounded(c, sw.x, sw.y, sw.width, sw.height, 6 * s, color.rgb, color.alpha * dim)
        let ring = enabled && (isHovered(sw) || picker?.id == id)
        sol_canvas_stroke_rounded(c, sw.x + 0.5, sw.y + 0.5, sw.width - 1, sw.height - 1, 6 * s, ring ? TerminalPalette.accent : fg, ring ? 1 : 0.2 * dim, ring ? 2 * s : 1)
    }

    /// Grey and white squares, behind a see-through color.
    private func drawChecks(_ r: UIRect, radius: Float, on target: Canvas) {
        let c = target.raw, cell = max((5 * scale).rounded(), 2)
        sol_canvas_fill_rounded(c, r.x, r.y, r.width, r.height, radius, 0xFFFFFF, 1)
        sol_canvas_push_clip(c, r.x + 2 * scale, r.y + 2 * scale, r.width - 4 * scale, r.height - 4 * scale)
        var y = r.y, row = 0
        while y < r.maxY {
            var x = r.x + (row % 2 == 0 ? 0 : cell)
            while x < r.maxX { sol_canvas_fill_rect(c, x, y, cell, cell, 0xC8C8C8, 1); x += cell * 2 }
            y += cell
            row += 1
        }
        sol_canvas_pop_clip(c)
    }

    /// Where the terminal color `i` is in the palette, as on the Mac (PaletteEditorView there).
    private func paletteCell(_ i: Int, in r: UIRect) -> UIRect {
        let s = scale, left = 76 * s, right = 16 * s, gap = 8 * s
        let cellWidth = ((r.width - left - right - gap * 7) / 8).rounded(.down)
        return UIRect(x: r.x + left + Float(i % 8) * (cellWidth + gap), y: r.y + 56 * s + Float(i / 8) * 70 * s, width: cellWidth, height: 34 * s)
    }

    private static let colorNames = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]

    /// The 16 colors, normal over bright, each a swatch (click for the picker) with its hex under it (type one in), as on
    /// the Mac: the one being picked is ringed and named at the top, and ones that differ from what's saved carry a dot.
    private func drawPalette(_ r: UIRect, on target: Canvas) {
        guard let draft else { return }
        let s = scale, c = target.raw, fg = TerminalPalette.foreground, colors = ThemeColors(draft).ansi
        let saved = savedTheme.map { ThemeColors($0).ansi } ?? colors
        sol_canvas_fill_rounded(c, r.x, r.y, r.width, r.height, 12 * s, fg, 0.05)
        sol_canvas_stroke_rounded(c, r.x + 0.5, r.y + 0.5, r.width - 1, r.height - 1, 12 * s, fg, 0.08, 1)
        // "Editing Bright Red · #FF9DAC" while the picker is on one; else how many have changed.
        let changed = (0..<16).filter { colors[$0] != saved[$0] }.count
        let status: String, lit: Bool
        if let id = picker?.id, id.hasPrefix("ansi-"), let i = Int(id.dropFirst(5)) {
            status = "Editing \(i < 8 ? "" : "Bright ")\(Self.colorNames[i % 8]) \u{00B7} " + String(format: "#%06X", colors[i])
            lit = true
        } else {
            status = changed > 0 ? "\(changed) changed" : "Click a color to change it"
            lit = changed > 0
        }
        label(target, status, UIRect(x: r.x + 18 * s, y: r.y + 10 * s, width: r.width - 36 * s, height: 18 * s), pixels: 11 * s, semibold: true,
              color: lit ? TerminalPalette.accent : fg, alpha: lit ? 1 : 0.5)
        for (i, name) in Self.colorNames.enumerated() {
            let cell = paletteCell(i, in: r), nw = measure(target, name, pixels: 10.5 * s)
            label(target, name, UIRect(x: cell.x + (cell.width - nw) / 2, y: cell.y - 19 * s, width: nw + 2, height: 14 * s), pixels: 10.5 * s, alpha: 0.55)
        }
        label(target, "Normal", UIRect(x: r.x + 18 * s, y: paletteCell(0, in: r).y, width: 56 * s, height: 34 * s), pixels: 11 * s, semibold: true, alpha: 0.55)
        label(target, "Bright", UIRect(x: r.x + 18 * s, y: paletteCell(8, in: r).y, width: 56 * s, height: 34 * s), pixels: 11 * s, semibold: true, alpha: 0.55)
        for i in 0..<16 {
            let cell = paletteCell(i, in: r), rgb = colors[i]
            sol_canvas_fill_rounded(c, cell.x, cell.y, cell.width, cell.height, 7 * s, rgb, 1)
            let active = picker?.id == "ansi-\(i)"
            if active || isHovered(cell) {
                let t = (active ? 3 : 2) * s
                sol_canvas_stroke_rounded(c, cell.x + t / 2, cell.y + t / 2, cell.width - t, cell.height - t, 7 * s, TerminalPalette.accent, 1, t)
            } else {
                sol_canvas_stroke_rounded(c, cell.x + 0.5, cell.y + 0.5, cell.width - 1, cell.height - 1, 7 * s, fg, 0.15, 1)
            }
            // Unsaved: a dot in the corner.
            if rgb != saved[i] {
                let d = 4 * s, cx = cell.maxX - 4 * s - d, cy = cell.y + 4 * s + d
                sol_canvas_fill_ellipse(c, cx, cy, d + 1.5 * s, d + 1.5 * s, TerminalPalette.background, 1)
                sol_canvas_fill_ellipse(c, cx, cy, d, d, TerminalPalette.accent, 1)
            }
        }
    }

    /// A theme's look in miniature, as on the Mac (ThemeCardView there): a prompt, a git status line and its palette, with
    /// the name underneath; a check on the theme in use, and a pencil on your own, which opens it in the editor. The
    /// editor's own copy (`interactive` false) has neither.
    private func drawThemeCard(_ spec: ThemeSpec, _ r: UIRect, on target: Canvas, interactive: Bool = true) {
        let s = scale, c = target.raw, colors = ThemeColors(spec), fg = TerminalPalette.foreground
        let current = interactive && AppSettings.shared.themeName == spec.name, hover = interactive && isHovered(r)
        let card = UIRect(x: r.x + 1.5 * s, y: r.y + 1.5 * s, width: r.width - 3 * s, height: r.height - 3 * s)
        let radius = 11 * s, strip = (32 * s).rounded()
        let preview = UIRect(x: card.x, y: card.y, width: card.width, height: card.height - strip)
        // The whole card in the name strip's color, rounded all round; then the preview over its top, rounded only there.
        sol_canvas_fill_rounded(c, card.x, card.y, card.width, card.height, radius, TerminalPalette.background, 1)
        sol_canvas_fill_rounded(c, card.x, card.y, card.width, card.height, radius, TerminalPalette.surface, 0.8)
        sol_canvas_fill_rounded(c, preview.x, preview.y, preview.width, preview.height, radius, colors.background, 1)
        if let picture = spec.image, let image = thumbnail(picture, on: target) {
            // Its picture, filling the preview, under its background color as the window shows it.
            var iw: Int32 = 0, ih: Int32 = 0
            sol_canvas_image_size(c, image, &iw, &ih)
            let zoom = max(preview.width / Float(max(iw, 1)), preview.height / Float(max(ih, 1)))
            let w = Float(iw) * zoom, h = Float(ih) * zoom
            sol_canvas_fill_rounded_image(c, image, preview.x, preview.y, preview.width, preview.height, radius,
                                          preview.x + (preview.width - w) / 2, preview.y + (preview.height - h) / 2, w, h)
            sol_canvas_fill_rounded(c, preview.x, preview.y, preview.width, preview.height, radius, colors.background, Float(picture.tint))
        } else {
            sol_canvas_fill_gradient(c, preview.x, preview.y + radius, preview.width, preview.height - radius, colors.background, colors.backgroundBottom)
        }
        // Window dots.
        for (k, color) in [colors.ansi[1], colors.ansi[3], colors.ansi[2]].enumerated() {
            sol_canvas_fill_ellipse(c, preview.x + (12 + 3.5 + Float(k) * 12) * s, preview.y + (10 + 3.5) * s, 3.5 * s, 3.5 * s, color, 1)
        }
        func line(_ y: Float, _ parts: [(String, UInt32)]) {
            var x = preview.x + 12 * s
            for (text, color) in parts {
                let units = Array(text.utf16)
                sol_canvas_draw_label(c, x, preview.y + y * s, preview.width, 15 * s, units, Int32(units.count), 11 * s, 0, color, 1)
                x += measure(target, text, pixels: 11 * s)
            }
        }
        line(22, [("❯ ", colors.accent), ("git status", colors.foreground)])
        line(38, [("on ", TerminalPalette.mix(colors.foreground, colors.background, 0.55)), ("main", colors.ansi[5]), (" ✓ clean", colors.ansi[2])])
        line(54, [("● ", colors.ansi[3]), ("3 files ", colors.foreground), ("changed", colors.ansi[4])])
        for (k, color) in [1, 2, 3, 4, 5, 6].map({ colors.ansi[$0] }).enumerated() {
            sol_canvas_fill_rounded(c, preview.x + (12 + Float(k) * 19) * s, preview.y + 76 * s, 15 * s, 6 * s, 2 * s, color, 1)
        }
        label(target, spec.name, UIRect(x: card.x + 12 * s, y: preview.maxY, width: card.width - 64 * s, height: strip), pixels: 12.5 * s, semibold: true)
        if interactive, let pencil = pencilRect(spec, r) {
            sol_canvas_draw_icon(c, pencil.x, pencil.y, pencil.width, pencil.height, 0xE70F, 11 * s, fg, hover ? 1 : 0.55)
        }
        if current {
            // A check in the accent, at the strip's right.
            let d = 16 * s, cx = card.maxX - 26 * s + d / 2, cy = preview.maxY + 8 * s + d / 2
            sol_canvas_fill_ellipse(c, cx, cy, d / 2, d / 2, TerminalPalette.accent, 1)
            let tick: [Float] = [cx - d / 2 + 4.2 * s, cy - 0.3 * s, cx - d / 2 + 7 * s, cy + 3 * s, cx + d / 2 - 4 * s, cy - 3 * s]
            tick.withUnsafeBufferPointer { sol_canvas_stroke_polyline(c, $0.baseAddress, 3, 0, 0xFFFFFF, 1, 1.8 * s) }
            sol_canvas_stroke_rounded(c, card.x, card.y, card.width, card.height, radius, TerminalPalette.accent, 1, 2.5 * s)
        } else {
            sol_canvas_stroke_rounded(c, card.x + 0.5, card.y + 0.5, card.width - 1, card.height - 1, radius, fg, hover ? 0.3 : 0.12, max(s, 1))
        }
    }

    /// Where a custom theme's pencil is on its card, which opens its file; nil for one that's built in.
    private func pencilRect(_ spec: ThemeSpec, _ r: UIRect) -> UIRect? {
        guard AppSettings.shared.customThemeFiles[spec.name] != nil else { return nil }
        let s = scale, current = AppSettings.shared.themeName == spec.name
        let card = UIRect(x: r.x + 1.5 * s, y: r.y + 1.5 * s, width: r.width - 3 * s, height: r.height - 3 * s)
        return UIRect(x: card.maxX - (current ? 50 : 28) * s, y: card.maxY - (32 - 6) * s, width: 20 * s, height: 20 * s)
    }

    /// The last card in the grid, as on the Mac: starts a new theme from the current one.
    private func drawNewThemeCard(_ r: UIRect, on target: Canvas) {
        let s = scale, c = target.raw, hover = isHovered(r), fg = TerminalPalette.foreground, accent = TerminalPalette.accent
        let card = UIRect(x: r.x + 1.5 * s, y: r.y + 1.5 * s, width: r.width - 3 * s, height: r.height - 3 * s)
        let radius = 11 * s, midX = card.x + card.width / 2, midY = card.midY
        if hover { sol_canvas_fill_rounded(c, card.x, card.y, card.width, card.height, radius, accent, 0.10) } else { sol_canvas_fill_rounded(c, card.x, card.y, card.width, card.height, radius, TerminalPalette.surface, 0.25) }
        sol_canvas_stroke_rounded_dashed(c, card.x, card.y, card.width, card.height, radius, hover ? accent : fg, hover ? 1 : 0.25, 1.5 * s, 5 * s, 4 * s)
        // The plus.
        let plusColor = hover ? accent : fg, plusAlpha: Float = hover ? 1 : 0.55, arm = 8 * s, py = midY - 13 * s
        sol_canvas_line(c, midX - arm, py, midX + arm, py, plusColor, plusAlpha, 2 * s)
        sol_canvas_line(c, midX, py - arm, midX, py + arm, plusColor, plusAlpha, 2 * s)
        let title = "New Theme", tw = measure(target, title, pixels: 12.5 * s, semibold: true)
        label(target, title, UIRect(x: midX - tw / 2, y: midY + 6 * s, width: tw + 2, height: 18 * s), pixels: 12.5 * s, semibold: true, alpha: hover ? 1 : 0.55)
        let sub = "Starts from the current one", sw = measure(target, sub, pixels: 11 * s)
        label(target, sub, UIRect(x: midX - sw / 2, y: midY + 24 * s, width: sw + 2, height: 16 * s), pixels: 11 * s, alpha: 0.55)
    }

    /// The last click on a theme card, for telling a double click on your own (which opens its file, as on the Mac).
    private var lastCardClick: (name: String, at: Date)?

    // MARK: Mouse and keys

    private func mouse(_ message: UINT, x: Float, y: Float) {
        // A question asked takes every click until it's answered.
        if dialog != nil { return dialogMouse(message, x: x, y: y) }
        // The save bar: Reset and Save Changes, and nothing under it.
        if let bar = footer, bar.contains(x, y), sliding == nil, picker?.dragging == nil, menu == nil {
            if message == Win.WM_MOUSEMOVE { hovered = (x, y); invalidate() }
            if message == Win.WM_LBUTTONDOWN {
                if picker != nil { commitEditing(); picker = nil }
                if let buttons = footerButtons(canvas), isDirty {
                    if buttons.save.contains(x, y) { saveTheme() } else if buttons.reset.contains(x, y) { resetTheme() }
                }
                invalidate()
            }
            return
        }
        if let menu {
            if message == Win.WM_MOUSEMOVE { menu.highlight(menu.item(atX: x, y: y)); invalidate() }
            if message == Win.WM_LBUTTONDOWN && !menu.frame.contains(x, y) { self.menu = nil; invalidate() }
            if message == Win.WM_LBUTTONUP, let i = menu.item(atX: x, y: y), menu.items[i].isEnabled {
                let run = menu.items[i].run
                self.menu = nil
                run()
                invalidate()
            }
            return
        }
        if sliding != nil {
            if message == Win.WM_MOUSEMOVE { hovered = (x, y); slide(toX: x); return }
            if message == Win.WM_LBUTTONUP { sliding = nil; ReleaseCapture(); invalidate(); return }
        }
        if let picker {
            switch message {
            case Win.WM_LBUTTONDOWN:
                if let part = picker.part(atX: x, y: y) {
                    if case .hexField = part {
                        guard editing?.id != "picker-hex" else { return }
                        commitEditing()
                        editing = ("picker-hex", TextFieldState(picker.color.hex), { [weak picker] text in
                            if picker?.typed(text) == false { _ = MessageBeep(UINT(bitPattern: -1)) }
                        })
                    } else {
                        commitEditing()
                        picker.dragging = part
                        picker.drag(part, toX: x, y: y)
                        if let hwnd { SetCapture(hwnd) }
                    }
                    invalidate()
                    return
                }
                if picker.frame.contains(x, y) { return }
                // Anywhere else closes it, and the click goes on to what's there: another swatch opens its own.
                commitEditing()
                justClosedPicker = picker.id
                self.picker = nil
                invalidate()
            case Win.WM_MOUSEMOVE:
                if let part = picker.dragging {
                    picker.drag(part, toX: x, y: y)
                    invalidate()
                    return
                }
            case Win.WM_LBUTTONUP:
                if picker.dragging != nil {
                    picker.dragging = nil
                    ReleaseCapture()
                    return
                }
            default:
                break
            }
        }
        switch message {
        case Win.WM_MOUSEMOVE:
            hovered = (x, y)
            invalidate()
        case Win.WM_LBUTTONDOWN:
            click(x: x, y: y)
            justClosedPicker = nil
        default:
            break
        }
    }

    private func click(x: Float, y: Float) {
        if x < sidebarWidth {
            if let p = Page.allCases.first(where: { sidebarRow($0).contains(x, y) }) {
                commitEditing()
                // Appearance again goes back to all the themes, as on the Mac; unsaved changes are asked about first.
                confirmLeavingTheme { [weak self] in
                    guard let self else { return }
                    if self.editingTheme != nil { self.leaveEditor() }
                    self.page = p
                    self.scroll = 0
                    self.invalidate()
                }
            }
            return
        }
        for piece in pieces(canvas, width: width, height: height) {
            switch piece {
            case .control(let control, let r) where r.contains(x, y):
                press(control, r, x: x)
                return
            case .palette(let r) where r.contains(x, y):
                guard let i = (0..<16).first(where: { paletteCell($0, in: r).contains(x, y) }), let draft else { break }
                let hex = String(format: "#%06X", ThemeColors(draft).ansi[i])
                openPicker(id: "ansi-\(i)", hex: hex, alpha: false, anchor: paletteCell(i, in: r)) { [weak self] picked in
                    guard let self, let d = self.draft else { return }
                    var ansi = ThemeColors(d).ansi.map { String(format: "#%06X", $0) }
                    ansi[i] = picked
                    self.draftChanged(d.with(ansi: ansi))
                }
                return
            case .theme(let spec, let r) where r.contains(x, y):
                commitEditing()
                let file = AppSettings.shared.customThemeFiles[spec.name]
                let double = lastCardClick.map { $0.name == spec.name && Date().timeIntervalSince($0.at) < Double(GetDoubleClickTime()) / 1000 } ?? false
                lastCardClick = (spec.name, Date())
                if let file, pencilRect(spec, r)?.contains(x, y) == true || double {
                    editTheme(file)
                } else {
                    AppSettings.shared.set("theme", spec.name)
                }
                return
            case .newTheme(let r) where r.contains(x, y):
                newTheme()
                return
            case .link(_, let r, let action) where r.contains(x, y):
                commitEditing()
                pressedLink = r
                action()
                invalidate()
                return
            case .removeAlias(let i, let r) where r.contains(x, y):
                editing = nil
                aliases.remove(at: i)
                AliasFile.save(aliases)
                invalidate()
                return
            default:
                break
            }
        }
        commitEditing()
    }

    private func press(_ control: Control, _ r: UIRect, x: Float) {
        switch control {
        case .slider(let lo, let hi, _, let set, _):
            commitEditing()
            sliding = (sliderTrack(r), lo, hi, set)
            slide(toX: x)
            if let hwnd { SetCapture(hwnd) }
        case .color(let id, let get, let alpha, let set):
            pressColor(id: id, hex: get(), alpha: alpha, r, x: x, set: set)
        case .gradient(let get, let set):
            let colorRect = UIRect(x: r.maxX - Self.colorWidth * scale, y: r.y, width: Self.colorWidth * scale, height: r.height)
            if x < colorRect.x {
                commitEditing()
                picker = nil
                set(get() == nil ? gradientMemory : nil)
            } else if let on = get() {
                pressColor(id: "background2", hex: on, alpha: false, colorRect, x: x) { set($0) }
            }
        case .toggle(let get, let set):
            commitEditing()
            set(!get())
        case .choice(let options, let get, let set):
            commitEditing()
            let current = get()
            let items = options.map { option in MenuItem(title: option, isChecked: option == current) { set(option) } }
            menu = MenuModel(items: items, anchorX: r.x, anchorY: r.maxY + 2 * scale, above: false, width: max(r.width, MenuView.width(for: items, canvas: canvas, scale: scale)),
                             window: UIRect(x: 0, y: 0, width: Float(width), height: Float(height)), scale: scale)
        case .field(let id, let get, _, _, let commit):
            if editing?.id == id { return }
            commitEditing()
            editing = (id, TextFieldState(get()), commit)
        case .button(_, let action):
            commitEditing()
            action()
        default:
            break
        }
        invalidate()
    }

    // MARK: Custom themes

    /// A theme's menu: edit, copy or remove a custom one; copy a built-in one to make it your own.
    private func rightClick(x: Float, y: Float) {
        for piece in pieces(canvas, width: width, height: height) {
            guard case .theme(let spec, let r) = piece, r.contains(x, y) else { continue }
            commitEditing()
            let custom = AppSettings.shared.customThemeFiles[spec.name]
            var items: [MenuItem] = []
            if let custom {
                items.append(MenuItem(title: "Edit Theme") { [weak self] in self?.editTheme(custom) })
                items.append(MenuItem(title: "Edit Theme File") { Self.edit(custom) })
                items.append(MenuItem(title: "Duplicate") { [weak self] in self?.duplicate(spec, edit: false) })
                items.append(MenuItem(title: "Show in Folder") {
                    _ = wide("explorer.exe").withUnsafeBufferPointer { exe in
                        wide("/select,\"\(custom.path)\"").withUnsafeBufferPointer { ShellExecuteW(nil, nil, exe.baseAddress, $0.baseAddress, nil, 1) }
                    }
                })
                items.append(.separator)
                items.append(MenuItem(title: "Delete Theme") { ThemeFiles.delete(spec.name) })
            } else {
                items.append(MenuItem(title: "Duplicate and Customize…") { [weak self] in self?.duplicate(spec, edit: true) })
            }
            menu = MenuModel(items: items, anchorX: x, anchorY: y, above: false, width: MenuView.width(for: items, canvas: canvas, scale: scale),
                             window: UIRect(x: 0, y: 0, width: Float(width), height: Float(height)), scale: scale)
            invalidate()
            return
        }
    }

    /// A copy of the theme in use, made the theme, and opened in the editor, as on the Mac.
    private func newTheme() {
        commitEditing()
        duplicate(AppSettings.shared.theme, edit: true)
    }

    private func duplicate(_ spec: ThemeSpec, edit: Bool) {
        guard let made = ThemeFiles.duplicate(spec) else { return }
        AppSettings.shared.set("theme", made.name)
        if edit { editTheme(made.file) }
        invalidate()
    }

    // MARK: The theme editor

    /// Opens a custom theme in the editor, and makes it the theme so every change shows in every window as it's made.
    /// Changes are a draft, as on the Mac: the file only changes on Save Changes.
    func editTheme(_ file: URL) {
        commitEditing()
        if isDirty, let current = editingTheme, !Self.same(current, file) {
            return confirmLeavingTheme { [weak self] in self?.editTheme(file) }
        }
        picker = nil
        let settings = AppSettings.shared
        guard let name = settings.customThemeFiles.first(where: { Self.same($0.value, file) })?.key,
              let spec = settings.customThemes.first(where: { $0.name == name }) else { Self.edit(file); return }
        // All 16 colors spelled out, so changing one keeps the rest as they were shown.
        let saved = Self.spelledOut(spec)
        savedTheme = saved
        // Unsaved changes to it from before (the page left and come back to) are picked up.
        if let d = settings.themeDraft, d.savedName == name { draft = d.spec } else { draft = saved }
        gradientMemory = spec.background2 ?? "#000000"
        editingTheme = file
        page = .appearance
        scroll = 0
        if settings.themeName != name { settings.set("theme", name) }
        invalidate()
    }

    private static func same(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.path.lowercased() == b.standardizedFileURL.path.lowercased()
    }

    private static func spelledOut(_ spec: ThemeSpec) -> ThemeSpec {
        spec.with(ansi: ThemeColors(spec).ansi.map { String(format: "#%06X", $0) })
    }

    /// Whether the editor's theme differs from its file.
    var isDirty: Bool {
        guard let draft, let savedTheme else { return false }
        return ThemeFiles.json(draft) != ThemeFiles.json(savedTheme)
    }

    /// Back to all the themes, asking first if there's anything unsaved.
    func closeEditor() {
        commitEditing()
        confirmLeavingTheme { [weak self] in
            guard let self else { return }
            self.leaveEditor()
            self.scroll = 0
            self.invalidate()
        }
    }

    /// Out of the editor, with any draft dropped (it's been saved, or not wanted).
    private func leaveEditor() {
        if let hwnd { KillTimer(hwnd, Self.draftTimer) }
        if AppSettings.shared.themeDraft != nil { AppSettings.shared.setThemeDraft(nil) }
        picker = nil
        draft = nil
        savedTheme = nil
        editingTheme = nil
    }

    /// Before leaving the editor with unsaved changes, as on the Mac: Save, Don't Save (back to what's saved), or Cancel.
    func confirmLeavingTheme(_ then: @escaping () -> Void) {
        guard isDirty, let savedTheme else { return then() }
        commitEditing()
        picker = nil
        ask(DialogModel(title: "Save changes to \u{201C}\(savedTheme.name)\u{201D}?",
                        message: "Your changes to this theme will be lost if you don't save them.",
                        primary: "Save", other: ("Don't Save", { [weak self] in self?.resetTheme(); then() }),
                        run: { [weak self] in self?.saveTheme(); then() }))
    }

    /// A change: shown here at once, and in every window a moment later, so dragging in the picker repaints them a few
    /// times a second rather than at every move.
    private func draftChanged(_ spec: ThemeSpec) {
        draft = spec
        invalidate()
        if let hwnd { _ = SetTimer(hwnd, Self.draftTimer, 60, nil) } else { publishDraft() }
    }

    /// Every window shows the draft (or, once there's nothing unsaved, the theme as saved).
    private func publishDraft() {
        guard let draft, let savedTheme else { return }
        AppSettings.shared.setThemeDraft(isDirty ? (savedTheme.name, draft) : nil)
    }

    /// Save Changes: the draft written to the theme's file, a new name made unique, the config following a rename.
    func saveTheme() {
        commitEditing()
        guard let d = draft, let saved = savedTheme, let file = editingTheme else { return }
        if let hwnd { KillTimer(hwnd, Self.draftTimer) }
        let theme = d.with(name: ThemeFiles.uniqueName(d.name, except: saved.name))
        let wasCurrent = AppSettings.shared.themeName == saved.name
        AppSettings.shared.setThemeDraft(nil, broadcast: false)
        ThemeFiles.save(theme, to: file)
        if wasCurrent && theme.name != saved.name { AppSettings.shared.set("theme", theme.name) }
        savedTheme = theme
        draft = theme
        invalidate()
    }

    /// Reset: back to what's saved.
    func resetTheme() {
        commitEditing()
        if let hwnd { KillTimer(hwnd, Self.draftTimer) }
        picker = nil
        draft = savedTheme
        gradientMemory = savedTheme?.background2 ?? "#000000"
        AppSettings.shared.setThemeDraft(nil)
        invalidate()
    }

    /// A copy as it's shown, unsaved changes and all, as on the Mac; this theme stays as saved.
    private func duplicateEditedTheme() {
        guard let d = draft else { return }
        commitEditing()
        let copy = d.with(name: savedTheme?.name ?? d.name)
        leaveEditor()
        guard let made = ThemeFiles.duplicate(copy) else { return }
        AppSettings.shared.set("theme", made.name)
        editTheme(made.file)
    }

    /// After asking, as on the Mac: its file goes to the Recycle Bin, and the theme in use back to Solanum's own.
    private func deleteEditedTheme() {
        guard let saved = savedTheme else { return }
        commitEditing()
        picker = nil
        ask(DialogModel(title: "Delete \u{201C}\(saved.name)\u{201D}?", message: "Its file moves to the Recycle Bin.", primary: "Delete") { [weak self] in
            guard let self else { return }
            self.leaveEditor()
            ThemeFiles.delete(saved.name)
            self.scroll = 0
            self.invalidate()
        })
    }

    // MARK: Questions

    private func ask(_ question: DialogModel) {
        menu = nil
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
        guard var current = dialog, canvas != nil else { return }
        let hit = DialogLayout(current, width: Float(width), height: Float(height), scale: scale, canvas: canvas).button(atX: x, y: y)
        switch message {
        case Win.WM_MOUSEMOVE: current.hovered = hit
        case Win.WM_LBUTTONDOWN: current.pressed = hit
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

    /// A click on a color control: in its hex, to type one; on its swatch, the picker (or, if it's open, closed).
    private func pressColor(id: String, hex: String, alpha: Bool, _ r: UIRect, x: Float, set: @escaping (String) -> Void) {
        let swatch = swatchRect(r)
        if x >= swatch.x - 4 * scale {
            openPicker(id: id, hex: hex, alpha: alpha, anchor: swatch, set: set)
            return
        }
        let fieldID = id + "-hex"
        if editing?.id == fieldID { return }
        commitEditing()
        picker = nil
        editing = (fieldID, TextFieldState(hex.uppercased()), { text in
            if let parsed = ColorPicker.parse(text, allowsAlpha: alpha) { set(parsed) } else if text.uppercased() != hex.uppercased() { _ = MessageBeep(UINT(bitPattern: -1)) }
        })
    }

    private func openPicker(id: String, hex: String, alpha: Bool, anchor: UIRect, set: @escaping (String) -> Void) {
        commitEditing()
        if picker?.id == id || justClosedPicker == id {
            picker = nil
            invalidate()
            return
        }
        let suggestions = draft.map { ThemeColors($0).ansi } ?? []
        let p = ColorPicker(id: id, hex: hex, allowsAlpha: alpha, suggestions: suggestions, onChange: set)
        p.place(under: anchor, in: UIRect(x: sidebarWidth, y: 0, width: Float(width) - sidebarWidth, height: Float(height)), scale: scale)
        picker = p
        invalidate()
    }

    /// A theme's file, in a tab of its own in Solanum's window: saved, it shows within a few seconds.
    private static func edit(_ file: URL) { TerminalWindow.openFileTabInFront(file.path) }

    private func importTheme() {
        commitEditing()
        guard let path = ThemeFiles.pickFile(owner: hwnd) else { return }
        if let name = ThemeFiles.importFile(path) {
            AppSettings.shared.set("theme", name)
        } else {
            _ = MessageBeep(UINT(bitPattern: -1))
        }
        invalidate()
    }

    private static func openThemesFolder() {
        guard let dir = ThemeFiles.folder else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = wide(dir.path).withUnsafeBufferPointer { ShellExecuteW(nil, nil, $0.baseAddress, nil, nil, 1) }
    }

    private func commitEditing() {
        guard let field = editing else { return }
        editing = nil
        field.commit(field.state.text)
        invalidate()
    }

    private func key(_ key: Int32) {
        if dialog != nil {
            switch key {
            case Win.VK_RETURN, Win.VK_SPACE: answer(0)
            case Win.VK_ESCAPE: answer(Int.max)
            default: break
            }
            return
        }
        if let menu {
            switch key {
            case Win.VK_ESCAPE: self.menu = nil
            case Win.VK_UP: menu.moveHighlight(by: -1)
            case Win.VK_DOWN: menu.moveHighlight(by: 1)
            case Win.VK_RETURN:
                if let i = menu.highlighted { let run = menu.items[i].run; self.menu = nil; run() }
            default: break
            }
            invalidate()
            return
        }
        guard var field = editing else {
            // Escape closes the picker, then leaves the editor, then closes Settings.
            if key == Win.VK_ESCAPE {
                if picker != nil { picker = nil; invalidate() } else if editingTheme != nil { closeEditor() } else { close() }
            }
            return
        }
        let ctrl = GetKeyState(Win.VK_CONTROL) < 0
        switch key {
        case Win.VK_RETURN, Win.VK_TAB: commitEditing(); return
        case Win.VK_ESCAPE: editing = nil; invalidate(); return
        case Win.VK_BACK: field.state.deleteBackward(word: ctrl)
        case Win.VK_DELETE: field.state.deleteForward()
        case Win.VK_LEFT: field.state.move(by: -1)
        case Win.VK_RIGHT: field.state.move(by: 1)
        case Win.VK_HOME: field.state.move(to: 0)
        case Win.VK_END: field.state.move(to: field.state.text.count)
        default: return
        }
        editing = field
        invalidate()
    }

    // MARK: For tests

    func showPage(_ p: Page) {
        commitEditing()
        if editingTheme != nil { leaveEditor() }
        page = p
        scroll = 0
        invalidate()
    }

    /// The control of the row with this title, on the page showing, for clicking it.
    func controlRect(forRow title: String) -> UIRect? {
        let laid = pieces(canvas, width: width, height: height)
        for (i, piece) in laid.enumerated() {
            guard case .row(let row, _, _) = piece, row.title == title, i + 1 < laid.count, case .control(_, let r) = laid[i + 1] else { continue }
            return r
        }
        return nil
    }

    func themeRect(_ name: String) -> UIRect? {
        for piece in pieces(canvas, width: width, height: height) {
            if case .theme(let spec, let r) = piece, spec.name == name { return r }
        }
        return nil
    }

    func linkRect(_ title: String) -> UIRect? {
        for piece in pieces(canvas, width: width, height: height) {
            if case .link(let t, let r, _) = piece, t == title { return r }
        }
        return nil
    }

    var aliasCount: Int { aliases.count }

    func click(_ r: UIRect) {
        guard let hwnd else { return }
        let position = LPARAM(Int(r.x + r.width / 2) & 0xFFFF) | (LPARAM(Int(r.y + r.height / 2) & 0xFFFF) << 16)
        PostMessageW(hwnd, Win.WM_LBUTTONDOWN, 1, position)
        PostMessageW(hwnd, Win.WM_LBUTTONUP, 0, position)
    }

    func type(_ text: String) {
        guard let hwnd else { return }
        for unit in text.utf16 { PostMessageW(hwnd, Win.WM_CHAR, WPARAM(unit), 0) }
    }

    func pressKey(_ key: Int32) { if let hwnd { PostMessageW(hwnd, Win.WM_KEYDOWN, WPARAM(key), 0) } }

    func menuRow(_ title: String) -> UIRect? {
        guard let menu, let i = menu.items.firstIndex(where: { $0.title == title }) else { return nil }
        return menu.rect(i)
    }

    /// A page drawn into a PNG at a size, with no window: for checking it by eye (--draw-settings).
    func drawPage(_ p: Page, width w: Int, height h: Int, to path: String) -> Bool {
        page = p
        width = w
        height = h
        aliases = AliasFile.load()
        return saveSnapshot(to: path)
    }

    /// The editor on a copy of Solanum Default, with the picker open for one color (--draw-settings theme-editor).
    func drawEditorForTesting(picking id: String, picture: String? = nil, to path: String) -> Bool {
        let w = 900, h = 1700
        page = .appearance
        width = w
        height = h
        let saved = Self.spelledOut(ThemeSpecs.solanumDefault.with(name: "My Solanum Default"))
        savedTheme = saved
        editingTheme = URL(fileURLWithPath: "C:\\nowhere\\my-solanum-default.json")
        var ansi = saved.ansi
        ansi[1] = "#FF3355"
        ansi[12] = "#4488FF"
        draft = saved.with(accent: "#E8A584", ansi: ansi, image: .some(picture.map { ThemeImage(file: $0) }))
        guard let bitmap = Canvas(width: w, height: h, fontPixels: 13 * scale) else { return false }
        if id.hasPrefix("ansi-"), let i = Int(id.dropFirst(5)) {
            if let r = pieces(bitmap, width: w, height: h).lazy.compactMap({ piece -> UIRect? in if case .palette(let r) = piece { return r }; return nil }).first {
                openPicker(id: id, hex: String(format: "#%06X", ThemeColors(draft!).ansi[i]), alpha: false, anchor: paletteCell(i, in: r)) { _ in }
            }
        } else if id != "none", let r = controlRect(forRow: "Selection", on: bitmap) {
            openPicker(id: id, hex: draft!.selection ?? "#A584E84D", alpha: true, anchor: swatchRect(r)) { _ in }
        }
        return saveSnapshot(to: path)
    }

    private func controlRect(forRow title: String, on target: Canvas) -> UIRect? {
        let laid = pieces(target, width: width, height: height)
        for (i, piece) in laid.enumerated() {
            guard case .row(let row, _, _) = piece, row.title == title, i + 1 < laid.count, case .control(_, let r) = laid[i + 1] else { continue }
            return r
        }
        return nil
    }

    func saveSnapshot(to path: String) -> Bool {
        guard width > 0, let bitmap = Canvas(width: width, height: height, fontPixels: 13 * scale),
              sol_canvas_begin(bitmap.raw, TerminalPalette.background) >= 0 else { return false }
        draw(on: bitmap)
        guard sol_canvas_end(bitmap.raw) >= 0 else { return false }
        return bitmap.savePNG(to: path)
    }
}
