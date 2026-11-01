import Foundation

/// The drawing and the real window, driven the way a person would. `Solanum-test --selftest` covers drawing;
/// `Solanum-test --window-test` opens a window, without taking focus, and runs a shell in it.
/// With SOLANUM_SNAPSHOT_DIR set, both save what they drew as PNGs there.
enum WindowSelfTest {
    private static var snapshotDirectory: String? { ProcessInfo.processInfo.environment["SOLANUM_SNAPSHOT_DIR"] }

    private static func snapshot(_ terminal: Terminal, name: String, canvas: Canvas) -> Bool {
        let renderer = TerminalRenderer(canvas: canvas, terminal: terminal)
        guard renderer.draw() >= 0 else { return false }
        guard let dir = snapshotDirectory else { return true }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return canvas.savePNG(to: dir + "\\" + name + ".png")
    }

    /// Everything the renderer has to tell apart, on one screen.
    static let sampler: String = {
        var s = "\u{1b}[1mSolanum on Windows\u{1b}[0m\r\n\r\n"
        s += "Plain, \u{1b}[1mbold\u{1b}[0m, \u{1b}[3mitalic\u{1b}[0m, \u{1b}[1;3mbold italic\u{1b}[0m, \u{1b}[2mdim\u{1b}[0m, "
        s += "\u{1b}[4munderline\u{1b}[0m, \u{1b}[21mdouble\u{1b}[0m, \u{1b}[9mstrike\u{1b}[0m, \u{1b}[7minverse\u{1b}[0m\r\n\r\n"
        for row in [30, 90] {
            for i in 0..<8 { s += "\u{1b}[\(row + i)m ansi\(row + i) \u{1b}[0m" }
            s += "\r\n"
        }
        for row in [40, 100] {
            for i in 0..<8 { s += "\u{1b}[\(row + i);30m \(row + i)  \u{1b}[0m" }
            s += "\r\n"
        }
        s += "\r\n"
        for i in 0..<36 { s += "\u{1b}[48;5;\(16 + i * 6)m  \u{1b}[0m" }
        s += "\r\n"
        for i in stride(from: 0, to: 256, by: 7) { s += "\u{1b}[48;2;\(i);\(255 - i);160m  \u{1b}[0m" }
        s += "\r\n\r\n"
        s += "Box: ┌──┬──┐ │██│░░│ └──┴──┘  Lines: ─│┼╭╮╰╯  Blocks: ▁▂▃▄▅▆▇█\r\n"
        s += "Symbols: ✦ ✓ ✗ → ← ↑ ↓ ⌘ ❯ • … ©\r\n"
        s += "Accents: héllo naïve Ελληνικά Русский e\u{301} a\u{308}\r\n"
        s += "Wide: 日本語のテキスト 한국어 中文 |columns line up|\r\n"
        s += "1234567890123456789012345678901234567890 |columns line up|\r\n"
        s += "Emoji: 🌱 🚀 ✨ 👍 |columns line up|\r\n"
        s += "\u{1b}]8;;https://example.com\u{7}a link\u{1b}]8;;\u{7}\r\n"
        s += "PS C:\\Users\\dev> "
        return s
    }()

    static func runDrawing(_ results: CoreSelfTest.Results) {
        print("Drawing")
        guard let canvas = Canvas(width: 1000, height: 640, fontPixels: 15) else {
            results.check("canvas: starts", false, "HRESULT \(String(UInt32(bitPattern: Canvas.lastError), radix: 16))")
            return
        }
        let m = canvas.metrics
        results.check("canvas: font metrics", m.cellWidth > 4 && m.cellHeight > m.cellWidth && m.baseline > 0 && m.baseline < m.cellHeight,
                      "\(m)")
        let grid = TerminalRenderer.grid(width: 1000, height: 640, metrics: m)
        results.check("canvas: grid from size", grid.cols > 50 && grid.rows > 20, "\(grid)")
        let terminal = Terminal(cols: grid.cols, rows: grid.rows, scrollbackLimit: 100)
        Array(sampler.utf8).withUnsafeBufferPointer { terminal.feed($0) }
        results.check("canvas: draws and saves", snapshot(terminal, name: "sampler", canvas: canvas))

        var selection = TerminalSelection(anchor: (0, 8), head: (0, 2))
        results.check("selection: backwards still orders", selection.ordered.start.col == 2)
        results.check("selection: text", selection.text(in: terminal) == "lanum", selection.text(in: terminal))
        selection = TerminalSelection(anchor: (0, 0), head: (2, 5))
        results.check("selection: spans lines", selection.text(in: terminal).hasPrefix("Solanum on Windows\r\n\r\nPlain"),
                      selection.text(in: terminal))
    }

    /// A real window with a real shell, in the order someone would try it. Exit code 0 if it all works.
    static func runWindow() -> Int32 {
        let results = CoreSelfTest.Results()
        guard TerminalWindow.prepare() else {
            print("  ✗ window class")
            return 1
        }
        var failure = ""
        guard let window = TerminalWindow(commandLine: PowerShellIntegration.commandLine(executable: "powershell.exe", loadProfile: false),
                                          activate: false, failure: &failure) else {
            print("  ✗ window: \(failure)")
            return 1
        }

        func hasLine(_ text: String) -> Bool { window.visibleText.contains("\n" + text) }
        struct Step {
            let name: String
            let action: () -> Void
            let done: () -> Bool
        }
        var widthBefore = 0
        let steps = [
            Step(name: "window: shell reaches its prompt", action: {}, done: { window.terminal.cwd != nil }),
            Step(name: "window: typing runs a command", action: {
                window.type("echo window-ok")
                window.pressEnter()
            }, done: { hasLine("window-ok") }),
            Step(name: "window: paste", action: {
                window.setClipboard("echo paste-ok")
                window.paste()
                window.pressEnter()
            }, done: { hasLine("paste-ok") }),
            Step(name: "window: a long-running program starts", action: {
                window.type("ping -t 127.0.0.1")
                window.pressEnter()
            }, done: { window.visibleText.contains("Reply from") || window.visibleText.contains("Pinging") }),
            Step(name: "window: Ctrl+C reaches the program", action: { window.type("\u{03}") },
                 // Ctrl+C throws away input already waiting, so wait for the prompt, as someone at the keyboard would.
                 done: { window.visibleText.contains("Control-C") && window.terminal.currentBlock?.state == .prompt }),
            Step(name: "window: the shell comes back after Ctrl+C", action: {
                window.type("echo after-ctrlc")
                window.pressEnter()
            }, done: { hasLine("after-ctrlc") }),
            Step(name: "window: resize reaches the emulator and the program", action: {
                widthBefore = window.terminal.cols
                window.resizeWindow(toCols: widthBefore - 20, rows: 25)
                window.type("echo ('width=' + $Host.UI.RawUI.WindowSize.Width)")
                window.pressEnter()
            }, done: { window.terminal.cols == widthBefore - 20 && hasLine("width=\(widthBefore - 20)") }),
            Step(name: "window: colors from a real program", action: {
                window.type("Write-Host hello -ForegroundColor Green; Write-Host '✦ unicode typed'")
                window.pressEnter()
            }, done: { hasLine("✦ unicode typed") }),
        ]

        var index = 0
        var deadline = Date().addingTimeInterval(45)
        steps[0].action()
        window.onTick = {
            guard index < steps.count else { return }
            let step = steps[index]
            let passed = step.done()
            guard passed || Date() > deadline else { return }
            results.check(step.name, passed, window.visibleText.suffix(600).description)
            index += 1
            guard index < steps.count else {
                results.check("window: painted", window.paints > 0, "\(window.paints)")
                if let canvas = Canvas(width: 1000, height: 640, fontPixels: 15) {
                    results.check("window: snapshot", snapshot(window.terminal, name: "window", canvas: canvas))
                }
                window.close()
                return
            }
            deadline = Date().addingTimeInterval(45)
            steps[index].action()
        }
        TerminalWindow.runLoop()
        return results.finish() && index == steps.count ? 0 : 1
    }
}
