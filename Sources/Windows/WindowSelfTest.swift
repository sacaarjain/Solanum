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
        print("Custom themes")
        let mac = ThemeFiles.parse(Data(##"{"background":"#101010","foreground":"#EEEEEE","ansi":["#000000","#FF0000","#00FF00","#FFFF00","#0000FF","#FF00FF","#00FFFF","#FFFFFF"]}"##.utf8),
                                   fallbackName: "my-theme")
        results.check("themes: a Mac file without a name takes its file's", mac?.name == "my-theme")
        results.check("themes: and blue for an accent, as the Mac does", mac?.accent == "#0000FF")
        let windowsTerminal = ThemeFiles.parse(Data(##"{"name":"Campbell","background":"#0C0C0C","foreground":"#CCCCCC","black":"#0C0C0C","red":"#C50F1F","green":"#13A10E","yellow":"#C19C00","blue":"#0037DA","purple":"#881798","cyan":"#3A96DD","white":"#CCCCCC","brightBlack":"#767676","brightRed":"#E74856","brightGreen":"#16C60C","brightYellow":"#F9F1A5","brightBlue":"#3B78FF","brightPurple":"#B4009E","brightCyan":"#61D6D6","brightWhite":"#F2F2F2","cursorColor":"#FFFFFF","selectionBackground":"#FFFFFF"}"##.utf8),
                                        fallbackName: "x")
        results.check("themes: a Windows Terminal scheme reads", windowsTerminal?.name == "Campbell" && windowsTerminal?.ansi.count == 16 && windowsTerminal?.ansi[9] == "#E74856")
        let vsCode = ThemeFiles.parse(Data("""
            {
              // VS Code allows comments
              "name": "Night Owl",
              "colors": {
                "editor.background": "#011627",
                "editor.foreground": "#d6deebff", /* and these */
                "terminal.ansiRed": "#EF5350",
              },
            }
            """.utf8), fallbackName: "x")
        results.check("themes: a VS Code theme reads, comments, trailing commas and all", vsCode?.name == "Night Owl" && vsCode?.background == "#011627"
                      && vsCode?.foreground == "#d6deeb")
        results.check("themes: a file that isn't a theme is left out", ThemeFiles.parse(Data(##"{"hello":"there"}"##.utf8), fallbackName: "x") == nil)
        if let mac, let back = ThemeFiles.parse(ThemeFiles.json(mac), fallbackName: "y") {
            results.check("themes: what Solanum writes reads back the same", back.name == mac.name && back.background == mac.background && back.ansi.count == 16)
        } else {
            results.check("themes: what Solanum writes reads back the same", false)
        }
        // A table copied for Word and Excel: the clipboard's HTML header says where everything starts and ends, in bytes.
        let wrapped = TerminalPane.clipboardHTML("<table><tr><td>é</td></tr></table>"), bytes = Array(wrapped.utf8)
        func at(_ key: String) -> Int { Int(wrapped.components(separatedBy: key + ":")[1].prefix(10)) ?? -1 }
        let fragment = String(decoding: bytes[at("StartFragment")..<at("EndFragment")], as: UTF8.self)
        results.check("code boxes: HTML on the clipboard as Windows wants it", fragment == "<table><tr><td>é</td></tr></table>" && at("EndHTML") == bytes.count, fragment)

        // An open file keeping up with the disk, as on the Mac: read here from a file kept in memory.
        var disk = Data("one\ntwo\n".utf8), stamp = 1
        let panel = FileEditorPanel(path: "C:\\notes.txt", name: "notes.txt", folder: "C:\\", isLocal: true, read: { _, done in done(disk, false) },
                                    write: { data, done in disk = data; stamp += 1; done(nil) }, signature: { done in done(true, "\(stamp)") })
        panel.reload()
        disk = Data("one\ntwo\nthree\n".utf8); stamp += 1
        panel.syncNowForTesting()
        results.check("live files: a change on disk shows", panel.textLines == ["one", "two", "three", ""])
        panel.typeForTesting("X")
        disk = Data("ONE\n".utf8); stamp += 1
        panel.syncNowForTesting()
        results.check("live files: unsaved edits stay, and say it changed on disk", panel.changedOnDisk && panel.textLines?.first == "Xone")
        panel.save()
        results.check("live files: saving over a change asks first", panel.hasConflict && disk == Data("ONE\n".utf8))
        panel.pressConflict("Overwrite")
        results.check("live files: Overwrite saves the edits", !panel.hasConflict && String(decoding: disk, as: UTF8.self).hasPrefix("Xone") && !panel.changedOnDisk)
        panel.press(button: .tail)
        results.check("live files: Tail File", panel.tailing)

        // Two editors on one real file, as when a file shown above the terminal is also opened in a tab: one saves, the
        // other catches up. Through the window's own reading and writing, each panel's work on one queue as on its thread.
        do {
            let dir = NSTemporaryDirectory() + "solanum-two-editors-\(GetCurrentProcessId())"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let path = (dir + "/late.txt").replacingOccurrences(of: "/", with: "\\")
            _ = FileManager.default.createFile(atPath: path, contents: Data("first line\nsecond line\n".utf8))
            // What the panels post for the window's thread, run here in turn.
            final class Pending: @unchecked Sendable {
                let lock = NSLock()
                var work: [() -> Void] = []
                func add(_ w: @escaping () -> Void) { lock.lock(); work.append(w); lock.unlock() }
                func drain() {
                    while true {
                        lock.lock()
                        let next = work.isEmpty ? nil : work.removeFirst()
                        lock.unlock()
                        guard let next else { return }
                        next()
                    }
                }
            }
            let pending = Pending()
            func make() -> FileEditorPanel {
                let p = FileEditorPanel(path: path, name: "late.txt", folder: dir, isLocal: true,
                                        read: { limit, done in TerminalWindow.readLocal(path, limit: limit, done) },
                                        write: { data, done in TerminalWindow.writeLocal(path, data, done) },
                                        signature: { done in TerminalWindow.localSignature(path, done) },
                                        readFrom: { offset, done in TerminalWindow.readLocal(path, from: offset, done) })
                p.post = { work in pending.add(work) }
                p.reload()
                return p
            }
            func wait(_ seconds: Double = 8, _ cond: () -> Bool) -> Bool {
                let end = Date().addingTimeInterval(seconds)
                while Date() < end {
                    pending.drain()
                    if cond() { return true }
                    Thread.sleep(forTimeInterval: 0.1)
                }
                pending.drain()
                return cond()
            }
            let shown = make(), opened = make()
            let read = wait { shown.textLines?.first == "first line" && opened.textLines?.first == "first line" }
            opened.typeForTesting("hi ")
            opened.save()
            let saved = wait { opened.hasUnsavedChanges == false && ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").hasPrefix("hi first") }
            // The other looks at the disk about once a second, from the window's timer.
            let caughtUp = wait {
                shown.syncNowForTesting()
                return shown.textLines?.first == "hi first line"
            }
            results.check("live files: one real file in two editors, one saves and the other catches up", read && saved && caughtUp,
                          "read=\(read) saved=\(saved) other=\(shown.textLines?.first ?? "nil")")
            try? FileManager.default.removeItem(atPath: dir)
        }

        // Agents on the PATH (an .exe, or npm's .cmd shim), for Send to Chat's new chats; and what continues one on restore.
        do {
            let dir = NSTemporaryDirectory() + "solanum-agents-\(GetCurrentProcessId())"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            _ = FileManager.default.createFile(atPath: dir + "\\claude.cmd", contents: Data())
            _ = FileManager.default.createFile(atPath: dir + "\\codex.exe", contents: Data())
            let found = InstalledAgents.scan(path: dir + ";C:\\nowhere")
            results.check("chat: agents on the PATH, by their .exe or npm's .cmd", found == [.claude, .codex], "\(found.map(\.command))")
            try? FileManager.default.removeItem(atPath: dir)
            let s = AppSettings.shared
            let was = (s.file["continue-agents"], s.file["continue-command-claude"])
            s.setForTesting("continue-command-claude", "claude --resume")
            let custom = s.continueCommand(forAgent: "claude"), codex = s.continueCommand(forAgent: "codex")
            s.setForTesting("continue-command-claude", "")
            let skipped = s.continueCommand(forAgent: "claude")
            s.setForTesting("continue-agents", "false")
            let off = s.continueCommand(forAgent: "codex")
            s.setForTesting("continue-agents", was.0 ?? "true")
            s.setForTesting("continue-command-claude", was.1 ?? "")
            if was.1 == nil { s.forgetForTesting("continue-command-claude") }
            results.check("continue: an agent's own command, its default, left out when empty, none when off",
                          custom == "claude --resume" && codex == "codex resume --last" && skipped == nil && off == nil)
        }

        // Keep Awake's time left, as the status bar shows it.
        results.check("keep awake: time left to the minute", KeepAwake.shortDuration(28_800) == "8h" && KeepAwake.shortDuration(28_799) == "8h"
                      && KeepAwake.shortDuration(28_740) == "7h 59m" && KeepAwake.shortDuration(2_700) == "45m" && KeepAwake.shortDuration(30) == "30s")

        // Find and replace in a file, as the Mac's ⌘F (Core's EditorFind).
        var findDisk = Data("Cat cat concat\ncat.dog (cat)\nline three\n".utf8)
        let found = FileEditorPanel(path: "C:\\find.txt", name: "find.txt", folder: "C:\\", isLocal: true, read: { _, done in done(findDisk, false) },
                                    write: { data, done in findDisk = data; done(nil) })
        found.reload()
        FileEditorPanel.findOptions = EditorFindOptions()
        _ = found.key(0x46, shift: false, ctrl: true)
        "cat".forEach { found.typed(String($0)) }
        results.check("find: Ctrl+F and typing finds every match, the first current", found.findStateForTesting == "1 of 5 current='Cat'" && found.findFocused,
                      found.findStateForTesting ?? "closed")
        _ = found.key(Win.VK_RETURN, shift: false, ctrl: false)
        _ = found.key(Win.VK_RETURN, shift: true, ctrl: false)
        _ = found.key(0x72, shift: true, ctrl: false)
        results.check("find: Enter steps on, Shift+Enter and Shift+F3 back round", found.findStateForTesting == "5 of 5 current='cat'", found.findStateForTesting ?? "")
        _ = found.findAltKey(0x43)
        results.check("find: Alt+C matches case", found.findStateForTesting?.hasSuffix("of 4 current='cat'") == true, found.findStateForTesting ?? "")
        _ = found.findAltKey(0x57)
        results.check("find: Alt+W whole words", found.findStateForTesting?.contains(" of 3 ") == true, found.findStateForTesting ?? "")
        _ = found.findAltKey(0x43)
        _ = found.findAltKey(0x57)
        _ = found.findAltKey(0x52)
        _ = found.key(Win.VK_BACK, shift: false, ctrl: true)
        "c.t".forEach { found.typed(String($0)) }
        results.check("find: Alt+R as a regular expression", found.findStateForTesting?.contains(" of 5 ") == true, found.findStateForTesting ?? "")
        "(".forEach { found.typed(String($0)) }
        results.check("find: a regular expression that doesn't parse says so", found.findStateForTesting?.hasSuffix(" bad") == true, found.findStateForTesting ?? "")
        _ = found.key(Win.VK_BACK, shift: false, ctrl: false)
        _ = found.findAltKey(0x52)
        _ = found.key(Win.VK_BACK, shift: false, ctrl: true)
        "cat".forEach { found.typed(String($0)) }
        // Ctrl+F again starts from the caret, at the top.
        _ = found.key(0x46, shift: false, ctrl: true)
        found.setReplaceForTesting("dog")
        found.replaceForTesting(all: false)
        results.check("find: Replace changes the current match and goes on to the next", found.textLines?.first == "dog cat concat"
                      && found.findStateForTesting == "1 of 4 current='cat'", "\(found.textLines?.first ?? "") \(found.findStateForTesting ?? "")")
        found.replaceForTesting(all: true)
        results.check("find: Replace All", found.textLines == ["dog dog condog", "dog.dog (dog)", "line three", ""], "\(found.textLines ?? [])")
        _ = found.key(0x5A, shift: false, ctrl: true)
        results.check("find: Ctrl+Z undoes Replace All in one step", found.textLines?.first == "dog cat concat", found.textLines?.first ?? "")
        _ = found.key(Win.VK_ESCAPE, shift: false, ctrl: false)
        results.check("find: Esc closes it, the match selected", found.findStateForTesting == nil && found.selectedText == "cat", found.selectedText ?? "nothing")
        found.reveal(line: 2, text: "DOG")
        results.check("search: a result opens with its query selected on its line", found.selectedText == "dog" && found.caretForTesting().line == 1)

        // A log, colored as on the Mac (Core's LogFormat): color codes hidden and shown, an error's line tinted.
        let esc = "\u{1b}"
        let logText = "2026-11-08 10:00:01 \(esc)[31mERROR\(esc)[0m app.Db - query failed\n    at app.Db.run(Db.java:42)\n2026-11-08 10:00:02 INFO app.Main - fine\n"
        let log = FileEditorPanel(path: "C:\\app.txt", name: "app.txt", folder: "C:\\", isLocal: true, read: { _, done in done(Data(logText.utf8), false) },
                                  write: { _, done in done(nil) })
        log.reload()
        results.check("logs: a file with color codes is a log, whatever it's called", log.language == .log && log.hidesEscapes)
        results.check("logs: the color codes take no room", log.shownForTesting(0) == "2026-11-08 10:00:01 ERROR app.Db - query failed", log.shownForTesting(0))
        let red = TerminalPalette.indexed(1)
        let errorCell = log.logLookForTesting(line: 0, cell: 20)
        results.check("logs: shown in the colors they ask for, the line tinted", errorCell?.color == red && errorCell?.wash == red,
                      "\(errorCell.map { "\($0)" } ?? "none")")
        results.check("logs: a stack trace's line takes its error's tint", log.logLookForTesting(line: 1, cell: 4)?.wash == red)
        results.check("logs: an info line isn't tinted", log.logLookForTesting(line: 2, cell: 0)?.wash == nil)
        let logMenu = log.logMenuForTesting().map(\.title)
        results.check("logs: the palette's menu picks the format and the colors", logMenu.contains("Automatic (Built-in)") && logMenu.contains("Levels  \u{203A}")
                      && logMenu.contains("Add Marker\u{2026}") && logMenu.contains("Import Log Format\u{2026}"), "\(logMenu)")
        _ = log.key(Win.VK_HOME, shift: false, ctrl: true)
        for _ in 0..<21 { _ = log.key(Win.VK_RIGHT, shift: false, ctrl: false) }
        results.check("logs: the caret steps over a hidden color code as nothing", log.caretForTesting().col == 26, "\(log.caretForTesting().col)")

        let roundTrip = ["#A584E8", "#111312", "#FFFFFF", "#000000", "#E3573F", "#56F0B4"].allSatisfy { HSVColor(HexColor($0)!).hex == $0 }
        results.check("theme editor: a color through hue, saturation and brightness comes back the same", roundTrip)
        results.check("theme editor: hex typed in reads as Solanum writes it", ColorPicker.parse("a5e", allowsAlpha: false) == "#AA55EE"
                      && ColorPicker.parse("#A584E84D", allowsAlpha: true) == "#A584E84D" && ColorPicker.parse("#A584E84D", allowsAlpha: false) == "#A584E8"
                      && ColorPicker.parse("nope", allowsAlpha: false) == nil)
        let picker = ColorPicker(id: "t", hex: "#FF0000", allowsAlpha: true, suggestions: [0x00FF00], onChange: { _ in })
        picker.place(under: UIRect(x: 300, y: 100, width: 46, height: 26), in: UIRect(x: 0, y: 0, width: 800, height: 600), scale: 1)
        picker.drag(.square, toX: picker.square.x, y: picker.square.y)
        let white = picker.color.hex
        picker.drag(.alpha, toX: picker.alphaBar!.x + picker.alphaBar!.width / 2, y: picker.alphaBar!.midY)
        picker.drag(.swatch(0), toX: 0, y: 0)
        results.check("theme editor: the picker's square, opacity and the theme's colors set the color", white == "#FFFFFF" && picker.color.hex == "#00FF0080")

        print("Window layout")
        results.check("app: has its icon", LoadIconW(GetModuleHandleW(nil), Win.appIcon) != nil)
        let layout = WindowLayout(width: 1000, height: 640, scale: 1, tabCount: 3)
        results.check("layout: window buttons at the right end", layout.close.maxX == 1000 && layout.maximize.maxX == layout.close.x && layout.minimize.maxX == layout.maximize.x)
        results.check("layout: tabs clear of the + button", layout.tab(2).maxX <= layout.newTab.x)
        results.check("layout: the + button follows the last tab", layout.newTab.x == layout.tab(2).maxX + 6)
        let crowded = WindowLayout(width: 1000, height: 640, scale: 1, tabCount: 12)
        results.check("layout: the + button is level with the tabs' x", abs(layout.newTab.midY - layout.tabClose(1).midY) <= 0.5,
                      "\(layout.newTab.midY) \(layout.tabClose(1).midY)")
        results.check("layout: and stays clear of the window's buttons", crowded.newTab.maxX <= crowded.minimize.x)
        results.check("layout: the flower is at the left end, before the tabs", layout.flower.x < 10 && layout.tab(0).x >= layout.flower.maxX
                      && WindowLayout(width: 1000, height: 640, scale: 1, tabCount: 2, leftWidth: 240).tab(0).x == 243)
        results.check("layout: the terminal is between the bars", layout.terminal.y == layout.tabBarHeight && layout.terminal.maxY == layout.statusBar.y)
        results.check("layout: finds a tab", layout.part(atX: layout.tab(1).x + 20, y: 20) == .tab(1))
        results.check("layout: finds its close button", layout.part(atX: layout.tabClose(1).x + 5, y: layout.tabClose(1).y + 5) == .tabClose(1))
        results.check("layout: finds the window buttons", layout.part(atX: 990, y: 10) == .close && layout.part(atX: layout.maximize.x + 2, y: 10) == .maximize && layout.part(atX: layout.minimize.x + 2, y: 10) == .minimize)
        results.check("layout: the rest of the bar drags", WindowLayout(width: 1800, height: 640, scale: 1, tabCount: 2).part(atX: 1000, y: 10) == .titleBar)
        results.check("layout: below the bars is the terminal", layout.part(atX: 500, y: 300) == .terminal && layout.part(atX: 500, y: 630) == .statusBar)
        results.check("layout: many tabs still fit", WindowLayout(width: 1000, height: 640, scale: 2, tabCount: 4).tabWidth >= 144)
        let many = WindowLayout(width: 1000, height: 640, scale: 1, tabCount: 20, tabScroll: 300)
        results.check("overflow: the arrows, tabs and + don't overlap", many.overflows && many.scrollLeft.maxX <= many.tabViewport.x
                      && many.tabViewport.maxX <= many.scrollRight.x && many.scrollRight.maxX <= many.newTab.x && many.newTab.maxX <= many.minimize.x)
        results.check("overflow: the arrows start after the flower", many.flower.maxX <= many.scrollLeft.x)
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

        print("File tree")
        results.check("path: join", WindowsPath.join(#"C:\a"#, "b") == #"C:\a\b"# && WindowsPath.join(#"C:\"#, "b") == #"C:\b"#)
        results.check("path: parent", WindowsPath.parent(#"C:\a\b"#) == #"C:\a"# && WindowsPath.parent(#"C:\a"#) == #"C:\"# && WindowsPath.parent(#"C:\"#) == nil)
        results.check("path: name", WindowsPath.name(#"C:\a\b.txt"#) == "b.txt")
        func entry(_ name: String, folder: Bool = false, hidden: Bool = false, in parent: String = #"C:\r"#) -> FileEntry {
            FileEntry(name: name, path: WindowsPath.join(parent, name), isDirectory: folder, isHidden: hidden)
        }
        let sorted = FileTree.sortedForDisplay([entry("b.txt"), entry("file10"), entry("file2"), entry(".cfg", folder: true), entry("zed", folder: true), entry("Apps", folder: true)])
        results.check("tree: folders first, dots after, numbers in order", sorted.map(\.name) == ["Apps", "zed", ".cfg", "b.txt", "file2", "file10"], "\(sorted.map(\.name))")
        let tree = FileTree()
        var asked: [String] = []
        tree.onNeedsListing = { asked.append($0) }
        tree.setRoot(#"C:\r"#)
        results.check("tree: asks for the root", asked == [#"C:\r"#] && tree.isLoadingRoot)
        tree.receive(#"C:\r"#, [entry("sub", folder: true), entry("a.txt"), entry("secret", hidden: true)])
        results.check("tree: hides what's hidden", tree.rows.map(\.entry.name) == ["sub", "a.txt"] && !tree.isLoadingRoot)
        tree.showHidden = true
        results.check("tree: or shows it", tree.rows.count == 3)
        tree.showHidden = false
        tree.toggle(#"C:\r\sub"#)
        results.check("tree: opening asks for its contents", asked.last == #"C:\r\sub"# && tree.isExpanded(#"C:\r\sub"#))
        tree.receive(#"C:\r\sub"#, [entry("in.txt", in: #"C:\r\sub"#)])
        results.check("tree: contents go under it, indented", tree.rows.map(\.entry.name) == ["sub", "in.txt", "a.txt"] && tree.rows[1].depth == 1)
        results.check("tree: the same listing changes nothing", !tree.receive(#"C:\r\sub"#, [entry("in.txt", in: #"C:\r\sub"#)]))
        results.check("tree: a new file shows", tree.receive(#"C:\r"#, [entry("sub", folder: true), entry("a.txt"), entry("c.txt"), entry("secret", hidden: true)]) && tree.rows.count == 4)
        tree.selection = #"C:\r\sub"#
        tree.moveSelection(by: 1)
        results.check("tree: arrow keys", tree.selection == #"C:\r\sub\in.txt"#)
        tree.stepOut()
        results.check("tree: left goes to the folder holding it", tree.selection == #"C:\r\sub"#)
        tree.stepOut()
        results.check("tree: left closes a folder", !tree.isExpanded(#"C:\r\sub"#) && tree.rows.count == 3)
        tree.stepIn()
        results.check("tree: right opens one", tree.isExpanded(#"C:\r\sub"#))
        tree.receive(#"C:\r\sub"#, nil)
        results.check("tree: an unreadable folder shows empty, and doesn't lose the rest", tree.rows.map(\.entry.name) == ["sub", "a.txt", "c.txt"])
        tree.setRoot(#"C:\other"#)
        results.check("tree: moving resets the view", tree.selection == nil && tree.scrollTop == 0 && tree.rows.isEmpty)
        tree.receive(#"C:\other"#, nil)
        results.check("tree: says when it can't read the root", tree.rootFailed)
        let sides = WindowLayout(width: 1000, height: 640, scale: 1, tabCount: 2, leftWidth: 240, rightWidth: 200)
        results.check("sidebars: the terminal fits between them", sides.terminal.x == 240 && sides.terminal.maxX == 800)
        results.check("sidebars: tabs start on the terminal's card, half a gap past the sidebar", sides.tab(0).x == 243)
        var splitSides = sides
        splitSides.splitCount = 1
        results.check("split: the right column's tabs start on its card's edge",
                      splitSides.tab(1).x == splitSides.rightColumnX, "\(splitSides.tab(1).x) \(splitSides.rightColumnX)")
        results.check("sidebars: found by position", sides.part(atX: 100, y: 200) == .leftSidebar && sides.part(atX: 900, y: 200) == .rightSidebar && sides.part(atX: 500, y: 200) == .terminal)
        results.check("sidebars: their borders can be grabbed", sides.part(atX: 240, y: 200) == .leftEdge && sides.part(atX: 800, y: 200) == .rightEdge)
        results.check("sidebars: the left switch is always there", sides.part(atX: sides.toggleLeft.x + 2, y: sides.toggleLeft.midY) == .toggleLeft)
        results.check("sidebars: the right switch only in a split", sides.part(atX: sides.toggleRight.x + 2, y: sides.toggleRight.midY) == .statusBar
                      && WindowLayout(width: 1000, height: 640, scale: 1, tabCount: 2, showsRightToggle: true).part(atX: sides.toggleRight.x + 2, y: sides.toggleRight.midY) == .toggleRight)
        let split = WindowLayout(width: 1200, height: 640, scale: 1, tabCount: 4, showsRightToggle: true, splitCount: 2)
        results.check("split: each column has its tabs", split.column(ofTab: 1) == 0 && split.column(ofTab: 2) == 1
                      && split.tab(1).maxX <= split.newTab(column: 0).x && split.newTab(column: 0).maxX <= split.divider
                      && split.tab(2).x >= split.divider && split.newTab(column: 1).maxX <= split.closeSplit.x && split.closeSplit.maxX <= split.minimize.x)
        results.check("split: and its terminal", split.terminal.x == 0 && split.terminal.maxX == split.divider && split.rightTerminal.x == split.divider + split.bandWidth
                      && split.rightTerminal.maxX == 1200 && split.divider == 597 && split.part(atX: 600, y: 300) == .columnDivider)
        var dragged = split
        dragged.splitFraction = dragged.splitFraction(atX: 800)
        results.check("split: the band drags", abs(dragged.divider + 3 - 800) <= 1 && dragged.rightTerminal.x == dragged.divider + 6, "\(dragged.divider)")
        results.check("split: its parts are found", split.part(atX: split.tab(3).x + 20, y: 20) == .tab(3) && split.part(atX: split.tab(0).x + 20, y: 20) == .tab(0)
                      && split.part(atX: split.newTab(column: 1).x + 4, y: split.newTab(column: 1).midY) == .newTabRight
                      && split.part(atX: split.closeSplit.x + 4, y: split.closeSplit.midY) == .closeSplit
                      && split.part(atX: split.newTab.x + 4, y: split.newTab.midY) == .newTab)
        let splitCrowded = WindowLayout(width: 1200, height: 640, scale: 1, tabCount: 14, splitCount: 12)
        results.check("split: a crowded column scrolls on its own", splitCrowded.overflows(column: 0) && !splitCrowded.overflows(column: 1)
                      && splitCrowded.scroll(showing: 11) == splitCrowded.maxTabScroll(column: 0) && splitCrowded.scroll(showing: 13) == 0)
        let crumbs = WindowText.crumbPaths(#"C:\Users\me\Projects\Solanum"#, home: #"C:\Users\me"#)
        results.check("path: parts know their folders", crumbs.map(\.path) == [#"C:\Users\me"#, #"C:\Users\me\Projects"#, #"C:\Users\me\Projects\Solanum"#])
        results.check("path: from the drive", WindowText.crumbPaths(#"D:\work\x"#, home: nil).map(\.path) == [#"D:\"#, #"D:\work"#, #"D:\work\x"#])
        let travelled = FileTree()
        travelled.setRoot(#"C:\a"#)
        travelled.receive(#"C:\a"#, [entry("x", folder: true, in: #"C:\a"#)])
        travelled.toggle(#"C:\a\x"#)
        travelled.selection = #"C:\a\x"#
        let kept = travelled.place
        travelled.setRoot(#"C:\b"#)
        travelled.collapseAll()
        travelled.restore(kept)
        results.check("tree: a place comes back whole", travelled.root == #"C:\a"# && travelled.isExpanded(#"C:\a\x"#) && travelled.selection == #"C:\a\x"#)
        print("Menus")
        let area = UIRect(x: 0, y: 0, width: 1000, height: 640)
        let menuItems = [MenuItem(title: "One"), .separator, MenuItem(title: "Off", isEnabled: false), MenuItem(title: "Two")]
        let down = MenuModel(items: menuItems, anchorX: 100, anchorY: 50, above: false, width: 200, window: area, scale: 1)
        results.check("menu: opens below", down.frame.y == 50 && down.frame.x == 100)
        let up = MenuModel(items: menuItems, anchorX: 100, anchorY: 600, above: true, width: 200, window: area, scale: 1)
        results.check("menu: or above", up.frame.maxY == 600)
        results.check("menu: stays in the window", MenuModel(items: menuItems, anchorX: 950, anchorY: 50, above: false, width: 200, window: area, scale: 1).frame.maxX <= 1000)
        results.check("menu: finds its rows, not its lines", down.item(atX: 150, y: down.rect(0).midY) == 0 && down.item(atX: 150, y: down.rect(1).midY) == nil)
        down.moveHighlight(by: 1)
        down.moveHighlight(by: 1)
        results.check("menu: arrows skip lines and what's off", down.highlighted == 3, "\(String(describing: down.highlighted))")
        down.highlight(2)
        results.check("menu: what's off can't be highlighted", down.highlighted == nil)
        let long = MenuModel(items: (0..<100).map { MenuItem(title: "\($0)") }, anchorX: 10, anchorY: 600, above: true, width: 200, window: area, scale: 1)
        results.check("menu: a long one fits and scrolls", long.frame.y >= 0 && long.scrolls)
        for _ in 0..<60 { long.moveHighlight(by: 1) }
        results.check("menu: the highlighted row stays in view", long.rect(59).maxY <= long.frame.maxY && long.rect(59).y >= long.frame.y)
        results.check("sidebars: none when hidden", WindowLayout(width: 1000, height: 640, scale: 1, tabCount: 2).part(atX: 3, y: 200) == .terminal)
        let shape = SidebarLayout(area: sides.leftSidebar, scale: 1)
        results.check("sidebars: rows from the top of the list", shape.visibleRow(atY: shape.list.y + 1) == 0 && shape.visibleRow(atY: shape.list.y + shape.rowHeight + 1) == 1 && shape.visibleRow(atY: shape.list.y - 1) == nil)

        print("Themes and settings")
        let fromTheme = ThemeColors(ThemeSpecs.solanumDefault), toTheme = ThemeColors(ThemeSpecs.vsCode[0])
        let midTheme = ThemeColors.blend(fromTheme, toTheme, 0.5)
        results.check("themes: a change eases through colors between the two",
                      midTheme.background == ThemeColors.mix(toTheme.background, fromTheme.background, 0.5)
                      && midTheme.ansi[1] == ThemeColors.mix(toTheme.ansi[1], fromTheme.ansi[1], 0.5)
                      && ThemeColors.blend(fromTheme, toTheme, 1) == toTheme && ThemeColors.blend(fromTheme, toTheme, 0).background == fromTheme.background)
        results.check("themes: all fourteen", ([ThemeSpecs.solanumDefault] + ThemeSpecs.outerWilds + ThemeSpecs.vsCode).count == 14)
        results.check("hex: six digits", HexColor("#A584E8")?.rgb == 0xA584E8 && HexColor("#A584E8")?.alpha == 1)
        results.check("hex: with alpha", HexColor("#FFFFFF66")?.rgb == 0xFFFFFF && abs((HexColor("#FFFFFF66")?.alpha ?? 0) - 0.4) < 0.01)
        results.check("hex: three digits", HexColor("#fa0")?.rgb == 0xFFAA00 && HexColor("nope") == nil)
        let standard = ThemeColors(ThemeSpecs.solanumDefault)
        results.check("theme: Solanum Default's chrome", standard.isDark && standard.chrome == ThemeColors.mix(0x17082B, 0x111312, 0.32) && standard.background == 0x111312)
        let light = ThemeColors(ThemeSpecs.vsCode.first { $0.name == "Light+" }!)
        results.check("theme: a light one", !light.isDark && light.background == 0xFFFFFF)
        results.check("theme: a see-through selection is mixed into the background", ThemeColors(ThemeSpecs.vsCode.last!).selection == ThemeColors.mix(0xFFFFFF, 0x000000, 0.4))
        let json = ##"{"name": "Mine", "background": "#101010", "foreground": "#EEEEEE", "accent": "#FF0000", "ansi": ["#000000"]}"##
        results.check("theme: from a Mac theme file", ThemeColors.spec(fromJSON: Data(json.utf8))?.name == "Mine")
        var settingsFile = SettingsFile(text: "# hello\ntheme = Hourglass\nfont-size = 14\nmac-only = keep me\ncursor-blink = no\n")
        results.check("settings: reads the file", settingsFile["theme"] == "Hourglass" && settingsFile.number("font-size", 11, in: 6...40) == 14 && !settingsFile.bool("cursor-blink", true))
        results.check("settings: numbers kept in range", settingsFile.number("font-size", 11, in: 6...12) == 12)
        settingsFile["font-size"] = "15"
        let written = settingsFile.text(header: "# top", sections: [("Font", ["font-size", "theme"])])
        results.check("settings: writes it back, keeping keys it doesn't know", written.contains("font-size = 15") && written.contains("mac-only = keep me") && written.contains("# Font"))
        results.check("settings: and reads what it wrote", SettingsFile(text: written)["mac-only"] == "keep me")

        var field = TextFieldState("hello world")
        field.deleteBackward(word: true)
        field.insert("there")
        results.check("field: typing and deleting words", field.text == "hello there")
        field.move(to: 0)
        field.deleteForward()
        results.check("field: Delete at the start", field.text == "ello there" && field.caret == 0)
        let aliasScript = CommandAlias.powerShell([CommandAlias(name: "c", command: "claude"), CommandAlias(name: "bad name", command: "x"), CommandAlias(name: "g.l", command: "git log")])
        results.check("aliases: valid ones become PowerShell", aliasScript.contains("Set-Alias -Name 'c'") && aliasScript.contains("{ claude @args }") && !aliasScript.contains("bad name"))
        results.check("aliases: a dot in a name is fine", aliasScript.contains("Set-Alias -Name 'g.l' -Value '__solanum_alias_g_l'"))

        print("Tab groups")
        final class Tab: Groupable {
            let name: String
            var group: TabGroup?
            init(_ name: String) { self.name = name }
        }
        var strip = ["a", "b", "c", "d", "e"].map(Tab.init)
        func names() -> String { strip.map { $0.name + ($0.group == nil ? "" : "*") }.joined(separator: " ") }
        let firstGroup = TabGroupOps.addToNewGroup(&strip, picked: [strip[3], strip[1]])
        results.check("groups: picked tabs gather where the first was", names() == "a b* d* c e", names())
        results.check("groups: a new one gets the first free color", firstGroup?.color == .blue && TabGroupOps.nextColor(in: strip) == .red)
        TabGroupOps.add(strip[4], to: firstGroup!, in: &strip)
        results.check("groups: added tabs go to the end of the group", names() == "a b* d* e* c", names())
        let second = TabGroupOps.addToNewGroup(&strip, picked: [strip[2]])
        results.check("groups: a new group never lands inside another", names() == "a b* e* d* c" || names() == "a b* d* e* c", names())
        _ = second
        strip = ["a", "b", "c", "d"].map(Tab.init)
        let g = TabGroupOps.addToNewGroup(&strip, picked: [strip[1], strip[2]])!
        TabGroupOps.remove(strip[1], in: &strip)
        results.check("groups: removing moves it past the group", names() == "a c* b d", names())
        strip.swapAt(2, 3)
        TabGroupOps.settle(strip[3], in: strip)
        results.check("groups: a tab dragged away from its group leaves it", strip[3].group == nil || strip[3].group !== g || names().hasSuffix("b"))
        let between = Tab("x")
        strip.insert(between, at: 1)
        strip[2].group = g
        strip[0].group = g
        TabGroupOps.settle(between, in: strip)
        results.check("groups: a tab dropped inside a group joins it", between.group === g)
        let named = TabGroup(color: .green)
        results.check("groups: chip labels", named.chipLabel(count: 3) == "" && { named.collapsed = true; return named.chipLabel(count: 3) == "3" }() && { named.name = "web"; return named.chipLabel(count: 3) == "web  3" }())
        let withChips = WindowLayout(width: 1200, height: 640, scale: 1, tabCount: 4, chips: [1: 60], hiddenTabs: [])
        results.check("groups: a chip sits before its first tab", withChips.chip(1)!.maxX + 6 == withChips.tab(1).x && withChips.part(atX: withChips.chip(1)!.x + 5, y: withChips.chip(1)!.midY) == .chip(1))
        let collapsedChips = WindowLayout(width: 1200, height: 640, scale: 1, tabCount: 4, chips: [1: 60], hiddenTabs: [1, 2])
        results.check("groups: collapsed tabs take no room", collapsedChips.tab(1).width == 0 && collapsedChips.tab(3).x == collapsedChips.chip(1)!.maxX + 6)
        var halfway = collapsedChips
        halfway.tabShown = [1: 0.5, 2: 0.5]
        results.check("groups: halfway through closing, its tabs are half wide, the rest right after them",
                      abs(halfway.tab(1).width - halfway.tab(0).width / 2) <= 1 && abs(halfway.tab(3).x - halfway.tab(2).maxX) <= 1,
                      "\(halfway.tab(0).width) \(halfway.tab(1).width) \(halfway.tab(2).maxX) \(halfway.tab(3).x)")

        print("ssh")
        var hostEntries: [SSHHostEntry] = [], covered = Set<String>()
        SSHHostList.parse("Host pi\n  HostName itsacaarpi.local\n  User pi\nHost *.corp\n  User me\nHost build-01 build-02\n  Port 2222\n", into: &hostEntries, covered: &covered)
        results.check("hosts: concrete ones from the config, with details", hostEntries.map(\.title) == ["pi", "build-01", "build-02"] && hostEntries[0].detail == "pi@itsacaarpi.local" && hostEntries[1].detail == "build-01:2222",
                      "\(hostEntries)")
        results.check("hosts: their names count as covered", covered.contains("itsacaarpi.local"))
        let knownList = SSHHostList.knownHosts("itsacaarpi.local,192.168.1.5 ssh-ed25519 AAAA\n|1|hashed= ssh-rsa AAAA\n[box.local]:2200 ssh-ed25519 AAAA\n")
        results.check("hosts: known ones, skipping hashed entries", knownList.map(\.title) == ["itsacaarpi.local", "192.168.1.5", "box.local:2200"] && knownList[2].target == "-p 2200 box.local", "\(knownList)")
        results.check("ssh: finds the destination", SSHHostList.destination(fromArguments: ["-p", "22", "-o", "X=y", "pi@itsacaarpi.local", "ls"]) == "pi@itsacaarpi.local")
        results.check("ssh: past grouped flags", SSHHostList.destination(fromArguments: ["-tA", "host"]) == "host" && SSHHostList.destination(fromArguments: ["-vp2222", "h"]) == "h")
        results.check("ssh: the label drops the user", SSHHostList.hostLabel("pi@itsacaarpi.local") == "itsacaarpi.local")
        results.check("askpass: knows a password question", Askpass.isSecret("pi@itsacaarpi.local's password: ") && Askpass.isPassword("Password:") && !Askpass.isSecret("Are you sure you want to continue connecting (yes/no)?"))
        let secret = ProtectedSecret("hunter2 ✦")
        results.check("secret: comes back as it went in", secret.reveal { $0 } == "hunter2 ✦")

        results.check("remote: arguments for the sidebar's connection", RemoteConnection.connectionArguments(["-t", "-p", "2222", "pi@host", "htop"]) == ["-p", "2222", "pi@host"])
        let remoteList = RemoteConnection.entries(fromListing: "docs/\n.bashrc\nnotes.txt\r\n./\n", in: "/home/pi")
        results.check("remote: a listing's folders and files", remoteList.map(\.name) == ["docs", ".bashrc", "notes.txt"] && remoteList[0].isDirectory && remoteList[1].isHidden && remoteList[0].path == "/home/pi/docs")
        results.check("hidden process: arguments quoted for Windows", [#"plain"#, #"a b"#, #"say "hi""#, #"C:\my dir\"#, #"C:\dir\"#, ""].map(HiddenProcess.quote)
                      == [#"plain"#, #""a b""#, #""say \"hi\"""#, #""C:\my dir\\""#, #"C:\dir\"#, #""""#])
        results.check("remote: quoting for sh", RemoteConnection.quote("it's") == "'it'\\''s'")
        results.check("paths: Unix ones", AnyPath.parent("/home/pi") == "/home" && AnyPath.parent("/home") == "/" && AnyPath.parent("/") == nil && AnyPath.join("/", "etc") == "/etc")
        let pc = GoToPaths(unix: false, base: #"C:\Users\me\proj"#, home: #"C:\Users\me"#)
        results.check("go to: relative paths start at the terminal's folder", pc.resolve(".") == #"C:\Users\me\proj"# && pc.resolve("..") == #"C:\Users\me"#
                      && pc.resolve(#"src\..\docs"#) == #"C:\Users\me\proj\docs"#, pc.resolve(#"src\..\docs"#))
        results.check("go to: ~, drives, either slash", pc.resolve(#"~\Desktop"#) == #"C:\Users\me\Desktop"# && pc.resolve("d:/x/./y/..") == #"D:\x"#
                      && pc.resolve("c:") == #"C:\"# && pc.resolve(#"\Windows"#) == #"C:\Windows"# && pc.resolve("~") == #"C:\Users\me"#, pc.resolve("d:/x/./y/.."))
        results.check("go to: never above the top", pc.resolve(#"C:\..\.."#) == #"C:\"# && pc.parent(#"C:\"#) == nil && pc.parent(#"C:\Users"#) == #"C:\"#)
        results.check("go to: home shows as ~", pc.shown(#"c:\users\me\proj"#) == #"~\proj"# && pc.shown(#"C:\Users\me"#) == "~" && pc.shown(#"C:\Users\meg"#) == #"C:\Users\meg"#
                      && pc.field(#"C:\Users\me\proj"#) == #"~\proj\"# && pc.field(#"C:\"#) == #"C:\"#)
        results.check("go to: what's typed splits at the last slash", pc.typedParent(#"~\Pro"#) == #"~\"# && pc.lastPart("~/Pro") == "Pro"
                      && pc.endsInSeparator("C:/") && pc.cleaned(#""C:\a b""#) == #"C:\a b"#)
        let host = GoToPaths(unix: true, base: "/home/u/p", home: "/home/u")
        results.check("go to: on a host", host.resolve("~/x") == "/home/u/x" && host.resolve("../..") == "/home" && host.resolve("/") == "/"
                      && host.parent("/") == nil && host.shown("/home/u/p") == "~/p" && host.cleaned(#"a\ b"#) == "a b" && host.lastPart(#"a\b"#) == #"a\b"#)
        var live = ["x"]
        let goTo = PaletteModel(query: #"C:\"#, placeholder: "", icon: 0, emptyMessage: "") { q in live.map { PaletteItem(title: q + $0) } }
        let startedAtEnd = goTo.caret == 3 && goTo.rows.first?.title == #"C:\x"#
        goTo.deleteToStart()
        live = ["y"]
        goTo.refresh()
        results.check("palette: a live one works its rows out from the field", startedAtEnd && goTo.query.isEmpty && goTo.rows.first?.title == "y" && goTo.isLive)
        results.check("reconnect: words for PowerShell", ["-o", "StrictHostKeyChecking=accept-new", "pi@host", "a b", "it's", "@x"].map(TerminalPane.powerShellWord)
                      == ["-o", "StrictHostKeyChecking=accept-new", "pi@host", "'a b'", "'it''s'", "'@x'"])
        results.check("paths: a host's folders from /", WindowText.crumbPaths("/etc/ssh", home: "/home/pi").map(\.path) == ["/", "/etc", "/etc/ssh"]
                      && WindowText.crumbPaths("/home/pi/docs", home: "/home/pi").map(\.path) == ["/home/pi", "/home/pi/docs"]
                      && WindowText.crumbs("/home/Pi", home: "/home/pi") == ["/", "home", "Pi"])
        results.check("paths: home is ~ on a host too", WindowText.crumbs("/home/pi/docs", home: "/home/pi") == ["~", "docs"])

        var altMenu = MenuItem(title: "pi") {}
        altMenu.alternate = ("pi — in This Pane", {})
        let alternates = MenuModel(items: [altMenu, MenuItem(title: "Edit")], anchorX: 0, anchorY: 0, above: false, width: 200,
                                   window: UIRect(x: 0, y: 0, width: 800, height: 600), scale: 1)
        let plainTitles = [alternates.title(0), alternates.title(1)]
        alternates.showsAlternates = true
        results.check("menu: Alt shows alternates, where there are any", plainTitles == ["pi", "Edit"] && [alternates.title(0), alternates.title(1)] == ["pi — in This Pane", "Edit"])

        print("Command palette")
        var ran: [String] = []
        func item(_ title: String, _ category: String = "Shell") -> PaletteItem {
            PaletteItem(title: title, category: category) { ran.append(title) }
        }
        let commands = [item("New Tab"), item("Close Tab"), item("Reopen Closed Tab"), item("Paste", "Edit"), item("Scroll to Top", "View")]
        let palette = PaletteModel(items: commands)
        results.check("palette: lists everything", palette.rows.count == 5 && palette.selectedItem?.title == "New Tab")
        palette.insert("reop")
        results.check("palette: fuzzy search", palette.rows.first?.title == "Reopen Closed Tab" && palette.rows.count == 1, "\(palette.rows.map(\.title))")
        palette.deleteBackward(); palette.deleteBackward(); palette.deleteBackward(); palette.deleteBackward()
        palette.insert("ct")
        results.check("palette: word starts win", palette.rows.first?.title == "Close Tab", "\(palette.rows.map(\.title))")
        palette.deleteBackward(word: true)
        palette.insert("edit")
        results.check("palette: finds by category", palette.rows.first?.title == "Paste", "\(palette.rows.map(\.title))")
        palette.insert("zzz")
        results.check("palette: no matches", palette.rows.isEmpty && palette.selectedItem == nil)
        palette.deleteBackward(word: true)
        results.check("palette: typing starts over", palette.query.isEmpty && palette.rows.count == 5)
        palette.moveSelection(by: 2)
        results.check("palette: arrows move", palette.selectedItem?.title == "Reopen Closed Tab")
        palette.moveSelection(by: 100)
        results.check("palette: a page past the end stops there", palette.selectedItem?.title == "Scroll to Top")
        palette.insert("ab")
        palette.moveCaret(by: -1)
        palette.insert("X")
        results.check("palette: typing goes in at the caret", palette.query == "aXb" && palette.textBeforeCaret == "aX")
        palette.moveCaret(to: 0)
        palette.deleteForward()
        results.check("palette: Delete", palette.query == "Xb")
        palette.setQuery("open the file")
        palette.selectWord(at: 6)
        results.check("palette: a double-click selects the word", palette.selectedText == "the")
        palette.insert("a")
        results.check("palette: typing replaces the selection", palette.query == "open a file" && palette.selection == nil)
        palette.moveCaret(to: 0)
        palette.moveCaret(by: 4, extend: true)
        results.check("palette: Shift+arrows select", palette.selectedText == "open")
        palette.deleteBackward()
        results.check("palette: Backspace deletes the selection", palette.query == " a file")
        palette.selectAll()
        palette.deleteForward()
        results.check("palette: Select All, then Delete, empties it", palette.query.isEmpty)
        palette.setQuery("one two")
        palette.moveCaret(to: 1)
        palette.moveCaret(to: 5, extend: true)
        palette.moveCaret(by: 1)
        results.check("palette: an arrow collapses the selection to its end", palette.selection == nil && palette.caret == 5)
        palette.setQuery("")
        palette.noteRun(commands[3])
        palette.noteRun(commands[1])
        palette.noteRun(commands[3])
        results.check("palette: recents, newest first, without repeats", palette.recents == [commands[3].recentKey, commands[1].recentKey])
        let remembered = PaletteModel(items: commands, recents: palette.recents)
        results.check("palette: recents on top", remembered.rows.map(\.title) == ["Recently used", "Paste", "Close Tab", "All commands", "New Tab", "Close Tab", "Reopen Closed Tab", "Paste", "Scroll to Top"],
                      "\(remembered.rows.map(\.title))")
        results.check("palette: starts past the header", remembered.selectedItem?.title == "Paste")
        remembered.moveSelection(by: 2)
        results.check("palette: arrows step over headers", remembered.selectedItem?.title == "New Tab")
        let vanished = PaletteModel(items: commands, recents: ["Gone › Removed"])
        results.check("palette: a recent that no longer exists isn't shown", vanished.rows.count == 5)
        let longList = PaletteModel(items: (0..<30).map { item("Command \($0)") })
        for _ in 0..<15 { longList.moveSelection(by: 1) }
        results.check("palette: the selection stays in view", longList.scrollTop > 0 && longList.selected < longList.scrollTop + PaletteModel.maxRows)
        let paletteShape = PaletteLayout(windowWidth: 1000, windowHeight: 700, scale: 1, rowCount: 3)
        results.check("palette: centered, and stays put as it shrinks", paletteShape.panel.x == 190 && paletteShape.panel.y == PaletteLayout(windowWidth: 1000, windowHeight: 700, scale: 1, rowCount: 10).panel.y)
        results.check("palette: finds a row", paletteShape.visibleRow(atX: 500, y: paletteShape.row(1).midY) == 1 && paletteShape.visibleRow(atX: 10, y: 10) == nil)
        results.check("palette: fits a small window", PaletteLayout(windowWidth: 400, windowHeight: 300, scale: 1, rowCount: 3).panel.maxX <= 400)

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
        var pastFitting = WindowLayout(width: 1200, height: 420, scale: 1, tabCount: 22)
        pastFitting.tabScroll = pastFitting.scroll(showing: 15)
        guard sol_canvas_begin(canvas.raw, TerminalPalette.background) >= 0 else { return }
        WindowChrome(canvas: canvas, layout: pastFitting, tabs: (1...22).map { "tab \($0)" }, activeTab: 15).draw()
        results.check("chrome: draws with too many tabs", sol_canvas_end(canvas.raw) >= 0)
        if let dir = snapshotDirectory { results.check("chrome: saves that too", canvas.savePNG(to: dir + "\\chrome-overflow.png")) }
        let openBars = WindowLayout(width: 1200, height: 660, scale: 1, tabCount: 2)
        if let big = Canvas(width: 1200, height: 660, fontPixels: 15), sol_canvas_begin(big.raw, TerminalPalette.background) >= 0 {
            WindowChrome(canvas: big, layout: openBars, tabs: ["~", "Solanum"], activeTab: 1).draw()
            let shown = PaletteModel(items: [PaletteItem(title: "New Tab", category: "Shell", shortcut: "Ctrl+T"), PaletteItem(title: "Reopen Closed Tab", category: "Shell", shortcut: "Ctrl+Shift+T"),
                                             PaletteItem(title: "Close Tab", category: "Shell", shortcut: "Ctrl+W"), PaletteItem(title: "Next Tab", category: "Window", shortcut: "Ctrl+Tab"),
                                             PaletteItem(title: "Paste", category: "Edit", shortcut: "Ctrl+V"), PaletteItem(title: "Scroll to Top", category: "View")],
                                     recents: ["Shell › Close Tab", "Edit › Paste"])
            PaletteView(canvas: big, model: shown, layout: PaletteLayout(windowWidth: 1200, windowHeight: 660, scale: 1, rowCount: shown.visibleRowCount), hoveredRow: nil).draw()
            results.check("palette: draws", sol_canvas_end(big.raw) >= 0)
            if let dir = snapshotDirectory { results.check("palette: saves", big.savePNG(to: dir + "\\palette.png")) }
        }
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
        func hasLine(_ text: String) -> Bool { ("\n" + pane.logicalText).contains("\n" + text + "\n") || ("\n" + pane.logicalText).contains("\n" + text) }
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
            Step(name: "window: grows again", action: { window.resizeWindow(toCols: 90, rows: 30) },
                 done: { pane.terminal.rows == 30 && !pane.isSettlingResize }),
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
            var boxState = ""
            steps.append(Step(name: "box: \(name): leaves the right text", action: { pane.pressEscape() }, done: {
                // On a row of its own, as it shows: the program can print it over a row the line above had wrapped onto,
                // which then still reads as part of that line when lines are joined back together.
                let printed = pane.terminal.screen.contains { $0.text().trimmingCharacters(in: .whitespaces) == "final=" + expected }
                let prompt = pane.terminal.currentBlock?.state == .prompt
                if !(printed && prompt) {
                    let state = "printed=\(printed) block=\(pane.terminal.currentBlock.map { "\($0.state)" } ?? "none")"
                    if state != boxState { boxState = state; print("    waiting: " + state); CoreSelfTest.Results.annotate("notice", "box \(name): " + state) }
                }
                return printed && prompt
            }))
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
        var beforeSwipe: Float = 0
        steps.append(Step(name: "overflow: a sideways swipe scrolls right", action: {
            beforeSwipe = window.currentLayout.tabScroll
            window.swipeTabs(delta: 60)
        }, done: { window.currentLayout.tabScroll > beforeSwipe }))
        steps.append(Step(name: "overflow: and left", action: {
            beforeSwipe = window.currentLayout.tabScroll
            window.swipeTabs(delta: -60)
        }, done: { window.currentLayout.tabScroll < beforeSwipe }))
        steps.append(Step(name: "overflow: closing them ends it", action: {}, done: {
            if window.panes.count > 2 && pane.atPrompt { press(0x57) }
            return window.panes.count == 2 && !window.currentLayout.overflows && window.currentLayout.tabScroll == 0
        }))
        steps.append(Step(name: "palette: Ctrl+Shift+P opens it", action: { press(0x50, shift: true) }, done: { window.isPaletteOpen }))
        steps.append(Step(name: "palette: typing filters it", action: { pane.type("new tab") },
                          done: { window.paletteSelection?.title == "New Tab" }))
        steps.append(Step(name: "palette: what's typed stays out of the shell", action: {},
                          done: { !pane.cursorRowText.contains("new tab") }))
        steps.append(Step(name: "palette: Enter runs it and closes", action: { pane.pressEnter() },
                          done: { !window.isPaletteOpen && window.panes.count == 3 && pane.atPrompt }))
        steps.append(Step(name: "palette: lists the tabs", action: { press(0x50, shift: true) },
                          done: { window.paletteRows.contains { $0.title.hasPrefix("Go to Tab:") } }))
        steps.append(Step(name: "palette: Esc closes it", action: { pane.pressEscape() }, done: { !window.isPaletteOpen }))
        steps.append(Step(name: "restart: Ctrl+Shift+R asks first, Windows' way", action: { _ = window.keyDown(0x52, shift: true, ctrl: true, alt: false) }, done: {
            window.dialogTitle == "Restart Solanum?" && (snapshotDirectory.map { window.saveSnapshot(to: $0 + "\\restart.png") } ?? true)
        }))
        steps.append(Step(name: "restart: Esc says no", action: { pane.pressEscape() }, done: { window.dialogTitle == nil && window.panes.count >= 1 }))
        steps.append(Step(name: "palette: and Close Tab works from it", action: {
            press(0x50, shift: true)
            pane.type("close tab")
        }, done: { window.paletteSelection?.title == "Close Tab" }))
        steps.append(Step(name: "palette: closes the tab", action: { pane.pressEnter() }, done: { window.panes.count == 2 && !window.isPaletteOpen }))
        steps.append(Step(name: "palette: clicking outside closes it", action: {
            press(0x50, shift: true)
            window.click(UIRect(x: 2, y: Float(window.currentLayout.height) - 40, width: 2, height: 2))
        }, done: { !window.isPaletteOpen }))
        steps.append(Step(name: "palette: typing reaches the shell again", action: {
            pane.type("echo after-palette")
            pane.pressEnter()
        }, done: { hasLine("after-palette") }))

        // Sidebars, on a folder made for the purpose.
        let sampleFolder = NSTemporaryDirectory() + "solanum-sidebar-\(GetCurrentProcessId())"
        let windowsFolder = sampleFolder.replacingOccurrences(of: "/", with: "\\")
        try? FileManager.default.createDirectory(atPath: windowsFolder + "\\alpha", withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: windowsFolder + "\\alpha\\inner.txt", contents: Data())
        _ = FileManager.default.createFile(atPath: windowsFolder + "\\zeta.txt", contents: Data())
        var openedFile: String?
        window.onOpenFile = { openedFile = $0 }
        var colsWithoutSidebar = 0
        steps.append(Step(name: "sidebar: the terminal goes to a folder", action: {
            colsWithoutSidebar = pane.terminal.cols
            pane.type("cd '\(windowsFolder)'")
            pane.pressEnter()
        }, done: { pane.terminal.cwd?.hasSuffix(WindowsPath.name(windowsFolder)) == true && pane.atPrompt }))
        var sawSlide = false
        steps.append(Step(name: "sidebar: Ctrl+B shows it, on that folder", action: { press(0x42) }, done: {
            if window.leftShown > 0 && window.leftShown < 1 { sawSlide = true }
            return window.leftIsVisible && window.leftShown == 1 && window.leftTree.root?.lowercased() == pane.terminal.cwd?.lowercased() && window.leftRow(named: "alpha") != nil
        }))
        steps.append(Step(name: "sidebar: it slides in, when Windows animates", action: {}, done: { sawSlide || !window.animatesSidebars }))
        steps.append(Step(name: "sidebar: the terminal makes room", action: {}, done: { pane.terminal.cols < colsWithoutSidebar }))
        steps.append(Step(name: "sidebar: lists folders first", action: {},
                          done: { window.leftTree.rows.map(\.entry.name) == ["alpha", "zeta.txt"] }))
        steps.append(Step(name: "sidebar: clicking a folder opens it", action: { if let row = window.leftRow(named: "alpha") { window.click(row) } },
                          done: { window.leftRow(named: "inner.txt") != nil && window.leftHasFocus }))
        steps.append(Step(name: "sidebar: arrow keys move through it", action: { _ = window.keyDown(Int32(0x28), shift: false, ctrl: false, alt: false) },
                          done: { window.leftTree.selection?.hasSuffix("inner.txt") == true }))
        steps.append(Step(name: "sidebar: Space shows a file above the terminal, with the keyboard", action: {
            _ = window.keyDown(Win.VK_SPACE, shift: false, ctrl: false, alt: false)
        }, done: {
            guard let preview = window.activePanel as? FileEditorPanel else { return false }
            return preview.path.hasSuffix("inner.txt") && preview.textLines != nil && pane.editorFocused && !window.leftHasFocus
        }))
        steps.append(Step(name: "sidebar: a new file shows by itself", action: {
            _ = FileManager.default.createFile(atPath: windowsFolder + "\\late.txt", contents: Data("first line\nsecond line\n".utf8))
        }, done: { window.leftRow(named: "late.txt") != nil }))
        steps.append(Step(name: "sidebar: clicking a file shows it, the keyboard staying in the sidebar", action: {
            if let row = window.leftRow(named: "late.txt") { window.click(row) }
        }, done: {
            guard let preview = window.activePanel as? FileEditorPanel else { return false }
            return preview.textLines == ["first line", "second line", ""] && pane.editors.count == 2 && window.leftHasFocus && !pane.editorFocused
                && (snapshotDirectory.map { window.saveSnapshot(to: $0 + "\\file-preview.png") } ?? true)
        }))
        // The editor, as on the Mac.
        let late = windowsFolder + "\\late.txt"
        func editor() -> FileEditorPanel? { window.activePanel as? FileEditorPanel }
        func onDisk(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
        func key(_ k: Int32, ctrl: Bool = false, shift: Bool = false, alt: Bool = false) { _ = window.keyDown(k, shift: shift, ctrl: ctrl, alt: alt) }
        steps.append(Step(name: "editor: double-clicking a file opens it, with the keyboard", action: { if let row = window.leftRow(named: "late.txt") { window.doubleClick(row) } },
                          done: { editor()?.path.hasSuffix("late.txt") == true && pane.editorFocused && !window.leftHasFocus && openedFile == nil }))
        steps.append(Step(name: "editor: typing edits it", action: {
            key(Win.VK_HOME, ctrl: true)
            window.typeIntoWindow("hi ")
        }, done: { editor()?.textLines?.first == "hi first line" && editor()?.hasUnsavedChanges == true }))
        steps.append(Step(name: "editor: Ctrl+S saves it", action: { key(0x53, ctrl: true) },
                          done: { onDisk(late) == "hi first line\nsecond line\n" && editor()?.hasUnsavedChanges == false }))
        steps.append(Step(name: "editor: an edit not saved asks before closing, Windows' way", action: {
            // Typed straight in: a posted character would only arrive after Ctrl+W had closed the file.
            editor()?.typeForTesting("x")
            key(0x57, ctrl: true)
        }, done: { window.dialogTitle == "Save changes to late.txt?" && (snapshotDirectory.map { window.saveSnapshot(to: $0 + "\\save-changes.png") } ?? true) }))
        steps.append(Step(name: "editor: Cancel keeps it open", action: { pane.pressEscape() },
                          done: { window.dialogTitle == nil && editor()?.path.hasSuffix("late.txt") == true }))
        var savedPanel: FileEditorPanel?
        var saveCloseState = ""
        steps.append(Step(name: "editor: Save saves, then closes", action: {
            savedPanel = editor()
            key(0x57, ctrl: true)
            pane.pressEnter()
        }, done: {
            // The editor that was saved: the copy shown above the terminal by the click earlier stays, as it should.
            let open = window.panes.contains { p in p.editors.contains { $0.panel === savedPanel } }
            let ok = onDisk(late).hasPrefix("hi x") && savedPanel != nil && !open
            // What it's waiting on, each time that changes: for reading a failure in CI's log.
            if !ok {
                let e = savedPanel
                let state = "dialog=\(window.dialogTitle ?? "none") stillOpen=\(open) unsaved=\(e?.hasUnsavedChanges ?? false) "
                    + "conflict=\(e?.hasConflict ?? false) changedOnDisk=\(e?.changedOnDisk ?? false) disk=\(onDisk(late).prefix(16).debugDescription)"
                if state != saveCloseState { saveCloseState = state; print("    waiting: " + state); CoreSelfTest.Results.annotate("notice", "Save saves, then closes: waiting: " + state) }
            }
            return ok
        }))
        steps.append(Step(name: "editor: the copy shown above the terminal catches up with the save", action: {}, done: {
            let copies = window.panes.flatMap { p in p.editors.compactMap { $0.panel as? FileEditorPanel } }.filter { $0.path.hasSuffix("late.txt") }
            let ok = copies.allSatisfy { $0.textLines?.first == "hi xfirst line" }
            if !ok {
                let state = copies.map { "\(($0.textLines?.first ?? "nil").debugDescription) unsaved=\($0.hasUnsavedChanges) changedOnDisk=\($0.changedOnDisk)" }.joined(separator: "; ")
                if state != saveCloseState { saveCloseState = state; print("    copies: " + state); CoreSelfTest.Results.annotate("notice", "copy catches up: " + state) }
            }
            return ok
        }))
        let json = windowsFolder + "\\data.json"
        // Made when it's needed, so the sidebar's listing earlier has only the sample's own files.
        steps.append(Step(name: "editor: Beautify re-indents JSON", action: {
            _ = FileManager.default.createFile(atPath: json, contents: Data(##"{"a":1,"b":[1,2]}"##.utf8))
            window.showFile(json, in: pane)
        }, done: {
            guard let e = editor(), e.textLines != nil else { return false }
            e.press(button: .beautify)
            // Colored as on the Mac: the key in the theme's blue, the number in its yellow.
            return e.textLines == ["{", #"  "a": 1,"#, #"  "b": ["#, "    1,", "    2", "  ]", "}"]
                && e.colorAt(line: 1, cell: 2) == TerminalPalette.ansi[4] && e.colorAt(line: 1, cell: 7) == TerminalPalette.ansi[3]
                && (snapshotDirectory.map { window.saveSnapshot(to: $0 + "\\editor.png") } ?? true)
        }))
        steps.append(Step(name: "editor: and saves", action: { key(0x53, ctrl: true) }, done: { onDisk(json).hasPrefix("{\n  \"a\": 1,") }))
        // Tab follows the file's own indentation, as VS Code: this file steps by 2, so Tab at the start puts in 2 spaces.
        let scratch = NSTemporaryDirectory() + "solanum-editor-\(GetCurrentProcessId())"
        try? FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        let script = scratch + "\\indent.py"
        steps.append(Step(name: "editor: Tab indents as the file does", action: {
            _ = FileManager.default.createFile(atPath: script, contents: Data("if x:\n  y()\n  if z:\n    w()\n".utf8))
            window.showFile(script, in: pane)
        }, done: { editor()?.textLines?.first == "if x:" }))
        steps.append(Step(name: "editor: by two spaces", action: {
            key(Win.VK_HOME, ctrl: true)
            key(Win.VK_TAB)
        }, done: { editor()?.textLines?.first == "  if x:" && editor()?.tabWidth == 2 }))
        steps.append(Step(name: "editor: Backspace goes back a whole level", action: { key(Win.VK_BACK) },
                          done: { editor()?.textLines?.first == "if x:" }))
        steps.append(Step(name: "editor: saved, so nothing asks later", action: { key(0x53, ctrl: true) },
                          done: { editor()?.hasUnsavedChanges == false }))
        // A big log, as less shows it: at its end at once, read-only, the lines before it fetched as it's scrolled up.
        let bigLog = scratch + "\\big.log"
        steps.append(Step(name: "editor: a big log opens at its end", action: {
            let text = (1...60_000).map { "2026-11-13 10:00:00 INFO line \($0) of the big log" }.joined(separator: "\n") + "\n"
            _ = FileManager.default.createFile(atPath: bigLog, contents: Data(text.utf8))
            window.showFile(bigLog, in: pane)
        }, done: {
            guard let e = editor(), e.path.hasSuffix("big.log"), let lines = e.textLines else { return false }
            return e.pager != nil && e.readOnly && lines.dropLast().last?.hasSuffix("line 60000 of the big log") == true && lines.count < 20_000
        }))
        steps.append(Step(name: "editor: its lines are numbered as in the whole file", action: {}, done: {
            guard let e = editor(), let first = e.textLines?.first, let n = e.firstLineNumberForTesting else { return false }
            return first.contains("line \(n) of")
        }))
        var linesShown = 0
        steps.append(Step(name: "editor: scrolled to its top, more of it comes", action: {
            linesShown = editor()?.textLines?.count ?? 0
            key(Win.VK_HOME, ctrl: true)
        }, done: { (editor()?.textLines?.count ?? 0) > linesShown }))
        steps.append(Step(name: "editor: and closes", action: { editor()?.press(button: .close) }, done: { editor()?.path.hasSuffix("big.log") != true }))
        // Where the files' line meets the sidebar's edge, a drag moves both, as in VS Code.
        var before: (left: Float, band: Float)?
        steps.append(Step(name: "editor: where dividers meet, a drag moves both", action: {
            guard let j = window.leftJunctionForTesting else { return }
            before = (window.currentLayout.leftWidth, j.y)
            window.drag(fromX: j.x, y: j.y, toX: j.x + 60, y: j.y + 45)
        }, done: {
            guard let before, let j = window.leftJunctionForTesting else { return false }
            return window.currentLayout.leftWidth > before.left + 20 && j.y > before.band + 15
        }))
        steps.append(Step(name: "editor: and back, for what follows", action: {
            guard let j = window.leftJunctionForTesting else { return }
            window.drag(fromX: j.x, y: j.y, toX: j.x - 60, y: j.y - 45)
        }, done: { before.map { abs(window.currentLayout.leftWidth - $0.left) <= 2 } ?? false }))
        let readme = windowsFolder + "\\readme.md"
        steps.append(Step(name: "preview: a Markdown file renders", action: {
            _ = FileManager.default.createFile(atPath: readme, contents: Data("# Title\n\nSome **bold** and *italic* text, `code`, a [link](https://example.com).\n\n- one\n- [x] done\n".utf8))
            window.showPreview(readme, in: pane)
        }, done: {
            guard let preview = window.activePanel as? MarkdownPreviewPanel, let blocks = preview.blocks else { return false }
            return blocks.count == 4 && (snapshotDirectory.map { window.saveSnapshot(to: $0 + "\\markdown.png") } ?? true)
        }))
        steps.append(Step(name: "sidebar: the files close", action: {
            while let panel = pane.panel { window.closeEditor(panel, in: pane) }
        }, done: { pane.editors.isEmpty && window.paneArea(pane) == window.editorSplit(for: pane).column }))
        steps.append(Step(name: "sidebar: Esc goes back to the terminal", action: { _ = window.keyDown(Int32(0x1B), shift: false, ctrl: false, alt: false) },
                          done: { !window.leftHasFocus }))
        var sidebarWidthBefore: Float = 0
        steps.append(Step(name: "sidebar: its border drags", action: {
            sidebarWidthBefore = window.leftWidthNow
            window.dragLeftEdge(to: sidebarWidthBefore + 60)
        }, done: { abs(window.leftWidthNow - sidebarWidthBefore - 60) <= 2 }))
        steps.append(Step(name: "sidebar: double-clicking a folder sends the terminal there", action: {
            if let row = window.leftRow(named: "alpha") { window.doubleClick(row) }
        }, done: { pane.terminal.cwd?.hasSuffix("alpha") == true && pane.atPrompt }))
        steps.append(Step(name: "sidebar: and it follows", action: {}, done: { window.leftTree.root?.hasSuffix("alpha") == true && window.leftRow(named: "inner.txt") != nil }))
        func inSample(_ root: String?) -> Bool { root?.hasSuffix(WindowsPath.name(windowsFolder)) == true }
        steps.append(Step(name: "sidebar: the parent button goes up without pinning", action: { window.click(window.leftButton(.parent)) },
                          done: { inSample(window.leftTree.root) && window.leftPinned == nil }))
        steps.append(Step(name: "sidebar: and it follows once the terminal moves", action: {
            pane.type("cd ..")
            pane.pressEnter()
        }, done: { inSample(pane.terminal.cwd) && pane.atPrompt && inSample(window.leftTree.root) }))
        steps.append(Step(name: "sidebar: back into the folder", action: {
            pane.type("cd alpha")
            pane.pressEnter()
        }, done: { window.leftTree.root?.hasSuffix("alpha") == true && pane.atPrompt }))
        steps.append(Step(name: "sidebar: the pin holds it", action: { window.click(window.leftButton(.pin)) }, done: { window.leftPinned != nil }))
        steps.append(Step(name: "sidebar: while the terminal moves", action: {
            pane.type("cd ..")
            pane.pressEnter()
        }, done: { inSample(pane.terminal.cwd) && pane.atPrompt && window.leftTree.root?.hasSuffix("alpha") == true }))
        steps.append(Step(name: "sidebar: unpinning catches up", action: { window.click(window.leftButton(.pin)) },
                          done: { window.leftPinned == nil && inSample(window.leftTree.root) }))
        steps.append(Step(name: "sidebar: the ... button opens its menu", action: { window.click(window.leftButton(.more)) },
                          done: { window.menuTitles == ["Show Hidden Files", "Collapse All"] }))
        steps.append(Step(name: "sidebar: a menu row works", action: { window.click(window.menuRow("Show Hidden Files")!) },
                          done: { !window.isMenuOpen && window.leftTree.showHidden }))
        steps.append(Step(name: "sidebar: and off again", action: {
            window.click(window.leftButton(.more))
        }, done: {
            guard let row = window.menuRow("Show Hidden Files") else { return false }
            window.click(row)
            return true
        }))
        steps.append(Step(name: "sidebar: hidden files are off", action: {}, done: { !window.isMenuOpen && !window.leftTree.showHidden }))
        steps.append(Step(name: "sidebar: the right one stays away without a split", action: { _ = window.keyDown(0x42, shift: false, ctrl: true, alt: true) },
                          done: { !window.rightIsVisible }))
        // The status bar's path.
        steps.append(Step(name: "path: clicking a part lists its folders", action: { window.click(window.crumbRect(WindowsPath.name(windowsFolder))!) },
                          done: { window.menuTitles.contains("alpha") && window.menuTitles.contains("Copy Path") }))
        steps.append(Step(name: "path: Esc closes the menu", action: { pane.pressEscape() }, done: { !window.isMenuOpen }))
        steps.append(Step(name: "path: choosing a folder sends the terminal there", action: { window.click(window.crumbRect(WindowsPath.name(windowsFolder))!) }, done: {
            guard let row = window.menuRow("alpha") else { return false }
            window.click(row)
            return true
        }))
        steps.append(Step(name: "path: it gets there", action: {}, done: { pane.terminal.cwd?.hasSuffix("alpha") == true && pane.atPrompt && window.leftTree.root?.hasSuffix("alpha") == true }))
        // Pinning from the path.
        let sampleName = WindowsPath.name(windowsFolder)
        steps.append(Step(name: "path: right-click offers the pin", action: { window.rightClick(window.crumbRect(sampleName)!) },
                          done: { window.menuTitles == ["Pin in Sidebar", "Copy Path"] && window.menuShortcuts["Pin in Sidebar"] == "" }))
        steps.append(Step(name: "path: the pin keeps the sidebar there", action: { window.click(window.menuRow("Pin in Sidebar")!) },
                          done: { !window.isMenuOpen && inSample(window.leftPinned) && inSample(window.leftTree.root) && pane.terminal.cwd?.hasSuffix("alpha") == true }))
        steps.append(Step(name: "path: and the menu offers to unpin it, with its keys", action: { window.rightClick(window.crumbRect(sampleName)!) },
                          done: { window.menuTitles == ["Unpin Sidebar", "Copy Path"] && window.menuShortcuts["Unpin Sidebar"] == "Ctrl+Shift+B" }))
        steps.append(Step(name: "path: unpinned, it follows the terminal again", action: { window.click(window.menuRow("Unpin Sidebar")!) },
                          done: { !window.isMenuOpen && window.leftPinned == nil && window.leftTree.root?.hasSuffix("alpha") == true }))
        steps.append(Step(name: "path: clicking a part has Go to Folder and the pin", action: { window.click(window.crumbRect("alpha")!) }, done: {
            Array(window.menuTitles.prefix(3)) == ["Go to Folder…", "Pin in Sidebar", "Copy Path"]
                && window.menuShortcuts["Go to Folder…"] == "Ctrl+Shift+O" && window.menuShortcuts["Pin in Sidebar"] == "Ctrl+Shift+B"
        }))
        if let dir = snapshotDirectory {
            steps.append(Step(name: "path-menu: snapshot", action: {}, done: {
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                return window.saveSnapshot(to: dir + "\\path-menu.png")
            }))
        }
        steps.append(Step(name: "path: closes", action: { pane.pressEscape() }, done: { !window.isMenuOpen }))
        // Go to Folder.
        func key(_ k: Int32, ctrl: Bool = false, shift: Bool = false) { _ = window.keyDown(k, shift: shift, ctrl: ctrl, alt: false) }
        steps.append(Step(name: "go to: Ctrl+Shift+O starts at the terminal's folder", action: { key(0x4F, ctrl: true, shift: true) }, done: {
            window.isPaletteOpen && window.paletteQuery?.hasSuffix(#"alpha\"#) == true && window.paletteSelection?.title.hasSuffix(#"alpha Here"#) == true
        }))
        if let dir = snapshotDirectory {
            steps.append(Step(name: "go-to-folder: snapshot", action: {}, done: {
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                return window.saveSnapshot(to: dir + "\\go-to-folder.png")
            }))
        }
        steps.append(Step(name: "go to: Ctrl+Backspace clears the field", action: { key(Win.VK_BACK, ctrl: true) }, done: { window.paletteQuery == "" }))
        steps.append(Step(name: "go to: a relative path", action: { pane.type(#"..\"#) },
                          done: { window.paletteSelection.map { $0.title.hasPrefix("Open ") && $0.title.hasSuffix(sampleName + " Here") } == true
                                    && window.paletteRows.contains { $0.title == "alpha" } }))
        steps.append(Step(name: "go to: Enter goes there", action: { pane.pressEnter() },
                          done: { !window.isPaletteOpen && inSample(pane.terminal.cwd) && pane.atPrompt }))
        steps.append(Step(name: "go to: typing picks a folder", action: {
            key(0x4F, ctrl: true, shift: true)
            pane.type("alp")
        }, done: { window.paletteSelection?.title == "alpha" }))
        steps.append(Step(name: "go to: Tab goes into it", action: { key(Win.VK_TAB) },
                          done: { window.paletteQuery?.hasSuffix(#"\alpha\"#) == true && window.paletteSelection?.title.hasSuffix("alpha Here") == true }))
        steps.append(Step(name: "go to: Enter there", action: { pane.pressEnter() },
                          done: { !window.isPaletteOpen && pane.terminal.cwd?.hasSuffix("alpha") == true && pane.atPrompt }))
        steps.append(Step(name: "go to: Ctrl+Shift+O again closes it", action: {
            key(0x4F, ctrl: true, shift: true)
            key(0x4F, ctrl: true, shift: true)
        }, done: { !window.isPaletteOpen }))
        // Files in the sidebar, in the alpha folder.
        let alphaFolder = WindowsPath.join(windowsFolder, "alpha")
        func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: WindowsPath.join(alphaFolder, name)) }
        func typeName(_ text: String) {
            for _ in 0..<40 { _ = window.keyDown(Win.VK_BACK, shift: false, ctrl: false, alt: false) }
            window.typeIntoWindow(text)
            pane.pressEnter()
        }
        steps.append(Step(name: "files: the sidebar shows the folder", action: {}, done: {
            window.leftTree.root?.hasSuffix("alpha") == true && window.leftRow(named: "inner.txt") != nil
        }))
        steps.append(Step(name: "files: a file's menu", action: { if let row = window.leftRow(named: "inner.txt") { window.rightClick(row) } }, done: {
            ["New File…", "New Folder…", "Cut", "Copy", "Paste", "Duplicate", "Copy Path", "Rename…", "Delete", "Show in Explorer"].allSatisfy(window.menuTitles.contains)
                && window.menuShortcuts["Rename…"] == "F2"
        }))
        steps.append(Step(name: "files: New File… asks for its name in place", action: { window.click(window.menuRow("New File…")!) },
                          done: { window.leftEditingText == "" && !window.isMenuOpen }))
        steps.append(Step(name: "files: typing it makes the file", action: { typeName("made.txt") },
                          done: { exists("made.txt") && window.leftRow(named: "made.txt") != nil && window.leftEditingText == nil }))
        steps.append(Step(name: "files: F2 renames it", action: {
            _ = window.keyDown(Win.VK_F2, shift: false, ctrl: false, alt: false)
            _ = window.keyDown(Win.VK_END, shift: false, ctrl: false, alt: false)
            typeName("renamed.txt")
        }, done: { exists("renamed.txt") && !exists("made.txt") && window.leftRow(named: "renamed.txt") != nil }))
        steps.append(Step(name: "files: a taken name keeps the field open", action: {
            _ = window.keyDown(Win.VK_F2, shift: false, ctrl: false, alt: false)
            _ = window.keyDown(Win.VK_END, shift: false, ctrl: false, alt: false)
            typeName("inner.txt")
        }, done: { window.leftEditingText == "inner.txt" && exists("renamed.txt") }))
        steps.append(Step(name: "files: Esc leaves it as it was", action: { pane.pressEscape() },
                          done: { window.leftEditingText == nil && exists("renamed.txt") }))
        steps.append(Step(name: "files: Enter renames, as Return does on the Mac", action: {
            if let row = window.leftRow(named: "renamed.txt") { window.click(row) }
            _ = window.keyDown(Win.VK_RETURN, shift: false, ctrl: false, alt: false)
        }, done: { window.leftEditingText == "renamed.txt" }))
        steps.append(Step(name: "files: and Esc again leaves it", action: { pane.pressEscape() },
                          done: { window.leftEditingText == nil && exists("renamed.txt") }))
        steps.append(Step(name: "files: Duplicate copies beside it", action: {
            if let row = window.leftRow(named: "renamed.txt") { window.rightClick(row) }
            window.click(window.menuRow("Duplicate")!)
        }, done: { exists("renamed - Copy.txt") }))
        steps.append(Step(name: "files: Ctrl+Shift+N makes a folder", action: {
            _ = window.keyDown(0x4E, shift: true, ctrl: true, alt: false)
            typeName("box")
        }, done: { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: WindowsPath.join(alphaFolder, "box"), isDirectory: &d) && d.boolValue
                    && window.leftRow(named: "box") != nil }))
        steps.append(Step(name: "files: Ctrl+C puts it on the clipboard, for Explorer too", action: {
            if let row = window.leftRow(named: "renamed.txt") { window.click(row) }
            _ = window.keyDown(0x43, shift: false, ctrl: true, alt: false)
        }, done: { FileOps.clipboardFiles(owner: nil)?.paths.map { $0.lowercased() } == [WindowsPath.join(alphaFolder, "renamed.txt").lowercased()] }))
        steps.append(Step(name: "files: Ctrl+V into a folder copies it there", action: {
            if let row = window.leftRow(named: "box") { window.click(row) }
            _ = window.keyDown(0x56, shift: false, ctrl: true, alt: false)
        }, done: { exists("box\\renamed.txt") && exists("renamed.txt") }))
        steps.append(Step(name: "files: cut and paste moves it", action: {
            if let row = window.leftRow(named: "renamed - Copy.txt") { window.click(row) }
            _ = window.keyDown(0x58, shift: false, ctrl: true, alt: false)
            if let row = window.leftRow(named: "box") { window.click(row) }
            _ = window.keyDown(0x56, shift: false, ctrl: true, alt: false)
        }, done: { exists("box\\renamed - Copy.txt") && !exists("renamed - Copy.txt") }))
        steps.append(Step(name: "files: dragging a file onto a folder moves it", action: {
            window.dragLeftRow("renamed.txt", onto: "box")
        }, done: { exists("box\\renamed (2).txt") && !exists("renamed.txt") }))
        let outside = WindowsPath.join(windowsFolder, "outside file.txt")
        steps.append(Step(name: "files: dropped from Explorer onto a folder, copied in", action: {
            _ = FileManager.default.createFile(atPath: outside, contents: Data("hi".utf8))
            let r = window.leftRow(named: "box")!
            window.dropFilesForTest([outside], atX: r.x + 40, y: r.midY)
        }, done: { exists("box\\outside file.txt") && FileManager.default.fileExists(atPath: outside) }))
        steps.append(Step(name: "files: dropped on the terminal, its path is typed", action: {
            let t = window.currentLayout.terminal
            window.dropFilesForTest([outside], atX: t.x + t.width / 2, y: t.y + t.height / 2)
        }, done: { pane.logicalText.contains("'\(outside)'") }))
        steps.append(Step(name: "files: and cleared again", action: { pane.pressEscape() }, done: { !pane.cursorRowText.contains("outside") }))
        steps.append(Step(name: "files: Delete sends to the Recycle Bin", action: {
            if let row = window.leftRow(named: "box") { window.click(row) }
            _ = window.keyDown(Win.VK_DELETE, shift: false, ctrl: false, alt: false)
        }, done: { !exists("box") && window.leftRow(named: "box") == nil }))
        steps.append(Step(name: "files: the folder's own menu below the rows", action: { window.rightClick(window.leftListEmptySpot) }, done: {
            window.menuTitles.contains("New File…") && window.menuTitles.contains("Open in Explorer") && !window.menuTitles.contains("Rename…")
        }))
        steps.append(Step(name: "files: closes", action: { pane.pressEscape() }, done: { !window.isMenuOpen }))
        // Git, in a repository of its own.
        steps.append(Step(name: "pages: the files clicked in the sidebar showed above the terminal, and close", action: {
            while let panel = pane.panel { window.closeEditor(panel, in: pane) }
        }, done: { pane.editors.isEmpty && !pane.editorFocused }))
        steps.append(Step(name: "git: a repository shows its branch and changes", action: {
            pane.type("New-Item -ItemType Directory repo | Out-Null; cd repo; git init -q -b main; git config user.email t@example.com; git config user.name T; "
                      + "'hello solanum' | Out-File -Encoding ascii tracked.txt; git add .; git commit -qm one; 'more' | Out-File -Encoding ascii new.txt")
            pane.pressEnter()
        }, done: {
            if pane.atPrompt && window.activeGit == nil { window.refreshGitForTest() }
            return window.activeGit?.branch == "main" && window.activeGit?.changes.count == 1 && window.gitSpot(.branch) != nil && window.gitSpot(.changes) != nil
        }))
        if let dir = snapshotDirectory {
            steps.append(Step(name: "git: snapshot of the status bar", action: {}, done: { window.saveSnapshot(to: dir + "\\git-bar.png") }))
        }
        steps.append(Step(name: "git: the branch opens the switcher", action: { window.click(window.gitSpot(.branch)!) },
                          done: { window.isPaletteOpen && window.paletteRows.contains { $0.title == "Show Git Graph" } && window.paletteRows.contains { $0.title == "main" } }))
        steps.append(Step(name: "git: and closes", action: { pane.pressEscape() }, done: { !window.isPaletteOpen }))
        steps.append(Step(name: "git: the changes list them", action: { window.click(window.gitSpot(.changes)!) },
                          done: { window.menuTitles.contains("U   new.txt") && window.menuTitles.contains("Show Git Changes") }))
        steps.append(Step(name: "git: and close", action: { pane.pressEscape() }, done: { !window.isMenuOpen }))
        steps.append(Step(name: "git: Ctrl+Shift+S shows Git Changes", action: { _ = window.keyDown(0x53, shift: true, ctrl: true, alt: false) }, done: {
            (window.activePanel as? GitChangesPanel)?.fileRows.map(\.path) == ["new.txt"]
        }))
        steps.append(Step(name: "pages: open above the terminal, which stays below", action: {}, done: {
            let split = window.editorSplit(for: pane)
            guard let editor = split.editor else { return false }
            let terminal = window.paneArea(pane)
            return pane.editorFocused && terminal.height > 0 && terminal.y >= editor.maxY && editor.y == split.column.y
        }))
        steps.append(Step(name: "git: an untracked file has a section of its own, as on the Mac", action: {}, done: {
            (window.activePanel as? GitChangesPanel)?.rows.contains(.header(.untracked, count: 1)) == true
        }))
        steps.append(Step(name: "git: staging there", action: { (window.activePanel as? GitChangesPanel)?.act(.stageAll, on: nil) }, done: {
            guard let rows = (window.activePanel as? GitChangesPanel)?.fileRows else { return false }
            return rows.count == 1 && rows[0].staged && (window.activePanel as? GitChangesPanel)?.diff.contains { $0.kind == .added } == true
        }))
        if let dir = snapshotDirectory {
            steps.append(Step(name: "git: snapshot of Git Changes", action: { window.typeIntoWindow("second") }, done: {
                (window.activePanel as? GitChangesPanel)?.message.text == "second" && window.saveSnapshot(to: dir + "\\git-changes.png")
            }))
        } else {
            steps.append(Step(name: "git: a message to commit with", action: { window.typeIntoWindow("second") },
                              done: { (window.activePanel as? GitChangesPanel)?.message.text == "second" }))
        }
        steps.append(Step(name: "git: Enter commits it", action: { pane.pressEnter() }, done: {
            (window.activePanel as? GitChangesPanel)?.fileRows.isEmpty == true && window.activeGit?.changes.isEmpty == true
        }))
        steps.append(Step(name: "git: Esc closes it", action: { pane.pressEscape() }, done: { window.activePanel == nil }))
        steps.append(Step(name: "git: Ctrl+Shift+G shows Git Graph", action: { _ = window.keyDown(0x47, shift: true, ctrl: true, alt: false) },
                          done: { (window.activePanel as? GitGraphPanel)?.rows.count == 2 }))
        steps.append(Step(name: "git: a commit's card", action: { (window.activePanel as? GitGraphPanel)?.selectRow(0) }, done: {
            (window.activePanel as? GitGraphPanel)?.cardLoaded == true && (snapshotDirectory.map { window.saveSnapshot(to: $0 + "\\git-graph.png") } ?? true)
        }))
        steps.append(Step(name: "git: Enter opens the commit's changes", action: { pane.pressEnter() }, done: {
            (window.activePanel as? GitCommitPanel)?.filePaths == ["new.txt"] && pane.editors.count == 2
        }))
        steps.append(Step(name: "git: a file there unfolds", action: { (window.activePanel as? GitCommitPanel)?.unfold("new.txt") }, done: {
            (window.activePanel as? GitCommitPanel)?.diffLines("new.txt")?.contains { $0.kind == .added && $0.text.hasPrefix("more") } == true
                && (snapshotDirectory.map { window.saveSnapshot(to: $0 + "\\git-commit.png") } ?? true)
        }))
        steps.append(Step(name: "git: Esc closes the commit, then the graph", action: { pane.pressEscape(); pane.pressEscape() }, done: {
            window.activePanel == nil && pane.editors.isEmpty && !pane.editorFocused && window.paneArea(pane) == window.editorSplit(for: pane).column
        }))
        // Git Graph's filters, as the Mac's toolbar.
        func graph() -> GitGraphPanel? { window.activePanel as? GitGraphPanel }
        steps.append(Step(name: "graph filters: Ctrl+Shift+G again", action: { _ = window.keyDown(0x47, shift: true, ctrl: true, alt: false) },
                          done: { graph()?.loaded == true && (graph()?.rows.count ?? 0) >= 2 && graph()?.toolbarRect("date") != nil }))
        steps.append(Step(name: "graph filters: Date has its choices", action: {
            if let r = graph()?.toolbarRect("date") { window.click(r) }
        }, done: { window.menuTitles.contains("Last 7 Days") && window.menuTitles.contains("Any Time") }))
        steps.append(Step(name: "graph filters: and closes", action: { pane.pressEscape() }, done: { !window.isMenuOpen }))
        // The shared dropdown, with its search box (Core's Dropdown does the narrowing, on the Mac too).
        steps.append(Step(name: "graph filters: Branch opens a dropdown under it, with a search box", action: {
            if let r = graph()?.toolbarRect("branch") { window.click(r) }
        }, done: { window.menuTitles.contains("All Branches") && window.menuSearchText == "" && window.menuTitles.contains { $0.hasPrefix("HEAD") } }))
        steps.append(Step(name: "graph filters: typing narrows it", action: { window.typeKeys("head") },
                          done: { window.menuSearchText == "head" && window.menuTitles.count == 1 && window.menuTitles[0].hasPrefix("HEAD") }))
        steps.append(Step(name: "graph filters: Enter picks what's highlighted", action: { pane.pressEnter() },
                          done: { !window.isMenuOpen && graph()?.filter.branch == "HEAD" }))
        steps.append(Step(name: "graph filters: back to every branch", action: { graph()?.setFilterForTesting { $0.branch = nil } },
                          done: { graph()?.filter.isEmpty == true && graph()?.loaded == true }))
        steps.append(Step(name: "graph filters: a user with no commits leaves none", action: {
            graph()?.setFilterForTesting { $0.user = "nobody-at-all" }
        }, done: { graph()?.loaded == true && graph()?.rows.isEmpty == true && graph()?.toolbarRect("clear") != nil }))
        steps.append(Step(name: "graph filters: text finds a commit by its message", action: {
            graph()?.setFilterForTesting { $0 = GraphFilter(); $0.text = "one" }
        }, done: {
            guard let g = graph(), g.loaded, !g.rows.isEmpty else { return false }
            return g.rows.allSatisfy { $0.commit.subject.lowercased().contains("one") }
        }))
        steps.append(Step(name: "graph filters: Esc clears them, then closes the graph", action: { pane.pressEscape() },
                          done: { graph()?.filter.isEmpty == true && (graph()?.rows.count ?? 0) >= 2 }))
        steps.append(Step(name: "graph filters: closed", action: { pane.pressEscape() }, done: { window.activePanel == nil }))
        // Search in Project Folder.
        steps.append(Step(name: "search: Ctrl+Shift+F finds text in the folder", action: {
            _ = window.keyDown(0x46, shift: true, ctrl: true, alt: false)
            window.typeIntoWindow("solanum")
        }, done: {
            let rows = window.paletteRows
            guard let i = rows.firstIndex(where: { $0.category == "line 1" && $0.title.contains("hello solanum") }) else { return false }
            // Under its file's header, as on the Mac, with the count above them.
            return i > 0 && rows[i - 1].isHeader && rows[i - 1].title == "tracked.txt" && rows.first?.title.contains("in 1 file") == true
        }))
        steps.append(Step(name: "search: a result opens its file, the query selected", action: { window.pressPaletteEnterForTest() }, done: {
            guard let file = window.activePanel as? FileEditorPanel else { return false }
            return file.path.hasSuffix("tracked.txt") && file.selectedText?.lowercased() == "solanum" && !window.isPaletteOpen
        }))
        steps.append(Step(name: "search: Ctrl+F finds in that file", action: {
            _ = window.keyDown(0x46, shift: false, ctrl: true, alt: false)
        }, done: { (window.activePanel as? FileEditorPanel)?.findStateForTesting == "1 of 1 current='solanum'" }))
        steps.append(Step(name: "search: Esc closes find, then Ctrl+W the file", action: {
            _ = window.keyDown(Win.VK_ESCAPE, shift: false, ctrl: false, alt: false)
            _ = window.keyDown(0x57, shift: false, ctrl: true, alt: false)
        }, done: { window.activePanel == nil && !window.isPaletteOpen }))
        // Links in what's printed.
        func cell(_ text: String) -> (line: Int, col: Int)? {
            guard let row = pane.terminal.screen.firstIndex(where: { $0.text().contains(text) }), let r = pane.terminal.screen[row].text().range(of: text) else { return nil }
            return (pane.terminal.screenTopAbs + row, pane.terminal.screen[row].text().distance(from: pane.terminal.screen[row].text().startIndex, to: r.lowerBound) + 2)
        }
        steps.append(Step(name: "links: a web address and a file in what's printed", action: {
            pane.type("Write-Output 'see https://example.com/page now'; Write-Output 'open tracked.txt:1 please'")
            pane.pressEnter()
        }, done: {
            guard pane.atPrompt, let web = cell("https://example.com/page"), let file = cell("tracked.txt:1") else { return false }
            return pane.link(atLine: web.line, col: web.col)?.target == "https://example.com/page"
                && pane.link(atLine: file.line, col: file.col)?.target.lowercased().hasSuffix("\\repo\\tracked.txt") == true
                && pane.link(atLine: file.line, col: file.col + 20) == nil
        }))
        // Find in the terminal, as the Mac's ⌘F.
        steps.append(Step(name: "terminal find: Ctrl+F and typing finds in what's printed", action: {
            _ = window.keyDown(0x46, shift: false, ctrl: true, alt: false)
            window.typeIntoWindow("example.com")
        }, done: {
            guard let bar = pane.findBar else { return false }
            return pane.findFocused && bar.matches.count >= 1 && bar.bar.count?.text == "\(bar.matches.count)/\(bar.matches.count)"
                && (snapshotDirectory.map { window.saveSnapshot(to: $0 + "\\terminal-find.png") } ?? true)
        }))
        steps.append(Step(name: "terminal find: typing doesn't reach the shell, and Esc closes it", action: {
            _ = window.keyDown(Win.VK_ESCAPE, shift: false, ctrl: false, alt: false)
        }, done: { pane.findBar == nil && !pane.cursorRowText.contains("example.com") }))
        // Keep Awake, as the Mac's Shift-Command-A, and its cup in the status bar.
        steps.append(Step(name: "keep awake: a click on the cup, while it's off, starts it", action: { window.click(window.keepAwakeButtonRect) },
                          done: { KeepAwake.isOn && !window.isMenuOpen }))
        steps.append(Step(name: "keep awake: while on, an hour more", action: {
            window.click(window.keepAwakeButtonRect)
            if let r = window.menuRow("Add 1 Hour") { window.click(r) }
        }, done: { (KeepAwake.secondsLeft ?? 0) > AppSettings.shared.keepAwakeSeconds + 3000 }))
        steps.append(Step(name: "keep awake: and an hour less", action: {
            window.click(window.keepAwakeButtonRect)
            if let r = window.menuRow("Subtract 1 Hour") { window.click(r) }
        }, done: { (KeepAwake.secondsLeft ?? .max) <= AppSettings.shared.keepAwakeSeconds + 5 }))
        steps.append(Step(name: "keep awake: End Caffeinate ends it", action: {
            window.click(window.keepAwakeButtonRect)
            if let r = window.menuRow("End Caffeinate") { window.click(r) }
        }, done: { !KeepAwake.isOn && !window.isMenuOpen }))
        steps.append(Step(name: "keep awake: Ctrl+Shift+A still turns it on and off", action: {
            _ = window.keyDown(0x41, shift: true, ctrl: true, alt: false)
            _ = window.keyDown(0x41, shift: true, ctrl: true, alt: false)
        }, done: { !KeepAwake.isOn }))
        // A tab's file sub-tabs, when they don't all fit: a sideways swipe moves them along, as it does the tabs.
        steps.append(Step(name: "subtabs: a dozen files open in the tab", action: {
            for i in 0..<12 {
                let path = windowsFolder + "\\subtab-file-with-a-long-name-\(i).txt"
                _ = FileManager.default.createFile(atPath: path, contents: Data("\(i)\n".utf8))
                window.showFile(path, in: pane, focus: false)
            }
        }, done: { pane.editors.count >= 12 && (window.subTabStrip(for: pane)?.maxScroll ?? 0) > 0 }))
        var subTabScroll: Float = 0
        steps.append(Step(name: "subtabs: a sideways swipe moves them along", action: {
            subTabScroll = window.subTabStrip(for: pane)?.scroll ?? 0
            if let s = window.subTabStrip(for: pane) { window.swipe(at: s.rect, delta: subTabScroll > 0 ? -240 : 240) }
        }, done: { (window.subTabStrip(for: pane)?.scroll).map { $0 != subTabScroll } ?? false }))
        steps.append(Step(name: "subtabs: closed again", action: { window.closeAllEditors(in: pane) }, done: { pane.editors.isEmpty }))
        // A command's buttons, and picking several, as on the Mac.
        steps.append(Step(name: "blocks: two commands", action: {
            pane.type("echo pick-one")
            pane.pressEnter()
            pane.type("echo pick-two")
            pane.pressEnter()
        }, done: { hasLine("pick-two") && pane.atPrompt && pane.spot(onCommand: "echo pick-two") != nil }))
        steps.append(Step(name: "blocks: the pointer over one shows Send to chat and Copy output", action: {
            if let r = pane.spot(onCommand: "echo pick-two") { window.hover(r) }
        }, done: { pane.blockButtonRect("copy") != nil && pane.blockButtonRect("send") != nil }))
        steps.append(Step(name: "blocks: Copy output copies it with what it printed", action: {
            if let r = pane.blockButtonRect("copy") { window.click(r) }
        }, done: { pane.clipboardText() == "$ echo pick-two\npick-two" }))
        steps.append(Step(name: "blocks: Ctrl+click picks several, and the bar says how many", action: {
            pane.togglePickedForTest(command: "echo pick-one")
            pane.togglePickedForTest(command: "echo pick-two")
        }, done: { pane.pickedCount == 2 && pane.blockButtonRect("all-copy") != nil }))
        steps.append(Step(name: "blocks: Copy All copies them oldest first", action: {
            if let r = pane.blockButtonRect("all-copy") { window.click(r) }
        }, done: { pane.clipboardText() == "$ echo pick-one\npick-one\n\n$ echo pick-two\npick-two" }))
        steps.append(Step(name: "blocks: Esc puts them down", action: { pane.pressEscape() },
                          done: { pane.pickedCount == 0 && pane.blockButtonRect("all-copy") == nil }))
        // Collapsing a command's output, as the Mac's Shift-Command-E.
        steps.append(Step(name: "collapse: a command with some output", action: {
            pane.type("1..6 | ForEach-Object { 'collapse-line ' + $_ }")
            pane.pressEnter()
        }, done: { hasLine("collapse-line 6") && pane.atPrompt }))
        steps.append(Step(name: "collapse: Ctrl+Shift+E hides its output, and says how much", action: {
            _ = window.keyDown(0x45, shift: true, ctrl: true, alt: false)
        }, done: {
            let shown = pane.shownRowsText
            return !shown.contains("collapse-line 3") && shown.contains("collapse-line") && pane.collapsedChipCount == 1
                && (snapshotDirectory.map { window.saveSnapshot(to: $0 + "\\collapsed.png") } ?? true)
        }))
        steps.append(Step(name: "collapse: typing still goes to the prompt under it", action: {
            pane.type("echo under-collapsed")
            pane.pressEnter()
        }, done: { pane.shownRowsText.contains("under-collapsed") && pane.atPrompt }))
        steps.append(Step(name: "collapse: Expand All Outputs shows it again", action: { pane.setAllCollapsed(false) },
                          done: { pane.shownRowsText.contains("collapse-line 3") && pane.collapsedChipCount == 0 }))
        // Command History, Clear Buffer, text size and full screen, as on the Mac.
        steps.append(Step(name: "history: a command to find again", action: {
            pane.type("echo solanum-history-check")
            pane.pressEnter()
        }, done: { hasLine("solanum-history-check") && pane.atPrompt }))
        steps.append(Step(name: "history: Ctrl+Shift+H lists it", action: {
            _ = window.keyDown(0x48, shift: true, ctrl: true, alt: false)
        }, done: { window.isPaletteOpen && window.paletteRows.contains { $0.title == "echo solanum-history-check" } }))
        steps.append(Step(name: "history: Enter puts it at the prompt, not run", action: {
            window.typeIntoWindow("history-check")
        }, done: {
            guard window.paletteSelection?.title == "echo solanum-history-check" else { return false }
            window.pressPaletteEnterForTest()
            return true
        }))
        steps.append(Step(name: "history: there to edit", action: {}, done: {
            !window.isPaletteOpen && pane.cursorRowText.contains("echo solanum-history-check") && pane.atPrompt
        }))
        steps.append(Step(name: "clear: Esc empties the line", action: { pane.pressEscape() }, done: { !pane.cursorRowText.contains("solanum-history-check") }))
        steps.append(Step(name: "clear: Ctrl+Shift+K clears what came before", action: {
            _ = window.keyDown(0x4B, shift: true, ctrl: true, alt: false)
        }, done: { !pane.logicalText.contains("solanum-history-check") && pane.terminal.scrollback.count == 0 && pane.atPrompt }))
        steps.append(Step(name: "clear: typing still works after", action: {
            pane.type("echo after-clear")
            pane.pressEnter()
        }, done: { hasLine("after-clear") }))
        var sizeBefore = 0.0
        steps.append(Step(name: "text size: Ctrl+= makes it bigger", action: {
            sizeBefore = AppSettings.shared.fontSize
            _ = window.keyDown(0xBB, shift: false, ctrl: true, alt: false)
        }, done: { AppSettings.shared.fontSize == sizeBefore + 1 }))
        steps.append(Step(name: "text size: Ctrl+0 goes back to the default", action: {
            _ = window.keyDown(0x30, shift: false, ctrl: true, alt: false)
        }, done: { AppSettings.shared.fontSize == 11 }))
        steps.append(Step(name: "full screen: F11 fills the display", action: {
            _ = window.keyDown(0x7A, shift: false, ctrl: false, alt: false)
        }, done: { window.isFullScreen }))
        steps.append(Step(name: "full screen: F11 again goes back", action: {
            _ = window.keyDown(0x7A, shift: false, ctrl: false, alt: false)
        }, done: { !window.isFullScreen }))
        steps.append(Step(name: "sidebar: the magnifying glass searches its folder", action: { window.click(window.leftButton(.search)) },
                          done: { window.isPaletteOpen }))
        steps.append(Step(name: "sidebar: and closes", action: { pane.pressEscape() }, done: { !window.isPaletteOpen }))
        steps.append(Step(name: "git: out of the repository", action: {
            pane.type("cd ..")
            pane.pressEnter()
        }, done: { pane.atPrompt && pane.terminal.cwd?.hasSuffix("alpha") == true && window.activeGit == nil }))
        steps.append(Step(name: "path: the folder icon lists the first part's folders", action: { window.click(window.folderIconRect!) },
                          done: { window.menuTitles.contains("Copy Path") }))
        steps.append(Step(name: "path: and closes", action: { pane.pressEscape() }, done: { !window.isMenuOpen }))
        // The pin belongs to the tab.
        steps.append(Step(name: "per tab: pinned here", action: { window.click(window.leftButton(.pin)) }, done: { window.leftPinned != nil }))
        var pinnedRoot: String?
        steps.append(Step(name: "per tab: a new tab isn't", action: {
            pinnedRoot = window.leftTree.root
            window.newTab()
        }, done: { window.leftPinned == nil && pane.atPrompt && window.leftTree.root?.lowercased() == pane.terminal.cwd?.lowercased() }))
        steps.append(Step(name: "per tab: back again, it still is", action: { window.selectTab(window.activeIndex - 1) },
                          done: { window.leftPinned != nil && window.leftTree.root == pinnedRoot }))
        steps.append(Step(name: "per tab: and the other still isn't", action: { window.selectTab(window.activeIndex + 1) },
                          done: { window.leftPinned == nil }))
        steps.append(Step(name: "per tab: closing it returns to the pinned one", action: { press(0x57) },
                          done: { window.leftPinned != nil && window.leftTree.root == pinnedRoot && window.panes.count == 2 }))
        steps.append(Step(name: "per tab: unpinned", action: { window.click(window.leftButton(.pin)) }, done: { window.leftPinned == nil }))
        // Dragging tabs.
        steps.append(Step(name: "drag: a third tab to move", action: { window.newTab() }, done: { window.panes.count == 3 && pane.atPrompt }))
        var movedPane: UInt = 0
        steps.append(Step(name: "drag: past its neighbor, they trade places", action: {
            movedPane = window.panes[0].id
            window.dragTab(0, toX: window.currentLayout.tab(1).maxX + 30)
        }, done: { window.panes[0].id != movedPane && window.panes.contains { $0.id == movedPane } && !window.isDraggingTab }))
        steps.append(Step(name: "drag: a short drag is only a click", action: {
            movedPane = window.panes[1].id
            window.dragTab(1, toX: window.currentLayout.tab(1).x + 22)
        }, done: { window.panes[1].id == movedPane && window.activeIndex == 1 && !window.isDraggingTab }))
        steps.append(Step(name: "drag: closes the extra tab", action: { press(0x57) }, done: { window.panes.count == 2 }))
        if let dir = snapshotDirectory {
            steps.append(Step(name: "sidebar: snapshot", action: {}, done: {
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                return window.saveSnapshot(to: dir + "\\sidebars.png")
            }))
        }
        // A prompt long enough to wrap, which is how a sidebar can leave things, through changes of both kinds.
        func promptsIntact() -> Bool {
            !pane.terminal.screen.contains { $0.text().contains("PS ") && !$0.text().hasPrefix("PS ") }
        }
        steps.append(Step(name: "wrapped prompt: a sidebar's width leaves it whole", action: { press(0x42) },
                          done: { !window.leftIsVisible && !pane.isSettlingResize && promptsIntact() }))
        steps.append(Step(name: "wrapped prompt: getting shorter leaves it whole", action: { window.resizeWindow(toCols: 40, rows: 8) },
                          done: { pane.terminal.rows == 8 && !pane.isSettlingResize && promptsIntact() }))
        steps.append(Step(name: "wrapped prompt: taller too", action: { window.resizeWindow(toCols: 40, rows: 24) },
                          done: { pane.terminal.rows == 24 && !pane.isSettlingResize && promptsIntact() }))
        steps.append(Step(name: "wrapped prompt: typing goes after it", action: { pane.type("claud") }, done: {
            guard let row = pane.terminal.screen.firstIndex(where: { $0.text().hasPrefix("claud") || $0.text().contains("> claud") || $0.text().hasSuffix("claud") }) else { return false }
            return row == pane.terminal.cursorY && promptsIntact()
        }))
        steps.append(Step(name: "wrapped prompt: clears", action: { pane.pressEscape() }, done: { !pane.cursorRowText.contains("claud") }))
        steps.append(Step(name: "wrapped prompt: back to size", action: { window.resizeWindow(toCols: 100, rows: 30) }, done: { pane.terminal.cols == 100 || window.leftIsVisible }))
        steps.append(Step(name: "sidebar: typing reaches the terminal", action: {
            pane.type("echo after-sidebar")
            pane.pressEnter()
        }, done: { hasLine("after-sidebar") }))

        // A new tab opens in the current tab's folder, which Settings makes the default.
        steps.append(Step(name: "new tab: opens in the current tab's folder", action: { press(0x54) }, done: {
            window.panes.count == 3 && pane.atPrompt && pane.terminal.cwd?.lowercased() == window.panes[window.activeIndex - 1].terminal.cwd?.lowercased()
        }))
        steps.append(Step(name: "new tab: closes", action: { press(0x57) }, done: { window.panes.count == 2 }))
        // Themes.
        // Extensions, as on the Mac: the puzzle piece left of the theme's name opens its page; Ctrl+Shift+X closes it.
        steps.append(Step(name: "themes: the Extensions button opens its page", action: { window.click(window.extensionsSpotRect) }, done: {
            guard pane.panel is ExtensionsPanel else { return false }
            return snapshotDirectory.map { window.saveSnapshot(to: $0 + "\\extensions.png") } ?? true
        }))
        steps.append(Step(name: "themes: Ctrl+Shift+X closes it", action: { press(0x58, shift: true) }, done: { !(pane.panel is ExtensionsPanel) }))
        steps.append(Step(name: "themes: the status bar's theme opens the menu", action: { window.click(window.themeSpotRect) },
                          done: { window.menuTitles.contains("Quantum Moon") && window.menuTitles.contains("Dark+") }))
        steps.append(Step(name: "themes: choosing one changes everything", action: { window.click(window.menuRow("Quantum Moon")!) },
                          done: { TerminalPalette.background == 0x202125 && AppSettings.shared.themeName == "Quantum Moon" }))
        if let dir = snapshotDirectory {
            steps.append(Step(name: "themes: snapshot", action: {}, done: { window.saveSnapshot(to: dir + "\\theme.png") }))
        }
        steps.append(Step(name: "resize: no errors from re-anchoring", action: {},
                          done: { !pane.visibleText.contains("exception occurred in custom key handler") }))
        steps.append(Step(name: "themes: and back from the palette", action: {
            press(0x50, shift: true)
            pane.type("theme solanum default")
        }, done: { window.paletteSelection?.title == "Theme: Solanum Default" }))
        steps.append(Step(name: "themes: back to the default", action: { pane.pressEnter() },
                          done: { TerminalPalette.background == 0x111312 && !window.isPaletteOpen }))

        // Command blocks, as on the Mac: Ctrl+Up and Down step through them, and they copy with their output.
        steps.append(Step(name: "blocks: a command to step back to", action: {
            pane.type("Write-Output 'block-out'")
            pane.pressEnter()
        }, done: { pane.atPrompt && pane.finishedCommands().contains { $0.command == "Write-Output 'block-out'" } }))
        steps.append(Step(name: "blocks: Ctrl+Up picks it", action: { _ = window.keyDown(Win.VK_UP, shift: false, ctrl: true, alt: false) }, done: {
            guard case .block? = pane.selectedStop else { return false }
            return snapshotDirectory.map { window.saveSnapshot(to: $0 + "\\blocks.png") } ?? true
        }))
        steps.append(Step(name: "blocks: Ctrl+Alt+C copies it with its output", action: { _ = window.keyDown(0x43, shift: false, ctrl: true, alt: true) }, done: {
            let text = pane.clipboardText() ?? ""
            return text.hasPrefix("$ Write-Output 'block-out'") && text.contains("\nblock-out")
        }))
        steps.append(Step(name: "blocks: Esc puts it away", action: { pane.pressEscape() }, done: { pane.selectedStop == nil }))
        // Selecting what's being typed from the keyboard, as on the Mac.
        steps.append(Step(name: "blocks: a command being typed", action: { pane.type("echo hello world") },
                          done: { pane.terminal.cursorLineText.hasSuffix("echo hello world") }))
        steps.append(Step(name: "blocks: Shift+Ctrl+Left selects its last word", action: {
            _ = window.keyDown(Win.VK_LEFT, shift: true, ctrl: true, alt: false)
        }, done: { pane.selectedTextForTesting == "world" }))
        steps.append(Step(name: "blocks: Shift+Left takes in one more", action: { _ = window.keyDown(Win.VK_LEFT, shift: true, ctrl: false, alt: false) },
                          done: { pane.selectedTextForTesting == " world" }))
        steps.append(Step(name: "blocks: Ctrl+A selects just what's typed", action: { _ = window.keyDown(0x41, shift: false, ctrl: true, alt: false) },
                          done: { pane.selectedTextForTesting == "echo hello world" }))
        steps.append(Step(name: "blocks: Backspace takes it out", action: { _ = window.keyDown(Win.VK_BACK, shift: false, ctrl: false, alt: false) },
                          done: { pane.selectedTextForTesting == nil && !pane.terminal.cursorLineText.contains("hello") }))
        // Each tab's own history, as on the Mac: Up gives what ran here, and a new tab has none of it.
        steps.append(Step(name: "blocks: Up gives this tab's last command", action: { _ = window.keyDown(Win.VK_UP, shift: false, ctrl: false, alt: false) },
                          done: { pane.terminal.cursorLineText.contains("Write-Output 'block-out'") }))
        steps.append(Step(name: "blocks: Esc clears it", action: { pane.pressEscape() },
                          done: { !pane.terminal.cursorLineText.contains("block-out") }))
        var tabsBefore = 0
        steps.append(Step(name: "blocks: a new tab", action: { tabsBefore = window.panes.count; press(0x54) }, done: { window.panes.count == tabsBefore + 1 && window.activePane.atPrompt }))
        var newTabLine = ""
        steps.append(Step(name: "blocks: Up there doesn't give the other tab's", action: {
            _ = window.keyDown(Win.VK_UP, shift: false, ctrl: false, alt: false)
        }, done: {
            // Give PSReadLine a moment to draw whatever Up brings.
            newTabLine = window.activePane.terminal.cursorLineText
            return window.activePane.lastOutputAge > 0.4
        }))
        steps.append(Step(name: "blocks: (nothing from it)", action: {}, done: { !newTabLine.contains("block-out") }))
        steps.append(Step(name: "blocks: closes", action: { press(0x57) }, done: { window.panes.count == tabsBefore }))
        steps.append(Step(name: "blocks: Ctrl+J lists what was run", action: { _ = window.keyDown(0x4A, shift: false, ctrl: true, alt: false) },
                          done: { window.isPaletteOpen && window.paletteRows.contains { $0.title == "Write-Output 'block-out'" } }))
        steps.append(Step(name: "blocks: picking one goes to it", action: { pane.pressEnter() }, done: { !window.isPaletteOpen && pane.selectedStop != nil }))
        steps.append(Step(name: "blocks: and Esc puts it away again", action: { pane.pressEscape() }, done: { pane.selectedStop == nil }))

        // A running agent is known, so a restart continues it (as `claude -c`), as on the Mac. A stand-in named claude.
        steps.append(Step(name: "resume: a stand-in for Claude Code", action: {
            pane.type("function claude { Start-Sleep -Seconds 60 }")
            pane.pressEnter()
        }, done: { pane.atPrompt }))
        steps.append(Step(name: "resume: running, it would continue after a restart", action: {
            pane.type("claude")
            pane.pressEnter()
        }, done: { pane.resumeCommand == "claude -c" }))
        steps.append(Step(name: "resume: and stopped, nothing would", action: { pane.type("\u{03}") },
                          done: { pane.atPrompt && pane.resumeCommand == nil }))

        // Send to Chat, as the Mac's Option-Command-S: a command and its output, to a chat running in another tab.
        var chatPane: TerminalPane?
        var sendingIndex = 0
        steps.append(Step(name: "chat: a command to send", action: {
            pane.type("echo chat-me")
            pane.pressEnter()
        }, done: { hasLine("chat-me") && pane.atPrompt }))
        steps.append(Step(name: "chat: a stand-in chat in a tab of its own", action: {
            sendingIndex = window.activeIndex
            window.newTab()
        }, done: { pane.atPrompt && window.activeIndex != sendingIndex }))
        steps.append(Step(name: "chat: a stand-in for Claude Code there", action: {
            chatPane = window.activePane
            pane.type("function claude { Start-Sleep -Seconds 60 }")
            pane.pressEnter()
        }, done: { pane.atPrompt }))
        // An agent is known by the program a command starts with, so it runs on its own line.
        steps.append(Step(name: "chat: running there", action: {
            pane.type("claude")
            pane.pressEnter()
        }, done: { chatPane?.agent?.kind == .claude }))
        steps.append(Step(name: "chat: Ctrl+Alt+S, back in the first tab, lists it", action: {
            window.selectTab(sendingIndex)
            _ = window.keyDown(0x53, shift: false, ctrl: true, alt: true)
        }, done: { window.menuTitles.contains("Active Chats") && window.menuTitles.count >= 2 }))
        steps.append(Step(name: "chat: the pointer over it marks its tab", action: {
            if let title = window.menuTitles.first(where: { $0 != "Active Chats" && !$0.hasPrefix("New ") && !$0.isEmpty }), let r = window.menuRow(title) {
                window.hover(r)
            }
        }, done: { window.sendTargetPane != nil && window.sendTargetPane == chatPane?.id }))
        steps.append(Step(name: "chat: choosing it goes there", action: {
            if let title = window.menuTitles.first(where: { $0 != "Active Chats" && !$0.hasPrefix("New ") && !$0.isEmpty }), let r = window.menuRow(title) {
                window.click(r)
            }
        }, done: { !window.isMenuOpen && window.activePane === chatPane && window.sendTargetPane == nil }))
        steps.append(Step(name: "chat: and closes", action: {
            chatPane?.type("\u{03}")
            if let i = window.panes.firstIndex(where: { $0 === chatPane }) { window.closeTab(i) }
        }, done: { !window.panes.contains { $0 === chatPane } && pane.atPrompt }))

        // Tab groups.
        // Four tabs, however many earlier sections left (two in a full run; one when run by itself).
        steps.append(Step(name: "groups: tabs to group", action: { while window.panes.count < 4 { window.newTab() } },
                          done: { window.panes.count == 4 && pane.atPrompt }))
        steps.append(Step(name: "groups: Ctrl and Shift pick tabs", action: {
            window.selectTab(1)
            window.pickForTest(3, range: true)
        }, done: { true }))
        steps.append(Step(name: "groups: right-click offers to group them", action: { window.rightClick(window.currentLayout.tab(2)) },
                          done: { window.menuTitles.contains("Add 3 Tabs to New Group") }))
        steps.append(Step(name: "groups: grouping asks for a name", action: { window.click(window.menuRow("Add 3 Tabs to New Group")!) },
                          done: { window.isNaming && window.groupNames.count == 1 }))
        steps.append(Step(name: "groups: keys pressed while naming go on to be typed", action: {},
                          done: { window.isNaming && !window.keyDown(0x41, shift: false, ctrl: false, alt: false) && window.isNaming }))
        steps.append(Step(name: "groups: Enter keeps the suggested name", action: { pane.pressEnter() },
                          done: { !window.isNaming && window.groupNames == ["Project 1"] }))
        steps.append(Step(name: "rename: double-clicking a tab names it", action: { window.doubleClick(window.currentLayout.tab(window.activeIndex)) },
                          done: { window.isNaming }))
        steps.append(Step(name: "rename: typing, then clicking elsewhere keeps the name", action: {
            for _ in 0..<12 { _ = window.keyDown(0x08, shift: false, ctrl: false, alt: false) }
            window.typeIntoWindow("named")
        }, done: {
            guard window.paneNameField == "named" else { return false }
            window.click(UIRect(x: Float(window.currentLayout.width) / 2, y: Float(window.currentLayout.height) / 2, width: 2, height: 2))
            return !window.isNaming && pane.tabTitle == "named"
        }))
        steps.append(Step(name: "rename: Reset Tab Name", action: { window.rightClick(window.currentLayout.tab(window.activeIndex)) }, done: {
            guard let row = window.menuRow("Reset Tab Name") else { return false }
            window.click(row)
            return pane.customTitle == nil
        }))
        steps.append(Step(name: "groups: Rename Group… from its chip", action: { window.rightClick(window.chipRect(1)!) }, done: {
            guard let row = window.menuRow("Rename Group…") else { return false }
            window.click(row)
            return true
        }))
        steps.append(Step(name: "groups: typing names it", action: {}, done: {
            guard window.isNaming else { return false }
            for _ in 0..<12 { _ = window.keyDown(0x08, shift: false, ctrl: false, alt: false) }
            window.typeIntoWindow("web")
            pane.pressEnter()
            return true
        }))
        steps.append(Step(name: "groups: and it's named", action: {}, done: { !window.isNaming && window.groupNames == ["web"] && window.chipRect(1) != nil }))
        if let dir = snapshotDirectory {
            steps.append(Step(name: "groups: snapshot", action: {}, done: { window.saveSnapshot(to: dir + "\\groups.png") }))
        }
        steps.append(Step(name: "groups: its chip collapses it", action: { window.click(window.chipRect(1)!) },
                          done: { window.currentLayout.tab(2).width == 0 && window.activeIndex == 0 }))
        if let dir = snapshotDirectory {
            steps.append(Step(name: "groups: collapsed snapshot", action: {}, done: { window.saveSnapshot(to: dir + "\\groups-collapsed.png") }))
        }
        steps.append(Step(name: "groups: and expands it", action: { window.click(window.chipRect(1)!) }, done: { window.currentLayout.tab(2).width > 0 }))
        steps.append(Step(name: "groups: dragging the chip moves the group", action: {
            window.dragChip(1, toX: window.currentLayout.tab(0).x - 10)
        }, done: { window.chipRect(0) != nil && window.panes[3].group == nil && window.groupNames == ["web"] && window.currentLayout.tab(2).width > 0 }))
        steps.append(Step(name: "groups: and back past the tab", action: {
            let l = window.currentLayout
            window.dragChip(0, toX: l.tab(3).x + l.tab(3).width + 40)
        }, done: { window.chipRect(1) != nil && window.panes[0].group == nil }))
        var shown: (split: Int?, chip: Bool, marker: Bool) = (nil, false, false)
        steps.append(Step(name: "groups: a tab dragged past its group's end leaves it, a bar showing where", action: {
            let l = window.currentLayout, r = l.tab(3)
            window.dragTab(3, toX: r.x + r.width + r.width * 0.6, y: r.midY) { shown = window.dragShows }
        }, done: { shown.marker && window.panes[3].group == nil && window.chipRect(1) != nil }))
        steps.append(Step(name: "groups: dropped on a group's chip, it joins", action: {
            let chip = window.chipRect(1)!
            window.dragTab(3, toX: chip.x + chip.width / 2, y: chip.midY) { shown = window.dragShows }
        }, done: { shown.chip && window.panes[3].group != nil && window.groupNames == ["web"] }))
        steps.append(Step(name: "groups: dragged down over the terminal, it goes into split view", action: {
            let l = window.currentLayout
            window.dragTab(3, toX: l.width * 0.75, y: l.height / 2) { shown = window.dragShows }
        }, done: {
            shown.split == 1 && window.isSplit && window.panes.last?.column == 1 && window.panes.last?.group == nil
                && (snapshotDirectory.map { _ in true } ?? true)
        }))
        steps.append(Step(name: "groups: while split, a tab after the group on the left, and the right one joins the group", action: {
            window.selectTab(0)
            window.newTab()
            window.panes.last { $0.column == 1 }?.group = window.panes[1].group
        }, done: { window.panes.count == 5 && window.panes.filter { $0.column == 0 }.count == 4 }))
        steps.append(Step(name: "groups: and the split closes again, the group's tabs together under one chip", action: { window.closeSplit() }, done: {
            let g = window.panes[1].group, members = window.panes.indices.filter { window.panes[$0].group === g && g != nil }
            return !window.isSplit && window.chipRect(1) != nil && members == [1, 2, 3]
                && (0..<window.panes.count).filter { window.chipRect($0) != nil } == [1]
        }))
        steps.append(Step(name: "groups: a tab put into split view again", action: {
            let l = window.currentLayout
            window.dragTab(4, toX: l.width * 0.75, y: l.height / 2) { shown = window.dragShows }
        }, done: { window.isSplit && window.panes.last?.column == 1 && window.panes.last?.group == nil }))
        // The left strip may scroll, narrow as it is: its group's second tab brought into view, the tab's let go over
        // the left part of it, between the group's two tabs.
        steps.append(Step(name: "groups: dragged from the right column in among the group's tabs on the left, it joins", action: {
            window.selectTab(2)
            let r = window.currentLayout.tab(2)
            window.dragTab(window.panes.count - 1, toX: r.x + r.width * 0.25, y: r.midY) { shown = window.dragShows }
            // What happened, for the log if the check below fails.
            print("    (columns \(window.panes.map(\.column)), grouped \(window.panes.map { $0.group != nil }))")
        }, done: {
            let g = window.panes[1].group
            return g != nil && window.panes.filter { $0.group === g }.count == 4 && window.panes.allSatisfy { $0.column == 0 }
                && (0..<window.panes.count).filter { window.chipRect($0) != nil } == [1]
        }))
        steps.append(Step(name: "groups: the chip's menu", action: { window.rightClick(window.chipRect(1)!) },
                          done: { window.menuTitles.contains("Ungroup") && window.menuTitles.contains("Purple") }))
        steps.append(Step(name: "groups: ungroups", action: { window.click(window.menuRow("Ungroup")!) },
                          done: { window.groupNames.isEmpty && !window.isMenuOpen }))
        steps.append(Step(name: "groups: back to two tabs", action: {}, done: {
            if window.panes.count > 2 && pane.atPrompt { press(0x57) }
            return window.panes.count == 2
        }))

        // Splits: two columns, each with its own tabs.
        func keys(_ k: Int32, shift: Bool = false, alt: Bool = false) { _ = window.keyDown(k, shift: shift, ctrl: true, alt: alt) }
        steps.append(Step(name: "split: Ctrl+Alt+D opens the right column", action: { keys(0x44, alt: true) },
                          done: { window.isSplit && window.splitColumnCounts == [2, 1] && window.focusedColumn == 1 && pane.atPrompt }))
        steps.append(Step(name: "split: each column is half the width", action: {}, done: {
            let l = window.currentLayout, left = window.panes[0]
            return window.paneArea(pane).x == l.rightColumnX && window.paneArea(left).maxX == l.divider && pane.terminal.cols * 2 <= left.terminal.cols + pane.terminal.cols + 2
        }))
        var colsBefore = 0
        steps.append(Step(name: "split: dragging the band between them resizes both", action: {
            colsBefore = pane.terminal.cols
            let l = window.currentLayout
            window.dragColumnBand(to: l.divider + (l.width - l.divider) / 2)
        }, done: {
            let l = window.currentLayout
            return pane.terminal.cols < colsBefore && window.paneArea(pane).x == l.rightColumnX
                && (snapshotDirectory.map { window.saveSnapshot(to: $0 + "\\split-band.png") } ?? true)
        }))
        steps.append(Step(name: "split: and back to halves", action: { window.dragColumnBand(to: window.currentLayout.width / 2) },
                          done: { pane.terminal.cols >= colsBefore - 1 }))
        steps.append(Step(name: "split: typing goes to the column with the keyboard", action: {
            pane.type("echo right-column")
            pane.pressEnter()
        }, done: { hasLine("right-column") && pane.atPrompt }))
        steps.append(Step(name: "split: both columns show", action: {}, done: { window.shownPaneIDs.count == 2 }))
        if let dir = snapshotDirectory {
            steps.append(Step(name: "split: snapshot", action: {}, done: { window.saveSnapshot(to: dir + "\\split.png") }))
        }
        steps.append(Step(name: "split: a click in the left column gives it the keyboard", action: {
            let l = window.currentLayout
            window.click(UIRect(x: l.terminal.x + 40, y: l.terminal.maxY - 40, width: 2, height: 2))
        }, done: { window.focusedColumn == 0 }))
        steps.append(Step(name: "split: Ctrl+Shift+D moves a tab over", action: { keys(0x44, shift: true) },
                          done: { window.splitColumnCounts == [1, 2] && window.focusedColumn == 1 }))
        steps.append(Step(name: "split: Ctrl+1 picks within the column", action: { keys(0x31) },
                          done: { window.activeIndex == 1 && window.focusedColumn == 1 }))
        steps.append(Step(name: "split: the right sidebar follows the right column", action: { _ = window.keyDown(0x42, shift: false, ctrl: true, alt: true) }, done: {
            window.rightIsVisible && window.rightTree.root?.lowercased() == pane.terminal.cwd?.lowercased()
        }))
        steps.append(Step(name: "split: the right strip's + adds there", action: { window.click(window.currentLayout.newTab(column: 1)) },
                          done: { window.splitColumnCounts == [1, 3] && window.focusedColumn == 1 && pane.atPrompt }))
        steps.append(Step(name: "split: closing a right tab keeps the split", action: { press(0x57) },
                          done: { window.splitColumnCounts == [1, 2] }))
        steps.append(Step(name: "split: Ctrl+Alt+W puts the columns back together", action: { keys(0x57, alt: true) },
                          done: { !window.isSplit && window.splitColumnCounts == [3] && !window.rightIsVisible && window.shownPaneIDs.count == 1 }))
        steps.append(Step(name: "split: and the terminal is full width again", action: {}, done: {
            window.paneArea(pane).maxX == window.currentLayout.terminal.maxX && window.currentLayout.terminal.x == window.currentLayout.leftWidth
        }))
        steps.append(Step(name: "split: again, for closing its last tab", action: { keys(0x44, alt: true) },
                          done: { window.splitColumnCounts == [3, 1] && pane.atPrompt }))
        steps.append(Step(name: "split: closing the right column's last tab ends it", action: { press(0x57) },
                          done: { !window.isSplit && window.panes.count == 3 && window.focusedColumn == 0 }))
        steps.append(Step(name: "split: back to two tabs", action: {}, done: {
            if window.panes.count > 2 && pane.atPrompt { press(0x57) }
            return window.panes.count == 2
        }))

        var flowerLit = false
        steps.append(Step(name: "flower: highlights under the pointer", action: {
            window.hover(window.currentLayout.flower)
            flowerLit = window.hoveredPart == .flower
        }, done: { flowerLit }))
        // ssh: the hosts button, and where GitHub's machine has an ssh server with a password, the whole flow.
        steps.append(Step(name: "ssh: the hosts button opens its menu", action: { window.click(window.hostsButtonRect) },
                          done: { window.menuTitles.contains("Edit SSH Config…") && window.menuSearchText == "" }))
        steps.append(Step(name: "ssh: New Connection… types ssh in the search box and stays open", action: {
            if let r = window.menuRow("New Connection…") { window.click(r) }
        }, done: { window.isMenuOpen && window.menuSearchText == "ssh " && !window.menuTitles.contains("New Connection…") }))
        steps.append(Step(name: "ssh: a host that isn't listed, typed, becomes a row to connect to it", action: { window.typeKeys("box.test") },
                          done: { window.menuSearchText == "ssh box.test" && window.menuTitles.contains("ssh box.test") }))
        steps.append(Step(name: "ssh: closes", action: { pane.pressEscape() }, done: { !window.isMenuOpen }))
        let env = ProcessInfo.processInfo.environment
        if let user = env["SOLANUM_TEST_SSH_USER"], let password = env["SOLANUM_TEST_SSH_PASSWORD"] {
            steps.append(Step(name: "ssh: asks for the password in Solanum", action: {
                pane.type("ssh -o StrictHostKeyChecking=accept-new \(user)@localhost")
                pane.pressEnter()
            }, done: { pane.questionPrompt?.lowercased().contains("password") == true }))
            if let dir = snapshotDirectory {
                steps.append(Step(name: "ssh: snapshot of the question", action: {}, done: { window.saveSnapshot(to: dir + "\\ssh-question.png") }))
            }
            steps.append(Step(name: "ssh: signs in with it", action: {
                window.typeIntoWindow(password)
                pane.pressEnter()
            }, done: { !pane.hasQuestion && !pane.logicalText.contains("Permission denied") && pane.sshHost == "localhost" && pane.lastAnswerLength != nil }))
            steps.append(Step(name: "ssh: the answer was the password's length", action: {}, done: { pane.lastAnswerLength == password.count }))
            steps.append(Step(name: "ssh: keeps the password for the sidebar", action: {}, done: { pane.hasRememberedPassword }))
            steps.append(Step(name: "ssh: the remote machine answers", action: {
                pane.type("echo remote-ok")
                pane.pressEnter()
            }, done: { hasLine("remote-ok") }))
            steps.append(Step(name: "ssh: the tab is named after the server", action: {}, done: { pane.tabTitle == "localhost" }))
            if let dir = snapshotDirectory {
                steps.append(Step(name: "ssh: snapshot connected", action: {}, done: { window.saveSnapshot(to: dir + "\\ssh-connected.png") }))
            }
            steps.append(Step(name: "ssh: the sidebar signs in with the same password", action: { press(0x42) }, done: {
                window.leftIsVisible && window.leftTree.root.map(AnyPath.isUnix) == true && !window.leftTree.rows.isEmpty
            }))
            steps.append(Step(name: "ssh: the sidebar's connection, as it went", action: {
                for line in pane.remoteDiagnostics { print("    " + line.replacingOccurrences(of: "\n", with: " | ")) }
            }, done: { true }))
            steps.append(Step(name: "ssh: and shows what's made there", action: {
                // Led by a space, which bash ignores: the test machine's Git bash sometimes drops the first key typed as
                // another login of the same user (the sidebar's) starts.
                pane.type(" touch from-remote.txt")
                pane.pressEnter()
            }, done: { window.leftRow(named: "from-remote.txt") != nil }))
            steps.append(Step(name: "ssh: finds the terminal's folder on the host", action: {
                let look = #"for d in /proc/[0-9]*; do [ -O "$d" ] && echo "${d#/proc/} $(readlink $d/fd/0) $(cat $d/comm) $(tr '\0' ' ' < $d/environ 2>/dev/null | grep -o 'LC_SOLANUM[^ ]*')"; done 2>/dev/null | grep -v ' pipe:\| socket:' | head -20"#
                print("    session: \(pane.terminal.sshControlPath ?? "none")")
                pane.remote?.run(look) { text, _ in
                    for line in (text ?? "(nothing)").split(separator: "\n") { print("    proc: " + line) }
                }
            }, done: { pane.remoteShellFolder != nil }))
            steps.append(Step(name: "ssh: the status bar shows the host's whole path", action: {}, done: {
                window.crumbRect("/") != nil && window.crumbRect("solanumtest") != nil && window.crumbRect("~") == nil
            }))
            steps.append(Step(name: "ssh: double-clicking a folder sends the terminal there", action: {
                if let row = window.leftRow(named: "Documents") { window.doubleClick(row) }
            }, done: { pane.remoteShellFolder?.hasSuffix("/Documents") == true && window.leftTree.root?.hasSuffix("/Documents") == true }))
            steps.append(Step(name: "ssh: the path's home part lists the host's folders", action: {
                if let r = window.crumbRect("solanumtest") { window.click(r) }
            }, done: { window.menuTitles.contains("Desktop") && window.menuTitles.contains("Copy Path") }))
            steps.append(Step(name: "ssh: choosing one sends the terminal there", action: {
                if let row = window.menuRow("Desktop") { window.click(row) }
            }, done: { pane.remoteShellFolder?.hasSuffix("/Desktop") == true && !window.isMenuOpen }))
            if let dir = snapshotDirectory {
                steps.append(Step(name: "ssh: snapshot of the sidebar on the host", action: {}, done: { window.saveSnapshot(to: dir + "\\ssh-sidebar.png") }))
            }
            // Files on the host, through the sidebar's connection.
            let hostTemp = NSTemporaryDirectory().replacingOccurrences(of: "/", with: "\\")
            let toUpload = WindowsPath.join(hostTemp, "uploadme-\(ProcessInfo.processInfo.processIdentifier).txt"), uploadName = WindowsPath.name(toUpload)
            let downloads = WindowsPath.join(hostTemp, "solanum-downloads-\(ProcessInfo.processInfo.processIdentifier)")
            func hostTyped(_ text: String) {
                for _ in 0..<40 { _ = window.keyDown(Win.VK_BACK, shift: false, ctrl: false, alt: false) }
                window.typeIntoWindow(text)
                pane.pressEnter()
            }
            steps.append(Step(name: "ssh files: the sidebar is on the host's folder", action: {}, done: {
                window.leftTree.root?.hasSuffix("/Desktop") == true && !window.leftTree.isLoadingRoot
            }))
            steps.append(Step(name: "ssh files: its menu has uploading", action: { window.rightClick(window.leftListEmptySpot) },
                              done: { window.menuTitles.contains("Upload Files Here…") && window.menuTitles.contains("New Folder…") }))
            steps.append(Step(name: "ssh files: a new folder there", action: {
                window.click(window.menuRow("New Folder…")!)
                hostTyped("made-on-host")
            }, done: { window.leftRow(named: "made-on-host") != nil }))
            steps.append(Step(name: "ssh files: renamed there", action: {
                if let row = window.leftRow(named: "made-on-host") { window.click(row) }
                _ = window.keyDown(Win.VK_F2, shift: false, ctrl: false, alt: false)
                hostTyped("renamed-on-host")
            }, done: { window.leftRow(named: "renamed-on-host") != nil && window.leftRow(named: "made-on-host") == nil }))
            steps.append(Step(name: "ssh files: uploads a file", action: {
                _ = FileManager.default.createFile(atPath: toUpload, contents: Data("from windows".utf8))
                window.uploadForTest([toUpload], into: window.leftTree.root!)
            }, done: { window.leftRow(named: uploadName) != nil }))
            steps.append(Step(name: "ssh files: and downloads it back", action: {
                try? FileManager.default.createDirectory(atPath: downloads, withIntermediateDirectories: true)
                window.downloadForTest([window.leftTree.root! + "/" + uploadName], into: downloads)
            }, done: {
                (try? String(contentsOfFile: WindowsPath.join(downloads, uploadName), encoding: .utf8)) == "from windows"
            }))
            steps.append(Step(name: "ssh files: deleting there asks first", action: {
                window.click(window.leftRow(named: uploadName)!)
                _ = window.keyDown(Win.VK_DELETE, shift: false, ctrl: false, alt: false)
            }, done: { window.menuTitles.contains("Delete") && window.menuTitles.contains("Cancel") }))
            steps.append(Step(name: "ssh files: and deletes", action: { window.click(window.menuRow("Delete")!) },
                              done: { window.leftRow(named: uploadName) == nil && !window.isMenuOpen }))
            // The server's end of each connection goes, as when the network drops: ssh sees the connection close, and exits 255.
            steps.append(Step(name: "ssh: a dropped connection shows the bar", action: {
                print("    ended \(endSSHConnections()) of the server's connection processes")
            }, done: { pane.showsLostBar && pane.sshHost == nil && window.leftTree.root.map(AnyPath.isUnix) == false }))
            if let dir = snapshotDirectory {
                steps.append(Step(name: "ssh: snapshot of the bar", action: {}, done: { window.saveSnapshot(to: dir + "\\ssh-lost.png") }))
            }
            steps.append(Step(name: "ssh: how it ended", action: {
                for line in pane.remoteDiagnostics.suffix(2) { print("    " + line) }
            }, done: { true }))
            var remoteBefore: RemoteConnection?
            steps.append(Step(name: "ssh: Reconnect signs both back in without asking", action: {
                remoteBefore = pane.remote
                window.clickLostBar(.reconnect)
            }, done: {
                pane.reconnectedCount > 0 && pane.sshHost == "localhost" && !pane.hasQuestion && !pane.showsLostBar && pane.lost == nil
                    && pane.remote != nil && pane.remote !== remoteBefore && pane.remote?.state == .ready && window.leftTree.root.map(AnyPath.isUnix) == true
            }))
            steps.append(Step(name: "ssh: back on the host", action: {
                pane.type("echo again-ok")
                pane.pressEnter()
            }, done: { hasLine("again-ok") && !pane.hasQuestion }))
            steps.append(Step(name: "ssh: leaving forgets the password", action: {
                pane.type("exit")
                pane.pressEnter()
            }, done: { pane.sshHost == nil && !pane.hasRememberedPassword && pane.atPrompt }))
            steps.append(Step(name: "ssh: the sidebar comes back to this machine", action: {},
                              done: { window.leftTree.root.map(AnyPath.isUnix) == false && pane.remoteStatus == nil }))
            steps.append(Step(name: "ssh: the sidebar hides", action: { press(0x42) }, done: { !window.leftIsVisible }))
            // The hosts menu now knows localhost, from known_hosts. Alt shows each host's "in This Pane".
            steps.append(Step(name: "hosts: a known host", action: { window.click(window.hostsButtonRect) },
                              done: { window.menuTitles.contains("localhost") }))
            steps.append(Step(name: "hosts: holding Alt shows in This Pane", action: { PostMessageW(window.hwnd, Win.WM_SYSKEYDOWN, WPARAM(Win.VK_MENU), 0) },
                              done: { window.menuTitles.contains("localhost — in This Pane") && !window.menuTitles.contains("localhost") && window.isMenuOpen }))
            steps.append(Step(name: "hosts: letting go shows the new tab one again", action: { PostMessageW(window.hwnd, Win.WM_KEYUP, WPARAM(Win.VK_MENU), 0) },
                              done: { window.menuTitles.contains("localhost") && window.isMenuOpen }))
            var tabsBefore = 0
            steps.append(Step(name: "hosts: in This Pane connects here, not in a new tab", action: {
                tabsBefore = window.tabCount
                PostMessageW(window.hwnd, Win.WM_SYSKEYDOWN, WPARAM(Win.VK_MENU), 0)
            }, done: {
                guard window.tabCount == tabsBefore else { return false }
                if let row = window.menuRow("localhost — in This Pane") { window.click(row) }
                return !window.isMenuOpen && pane.logicalText.contains("ssh localhost")
            }))
            // There's no password for this account: each question is cancelled until ssh gives up.
            steps.append(Step(name: "hosts: and gives up when cancelled", action: {}, done: {
                if pane.hasQuestion { pane.pressEscape() }
                return window.tabCount == tabsBefore && pane.atPrompt && pane.sshHost == nil
            }))
        }
        // Settings.
        let settingsWindow = SettingsWindow.shared
        steps.append(Step(name: "settings: the flower opens it", action: { window.click(window.currentLayout.flower) },
                          done: { settingsWindow.isOpen }))
        for page in SettingsWindow.Page.allCases {
            steps.append(Step(name: "settings: \(page.title)", action: { settingsWindow.showPage(page) }, done: {
                guard let dir = snapshotDirectory else { return true }
                return settingsWindow.saveSnapshot(to: dir + "\\settings-\(page.rawValue)-\(page.title.replacingOccurrences(of: " & ", with: "-")).png")
            }))
        }
        steps.append(Step(name: "settings: a toggle", action: {
            settingsWindow.showPage(.text)
        }, done: {
            guard let r = settingsWindow.controlRect(forRow: "Copy on select") else { return false }
            settingsWindow.click(r)
            return true
        }))
        steps.append(Step(name: "settings: turns its setting on", action: {}, done: { AppSettings.shared.copyOnSelect }))
        steps.append(Step(name: "settings: and off", action: { settingsWindow.click(settingsWindow.controlRect(forRow: "Copy on select")!) },
                          done: { !AppSettings.shared.copyOnSelect }))
        steps.append(Step(name: "settings: a choice opens its menu", action: {
            settingsWindow.showPage(.preferences)
        }, done: {
            guard let r = settingsWindow.controlRect(forRow: "New tabs open in") else { return false }
            settingsWindow.click(r)
            return true
        }))
        steps.append(Step(name: "settings: and picks", action: {}, done: {
            guard let row = settingsWindow.menuRow("Home Folder") else { return false }
            settingsWindow.click(row)
            return true
        }))
        steps.append(Step(name: "settings: new tabs open at home now", action: {}, done: { AppSettings.shared.newTabFolder == "home" }))
        steps.append(Step(name: "settings: back to the current folder", action: { AppSettings.shared.set("new-tab-folder", "current") },
                          done: { AppSettings.shared.newTabFolder == "current" }))
        var cellBefore: Float = 0
        steps.append(Step(name: "settings: a field takes typing", action: {
            cellBefore = window.fontCellHeight
            settingsWindow.showPage(.text)
        }, done: {
            guard let r = settingsWindow.controlRect(forRow: "Size") else { return false }
            settingsWindow.click(r)
            settingsWindow.pressKey(0x08)
            settingsWindow.pressKey(0x08)
            settingsWindow.type("15")
            settingsWindow.pressKey(0x0D)
            return true
        }))
        steps.append(Step(name: "settings: and the text gets bigger", action: {},
                          done: { AppSettings.shared.fontSize == 15 && window.fontCellHeight > cellBefore }))
        steps.append(Step(name: "settings: back to its size", action: { AppSettings.shared.set("font-size", "11") }, done: { abs(window.fontCellHeight - cellBefore) < 0.5 }))
        steps.append(Step(name: "settings: a theme card", action: { settingsWindow.showPage(.appearance) }, done: {
            guard let r = settingsWindow.themeRect("Giant's Deep") else { return false }
            settingsWindow.click(r)
            return true
        }))
        steps.append(Step(name: "settings: switches the theme", action: {}, done: { AppSettings.shared.themeName == "Giant's Deep" && TerminalPalette.background == 0x0B3328 }))
        steps.append(Step(name: "settings: back to the default theme", action: { AppSettings.shared.set("theme", ThemeSpecs.defaultName) },
                          done: { TerminalPalette.background == 0x111312 }))
        var aliasesBefore: [CommandAlias] = []
        steps.append(Step(name: "aliases: Add Alias makes a row to type in", action: {
            aliasesBefore = AliasFile.load()
            settingsWindow.showPage(.aliases)
        }, done: {
            guard let r = settingsWindow.linkRect("Add Alias") else { return false }
            settingsWindow.click(r)
            settingsWindow.type("hey")
            settingsWindow.pressKey(0x0D)
            return true
        }))
        steps.append(Step(name: "aliases: it's kept", action: {}, done: { AliasFile.load().last?.name == "hey" && settingsWindow.aliasCount == aliasesBefore.count + 1 }))
        steps.append(Step(name: "aliases: reach the shell at its next prompt", action: {
            AliasFile.save(aliasesBefore + [CommandAlias(name: "hey", command: "echo alias-works")])
            pane.pressEnter()
        }, done: { pane.atPrompt }))
        steps.append(Step(name: "aliases: and run", action: {
            pane.type("hey")
            pane.pressEnter()
        }, done: { hasLine("alias-works") }))
        steps.append(Step(name: "settings: closes", action: {
            AliasFile.save(aliasesBefore)
            settingsWindow.close()
        }, done: { !settingsWindow.isOpen }))

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

        // `--window-test graph,ssh`: just the sections whose names start with those (each step is "section: what"),
        // after the first step (the shell at its prompt). A section that builds on another needs that one listed too
        // ("git,graph"). Such a run stops at its first failure, as later steps would only be working from a wrong start.
        let flag = CommandLine.arguments.firstIndex(of: "--window-test")
        var stopsAtFailure = false
        if let flag, CommandLine.arguments.indices.contains(flag + 1), !CommandLine.arguments[flag + 1].hasPrefix("--") {
            let wanted = CommandLine.arguments[flag + 1].lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let first = steps[0]
            steps = [first] + steps.dropFirst().filter { step in
                let section = step.name.split(separator: ":").first.map { String($0).lowercased() } ?? ""
                return wanted.contains { section.hasPrefix($0) }
            }
            stopsAtFailure = true
            print("Only \(wanted.joined(separator: ", ")): \(steps.count) steps.")
        }
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
            if !passed && stopsAtFailure { index = steps.count + 1 }
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

/// Ends every connection to this machine's ssh server, leaving the server itself: the sshd processes it started for
/// them. For tests.
func endSSHConnections() -> Int {
    let snapshot = CreateToolhelp32Snapshot(DWORD(TH32CS_SNAPPROCESS), 0)
    guard let snapshot, snapshot != INVALID_HANDLE_VALUE else { return 0 }
    defer { CloseHandle(snapshot) }
    var entry = PROCESSENTRY32W()
    entry.dwSize = DWORD(MemoryLayout<PROCESSENTRY32W>.size)
    var processes: [DWORD: (name: String, parent: DWORD)] = [:]
    var more = Process32FirstW(snapshot, &entry)
    while more {
        let name = withUnsafeBytes(of: entry.szExeFile) { String(decoding: $0.bindMemory(to: UInt16.self).prefix { $0 != 0 }, as: UTF16.self) }
        processes[entry.th32ProcessID] = (name.lowercased(), entry.th32ParentProcessID)
        more = Process32NextW(snapshot, &entry)
    }
    var ended = 0
    for (id, p) in processes where p.name == "sshd.exe" && processes[p.parent]?.name == "sshd.exe" {
        guard let process = OpenProcess(DWORD(PROCESS_TERMINATE), false, id) else { continue }
        if TerminateProcess(process, 1) { ended += 1 }
        CloseHandle(process)
    }
    return ended
}
