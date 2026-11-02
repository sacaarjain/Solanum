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
        results.check("sidebars: tabs start at the terminal", sides.tab(0).x == 240)
        results.check("sidebars: found by position", sides.part(atX: 100, y: 200) == .leftSidebar && sides.part(atX: 900, y: 200) == .rightSidebar && sides.part(atX: 500, y: 200) == .terminal)
        results.check("sidebars: their borders can be grabbed", sides.part(atX: 240, y: 200) == .leftEdge && sides.part(atX: 800, y: 200) == .rightEdge)
        results.check("sidebars: the left switch is always there", sides.part(atX: sides.toggleLeft.x + 2, y: sides.toggleLeft.midY) == .toggleLeft)
        results.check("sidebars: the right switch only in a split", sides.part(atX: sides.toggleRight.x + 2, y: sides.toggleRight.midY) == .statusBar
                      && WindowLayout(width: 1000, height: 640, scale: 1, tabCount: 2, showsRightToggle: true).part(atX: sides.toggleRight.x + 2, y: sides.toggleRight.midY) == .toggleRight)
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
        steps.append(Step(name: "sidebar: Ctrl+B shows it, on that folder", action: { press(0x42) }, done: {
            window.leftIsVisible && window.leftTree.root?.lowercased() == pane.terminal.cwd?.lowercased() && window.leftRow(named: "alpha") != nil
        }))
        steps.append(Step(name: "sidebar: the terminal makes room", action: {}, done: { pane.terminal.cols < colsWithoutSidebar }))
        steps.append(Step(name: "sidebar: lists folders first", action: {},
                          done: { window.leftTree.rows.map(\.entry.name) == ["alpha", "zeta.txt"] }))
        steps.append(Step(name: "sidebar: clicking a folder opens it", action: { window.click(window.leftRow(named: "alpha")!) },
                          done: { window.leftRow(named: "inner.txt") != nil && window.leftHasFocus }))
        steps.append(Step(name: "sidebar: arrow keys move through it", action: { _ = window.keyDown(Int32(0x28), shift: false, ctrl: false, alt: false) },
                          done: { window.leftTree.selection?.hasSuffix("inner.txt") == true }))
        steps.append(Step(name: "sidebar: Enter opens a file", action: { _ = window.keyDown(Int32(0x0D), shift: false, ctrl: false, alt: false) },
                          done: { openedFile?.hasSuffix("inner.txt") == true }))
        steps.append(Step(name: "sidebar: a new file shows by itself", action: {
            _ = FileManager.default.createFile(atPath: windowsFolder + "\\late.txt", contents: Data())
        }, done: { window.leftRow(named: "late.txt") != nil }))
        steps.append(Step(name: "sidebar: Esc goes back to the terminal", action: { _ = window.keyDown(Int32(0x1B), shift: false, ctrl: false, alt: false) },
                          done: { !window.leftHasFocus }))
        var sidebarWidthBefore: Float = 0
        steps.append(Step(name: "sidebar: its border drags", action: {
            sidebarWidthBefore = window.leftWidthNow
            window.dragLeftEdge(to: sidebarWidthBefore + 60)
        }, done: { abs(window.leftWidthNow - sidebarWidthBefore - 60) <= 2 }))
        steps.append(Step(name: "sidebar: double-clicking a folder sends the terminal there", action: {
            window.doubleClick(window.leftRow(named: "alpha")!)
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
        steps.append(Step(name: "themes: the status bar's theme opens the menu", action: { window.click(window.themeSpotRect) },
                          done: { window.menuTitles.contains("Quantum Moon") && window.menuTitles.contains("Dark+") }))
        steps.append(Step(name: "themes: choosing one changes everything", action: { window.click(window.menuRow("Quantum Moon")!) },
                          done: { TerminalPalette.background == 0x202125 && AppSettings.shared.themeName == "Quantum Moon" }))
        if let dir = snapshotDirectory {
            steps.append(Step(name: "themes: snapshot", action: {}, done: { window.saveSnapshot(to: dir + "\\theme.png") }))
        }
        steps.append(Step(name: "themes: and back from the palette", action: {
            press(0x50, shift: true)
            pane.type("theme solanum default")
        }, done: { window.paletteSelection?.title == "Theme: Solanum Default" }))
        steps.append(Step(name: "themes: back to the default", action: { pane.pressEnter() },
                          done: { TerminalPalette.background == 0x111312 && !window.isPaletteOpen }))

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
