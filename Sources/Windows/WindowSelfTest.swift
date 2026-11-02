import CCanvas
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

    static func runChrome(_ results: CoreSelfTest.Results) {
        print("Window layout")
        results.check("app: has its icon", LoadIconW(GetModuleHandleW(nil), Win.appIcon) != nil)
        let layout = WindowLayout(width: 1000, height: 640, scale: 1, tabCount: 3)
        results.check("layout: window buttons at the right end", layout.close.maxX == 1000 && layout.maximize.maxX == layout.close.x && layout.minimize.maxX == layout.maximize.x)
        results.check("layout: tabs clear of the + button", layout.tab(2).maxX <= layout.newTab.x)
        results.check("layout: the + button follows the last tab", layout.newTab.x == layout.tab(2).maxX + 6)
        let crowded = WindowLayout(width: 1000, height: 640, scale: 1, tabCount: 12)
        results.check("layout: the + button is level with the tabs' x", abs(layout.newTab.midY - layout.tabClose(1).midY) <= 0.5,
                      "\(layout.newTab.midY) \(layout.tabClose(1).midY)")
        results.check("layout: and stays clear of the flower", crowded.newTab.maxX <= crowded.flower.x)
        results.check("layout: the terminal is between the bars", layout.terminal.y == layout.tabBarHeight && layout.terminal.maxY == layout.statusBar.y)
        results.check("layout: finds a tab", layout.part(atX: layout.tab(1).x + 20, y: 20) == .tab(1))
        results.check("layout: finds its close button", layout.part(atX: layout.tabClose(1).x + 5, y: layout.tabClose(1).y + 5) == .tabClose(1))
        results.check("layout: finds the window buttons", layout.part(atX: 990, y: 10) == .close && layout.part(atX: layout.maximize.x + 2, y: 10) == .maximize && layout.part(atX: layout.minimize.x + 2, y: 10) == .minimize)
        results.check("layout: the rest of the bar drags", WindowLayout(width: 1800, height: 640, scale: 1, tabCount: 2).part(atX: 1000, y: 10) == .titleBar)
        results.check("layout: below the bars is the terminal", layout.part(atX: 500, y: 300) == .terminal && layout.part(atX: 500, y: 630) == .statusBar)
        results.check("layout: many tabs still fit", WindowLayout(width: 1000, height: 640, scale: 2, tabCount: 4).tabWidth >= 144)
        let many = WindowLayout(width: 1000, height: 640, scale: 1, tabCount: 20, tabScroll: 300)
        results.check("overflow: the arrows, tabs and + don't overlap", many.overflows && many.scrollLeft.maxX <= many.tabViewport.x
                      && many.tabViewport.maxX <= many.scrollRight.x && many.scrollRight.maxX <= many.newTab.x && many.newTab.maxX <= many.flower.x)
        results.check("overflow: + stays beside the flower, not over the buttons", many.flower.maxX <= many.minimize.x)
        results.check("overflow: finds the arrows", many.part(atX: many.scrollLeft.x + 2, y: 20) == .scrollLeft && many.part(atX: many.scrollRight.x + 2, y: 20) == .scrollRight)
        results.check("overflow: tabs out of view can't be clicked", WindowLayout(width: 1000, height: 640, scale: 1, tabCount: 20).part(atX: many.newTab.x + 2, y: 20) == .newTab)
        results.check("overflow: a tab in view can", many.part(atX: many.tabViewport.x + 40, y: 20) != .titleBar)
        results.check("overflow: scrolls to show a tab past the end", WindowLayout(width: 1000, height: 640, scale: 1, tabCount: 20).scroll(showing: 19) == many.maxTabScroll)
        results.check("overflow: and back to the first", many.scroll(showing: 0) == 0)
        results.check("overflow: not when they fit", !WindowLayout(width: 1000, height: 640, scale: 1, tabCount: 3).overflows)
        results.check("layout: scales with the display", WindowLayout(width: 1000, height: 640, scale: 2, tabCount: 1).tabBarHeight == 76)
        results.check("text: home is ~", WindowText.crumbs(#"C:\Users\me\Projects\Solanum"#, home: #"C:\Users\me"#) == ["~", "Projects", "Solanum"])
        results.check("text: not home", WindowText.crumbs(#"C:\Users\medium"#, home: #"C:\Users\me"#) == ["C:", "Users", "medium"])
        results.check("text: a program's title is the tab's", WindowText.tabTitle(title: "vim notes.txt", folder: #"C:\x"#, home: nil) == "vim notes.txt")
        results.check("text: a shell's own path isn't", WindowText.tabTitle(title: #"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"#, folder: #"C:\Users\me\Solanum"#, home: #"C:\Users\me"#) == "Solanum")
        results.check("text: nor as administrator", WindowText.tabTitle(title: #"Administrator: C:\Windows\system32\cmd.exe"#, folder: #"C:\Users\me"#, home: #"C:\Users\me"#) == "~")

        guard let canvas = Canvas(width: 1200, height: 420, fontPixels: 15) else { return }
        let bars = WindowLayout(width: 1200, height: 420, scale: 1, tabCount: 5)
        canvas.terminalArea = bars.terminal
        let grid = TerminalRenderer.grid(width: 1200, height: 420, canvas: canvas)
        let terminal = Terminal(cols: grid.cols, rows: grid.rows, scrollbackLimit: 100)
        Array("PS C:\\Users\\dev\\Projects\\Solanum> ".utf8).withUnsafeBufferPointer { terminal.feed($0) }
        guard sol_canvas_begin(canvas.raw, TerminalPalette.background) >= 0 else { return }
        var chrome = WindowChrome(canvas: canvas, layout: bars, tabs: ["~", "Solanum", "docs", "tests", "a long tab title that has to be cut short somewhere"], activeTab: 2)
        chrome.folder = #"C:\Users\dev\Projects\Solanum"#
        chrome.home = #"C:\Users\dev"#
        chrome.draw()
        TerminalRenderer(canvas: canvas, terminal: terminal).drawContents()
        results.check("chrome: draws", sol_canvas_end(canvas.raw) >= 0)
        if let dir = snapshotDirectory {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            results.check("chrome: saves", canvas.savePNG(to: dir + "\\chrome.png"))
        }
        var crowded = WindowLayout(width: 1200, height: 420, scale: 1, tabCount: 22)
        crowded.tabScroll = crowded.scroll(showing: 15)
        guard sol_canvas_begin(canvas.raw, TerminalPalette.background) >= 0 else { return }
        WindowChrome(canvas: canvas, layout: crowded, tabs: (1...22).map { "tab \($0)" }, activeTab: 15).draw()
        results.check("chrome: draws with too many tabs", sol_canvas_end(canvas.raw) >= 0)
        if let dir = snapshotDirectory { results.check("chrome: saves that too", canvas.savePNG(to: dir + "\\chrome-overflow.png")) }
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

        var pane: TerminalPane { window.activePane }
        func hasLine(_ text: String) -> Bool { pane.visibleText.contains("\n" + text) }
        /// Selects text on the cursor's row by dragging over it.
        func select(_ text: String) {
            let row = pane.cursorRowText
            guard let found = row.range(of: text) else { return }
            let col = row.distance(from: row.startIndex, to: found.lowerBound)
            pane.drag(fromCol: col, toCol: col + text.count, row: pane.terminal.cursorY)
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
            Step(name: "window: shell reaches its prompt", action: {}, done: { pane.terminal.cwd != nil }),
            Step(name: "window: typing runs a command", action: {
                pane.type("echo window-ok")
                pane.pressEnter()
            }, done: { hasLine("window-ok") }),
            Step(name: "window: paste", action: {
                pane.setClipboard("echo paste-ok")
                pane.paste()
                pane.pressEnter()
            }, done: { hasLine("paste-ok") }),
            Step(name: "window: a long-running program starts", action: {
                pane.type("ping -t 127.0.0.1")
                pane.pressEnter()
            }, done: { pane.visibleText.contains("Reply from") || pane.visibleText.contains("Pinging") }),
            Step(name: "window: Ctrl+C reaches the program", action: { pane.type("\u{03}") },
                 // Ctrl+C throws away input already waiting, so wait for the prompt, as someone at the keyboard would.
                 done: { pane.visibleText.contains("Control-C") && pane.terminal.currentBlock?.state == .prompt }),
            Step(name: "window: the shell comes back after Ctrl+C", action: {
                pane.type("echo after-ctrlc")
                pane.pressEnter()
            }, done: { hasLine("after-ctrlc") }),
            Step(name: "window: resize reaches the emulator and the program", action: {
                widthBefore = pane.terminal.cols
                window.resizeWindow(toCols: widthBefore - 20, rows: 25)
                pane.type("echo ('width=' + $Host.UI.RawUI.WindowSize.Width)")
                pane.pressEnter()
            }, done: { pane.terminal.cols == widthBefore - 20 && hasLine("width=\(widthBefore - 20)") }),
            Step(name: "window: output fills the screen", action: {
                pane.type("1..60 | % { 'line ' + $_ }")
                pane.pressEnter()
            }, done: { hasLine("line 60") && pane.terminal.currentBlock?.state == .prompt }),
            Step(name: "window: shrinks", action: { window.resizeWindow(toCols: 90, rows: 12) },
                 done: { pane.terminal.rows == 12 && !pane.isSettlingResize }),
            Step(name: "window: grows again", action: { window.resizeWindow(toCols: 90, rows: 40) },
                 done: { pane.terminal.rows == 40 && !pane.isSettlingResize }),
            Step(name: "window: typing after resizing stays on the prompt", action: { pane.type("claud") },
                 // Newer PSReadLine adds a suggestion from its history after what's typed.
                 done: { pane.cursorRowText.hasPrefix("PS ") && pane.cursorRowText.contains("> claud") }),
            Step(name: "window: resizing keeps scrollback", action: {},
                 done: { pane.visibleText.contains("\nline 1\n") }),
            Step(name: "window: clears the line", action: { pane.type("\u{1b}") },
                 done: { !pane.cursorRowText.contains("claud") }),
            Step(name: "window: a command to click into", action: { pane.type("echo abcdef") },
                 done: { pane.cursorRowText.contains("echo abcdef") }),
            Step(name: "window: clicking moves the cursor there", action: {
                let promptEnd = pane.cursorRowText.range(of: "echo abcdef")!.lowerBound
                let col = pane.cursorRowText.distance(from: pane.cursorRowText.startIndex, to: promptEnd) + "echo ab".count
                pane.click(col: col, row: pane.terminal.cursorY)
            }, done: { pane.terminal.cursorX == pane.cursorRowText.distance(from: pane.cursorRowText.startIndex, to: pane.cursorRowText.range(of: "echo abcdef")!.lowerBound) + "echo ab".count }),
            Step(name: "window: typing goes in at the click", action: {
                pane.type("X")
                pane.pressEnter()
            }, done: { hasLine("abXcdef") }),
            Step(name: "window: a command to edit", action: { pane.type("echo mnopqr") },
                 done: { pane.cursorRowText.contains("echo mnopqr") }),
            Step(name: "window: typing replaces the selection", action: {
                select("op")
                pane.type("X")
            }, done: { pane.cursorRowText.contains("echo mnXqr") }),
            Step(name: "window: Ctrl+Z undoes all of it", action: { pane.type("\u{1a}") },
                 done: { pane.cursorRowText.contains("echo mnopqr") }),
            Step(name: "window: Backspace deletes the selection", action: {
                select("op")
                pane.pressBackspace()
            }, done: { pane.cursorRowText.contains("echo mnqr") && !pane.cursorRowText.contains("op") }),
            Step(name: "window: paste replaces the selection", action: {
                pane.setClipboard("ZZ")
                select("qr")
                pasteSoon = true
            }, done: { pane.cursorRowText.contains("echo mnZZ") }),
            Step(name: "window: the edited command runs", action: { pane.pressEnter() },
                 done: { hasLine("mnZZ") }),
            Step(name: "keys: a command for the clipboard keys", action: { pane.type("echo uvwxyz") },
                 done: { pane.cursorRowText.contains("echo uvwxyz") }),
            Step(name: "keys: Ctrl+C copies a selection and clears it", action: {
                pane.setClipboard("nothing yet")
                select("vwx")
            }, done: {
                guard pane.hasSelection else { return false }
                _ = pane.keyDown(0x43, shift: false, ctrl: true, alt: false)
                return pane.clipboardText() == "vwx" && !pane.hasSelection
            }),
            Step(name: "keys: Ctrl+C with a selection doesn't interrupt", action: {},
                 done: { pane.cursorRowText.contains("echo uvwxyz") }),
            Step(name: "keys: Ctrl+V pastes", action: {
                pane.setClipboard("-pasted")
                _ = pane.keyDown(0x56, shift: false, ctrl: true, alt: false)
            }, done: { pane.cursorRowText.contains("uvwxyz-pasted") }),
            Step(name: "keys: Ctrl+X cuts a selection", action: { select("-pasted") }, done: {
                guard pane.hasSelection else { return false }
                _ = pane.keyDown(0x58, shift: false, ctrl: true, alt: false)
                return true
            }),
            Step(name: "keys: and it's on the clipboard, gone from the line", action: {},
                 done: { pane.clipboardText() == "-pasted" && !pane.cursorRowText.contains("-pasted") }),
            Step(name: "keys: Ctrl+C with nothing selected interrupts", action: {
                _ = pane.keyDown(0x43, shift: false, ctrl: true, alt: false)
                pane.type("\u{03}")
            }, done: { !pane.cursorRowText.contains("uvwxyz") && pane.cursorRowText.hasPrefix("PS ") }),
            Step(name: "window: colors from a real program", action: {
                pane.type("Write-Host hello -ForegroundColor Green; Write-Host '✦ unicode typed'")
                pane.pressEnter()
            }, done: { hasLine("✦ unicode typed") }),
        ]

        // Selections in a Claude Code-like input box. Each run starts it afresh, selects from the start of one word to
        // the end of another, does `act`, then leaves it, and it prints what's left of its text.
        let sampleText = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu pi rho sigma"
        var executable = [UInt16](repeating: 0, count: 1024)
        _ = GetModuleFileNameW(nil, &executable, DWORD(executable.count))
        let launch = "& '\(String(decodingCString: executable, as: UTF16.self))' --fake-agent \(sampleText)"
        func cell(of word: String) -> (col: Int, row: Int)? {
            for (row, line) in pane.terminal.screen.enumerated() {
                let text = line.text()
                if let found = text.range(of: word) { return (text.distance(from: text.startIndex, to: found.lowerBound), row) }
            }
            return nil
        }
        func boxRun(_ name: String, from: String, through: String, act: @escaping () -> Void, leaves expected: String) {
            var acted = Date.distantFuture
            steps.append(Step(name: "box: \(name): starts", action: {
                pane.type(launch)
                pane.pressEnter()
            }, done: { cell(of: "❯ alpha") != nil && pane.terminal.currentBlock?.state == .running }))
            steps.append(Step(name: "box: \(name): selects and acts", action: {
                guard let a = cell(of: from), let b = cell(of: through) else { return }
                pane.drag(fromCol: a.col, fromRow: a.row, toCol: b.col + through.count, toRow: b.row)
                act()
                acted = Date()
            }, done: { Date().timeIntervalSince(acted) > 3 }))
            steps.append(Step(name: "box: \(name): leaves the right text", action: { pane.pressEscape() },
                              done: { hasLine("final=" + expected) && pane.terminal.currentBlock?.state == .prompt }))
        }
        // Tabs. Each has its own shell, and what's typed goes to the one on screen.
        steps.append(Step(name: "tabs: the + button opens one", action: { window.click(window.currentLayout.newTab) },
                          done: { window.panes.count == 2 && window.activeIndex == 1 && pane.terminal.cwd != nil }))
        steps.append(Step(name: "tabs: typing goes to the new tab", action: {
            pane.type("echo in-tab-two")
            pane.pressEnter()
        }, done: { hasLine("in-tab-two") }))
        steps.append(Step(name: "tabs: clicking a tab shows it", action: { window.click(window.currentLayout.tab(0)) },
                          done: { window.activeIndex == 0 && !pane.visibleText.contains("in-tab-two") }))
        steps.append(Step(name: "tabs: a command starts in the second tab", action: {
            window.selectTab(1)
            pane.type("Start-Sleep 2; echo background-done")
            pane.pressEnter()
        }, done: { window.panes[1].terminal.currentBlock?.state == .running }))
        steps.append(Step(name: "tabs: it keeps running behind another", action: { window.selectTab(0) },
                          done: { window.activeIndex == 0 && window.panes[1].visibleText.contains("\nbackground-done") }))
        steps.append(Step(name: "tabs: all of them resize", action: { window.resizeWindow(toCols: 100, rows: 30) },
                          done: { window.panes[0].terminal.cols == 100 && window.panes[1].terminal.cols == 100 }))
        func press(_ key: Int32, shift: Bool = false) { _ = window.keyDown(key, shift: shift, ctrl: true, alt: false) }
        steps.append(Step(name: "tabs: Ctrl+T opens one at a prompt", action: { press(0x54) },
                          done: { window.panes.count == 3 && pane.atPrompt }))
        steps.append(Step(name: "tabs: a program starts in it", action: {
            pane.type(launch)
            pane.pressEnter()
        }, done: { cell(of: "❯ alpha") != nil && pane.terminal.currentBlock?.state == .running }))
        steps.append(Step(name: "tabs: Ctrl+T opens one from a program too", action: { press(0x54) },
                          done: { window.panes.count == 4 && window.activeIndex == 3 && pane.atPrompt }))
        steps.append(Step(name: "tabs: Ctrl+W closes one at a prompt", action: { press(0x57) },
                          done: { window.panes.count == 3 && window.activeIndex == 2 }))
        steps.append(Step(name: "tabs: Ctrl+W closes one with a program running", action: { press(0x57) },
                          done: { window.panes.count == 2 }))
        let folder = ProcessInfo.processInfo.environment["SystemRoot"] ?? #"C:\Windows"#
        steps.append(Step(name: "reopen: a tab with a folder and some output", action: { window.newTab() },
                          done: { window.panes.count == 3 && pane.atPrompt }))
        steps.append(Step(name: "reopen: it gets them", action: {
            pane.type("cd '\(folder)'; echo reopen-marker")
            pane.pressEnter()
        }, done: { hasLine("reopen-marker") && pane.terminal.cwd?.lowercased() == folder.lowercased() && pane.atPrompt }))
        steps.append(Step(name: "reopen: closed", action: { window.selectTab(0); window.selectTab(2); press(0x57) },
                          done: { window.panes.count == 2 }))
        steps.append(Step(name: "reopen: Ctrl+Shift+T brings it back", action: { press(0x54, shift: true) }, done: {
            window.panes.count == 3 && window.activeIndex == 2 && pane.atPrompt
                && pane.terminal.cwd?.lowercased() == folder.lowercased()
        }))
        steps.append(Step(name: "reopen: with what it showed", action: {}, done: { hasLine("reopen-marker") }))
        steps.append(Step(name: "reopen: typing works in it", action: {
            pane.type("echo after-reopen")
            pane.pressEnter()
        }, done: { hasLine("after-reopen") }))
        steps.append(Step(name: "tabs: Ctrl+Shift+W closes one too", action: { press(0x57, shift: true) },
                          done: { window.panes.count == 2 }))
        steps.append(Step(name: "overflow: opening tabs past what fits", action: {}, done: {
            if !window.currentLayout.overflows { window.newTab() }
            return window.currentLayout.overflows && pane.atPrompt
        }))
        steps.append(Step(name: "overflow: the new tab is in view", action: {}, done: {
            let l = window.currentLayout, r = l.tab(window.activeIndex)
            return r.x >= l.tabViewport.x && r.maxX <= l.tabViewport.maxX
        }))
        steps.append(Step(name: "overflow: the left arrow scrolls", action: { window.click(window.currentLayout.scrollLeft) },
                          done: { window.currentLayout.tabScroll < window.currentLayout.maxTabScroll }))
        steps.append(Step(name: "overflow: closing them ends it", action: {}, done: {
            if window.panes.count > 2 && pane.atPrompt { press(0x57) }
            return window.panes.count == 2 && !window.currentLayout.overflows && window.currentLayout.tabScroll == 0
        }))
        steps.append(Step(name: "tabs: titled by folder, not the shell's path", action: {},
                          done: { !window.panes[1].tabTitle.contains(".exe") && !window.panes[1].tabTitle.isEmpty }))
        steps.append(Step(name: "tabs: exit closes only its tab", action: {
            window.selectTab(1)
            pane.type("exit")
            pane.pressEnter()
        }, done: { window.panes.count == 1 && window.activeIndex == 0 }))
        steps.append(Step(name: "tabs: the x closes one", action: {
            window.newTab()
            window.click(window.currentLayout.tabClose(1))
        }, done: { window.panes.count == 1 }))

        boxRun("replace on one row", from: "gamma", through: "gamma", act: { pane.type("X") },
               leaves: sampleText.replacingOccurrences(of: "gamma", with: "X"))
        boxRun("replace across two rows", from: "gamma", through: "iota", act: { pane.type("X") },
               leaves: "alpha beta X kappa lambda mu nu pi rho sigma")
        boxRun("delete across two rows", from: "gamma", through: "iota", act: { pane.pressBackspace() },
               leaves: "alpha beta  kappa lambda mu nu pi rho sigma")
        boxRun("delete across three rows", from: "epsilon", through: "rho", act: { pane.pressBackspace() },
               leaves: "alpha beta gamma delta  sigma")

        var index = 0
        var deadline = Date().addingTimeInterval(45)
        steps[0].action()
        window.onTick = {
            guard index < steps.count else { return }
            if pasteSoon {
                pasteSoon = false
                pane.paste()
            }
            let step = steps[index]
            let passed = step.done()
            guard passed || Date() > deadline else { return }
            results.check(step.name, passed, pane.visibleText.suffix(600).description)
            index += 1
            guard index < steps.count else {
                results.check("window: painted", window.paints > 0, "\(window.paints)")
                if let dir = snapshotDirectory {
                    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                    results.check("window: snapshot", window.saveSnapshot(to: dir + "\\window.png"))
                }
                window.close()
                return
            }
            deadline = Date().addingTimeInterval(25)
            steps[index].action()
        }
        TerminalWindow.runLoop()
        print("Clipboard found busy \(TerminalPane.clipboardBusyCount) times; got through \(index) of \(steps.count) steps.")
        return results.finish() && index == steps.count ? 0 : 1
    }
}
