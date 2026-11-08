import Foundation

/// Solanum's settings on Windows, in %APPDATA%\Solanum\config, in the Mac's format. Tests use them without the file.
final class AppSettings {
    static let shared = AppSettings()

    private(set) var file = SettingsFile()
    private var fileDate: Date?
    private(set) var customThemes: [ThemeSpec] = []
    /// Each custom theme's file in the themes folder, by its name.
    private(set) var customThemeFiles: [String: URL] = [:]
    /// What the themes folder held when last read (see `ThemeFiles.signature`).
    private var themesSignature = ""
    /// Called after any change, from the file or from Settings.
    var onChange: [() -> Void] = []

    static var folder: URL? {
        guard !CommandLine.arguments.contains("--window-test"), let appData = ProcessInfo.processInfo.environment["APPDATA"] else { return nil }
        return URL(fileURLWithPath: appData).appendingPathComponent("Solanum")
    }
    static var fileURL: URL? { folder?.appendingPathComponent("config") }
    static var themesFolder: URL? { folder?.appendingPathComponent("themes") }

    private init() { load() }

    // MARK: Values

    var themeName: String { file["theme"].flatMap { name in allThemes.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.name } ?? ThemeSpecs.defaultName }
    var fontFamily: String { file["font-family"].flatMap { $0.isEmpty || $0 == "System Mono" ? nil : $0 } ?? "" }
    /// Points at 100% display scaling.
    var fontSize: Double { file.number("font-size", 11, in: 6...40) }
    var lineHeight: Double { file.number("line-height", 1.2, in: 0.9...2.0) }
    var padding: Double { file.number("padding", 6, in: 0...60) }
    var cursorStyle: String { ["bar", "block", "underline"].contains(file["cursor-style"]?.lowercased() ?? "") ? file["cursor-style"]!.lowercased() : "bar" }
    var cursorBlink: Bool { file.bool("cursor-blink", true) }
    var audibleBell: Bool { file.bool("audible-bell", false) }
    var boldIsBright: Bool { file.bool("bold-is-bright", false) }
    var copyOnSelect: Bool { file.bool("copy-on-select", false) }
    var scrollback: Int { Int(file.number("scrollback-lines", 10000, in: 100...200_000)) }
    /// Lines the terminal and open pages move per notch of a mouse wheel; a touchpad's small steps move it in proportion.
    var scrollSpeed: Double { file.number("scroll-speed", 3, in: 0.25...20) }
    var shell: String { file["shell"] ?? "" }
    var shellIntegration: Bool { file.bool("shell-integration", true) }
    var themeIcon: Bool { file.bool("theme-icon", true) }
    /// How solid the window's background is, as on the Mac: below 1 the desktop shows through, blurred if `blur`.
    var opacity: Double { file.number("background-opacity", 0.95, in: 0.3...1) }
    var blur: Bool { file.bool("background-blur", true) }
    /// What shows through a see-through window: the desktop wallpaper, drawn by Solanum and the same whether the window
    /// is in front or not ("wallpaper"), or whatever's behind it, windows included ("windows").
    var showsWallpaper: Bool { file["see-through"]?.lowercased() != "windows" }
    /// "current": a new tab opens in the current tab's folder. "home": in the home folder.
    var newTabFolder: String { file["new-tab-folder"]?.lowercased() == "home" ? "home" : "current" }
    /// Keep the password an ssh session signed in with, in memory only, so the sidebar can sign in with it too.
    var rememberSSHPasswords: Bool { file.bool("remember-ssh-passwords", true) }
    var windowColumns: Int { Int(file.number("window-columns", 110, in: 40...400)) }
    var windowRows: Int { Int(file.number("window-rows", 32, in: 10...200)) }

    /// The theme's planet, beside its name in the status bar, as on the Mac: a planet theme's, or a custom theme's that's
    /// named after one. VS Code's themes have none.
    var themePlanet: PlanetArt.Planet? {
        let name = themeName, custom = customThemes.contains { $0.name == name }
        return PlanetArt.planet(themeName: name, isVSCode: !custom && ThemeSpecs.vsCode.contains { $0.name == name })
    }

    var theme: ThemeSpec {
        let name = themeName
        // A custom theme being edited shows its unsaved colors everywhere, under its saved name until it's saved.
        if let draft = themeDraft, draft.savedName == name { return draft.spec.with(name: name) }
        return allThemes.first { $0.name == name } ?? ThemeSpecs.solanumDefault
    }

    /// Settings' theme editor's unsaved changes to a custom theme, by the theme's saved name; nil when there are none.
    private(set) var themeDraft: (savedName: String, spec: ThemeSpec)?

    /// Shows the editor's unsaved changes in every window (or, with nil, what's saved again).
    func setThemeDraft(_ draft: (savedName: String, spec: ThemeSpec)?, broadcast: Bool = true) {
        let before = themeDraft.map { ThemeFiles.json($0.spec) }, after = draft.map { ThemeFiles.json($0.spec) }
        themeDraft = draft
        if broadcast && before != after { onChange.forEach { $0() } }
    }
    var allThemes: [ThemeSpec] { [ThemeSpecs.solanumDefault] + ThemeSpecs.outerWilds + customThemes + ThemeSpecs.vsCode }

    /// The command a new tab runs: the configured shell, else PowerShell with Solanum's hook.
    var shellCommandLine: String {
        let configured = shell.trimmingCharacters(in: .whitespaces)
        let exe = configured.isEmpty ? PowerShellIntegration.executable() : configured
        let isPowerShell = ["powershell", "powershell.exe", "pwsh", "pwsh.exe"].contains((exe.split(separator: "\\").last.map(String.init) ?? exe).lowercased())
        if isPowerShell && shellIntegration { return PowerShellIntegration.commandLine(executable: exe) }
        return isPowerShell ? "\(exe) -NoLogo" : configured
    }

    // MARK: Changing them

    func set(_ key: String, _ value: String) {
        guard file[key] != value else { return }
        file[key] = value
        save()
        onChange.forEach { $0() }
    }

    func set(_ key: String, _ value: Bool) { set(key, value ? "true" : "false") }

    // MARK: The file

    /// Reads the file again if it's changed since, as when it's edited by hand. Cheap enough for a timer.
    func reloadIfChanged() {
        // A theme added, changed or taken away in the themes folder shows too.
        if ThemeFiles.signature() != themesSignature {
            reloadThemes()
        }
        guard let url = Self.fileURL, let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
              date != fileDate else { return }
        load()
        onChange.forEach { $0() }
    }

    /// Reads the themes folder again, and shows what's changed.
    func reloadThemes() {
        readThemes()
        onChange.forEach { $0() }
    }

    private func readThemes() {
        let loaded = ThemeFiles.load()
        customThemes = loaded.map(\.spec)
        customThemeFiles = Dictionary(loaded.map { ($0.spec.name, $0.file) }, uniquingKeysWith: { a, _ in a })
        themesSignature = ThemeFiles.signature()
    }

    func load() {
        readThemes()
        guard let url = Self.fileURL else { return }
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            file = SettingsFile(text: text)
            fileDate = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        } else {
            save()
        }
    }

    private func save() {
        guard let url = Self.fileURL else { return }
        var full = file
        for (key, value) in Self.defaults where full[key] == nil { full[key] = value }
        let text = full.text(header: "# Solanum configuration. Edit here or in Settings (the flower). Changes apply live.\n# Custom themes: JSON files in the themes folder beside this one, as on the Mac.", sections: Self.sections)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        fileDate = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    static let defaults: [String: String] = [
        "theme": ThemeSpecs.defaultName, "font-family": "", "font-size": "11", "line-height": "1.2", "padding": "6",
        "cursor-style": "bar", "cursor-blink": "true", "audible-bell": "false", "bold-is-bright": "false", "copy-on-select": "false", "scroll-speed": "3",
        "scrollback-lines": "10000", "shell": "", "shell-integration": "true", "theme-icon": "true", "new-tab-folder": "current", "background-opacity": "0.95", "background-blur": "true", "see-through": "wallpaper",
        "window-columns": "110", "window-rows": "32", "notify-after-seconds": "10", "keep-awake-seconds": "28800",
        "confirm-quit": "true", "restore-session": "true", "restore-scrollback": "true", "continue-agents": "true",
        "check-for-updates": "true", "minimum-contrast": "true", "remember-ssh-passwords": "true",
    ]

    static let sections: [(comment: String?, keys: [String])] = [
        (nil, ["theme"]),
        ("Font: any monospaced font installed (empty for Cascadia Mono, else Consolas). Size in points.", ["font-family", "font-size", "line-height", "padding"]),
        ("The flower or planet beside the theme's name in the status bar.", ["theme-icon"]),
        ("How solid the window's background is (0.3 to 1; 1 is solid), and whether what shows through is blurred.", ["background-opacity", "background-blur"]),
        ("What shows through it: wallpaper (your desktop picture, always) | windows (whatever is behind the window).", ["see-through"]),
        ("bar | block | underline", ["cursor-style", "cursor-blink"]),
        ("Play the alert sound when a program rings the bell (it always flashes the taskbar).", ["audible-bell", "bold-is-bright", "minimum-contrast", "copy-on-select", "scrollback-lines"]),
        ("Leave empty for PowerShell. A full command line works too, such as cmd.exe.", ["shell", "shell-integration"]),
        ("Keep an ssh session's password in memory, encrypted and never saved, so the sidebar can sign in with it too.", ["remember-ssh-passwords"]),
        ("Where Ctrl+T opens a new tab: current (the current tab's folder) | home", ["new-tab-folder"]),
        ("Notify when a command in a background tab takes at least this long (0 = off). Keep Awake's length in seconds.", ["notify-after-seconds", "keep-awake-seconds"]),
        ("Reopen windows and tabs on launch, with recent output, continuing coding agents.", ["restore-session", "restore-scrollback", "continue-agents", "confirm-quit", "check-for-updates"]),
        ("A new window's size, in columns and rows.", ["window-columns", "window-rows"]),
        ("Lines the terminal and open files scroll per mouse-wheel notch (touchpads in proportion). Lower is slower; 0.25 to 20.", ["scroll-speed"]),
    ]
}
