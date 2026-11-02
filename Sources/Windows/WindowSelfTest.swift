import Foundation
import WinSDK

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
        let grid = TerminalRenderer.grid(width: 1000, height: 640, canvas: canvas)
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
        /// Selects text on the cursor's row by dragging over it.
        func select(_ text: String) {
            let row = window.cursorRowText
            guard let found = row.range(of: text) else { return }
            let col = row.distance(from: row.startIndex, to: found.lowerBound)
            window.drag(fromCol: col, toCol: col + text.count, row: window.terminal.cursorY)
        }
        /// Pasting reads the selection at once, so it waits for the posted drag to arrive first.
        var pasteSoon = false
        struct Step {
            let name: String
            let action: () -> Void
            let done: () -> Bool
        }
        var widthBefore = 0
        var steps = [
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
            Step(name: "window: output fills the screen", action: {
                window.type("1..60 | % { 'line ' + $_ }")
                window.pressEnter()
            }, done: { hasLine("line 60") && window.terminal.currentBlock?.state == .prompt }),
            Step(name: "window: shrinks", action: { window.resizeWindow(toCols: 90, rows: 12) },
                 done: { window.terminal.rows == 12 && !window.isSettlingResize }),
            Step(name: "window: grows again", action: { window.resizeWindow(toCols: 90, rows: 40) },
                 done: { window.terminal.rows == 40 && !window.isSettlingResize }),
            Step(name: "window: typing after resizing stays on the prompt", action: { window.type("claud") },
                 // Newer PSReadLine adds a suggestion from its history after what's typed.
                 done: { window.cursorRowText.hasPrefix("PS ") && window.cursorRowText.contains("> claud") }),
            Step(name: "window: resizing keeps scrollback", action: {},
                 done: { window.visibleText.contains("\nline 1\n") }),
            Step(name: "window: clears the line", action: { window.type("\u{1b}") },
                 done: { !window.cursorRowText.contains("claud") }),
            Step(name: "window: a command to click into", action: { window.type("echo abcdef") },
                 done: { window.cursorRowText.contains("echo abcdef") }),
            Step(name: "window: clicking moves the cursor there", action: {
                let promptEnd = window.cursorRowText.range(of: "echo abcdef")!.lowerBound
                let col = window.cursorRowText.distance(from: window.cursorRowText.startIndex, to: promptEnd) + "echo ab".count
                window.click(col: col, row: window.terminal.cursorY)
            }, done: { window.terminal.cursorX == window.cursorRowText.distance(from: window.cursorRowText.startIndex, to: window.cursorRowText.range(of: "echo abcdef")!.lowerBound) + "echo ab".count }),
            Step(name: "window: typing goes in at the click", action: {
                window.type("X")
                window.pressEnter()
            }, done: { hasLine("abXcdef") }),
            Step(name: "window: a command to edit", action: { window.type("echo mnopqr") },
                 done: { window.cursorRowText.contains("echo mnopqr") }),
            Step(name: "window: typing replaces the selection", action: {
                select("op")
                window.type("X")
            }, done: { window.cursorRowText.contains("echo mnXqr") }),
            Step(name: "window: Ctrl+Z undoes all of it", action: { window.type("\u{1a}") },
                 done: { window.cursorRowText.contains("echo mnopqr") }),
            Step(name: "window: Backspace deletes the selection", action: {
                select("op")
                window.pressBackspace()
            }, done: { window.cursorRowText.contains("echo mnqr") && !window.cursorRowText.contains("op") }),
            Step(name: "window: paste replaces the selection", action: {
                window.setClipboard("ZZ")
                select("qr")
                pasteSoon = true
            }, done: { window.cursorRowText.contains("echo mnZZ") }),
            Step(name: "window: the edited command runs", action: { window.pressEnter() },
                 done: { hasLine("mnZZ") }),
            Step(name: "window: colors from a real program", action: {
                window.type("Write-Host hello -ForegroundColor Green; Write-Host '✦ unicode typed'")
                window.pressEnter()
            }, done: { hasLine("✦ unicode typed") }),
        ]

        // Selections in a Claude Code-like input box. Each run starts it afresh, selects from the start of one word to
        // the end of another, does `act`, then leaves it, and it prints what's left of its text.
        let sampleText = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu pi rho sigma"
        var executable = [UInt16](repeating: 0, count: 1024)
        _ = GetModuleFileNameW(nil, &executable, DWORD(executable.count))
        let launch = "& '\(String(decodingCString: executable, as: UTF16.self))' --fake-agent \(sampleText)"
        func cell(of word: String) -> (col: Int, row: Int)? {
            for (row, line) in window.terminal.screen.enumerated() {
                let text = line.text()
                if let found = text.range(of: word) { return (text.distance(from: text.startIndex, to: found.lowerBound), row) }
            }
            return nil
        }
        func boxRun(_ name: String, from: String, through: String, act: @escaping () -> Void, leaves expected: String) {
            var acted = Date.distantFuture
            steps.append(Step(name: "box: \(name): starts", action: {
                window.type(launch)
                window.pressEnter()
            }, done: { cell(of: "❯ alpha") != nil && window.terminal.currentBlock?.state == .running }))
            steps.append(Step(name: "box: \(name): selects and acts", action: {
                guard let a = cell(of: from), let b = cell(of: through) else { return }
                window.drag(fromCol: a.col, fromRow: a.row, toCol: b.col + through.count, toRow: b.row)
                act()
                acted = Date()
            }, done: { Date().timeIntervalSince(acted) > 3 }))
            steps.append(Step(name: "box: \(name): leaves the right text", action: { window.pressEscape() },
                              done: { hasLine("final=" + expected) && window.terminal.currentBlock?.state == .prompt }))
        }
        boxRun("replace on one row", from: "gamma", through: "gamma", act: { window.type("X") },
               leaves: sampleText.replacingOccurrences(of: "gamma", with: "X"))
        boxRun("replace across two rows", from: "gamma", through: "iota", act: { window.type("X") },
               leaves: "alpha beta X kappa lambda mu nu pi rho sigma")
        boxRun("delete across two rows", from: "gamma", through: "iota", act: { window.pressBackspace() },
               leaves: "alpha beta  kappa lambda mu nu pi rho sigma")
        boxRun("delete across three rows", from: "epsilon", through: "rho", act: { window.pressBackspace() },
               leaves: "alpha beta gamma delta  sigma")

        var index = 0
        var deadline = Date().addingTimeInterval(45)
        steps[0].action()
        window.onTick = {
            guard index < steps.count else { return }
            if pasteSoon {
                pasteSoon = false
                window.paste()
            }
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
