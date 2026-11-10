import CCanvas
import Foundation
import WinSDK

// Solanum on Windows. build.ps1 links this twice: Solanum.exe, a windowed app with no console, and Solanum-test.exe, a
// console program that can print test results and that PowerShell waits for.
_ = SetConsoleOutputCP(65001)

// Started by ssh to ask for a password (see Askpass): ask the running Solanum, and print the answer for ssh.
if ProcessInfo.processInfo.environment["SOLANUM_ASKPASS"] == "1" {
    exit(Askpass.runHelper(prompt: CommandLine.arguments.dropFirst().joined(separator: " ")))
}

if CommandLine.arguments.contains("--selftest") {
    let results = CoreSelfTest.Results()
    CoreSelfTest.run(results)
    WindowSelfTest.runDrawing(results)
    WindowSelfTest.runChrome(results)
    ConPTYSelfTest.run(results)
    exit(results.finish() ? 0 : 1)
}

// Draws the agents' marks with each status's dot, at 100% and 200%, into a PNG, with no window: for checking them by eye.
// Claude Code's screen with pasted images, drawn as their thumbnails, one shown larger: --draw-image-chips <png> <session> <folder>
if let flag = CommandLine.arguments.firstIndex(of: "--draw-image-chips"), CommandLine.arguments.indices.contains(flag + 3) {
    let args = CommandLine.arguments
    ClaudeImages.testing = (args[flag + 2], args[flag + 3])
    guard let canvas = Canvas(width: 900, height: 520, fontPixels: 15) else { exit(1) }
    canvas.terminalArea = UIRect(x: 0, y: 0, width: 900, height: 520)
    canvas.padding = 10
    let m = canvas.metrics
    let terminal = Terminal(cols: Int((900 - 20) / m.cellWidth), rows: Int((520 - 20) / m.cellHeight), scrollbackLimit: 100)
    let rule = String(repeating: "\u{2500}", count: terminal.cols)
    let screen = "\u{1b}]133;A\u{07}PS> \u{1b}]133;B\u{07}claude\r\n\u{1b}]133;C\u{07}"
        + "\r\n\u{276F} what's wrong with these tabs? [Image #1] [Image #2]\r\n  \u{23BF}  [Image #1]\r\n  \u{23BF}  [Image #2]\r\n\r\n\r\n\r\n"
        + "\u{25CF} The second tab's close button overlaps its title.\r\n\r\n\r\n\r\n\r\n"
        + rule + "\u{276F} and this one [Image #3]\r\n" + rule + "\r\n  ? for shortcuts"
    Array(screen.utf8).withUnsafeBufferPointer { terminal.feed($0) }
    let chips = ImageChips()
    chips.layout(terminal: terminal, top: terminal.screenTopAbs, canvas: canvas, shell: 1, scale: 1)
    chips.popup = 2
    guard sol_canvas_begin(canvas.raw, TerminalPalette.background) >= 0 else { exit(1) }
    var renderer = TerminalRenderer(canvas: canvas, terminal: terminal)
    renderer.hiddenText = chips.hidden
    renderer.drawContents()
    chips.draw(on: canvas, scale: 1)
    guard sol_canvas_end(canvas.raw) >= 0 else { exit(1) }
    print("thumbnails: \(chips.chips.map(\.n))")
    exit(canvas.savePNG(to: args[flag + 1]) ? 0 : 1)
}

// Corner cards over a window's top right, as each kind shows: --draw-notices <png>
if let flag = CommandLine.arguments.firstIndex(of: "--draw-notices"), CommandLine.arguments.indices.contains(flag + 1) {
    guard let canvas = Canvas(width: 760, height: 560, fontPixels: 13), sol_canvas_begin(canvas.raw, TerminalPalette.background) >= 0 else { exit(1) }
    sol_canvas_fill_rect(canvas.raw, 0, 0, 760, 38, TerminalPalette.chrome, 1)
    let stack = CornerNoticeStack()
    let lost = CornerNotice(NoticeRules.lostConnection(host: "pi@raspberrypi", place: "Servers \u{203A} pi", folder: "/home/pi/projects/weather-station"),
                            button: ("Reconnect", {}), keepsOpen: true, lifetime: 600)
    stack.show(CornerNotice(NoticeRules.commandFinished(command: "cargo build --release --target x86_64-pc-windows-msvc", duration: 312, exitCode: 0,
                                                        threshold: 10, place: "api")!))
    stack.show(CornerNotice(NoticeRules.commandFinished(command: "npm test", duration: 48.2, exitCode: 1, threshold: 10, place: "Web \u{203A} frontend")!))
    stack.show(CornerNotice(NoticeRules.agentStopped(agent: "Claude", waiting: false, worked: 734, prompt: "make the sidebar remember its width", place: "Solanum")))
    stack.show(CornerNotice(NoticeRules.agentStopped(agent: "Codex", waiting: true, worked: 95, prompt: "migrate the tests", place: "api")))
    stack.show(lost)
    lost.hideButton()
    lost.setTitle("Log in to pi@raspberrypi")
    lost.askSecret("pi@raspberrypi's password:") { _ in }
    _ = stack.tick()
    stack.draw(on: canvas, windowWidth: 760, top: 38, scale: 1)
    guard sol_canvas_end(canvas.raw) >= 0 else { exit(1) }
    exit(canvas.savePNG(to: CommandLine.arguments[flag + 1]) ? 0 : 1)
}

// The status bar's git marks at 200%, for comparing with the Mac's by eye: up to date, then 1 ahead. --draw-git-bar <png>
if let flag = CommandLine.arguments.firstIndex(of: "--draw-git-bar"), CommandLine.arguments.indices.contains(flag + 1) {
    // The bar up to date, and below it each mark large.
    let width: Float = 1300, height: Float = 260
    guard let canvas = Canvas(width: Int(width), height: Int(height), fontPixels: 26), sol_canvas_begin(canvas.raw, TerminalPalette.background) >= 0 else { exit(1) }
    var info = GitInfo(root: "C:\\repo", branch: "EZ-578-vsi-support", upstream: "origin/EZ-578-vsi-support")
    info.changes = (0..<4).map { GitChange(code: "M", path: "f\($0)") }
    var chrome = WindowChrome(canvas: canvas, layout: WindowLayout(width: width, height: 120, scale: 2, tabCount: 1), tabs: ["~"], activeTab: 0)
    chrome.git = GitBadge(info, busy: nil)
    chrome.folder = #"C:\Users\dev\Projects\Solanum"#
    chrome.keepAwakeLeft = "Awake 7h 59m"
    chrome.draw()
    for (i, kind) in [GitIcons.Kind.branch, .sync, .publish, .changes].enumerated() {
        GitIcons.draw(kind, in: UIRect(x: 40 + Float(i) * 140, y: 130, width: 120, height: 120), on: canvas, scale: 7, color: TerminalPalette.foreground, alpha: 0.8)
    }
    guard sol_canvas_end(canvas.raw) >= 0 else { exit(1) }
    exit(canvas.savePNG(to: CommandLine.arguments[flag + 1]) ? 0 : 1)
}

// Ctrl+F's two bars at 200%, for comparing with the Mac's by eye: a file's (Replace showing) above the terminal's.
// --draw-find <png>
if let flag = CommandLine.arguments.firstIndex(of: "--draw-find"), CommandLine.arguments.indices.contains(flag + 1) {
    let width: Float = 1400, height: Float = 1300, s: Float = 2
    guard let canvas = Canvas(width: Int(width), height: Int(height), fontPixels: 26), sol_canvas_begin(canvas.raw, TerminalPalette.background) >= 0 else { exit(1) }
    let text = "{\n  \"name\": \"solanum\",\n  \"cat\": \"Cat cat concat\",\n  \"more\": [\"cat\", \"dog\"]\n}\n"
    let file = FileEditorPanel(path: "C:\\demo.json", name: "demo.json", folder: "C:\\", isLocal: true, read: { _, done in done(Data(text.utf8), false) },
                               write: { _, done in done(nil) })
    file.cellSize = (canvas.metrics.cellWidth, canvas.metrics.cellHeight)
    file.reload()
    _ = file.key(0x48, shift: false, ctrl: true)
    "cat".forEach { file.typed(String($0)) }
    file.draw(on: canvas, in: UIRect(x: 0, y: 0, width: width, height: 420), scale: s)
    // The terminal's, over a transcript.
    canvas.terminalArea = UIRect(x: 0, y: 440, width: width, height: 460)
    let grid = TerminalRenderer.grid(width: Int(width), height: 460, canvas: canvas)
    let terminal = Terminal(cols: grid.cols, rows: grid.rows, scrollbackLimit: 100)
    Array("PS C:\\demo> cat notes.txt\r\nthe cat sat\r\nconcatenate\r\nPS C:\\demo> ".utf8).withUnsafeBufferPointer { terminal.feed($0) }
    let find = TerminalFindBar()
    find.bar.type("cat")
    FindBar.options = EditorFindOptions(wholeWord: true)
    find.search(terminal, bottomLine: terminal.lastAbs)
    var renderer = TerminalRenderer(canvas: canvas, terminal: terminal)
    renderer.findMatches = find.cells
    renderer.drawContents()
    find.bar.draw(on: canvas, in: canvas.terminalArea!, scale: s)
    FindBar.options = EditorFindOptions()
    // A README's preview, its bar open.
    let readme = "# Solanum\n\nA terminal for **agents**: find in the terminal, in files and in previews.\n\n- terminal tabs\n- a sidebar\n"
    let preview = MarkdownPreviewPanel(path: "C:\\README.md", name: "README.md") { _, done in done(Data(readme.utf8), false) }
    preview.cellSize = (canvas.metrics.cellWidth, canvas.metrics.cellHeight)
    preview.reload()
    let pageArea = UIRect(x: 0, y: 910, width: width, height: 390)
    preview.draw(on: canvas, in: pageArea, scale: s)
    _ = preview.key(0x46, shift: false, ctrl: true)
    "terminal".forEach { preview.typed(String($0)) }
    preview.draw(on: canvas, in: pageArea, scale: s)
    guard sol_canvas_end(canvas.raw) >= 0 else { exit(1) }
    exit(canvas.savePNG(to: CommandLine.arguments[flag + 1]) ? 0 : 1)
}

// Git Graph with its filters, on the repository in the folder given, at 200%: --draw-graph <png> <folder>
if let flag = CommandLine.arguments.firstIndex(of: "--draw-graph"), CommandLine.arguments.indices.contains(flag + 2) {
    let width: Float = 1500, height: Float = 640, s: Float = 2
    let panel = GitGraphPanel(place: GitPlace(dir: CommandLine.arguments[flag + 2], remote: nil))
    panel.reload()
    let until = Date().addingTimeInterval(20)
    while !panel.loaded && Date() < until { Thread.sleep(forTimeInterval: 0.1) }
    panel.setFilterForTesting { $0.days = 30; $0.branch = "windows-compat" }
    while !panel.loaded && Date() < until { Thread.sleep(forTimeInterval: 0.1) }
    guard let canvas = Canvas(width: Int(width), height: Int(height), fontPixels: 26), sol_canvas_begin(canvas.raw, TerminalPalette.background) >= 0 else { exit(1) }
    panel.draw(on: canvas, in: UIRect(x: 0, y: 0, width: width, height: height), scale: s)
    guard sol_canvas_end(canvas.raw) >= 0 else { exit(1) }
    exit(canvas.savePNG(to: CommandLine.arguments[flag + 1]) ? 0 : 1)
}

// A file changed on disk under unsaved edits, saved: its header, the conflict bar, and Compare when asked:
// --draw-file-conflict <png> [compare]
if let flag = CommandLine.arguments.firstIndex(of: "--draw-file-conflict"), CommandLine.arguments.indices.contains(flag + 1) {
    var disk = Data("{\n  \"name\": \"solanum\",\n  \"version\": \"1.4.0\",\n  \"private\": true\n}\n".utf8), stamp = 1
    let panel = FileEditorPanel(path: "C:\\work\\package.json", name: "package.json", folder: "C:\\work", isLocal: true, read: { _, done in done(disk, false) },
                                write: { data, done in disk = data; stamp += 1; done(nil) }, signature: { done in done(true, "\(stamp)") })
    panel.reload()
    panel.typeForTesting("// mine\n")
    disk = Data("{\n  \"name\": \"solanum\",\n  \"version\": \"1.5.0\",\n  \"private\": true,\n  \"type\": \"module\"\n}\n".utf8); stamp += 1
    panel.syncNowForTesting()
    panel.save()
    if CommandLine.arguments.indices.contains(flag + 2) { panel.pressConflict("Compare") }
    panel.press(button: .tail)
    guard let canvas = Canvas(width: 900, height: 420, fontPixels: 14), sol_canvas_begin(canvas.raw, TerminalPalette.background) >= 0 else { exit(1) }
    panel.cellSize = (canvas.metrics.cellWidth, canvas.metrics.cellHeight)
    panel.draw(on: canvas, in: UIRect(x: 0, y: 0, width: 900, height: 420), scale: 1)
    guard sol_canvas_end(canvas.raw) >= 0 else { exit(1) }
    exit(canvas.savePNG(to: CommandLine.arguments[flag + 1]) ? 0 : 1)
}

// Claude's reply with a code block, a table and a quote, boxed with their Copy buttons: --draw-code-boxes <png>
if let flag = CommandLine.arguments.firstIndex(of: "--draw-code-boxes"), CommandLine.arguments.indices.contains(flag + 1) {
    guard let canvas = Canvas(width: 900, height: 470, fontPixels: 15) else { exit(1) }
    canvas.terminalArea = UIRect(x: 0, y: 0, width: 900, height: 470)
    canvas.padding = 10
    let m = canvas.metrics
    let terminal = Terminal(cols: Int((900 - 20) / m.cellWidth), rows: Int((470 - 20) / m.cellHeight), scrollbackLimit: 100)
    let h = "\u{2500}"
    let screen = "\u{23FA} Here's how to see every branch at once:\r\n\r\n"
        + "  \u{1b}[36mgit\u{1b}[0m log --oneline --graph --decorate --all --simplify-by-decoration\r\n"
        + "    --date=relative\r\n\r\n"
        + "  The flags, briefly:\r\n\r\n"
        + "  \u{250C}" + String(repeating: h, count: 22) + "\u{252C}" + String(repeating: h, count: 34) + "\u{2510}\r\n"
        + "  \u{2502} Flag                 \u{2502} What it does                     \u{2502}\r\n"
        + "  \u{251C}" + String(repeating: h, count: 22) + "\u{253C}" + String(repeating: h, count: 34) + "\u{2524}\r\n"
        + "  \u{2502} --graph              \u{2502} Draws the branches beside commits \u{2502}\r\n"
        + "  \u{2502} --decorate           \u{2502} Names branches and tags          \u{2502}\r\n"
        + "  \u{2514}" + String(repeating: h, count: 22) + "\u{2534}" + String(repeating: h, count: 34) + "\u{2518}\r\n\r\n"
        + "  \u{1b}[2m\u{258E}\u{1b}[0m \u{1b}[3mTip: alias it, so it's one word away next time.\u{1b}[0m\r\n"
        + "  \u{1b}[2m\u{258E}\u{1b}[0m \u{1b}[3mgit config --global alias.tree '...'\u{1b}[0m\r\n"
    Array(screen.utf8).withUnsafeBufferPointer { terminal.feed($0) }
    let boxes = terminal.snapshot().findBoxes(code: ["git log --oneline --graph --decorate --all --simplify-by-decoration --date=relative"])
    print("boxes: \(boxes.map { "\($0.kind)" })")
    guard sol_canvas_begin(canvas.raw, TerminalPalette.background) >= 0 else { exit(1) }
    let view = CodeBoxView(canvas: canvas, terminal: terminal, boxes: boxes, top: terminal.screenTopAbs, scale: 1)
    view.drawPanels()
    var renderer = TerminalRenderer(canvas: canvas, terminal: terminal)
    renderer.cursorShown = false
    renderer.drawContents()
    view.drawButtons(hover: 0, copied: 2)
    guard sol_canvas_end(canvas.raw) >= 0 else { exit(1) }
    exit(canvas.savePNG(to: CommandLine.arguments[flag + 1]) ? 0 : 1)
}

// Every catalog pack downloaded into a folder (unless it's there already), and a row of icons from each theme:
// --draw-icon-packs <png> <packs folder>
if let flag = CommandLine.arguments.firstIndex(of: "--draw-icon-packs"), CommandLine.arguments.indices.contains(flag + 2) {
    IconPacks.folderOverride = CommandLine.arguments[flag + 2].replacingOccurrences(of: "\\", with: "/")
    if IconPacks.installed.isEmpty {
        for pack in IconPackCatalog.packs {
            do { print("\(pack.label): \(try IconPacks.fetchAndInstall(pack.source).map(\.id))") } catch { print("\(pack.label): \(error)") }
        }
        IconPacks.reload()
    }
    let names: [(String, Bool, Bool)] = [("src", true, false), ("src", true, true), ("node_modules", true, false), ("package.json", false, false),
        ("README.md", false, false), ("main.swift", false, false), ("index.ts", false, false), ("app.py", false, false), ("Dockerfile", false, false),
        (".gitignore", false, false), ("style.css", false, false), ("logo.png", false, false), ("notes.txt", false, false), ("Cargo.toml", false, false)]
    // Icons at 28 pixels, as a display scaled to 175% draws them, so a pack that only draws at its own size shows it.
    let rowH: Float = 40, labelW: Float = 220
    guard let canvas = Canvas(width: Int(labelW) + names.count * 40 + 20, height: Int(rowH) * (IconPacks.installed.count + 1) + 20, fontPixels: 13),
          sol_canvas_begin(canvas.raw, TerminalPalette.background) >= 0 else { exit(1) }
    for (k, entry) in ([IconPackEntry(id: "solanum", label: "Solanum", manifest: "", root: "")] + IconPacks.installed).enumerated() {
        AppSettings.shared.setForTesting("file-icons", entry.id)
        let y = 10 + Float(k) * rowH
        let units = Array(entry.label.utf16)
        sol_canvas_draw_label(canvas.raw, 10, y, labelW - 20, rowH, units, Int32(units.count), 13, 0, TerminalPalette.foreground, 0.8)
        for (i, n) in names.enumerated() {
            let x = labelW + Float(i) * 40
            if !FileIcons.draw(name: n.0, directory: n.1, expanded: n.2, x: x, y: y + 6, size: 28, on: canvas) {
                sol_canvas_draw_icon(canvas.raw, x, y, 16, rowH, n.1 ? 0xE8B7 : FileKind(name: n.0).glyph, 13, TerminalPalette.foreground, 0.65)
            }
        }
    }
    guard sol_canvas_end(canvas.raw) >= 0 else { exit(1) }
    exit(canvas.savePNG(to: CommandLine.arguments[flag + 1]) ? 0 : 1)
}

// The status bar's left end at 175%, with guides through the middle of each icon: --draw-status-bar <png>
if let flag = CommandLine.arguments.firstIndex(of: "--draw-status-bar"), CommandLine.arguments.indices.contains(flag + 1) {
    let scale: Float = Float(CommandLine.arguments.indices.contains(flag + 2) ? CommandLine.arguments[flag + 2] : "1.75") ?? 1.75
    var layout = WindowLayout(width: 700 * scale, height: 120 * scale, scale: scale, tabCount: 1)
    layout.hasShellButton = true
    guard let canvas = Canvas(width: Int(700 * scale), height: Int(120 * scale), fontPixels: 13 * scale), sol_canvas_begin(canvas.raw, TerminalPalette.background) >= 0 else { exit(1) }
    var chrome = WindowChrome(canvas: canvas, layout: layout, tabs: ["PowerShell"], activeTab: 0)
    chrome.shell = Shells.defaultShell
    // Git on a branch with work to push and pull, and changes; a second bar below with a branch not yet published.
    var info = GitInfo(root: "C:/work")
    info.branch = "windows-compat"
    info.upstream = "origin/windows-compat"
    info.ahead = 2
    info.behind = 1
    info.changes = Array(repeating: GitChange(code: "M", path: "a"), count: 13)
    chrome.git = GitBadge(info, busy: nil)
    chrome.folder = "C:/work"
    chrome.draw()
    // A line through the bar's middle, to see each icon against.
    sol_canvas_fill_rect(canvas.raw, 0, layout.toggleLeft.midY, 100 * scale, 1, 0xFF0000, 0.8)
    guard sol_canvas_end(canvas.raw) >= 0 else { exit(1) }
    exit(canvas.savePNG(to: CommandLine.arguments[flag + 1]) ? 0 : 1)
}

if let flag = CommandLine.arguments.firstIndex(of: "--draw-agent-marks"), CommandLine.arguments.indices.contains(flag + 1) {
    let kinds: [AgentKind] = [.claude, .codex, .antigravity, .other("aider")]
    let statuses: [AgentStatus] = [.working, .waiting, .done, .failed]
    guard let canvas = Canvas(width: 520, height: 260, fontPixels: 13), sol_canvas_begin(canvas.raw, TerminalPalette.chrome) >= 0 else { exit(1) }
    // 100% on the left, 200% beside it: a row for each agent, a column for each status.
    for (scale, left) in [(Float(1), Float(0)), (2, 140)] {
        for (k, kind) in kinds.enumerated() {
            for (j, status) in statuses.enumerated() {
                WindowChrome.drawAgent(AgentInfo(kind: kind, status: status), on: canvas, atX: left + Float(12 + j * 30) * scale,
                                       midY: Float(14 + k * 22) * scale, scale: scale)
            }
        }
    }
    _ = sol_canvas_end(canvas.raw)
    exit(canvas.savePNG(to: CommandLine.arguments[flag + 1]) ? 0 : 1)
}

// Draws every theme's planet, at the status bar's size at 100% and 200% and large, into a PNG, with no window.
if let flag = CommandLine.arguments.firstIndex(of: "--draw-planets"), CommandLine.arguments.indices.contains(flag + 1) {
    let planets = PlanetArt.Planet.allCases
    guard let canvas = Canvas(width: 24 + planets.count * 104, height: 190, fontPixels: 13), sol_canvas_begin(canvas.raw, TerminalPalette.chrome) >= 0 else { exit(1) }
    for (i, planet) in planets.enumerated() {
        let x = Float(12 + i * 104)
        canvas.drawPlanet(planet, UIRect(x: x, y: 10, width: 18, height: 18))
        canvas.drawPlanet(planet, UIRect(x: x + 30, y: 6, width: 36, height: 36))
        canvas.drawPlanet(planet, UIRect(x: x, y: 60, width: 96, height: 96))
        let units = Array(planet.rawValue.utf16)
        sol_canvas_draw_label(canvas.raw, x, 160, 100, 20, units, Int32(units.count), 11, 0, TerminalPalette.foreground, 0.8)
    }
    _ = sol_canvas_end(canvas.raw)
    exit(canvas.savePNG(to: CommandLine.arguments[flag + 1]) ? 0 : 1)
}

// Draws the Quantum Moon's reading at a few moments (Solanum's mid-read, then typed out; Bells' typed out) into a PNG,
// with no window.
if let flag = CommandLine.arguments.firstIndex(of: "--draw-quantum-moon"), CommandLine.arguments.indices.contains(flag + 1) {
    guard let canvas = Canvas(width: 1500, height: 520, fontPixels: 13), sol_canvas_begin(canvas.raw, TerminalPalette.background) >= 0 else { exit(1) }
    for (i, (bells, elapsed)) in [(false, 1.6), (false, 9.0), (true, 6.0)].enumerated() {
        guard let reading = NomaiReading.forTesting(bells: bells) else { exit(2) }
        reading.pretend(elapsed: elapsed)
        let moon = UIRect(x: Float(30 + i * 500), y: 480, width: 22, height: 26)
        canvas.drawPlanet(.quantumMoon, UIRect(x: moon.x + 2, y: moon.y + 4, width: 18, height: 18))
        reading.place(moon: moon, width: Float(500 + i * 500), scale: 1, canvas: canvas)
        reading.draw(on: canvas)
    }
    _ = sol_canvas_end(canvas.raw)
    exit(canvas.savePNG(to: CommandLine.arguments[flag + 1]) ? 0 : 1)
}

// Draws a page of Settings (by its name, as `appearance`) into a PNG, with no window.
// The wallpaper as a see-through window would show it, at 80%, with the tab bar's color over its top: --draw-wallpaper <png> [blur]
if let flag = CommandLine.arguments.firstIndex(of: "--draw-wallpaper"), CommandLine.arguments.indices.contains(flag + 1) {
    guard let canvas = Canvas(width: 900, height: 520, fontPixels: 13) else { exit(1) }
    var path = [UInt16](repeating: 0, count: 2048), area = [Int32](repeating: 0, count: 4), position: Int32 = 4, color: UInt32 = 0
    guard sol_wallpaper_at(100, 100, &path, 2048, &area, &position, &color) >= 0 else { exit(3) }
    let file = String(decoding: path.prefix { $0 != 0 }, as: UTF16.self)
    print("wallpaper: \(file.isEmpty ? "(none)" : file), area \(area), position \(position), color \(String(color, radix: 16))")
    let blur: Float = CommandLine.arguments.indices.contains(flag + 2) ? Float(CommandLine.arguments[flag + 2]) ?? 48 : 48
    let made = file.isEmpty ? sol_canvas_set_wallpaper(canvas.raw, nil, area[2], area[3], position, color, blur)
        : wide(file).withUnsafeBufferPointer { sol_canvas_set_wallpaper(canvas.raw, $0.baseAddress, area[2], area[3], position, color, blur) }
    print("made: \(made)")
    sol_canvas_set_opacity(canvas.raw, 0.8)
    sol_canvas_set_wallpaper_origin(canvas.raw, -200, -150)
    guard sol_canvas_begin(canvas.raw, TerminalPalette.background) >= 0 else { exit(1) }
    sol_canvas_backdrop_rect(canvas.raw, 0, 0, 900, 40, TerminalPalette.chrome)
    let text = Array("PS > the wallpaper shows through".utf16)
    sol_canvas_draw_label(canvas.raw, 20, 60, 600, 24, text, Int32(text.count), 16, 0, TerminalPalette.foreground, 1)
    guard sol_canvas_end(canvas.raw) >= 0 else { exit(1) }
    exit(canvas.savePNG(to: CommandLine.arguments[flag + 1]) ? 0 : 1)
}

if let flag = CommandLine.arguments.firstIndex(of: "--draw-settings"), CommandLine.arguments.indices.contains(flag + 2) {
    let name = CommandLine.arguments[flag + 1].lowercased()
    // The theme editor, with the picker open on the selection (which has opacity) or on red.
    // With a picture (the desktop's), the editor scrolled to show it and the card.
    if name == "theme-editor-picture" {
        var path = [UInt16](repeating: 0, count: 2048), area = [Int32](repeating: 0, count: 4), position: Int32 = 0, color: UInt32 = 0
        _ = sol_wallpaper_at(100, 100, &path, 2048, &area, &position, &color)
        let file = String(decoding: path.prefix { $0 != 0 }, as: UTF16.self)
        exit(SettingsWindow.shared.drawEditorForTesting(picking: "none", picture: file, to: CommandLine.arguments[flag + 2]) ? 0 : 1)
    }
    if name == "theme-editor" || name == "theme-editor-red" {
        exit(SettingsWindow.shared.drawEditorForTesting(picking: name == "theme-editor" ? "selection" : "ansi-1", to: CommandLine.arguments[flag + 2]) ? 0 : 1)
    }
    guard let page = SettingsWindow.Page.allCases.first(where: { "\($0)" == name }) else { exit(2) }
    exit(SettingsWindow.shared.drawPage(page, width: 900, height: 1500, to: CommandLine.arguments[flag + 2]) ? 0 : 1)
}

if let flag = CommandLine.arguments.firstIndex(of: "--fake-agent") {
    FakeAgent.run(text: CommandLine.arguments[(flag + 1)...].joined(separator: " "))
    exit(0)
}

// How fast the emulator takes output, for comparing builds: colored lines and plain ones, as a busy program prints them.
if CommandLine.arguments.contains("--bench") {
    var chunk = ""
    for i in 0..<2000 {
        chunk += i % 3 == 0 ? "\u{1b}[38;5;\(i % 200)mline \(i)\u{1b}[0m some ordinary output text that runs on for a while, plus more\r\n"
            : "  \(i): let value = compute(input, with: options) // a comment that is long enough to matter\r\n"
    }
    let bytes = Array(chunk.utf8), rounds = 120
    let terminal = Terminal(cols: 120, rows: 40, scrollbackLimit: 10000)
    let start = Date()
    for _ in 0..<rounds { bytes.withUnsafeBufferPointer { terminal.feed($0) } }
    let seconds = Date().timeIntervalSince(start), mb = Double(bytes.count * rounds) / 1_048_576
    print(String(format: "%.0f MB in %.2f s: %.0f MB/s", mb, seconds, mb / seconds))
    exit(0)
}

if CommandLine.arguments.contains("--input-probe") {
    ConPTYSelfTest.probeInput()
    exit(0)
}

if CommandLine.arguments.contains("--resize-probe") {
    ConPTYSelfTest.probeResize()
    exit(0)
}

if CommandLine.arguments.contains("--window-test") {
    // Unbuffered, so that whatever happens the log shows how far it got.
    setvbuf(stdout, nil, _IONBF, 0)
    exit(WindowSelfTest.runWindow())
}

if CommandLine.arguments.contains("--restart-running") {
    exit(AppRestart.askRunningToRestart())
}

exit(TerminalWindow.runApp())
