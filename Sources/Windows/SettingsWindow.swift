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
        case themes
        case links([(String, () -> Void)])
        case note(String)
        case aliases
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
        case link(String, UIRect, () -> Void)
        case note(String, UIRect)
        case removeAlias(Int, UIRect)
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

    private var dpi: Float { hwnd.map { Float(GetDpiForWindow($0)) } ?? 96 }
    var scale: Float { dpi / 96 }

    // MARK: Showing it

    func show(_ page: Page? = nil, activate: Bool = true) {
        if let page { self.page = page; scroll = 0 }
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
            mouse(message, x: x, y: y)
            return 0
        case Win.WM_MOUSEWHEEL:
            let notches = Float(Int16(truncatingIfNeeded: (wParam >> 16) & 0xFFFF)) / Float(Win.WHEEL_DELTA)
            if let menu { menu.scrollBy(-notches * menu.rowHeight * 2) } else { scroll -= notches * 60 * scale; clampScroll() }
            invalidate()
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
                       Row(glyph: 0xEA8F, title: "Notify after (seconds)", detail: "When a command in a background tab runs at least this long. " + later,
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
                .header("Keep Awake"),
                .card([Row(glyph: 0xEC32, title: "Keep awake for (seconds)", detail: "How long Keep Awake lasts. The default, 28800, is 8 hours. " + later,
                           control: number("keep-awake-seconds", { s.file["keep-awake-seconds"] ?? "28800" }, placeholder: "28800", width: 90))]),
                .header("Sessions"),
                .card([Row(glyph: 0xE8F1, title: "Reopen windows and tabs", detail: later, control: toggle("restore-session") { s.file.bool("restore-session", true) }),
                       Row(glyph: 0xE81C, title: "Include recent output", detail: later, control: toggle("restore-scrollback") { s.file.bool("restore-scrollback", true) }),
                       Row(glyph: 0xE72C, title: "Continue coding agents", detail: later, control: toggle("continue-agents") { s.file.bool("continue-agents", true) }),
                       Row(glyph: 0xE711, title: "Ask before closing with something running", detail: later, control: toggle("confirm-quit") { s.file.bool("confirm-quit", true) })]),
            ]
        case .appearance:
            return [
                .header("Theme"),
                .themes,
                .header("Window"),
                .card([Row(glyph: 0xE7F4, title: "Padding", detail: "Space between the text and the window's edges, in points.",
                           control: number("padding", { s.file["padding"] ?? "6" }, placeholder: "6")),
                       Row(glyph: 0xE790, title: "Theme icon", detail: "The flower beside the theme's name in the status bar.",
                           control: toggle("theme-icon") { s.themeIcon }),
                       Row(glyph: 0xE7B3, title: "Keep text readable on light themes", detail: later,
                           control: toggle("minimum-contrast") { s.file.bool("minimum-contrast", true) })]),
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
                .card([Row(glyph: 0xE8C8, title: "Copy on select", detail: "Selecting text copies it right away.", control: toggle("copy-on-select") { s.copyOnSelect })]),
            ]
        case .shortcuts:
            return TerminalWindow.shortcutGroups.flatMap { group -> [Block] in
                [.header(group.title), .card(group.items.map { Row(title: $0.title, control: .keys($0.keys.split(separator: "+").map(String.init))) })]
            } + [.note("Ctrl stands in for the Mac's Command key, Alt for Option. A key Solanum takes is its own in every program.")]
        case .aliases:
            return [.note("Short names for longer commands, in PowerShell tabs. Changes reach open tabs at their next prompt."), .aliases]
        }
    }

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
        case .none: return 0
        }
    }

    /// Lays out the page, from the top of its scrolled content, for drawing and for clicks alike.
    private func pieces(_ target: Canvas, width w: Int, height h: Int) -> [Piece] {
        let s = scale
        let left = sidebarWidth + 32 * s, contentWidth = min(Float(w) - left - 32 * s, 760 * s)
        var y = 28 * s - scroll
        var out: [Piece] = [.title(page.title, UIRect(x: left, y: y, width: contentWidth, height: 34 * s))]
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
            case .themes:
                let gap = 20 * s, cardWidth = ((contentWidth - gap) / 2).rounded(), cardHeight = (150 * s).rounded()
                for (i, spec) in AppSettings.shared.allThemes.enumerated() {
                    let col = i % 2, row = i / 2
                    out.append(.theme(spec, UIRect(x: left + Float(col) * (cardWidth + gap), y: y + Float(row) * (cardHeight + gap), width: cardWidth, height: cardHeight)))
                }
                let rows = (AppSettings.shared.allThemes.count + 1) / 2
                y += Float(rows) * (cardHeight + gap) + 8 * s
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
            }
        }
        contentHeight = y + scroll
        return out
    }

    private var contentHeight: Float = 0

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
        case .link(let title, let r, _):
            label(target, title, r, pixels: 13 * s, semibold: true, color: TerminalPalette.accent, alpha: isHovered(r) ? 1 : 0.85)
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
            let editingThis = editing?.id == id
            sol_canvas_fill_rounded(target.raw, r.x, r.y, r.width, r.height, 5 * s, TerminalPalette.mix(0x000000, TerminalPalette.background, 0.25), 1)
            sol_canvas_stroke_rounded(target.raw, r.x + 0.5, r.y + 0.5, r.width - 1, r.height - 1, 5 * s, editingThis ? TerminalPalette.accent : fg, editingThis ? 0.9 : 0.12, 1)
            if editingThis { sol_canvas_fill_rect(target.raw, r.x + 4 * s, r.maxY - 2 * s, r.width - 8 * s, 2 * s, TerminalPalette.accent, 1) }
            let text = editingThis ? editing!.state.text : get()
            let inner = UIRect(x: r.x + 9 * s, y: r.y, width: r.width - 18 * s, height: r.height)
            if text.isEmpty { label(target, placeholder, inner, pixels: 13 * s, alpha: 0.35) } else { label(target, text, inner, pixels: 13 * s) }
            if editingThis {
                let caretX = inner.x + measure(target, editing!.state.beforeCaret, pixels: 13 * s)
                sol_canvas_fill_rect(target.raw, caretX.rounded(), r.y + 7 * s, max(s.rounded(), 1), r.height - 14 * s, TerminalPalette.accent, 1)
            }
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

    /// A preview of a theme, as on the Mac: a few lines of a terminal in its colors, and its name.
    private func drawThemeCard(_ spec: ThemeSpec, _ r: UIRect, on target: Canvas) {
        let s = scale, colors = ThemeColors(spec), current = AppSettings.shared.themeName == spec.name
        let radius = 10 * s, strip = (40 * s).rounded()
        sol_canvas_push_clip(target.raw, r.x, r.y, r.width, r.height)
        sol_canvas_fill_rounded(target.raw, r.x, r.y, r.width, r.height, radius, colors.background, 1)
        sol_canvas_fill_gradient(target.raw, r.x, r.y + radius, r.width, r.height - strip - radius, colors.background, colors.backgroundBottom)
        sol_canvas_fill_rect(target.raw, r.x, r.maxY - strip, r.width, strip, TerminalPalette.foreground, 0.08)
        sol_canvas_fill_rounded(target.raw, r.x, r.maxY - strip, r.width, strip, radius, TerminalPalette.surface, 1)
        sol_canvas_fill_rect(target.raw, r.x, r.maxY - strip, r.width, radius, TerminalPalette.surface, 1)
        sol_canvas_pop_clip(target.raw)
        let x = r.x + 18 * s
        for (k, color) in [colors.ansi[1], colors.ansi[3], colors.ansi[2]].enumerated() {
            sol_canvas_fill_ellipse(target.raw, x + 5 * s + Float(k) * 18 * s, r.y + 20 * s, 5 * s, 5 * s, color, 1)
        }
        func line(_ y: Float, _ parts: [(String, UInt32)]) {
            var cx = x
            for (text, color) in parts {
                let units = Array(text.utf16)
                sol_canvas_draw_label(target.raw, cx, r.y + y, r.width, 18 * s, units, Int32(units.count), 13 * s, 0, color, 1)
                cx += measure(target, text, pixels: 13 * s)
            }
        }
        line(32 * s, [("❯ ", colors.accent), ("git status", colors.foreground)])
        line(52 * s, [("on ", TerminalPalette.mix(colors.foreground, colors.background, 0.55)), ("main ", colors.ansi[5]), ("✓ clean", colors.ansi[2])])
        line(72 * s, [("● ", colors.ansi[3]), ("3 files ", colors.foreground), ("changed", colors.ansi[4])])
        for (k, color) in [1, 2, 3, 4, 5, 6].map({ colors.ansi[$0] }).enumerated() {
            sol_canvas_fill_rounded(target.raw, x + Float(k) * 26 * s, r.y + 96 * s, 22 * s, 7 * s, 3.5 * s, color, 1)
        }
        label(target, spec.name, UIRect(x: x, y: r.maxY - strip, width: r.width - 36 * s, height: strip), pixels: 13.5 * s, semibold: true)
        if current {
            sol_canvas_stroke_rounded(target.raw, r.x + 1, r.y + 1, r.width - 2, r.height - 2, radius, TerminalPalette.accent, 1, 2 * s)
        } else if isHovered(r) {
            sol_canvas_stroke_rounded(target.raw, r.x + 0.5, r.y + 0.5, r.width - 1, r.height - 1, radius, TerminalPalette.foreground, 0.3, 1)
        }
    }

    // MARK: Mouse and keys

    private func mouse(_ message: UINT, x: Float, y: Float) {
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
        switch message {
        case Win.WM_MOUSEMOVE:
            hovered = (x, y)
            invalidate()
        case Win.WM_LBUTTONDOWN:
            click(x: x, y: y)
        default:
            break
        }
    }

    private func click(x: Float, y: Float) {
        if x < sidebarWidth {
            if let p = Page.allCases.first(where: { sidebarRow($0).contains(x, y) }) {
                commitEditing()
                page = p
                scroll = 0
                invalidate()
            }
            return
        }
        for piece in pieces(canvas, width: width, height: height) {
            switch piece {
            case .control(let control, let r) where r.contains(x, y):
                press(control, r)
                return
            case .theme(let spec, let r) where r.contains(x, y):
                commitEditing()
                AppSettings.shared.set("theme", spec.name)
                return
            case .link(_, let r, let action) where r.contains(x, y):
                commitEditing()
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

    private func press(_ control: Control, _ r: UIRect) {
        switch control {
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

    private func commitEditing() {
        guard let field = editing else { return }
        editing = nil
        field.commit(field.state.text)
        invalidate()
    }

    private func key(_ key: Int32) {
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
            if key == Win.VK_ESCAPE { close() }
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

    func saveSnapshot(to path: String) -> Bool {
        guard width > 0, let bitmap = Canvas(width: width, height: height, fontPixels: 13 * scale),
              sol_canvas_begin(bitmap.raw, TerminalPalette.background) >= 0 else { return false }
        draw(on: bitmap)
        guard sol_canvas_end(bitmap.raw) >= 0 else { return false }
        return bitmap.savePNG(to: path)
    }
}
