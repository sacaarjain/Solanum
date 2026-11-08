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
