import AppKit

/// Emulator self-tests: `Solanum.app/Contents/MacOS/Solanum --selftest`
enum SelfTest {
    private final class Sink: TerminalDelegate {
        var sent: [UInt8] = []
        func terminalSend(_ bytes: [UInt8]) { sent += bytes }
        func terminalTitleChanged(_ t: Terminal) {}
        func terminalCwdChanged(_ t: Terminal) {}
        func terminalBell(_ t: Terminal) {}
        func terminalBlockFinished(_ t: Terminal, block: Block) {}
        func terminalClipboardWrite(_ t: Terminal, text: String) {}
        func terminalScreenSwitched(_ t: Terminal) {}
        func terminalSyncEnded(_ t: Terminal) {}
        func terminalColor(_ t: Terminal, code: Int) -> (UInt8, UInt8, UInt8) { (0, 0, 0) }
        func terminalPixelSize(_ t: Terminal) -> (width: Int, height: Int) { (800, 600) }
        /// What the terminal still knew when the ssh session ended: (status, control socket, remote folder).
        var sshExit: (Int, String?, String?)?
        func terminalSSHExited(_ t: Terminal, status: Int) { sshExit = (status, t.sshControlPath, t.remoteCwd) }
    }

    private static func feed(_ t: Terminal, _ s: String) {
        Array(s.utf8).withUnsafeBufferPointer { t.feed($0) }
    }

    private static func row(_ t: Terminal, _ r: Int) -> String { t.screen[r].text() }

    static func run() -> Bool {
        var failures = 0
        var count = 0
        func check(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
            count += 1
            if cond { print("  ✓ \(name)") } else { failures += 1; print("  ✗ \(name) \(detail())") }
        }
        func make(_ c: Int = 20, _ r: Int = 5) -> (Terminal, Sink) {
            let t = Terminal(cols: c, rows: r, scrollbackLimit: 1000)
            let s = Sink()
            t.delegate = s
            return (t, s)
        }

        print("Solanum emulator self-test")
        do {
            let (t, _) = make()
            feed(t, "hello\r\nworld")
            check("print + CRLF", row(t, 0) == "hello" && row(t, 1) == "world" && t.cursorX == 5 && t.cursorY == 1)
        }
        do {
            let (t, _) = make(10, 3)
            feed(t, "0123456789AB")
            check("autowrap", row(t, 0) == "0123456789" && row(t, 1) == "AB" && t.screen[0].wrapped)
        }
        do {
            let (t, _) = make(10, 3)
            feed(t, "a\r\nb\r\nc\r\nd")
            check("scroll into scrollback", t.scrollback.count == 1 && t.scrollback[0].text() == "a" && row(t, 2) == "d")
        }
        do {
            let (t, _) = make()
            feed(t, "abcdef\u{1b}[1;3H\u{1b}[K")
            check("CUP + EL", row(t, 0) == "ab")
            feed(t, "\u{1b}[2J\u{1b}[H")
            check("ED 2", row(t, 0) == "" && t.cursorX == 0)
        }
        do {
            let (t, _) = make()
            feed(t, "\u{1b}[1;31mR\u{1b}[38;5;200mP\u{1b}[38;2;1;2;3mT\u{1b}[0mN")
            let c = t.screen[0].cells
            check("SGR colors", c[0].fg == TermColor.indexed(1) && c[0].flags.contains(.bold)
                  && c[1].fg == TermColor.indexed(200) && c[2].fg == TermColor.rgb(1, 2, 3) && c[3].fg == 0 && c[3].flags.isEmpty)
            feed(t, "\u{1b}[38:2::9:8:7mX\u{1b}[4:3mY")
            check("SGR colon forms", t.screen[0].cells[4].fg == TermColor.rgb(9, 8, 7) && t.screen[0].cells[5].flags.contains(.curlyUnderline))
        }
        do {
            let (t, _) = make()
            feed(t, "main\u{1b}[?1049h")
            check("alt screen enter", t.usingAlt && row(t, 0) == "")
            feed(t, "alt\u{1b}[?1049l")
            check("alt screen exit restores", !t.usingAlt && row(t, 0) == "main" && t.cursorX == 4)
        }
        do {
            let (t, _) = make(10, 5)
            feed(t, "1\r\n2\r\n3\r\n4\r\n5\u{1b}[2;4r\u{1b}[4;1H\n")
            check("scroll region", row(t, 0) == "1" && row(t, 1) == "3" && row(t, 2) == "4" && row(t, 3) == "" && row(t, 4) == "5")
        }
        do {
            let (t, _) = make(10, 3)
            feed(t, "日本x")
            check("wide chars", t.screen[0].cells[0].width == 2 && t.screen[0].cells[1].width == 0 && t.screen[0].cells[4].ch == 0x78 && t.cursorX == 5)
        }
        do {
            let (t, _) = make(10, 4)
            feed(t, "abcdefghijklmno\r\nxyz")
            t.resize(cols: 20, rows: 4)
            check("reflow wider", row(t, 0) == "abcdefghijklmno" && row(t, 1) == "xyz" && t.cursorY == 1 && t.cursorX == 3)
            t.resize(cols: 5, rows: 4)
            let all = (0..<t.scrollback.count).map { t.scrollback[$0].text() } + (0..<4).map { row(t, $0) }
            check("reflow narrower", all.joined(separator: "|").hasPrefix("abcde|fghij|klmno|xyz"), all.joined(separator: "|"))
        }
        do {
            let (t, s) = make()
            feed(t, "\u{1b}[6n\u{1b}[c")
            check("DSR/DA responses", String(decoding: s.sent, as: UTF8.self) == "\u{1b}[1;1R\u{1b}[?62;22c")
        }
        do {
            // The exit status comes while the session is still known, so a lost connection can be reopened where it was.
            let (t, s) = make()
            feed(t, "\u{1b}]1337;SolanumSSH=/tmp/sock\u{07}\u{1b}]7;file://host/srv/app\u{07}"
                 + "\u{1b}]1337;SolanumSSHExit=255\u{07}\u{1b}]1337;SolanumSSH=\u{07}")
            let e = s.sshExit
            check("ssh exit reported before the session clears", e?.0 == 255 && e?.1 == "/tmp/sock" && e?.2 == "/srv/app"
                  && t.sshControlPath == nil, "\(String(describing: e))")
        }
        do {
            let (t, _) = make(30, 6)
            feed(t, "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}ls -la\r\n\u{1b}]133;C\u{07}file1\r\nfile2\r\n\u{1b}]133;D;0\u{07}\u{1b}]133;A\u{07}$ ")
            let b = t.blocks.first
            check("OSC 133 blocks", t.blocks.count == 2 && b?.command == "ls -la" && b?.outputLine == 1 && b?.endLine == 2 && b?.exitCode == 0,
                  "\(t.blocks.count) \(b?.command ?? "") \(String(describing: b?.outputLine)) \(String(describing: b?.endLine))")
        }
        do {
            let (t, _) = make(40, 30)
            let shade = "\u{1b}[48;2;55;55;55m", plain = "\u{1b}[49m", rule = String(repeating: "─", count: 40)
            feed(t, "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}claude\r\n\u{1b}]133;C\u{07}")
            feed(t, "\(shade)❯ first question\u{1b}[K\(plain)\r\n\(shade)  second line\u{1b}[K\(plain)\r\n\r\n⏺ answer one\r\n  more\r\n\r\n")
            feed(t, "\(shade)❯ next\(plain)\r\n\r\n⏺ answer two\r\n\r\n\(rule)❯ typing\r\n\(rule)")
            let turns = t.blocks.last.map { t.agentTurns(in: $0) } ?? []
            check("agent turns", turns.count == 2 && turns[0].promptLine == 1 && turns[0].promptEnd == 2 && turns[0].end == 5
                  && t.agentPromptText(turns[0]) == "first question\nsecond line" && turns[1].end == 9,
                  turns.map { "\($0.promptLine)-\($0.promptEnd)-\($0.end)" }.joined(separator: " "))
            feed(t, "\u{1b}[2J\u{1b}[H")
            check("ED 2 keeps running block", t.currentBlock?.state == .running && t.currentBlock?.command == "claude")
        }
        do {
            let (t, _) = make()
            feed(t, "\u{1b}(0lqk\u{1b}(B")
            check("DEC line drawing", t.screen[0].cells[0].ch == 0x250C && t.screen[0].cells[1].ch == 0x2500)
        }
        do {
            let (t, _) = make()
            feed(t, "e\u{301}x")
            check("combining marks", t.screen[0].extras?[0] == "\u{301}" && t.screen[0].cells[1].ch == 0x78)
        }
        do {
            let (t, _) = make(20, 8)
            feed(t, "\u{1b}[1;31mred\u{1b}[0m plain\r\n" + String(repeating: "x", count: 25) + "\r\n\u{1b}[48;2;10;20;30mshaded\u{1b}[0m")
            let (u, _) = make(20, 8)
            feed(u, t.restorableText(maxLines: 100))
            let same = (0..<4).allSatisfy { u.screen[$0].text() == t.screen[$0].text() }
            check("session text round-trip", same && u.screen[0].cells[0].flags.contains(.bold) && u.screen[0].cells[0].fg == t.screen[0].cells[0].fg
                  && u.screen[1].wrapped && u.screen[3].cells[0].bg == TermColor.rgb(10, 20, 30),
                  (0..<4).map { u.screen[$0].text() }.joined(separator: "|"))
        }
        do {
            let bash = CommandHistory.parse("ls\n#1700000000\ngit status\n\n  echo hi  \n")
            check("history: bash + timestamps", bash == ["ls", "git status", "echo hi"], "\(bash)")
            let zsh = CommandHistory.parse(": 1700000000:0;make\n: 1700000001:3;for x in a b; do\\\necho $x\\\ndone\n")
            check("history: zsh extended + multi-line", zsh == ["make", "for x in a b; do\necho $x\ndone"], "\(zsh)")
            check("history: newest first, unique", CommandHistory.newestFirst(["a", "b", "a", "c"]) == ["c", "a", "b"])
        }
        do {
            check("hex round-trip", NSColor(hex: "#1A2B3C").hexString == "#1A2B3C" && NSColor(hex: "#11223380").hexString == "#11223380")
            let t = ThemeLibrary.builtIn[1]
            let j = t.json
            let back = Theme(name: j["name"] as! String, bg: j["background"] as! String, bg2: j["background2"] as? String, fg: j["foreground"] as! String,
                             cursor: j["cursor"] as? String, selection: j["selection"] as? String, accent: j["accent"] as! String,
                             chrome: j["chrome"] as? String, ansi: j["ansi"] as! [String])
            check("theme JSON round-trip", back.json as NSDictionary == j as NSDictionary)
        }
        print(failures == 0 ? "All \(count) checks passed." : "\(failures) of \(count) checks FAILED.")
        return failures == 0
    }
}

/// Development aid: SOLANUM_SNAPSHOT=/path.png renders the first window to a PNG after a delay.
/// SOLANUM_SNAPSHOT_INPUT types text first; SOLANUM_SNAPSHOT_ACTIONS=split,palette,select-block,collapse,jump-prompt,find,find-commands,find-output,click:<col>:<row>,keys:<text>,theme:<name>,
/// newtab,rename-tab,new-group,edit:<text>,select-tab:<i>,collapse-group:<i>,split-down,save-session,
/// tabbar-drag:<x1>:<x2>,chip-menu-rename,open-config,git-branches,later-keys:<text>,newtab-run:<command>,pin-sidebar,collapse-sidebar,print-claude-fg,undo,redo,print-input,sleep:<seconds>,print-boxes,print-return-keys,hover-last-block,scrollbar:<y0>:<y1>,print-tabs,cmd-click-tab:<i>,group-picked,name-tabs,chip-drag[-hold]:<x>,print-anim,close-tab:<i>,newtab-group,click-input:<col>,split-columns,close-split,move-tab-other,right-sidebar,focus-other,close-right-tabs,print-columns,tab-drop[-hold]:<i>:<fx>:<fy>,open-file-tab:<path>,open-diff:<path>,open-graph:<path>,open-preview:<path>,format-file,hover-graph:<row>,toggle-terminal,restore-prompt,editor-drag-out,select-input:<r0>:<c0>:<r1>:<c1>,drag-input:<r0>:<c0>:<r1>:<c1>:<seconds>,delete-selection,cmd-delete,select-cmd:<from>:<to>,print-selection,print-ssh,close-file,hover-title,print-sidebar,print-pins,sidebar-expand:<name>,sidebar-import:<path>,print-rows,status-transfer:<text>,refresh-tab,glide-bottom,print-scroll,reopen-tab
/// (with SOLANUM_SESSION_FILE set, which also makes the run restore from that file).
enum SnapshotHelper {
    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["SOLANUM_SNAPSHOT"] else { return }
        let delay = Double(env["SOLANUM_SNAPSHOT_DELAY"] ?? "") ?? 4
        func wc() -> TerminalWindowController? {
            NSApp.windows.compactMap { $0.windowController as? TerminalWindowController }.first
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if let input = env["SOLANUM_SNAPSHOT_INPUT"], let pane = wc()?.activeTab?.focusedPane {
                pane.send(input.replacingOccurrences(of: "\\r", with: "\r"))
            }
        }
        // SOLANUM_SNAPSHOT_ACTIONS_AT runs the actions earlier, leaving time for async results (e.g. ssh) to land.
        let actionsAt = Double(env["SOLANUM_SNAPSHOT_ACTIONS_AT"] ?? "") ?? delay - 1
        DispatchQueue.main.asyncAfter(deadline: .now() + actionsAt) {
            let actions = (env["SOLANUM_SNAPSHOT_ACTIONS"] ?? "").split(separator: ",").map(String.init)
            // "sleep:<seconds>" pauses before the remaining actions (e.g. to let the shell echo what was typed).
            func run(_ i: Int) {
                guard i < actions.count else { return }
                let action = actions[i]
                if action.hasPrefix("sleep:") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + (Double(action.dropFirst(6)) ?? 0.5)) { run(i + 1) }
                    return
                }
                defer { run(i + 1) }
                guard let c = wc(), let pane = c.activeTab?.focusedPane else { return }
                switch action {
                case "split": pane.splitRight(nil)
                case "palette": c.showCommandPalette(nil)
                case "select-block": pane.selectPreviousBlock(nil)
                case "collapse": pane.toggleBlockCollapse(nil)
                case "jump-prompt": pane.jumpToPrompt(nil)
                case "find": pane.showFind(nil); pane.searchBar?.field.stringValue = "Solanum"; pane.performSearch("Solanum")
                case "find-commands", "find-output":
                    // Shows the find bar scoped to commands/output, searching SOLANUM_SNAPSHOT_FIND (default "echo").
                    let q = env["SOLANUM_SNAPSHOT_FIND"] ?? "echo"
                    pane.searchScope = action == "find-commands" ? .commands : .output
                    pane.showFind(nil); pane.searchBar?.field.stringValue = q; pane.performSearch(q)
                case "newtab": c.newTab(nil)
                case "newtab-group": c.newTabInGroup(nil)
                case "sidebar": c.toggleFileSidebar(nil)
                case "pin-sidebar": c.togglePinnedSidebarFolder(nil)
                case "undo": pane.undo(nil)
                case let a where a.hasPrefix("scrollbar:"):
                    // scrollbar:<y0>:<y1> presses the scrollbar at y0 (0 = top … 1 = bottom), drags to y1 and releases;
                    // prints the scroll position after the press and after the drag. The scrollbar stays hovered.
                    let n = a.dropFirst(10).split(separator: ":").compactMap { Double($0) }
                    if n.count == 2, let w = pane.window {
                        func ev(_ type: NSEvent.EventType, _ f: Double) -> NSEvent? {
                            let pt = pane.convert(NSPoint(x: pane.bounds.width - 6, y: 8 + (pane.bounds.height - 16) * f), to: nil)
                            return NSEvent.mouseEvent(with: type, location: pt, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                                      context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                        }
                        pane.scrollbarHover = true
                        if let d = ev(.leftMouseDown, n[0]) { pane.mouseDown(with: d) }
                        let afterPress = pane.scrollOffset
                        if let m = ev(.leftMouseDragged, n[1]) { pane.mouseDragged(with: m) }
                        let afterDrag = pane.scrollOffset
                        if let u = ev(.leftMouseUp, n[1]) { pane.mouseUp(with: u) }
                        pane.scrollbarHover = true
                        FileHandle.standardError.write("scrollbar: max=\(pane.maxScrollOffset) afterPress=\(afterPress) afterDrag=\(afterDrag)\n".data(using: .utf8)!)
                    }
                case "hover-last-block": pane.hoverBlock = pane.terminal.blocks.last { $0.state == .finished }; pane.needsDisplay = true
                case "print-return-keys":
                    // What ↩ and ⇧↩ send to the foreground program right now.
                    for (name, flags) in [("return", NSEvent.ModifierFlags()), ("shift-return", .shift)] {
                        if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                                    characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
                            FileHandle.standardError.write("\(name)=\(pane.encodeKey(e) ?? [])\n".data(using: .utf8)!)
                        }
                    }
                case "print-boxes":
                    // Each box, what Copy gives, and what selecting its second line gives (code: a wrapped piece).
                    for b in pane.codeBoxes {
                        var out = "box \(b.kind) lines \(b.first)-\(b.last) indent \(b.indent)\nCOPY<<\(b.copyText)>>\n"
                        if b.kind == .code, b.last > b.first {
                            let s = Selection(mode: .line, aStart: GridPos(line: b.first + 1, col: 0), aEnd: GridPos(line: b.first + 1, col: 0),
                                              hStart: GridPos(line: b.first + 1, col: pane.terminal.cols - 1), hEnd: GridPos(line: b.first + 1, col: pane.terminal.cols - 1))
                            out += "LINE2<<\(pane.textForSelection(s))>>\n"
                        }
                        if b.kind == .table {
                            // What a table copy carries, on a private pasteboard (the real clipboard is left alone).
                            let pb = NSPasteboard(name: .init("solanum.test"))
                            b.copy(to: pb)
                            out += "TYPES \(pb.types?.map(\.rawValue) ?? [])\nHTML<<\(pb.string(forType: .html) ?? "")>>\nRTF bytes \(pb.data(forType: .rtf)?.count ?? 0)\n"
                        }
                        FileHandle.standardError.write(out.data(using: .utf8)!)
                    }
                case "redo": pane.redo(nil)
                case "print-input": FileHandle.standardError.write("input=\(String(describing: pane.promptInput)) redo=\(pane.redoStack.count)\n".data(using: .utf8)!)
                case "print-claude-fg":
                    // A beat later, so a command typed in the same batch has started.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { pane.updateAgent(); FileHandle.standardError.write("agent=\(pane.agent?.summary ?? "none") claude-fg=\(pane.pty?.foregroundIsClaudeCode ?? false) name=\(pane.pty?.foregroundProcessName ?? "-") job=\(pane.pty?.hasForegroundJob ?? false)\n".data(using: .utf8)!) }
                case "collapse-sidebar": c.rootView.sidebar.outline.collapseItem(nil, collapseChildren: true)
                case "fullscreen": c.window?.toggleFullScreen(nil)
                case "fullscreen-roundtrip":
                    // Enters full screen, then leaves it 5s later (pair with probe-tabbar, which samples at 0/3/9s).
                    c.window?.toggleFullScreen(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak c] in c?.window?.toggleFullScreen(nil) }
                case "probe-tabbar":
                    // Prints which view a real click at points along the tab bar would hit (titlebar overlays included).
                    let bar = c.tabBar
                    for delay in [0.0, 3.0, 9.0] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        func print(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
                        guard let w = bar.window, let frame = w.contentView?.superview else { return }
                        let fs = w.styleMask.contains(.fullScreen)
                        print("probe: fullScreen=\(fs) toolbar=\(w.toolbar != nil) bar=\(bar.frame)")
                        for x in stride(from: 40.0, to: Double(bar.bounds.width), by: 200) {
                            let p = frame.convert(bar.convert(NSPoint(x: x, y: bar.bounds.midY), to: nil), from: nil)
                            print("probe: x=\(Int(x)) -> \(frame.hitTest(p).map { String(describing: type(of: $0)) } ?? "nil")")
                        }
                        for cw in NSApp.windows where cw !== w && cw.isVisible {
                            let cv = cw.contentView.map { v in "\(v.frame) hidden=\(v.isHidden) alpha=\(v.alphaValue)" } ?? "-"
                            print("probe: other window \(type(of: cw)) frame=\(cw.frame) level=\(cw.level.rawValue) alpha=\(cw.alphaValue) occl=\(cw.occlusionState.contains(.visible)) content=\(cv)")
                        }
                    } }
                case "save-session":
                    SessionStore.save(NSApp.windows.compactMap { $0.windowController as? TerminalWindowController }, sync: true)
                case "split-down": pane.splitDown(nil)
                case "rename-tab": c.renameCurrentTab(nil)
                case "new-group": c.addCurrentTabToNewGroup(nil)
                case "chip-menu-rename":
                    // Right-clicks the first group chip, picks "Rename Group…" from the real menu via posted keys,
                    // then logs the editor/first responder to stderr and types into it.
                    NSApp.activate(ignoringOtherApps: true)
                    c.window?.makeKeyAndOrderFront(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak c] in
                    guard let c else { return }
                    let bar = c.tabBar
                    bar.layoutSubtreeIfNeeded()
                    guard let r = bar.firstChipRect, let w = c.window else { return }
                    func log(_ s: String) { FileHandle.standardError.write(("probe: " + s + "\n").data(using: .utf8)!) }
                    func key(_ chars: String, _ code: UInt16) {
                        for t in [NSEvent.EventType.keyDown, .keyUp] {
                            if let e = NSEvent.keyEvent(with: t, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: w.windowNumber, context: nil, characters: chars,
                                                        charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) { NSApp.postEvent(e, atStart: false) }
                        }
                    }
                    let state = {
                        let f = bar.subviews.compactMap { $0 as? NSTextField }.first
                        log("editor=\(f != nil) value=\(f?.stringValue ?? "-") frame=\(f?.frame ?? .zero) fr=\(w.firstResponder.map { String(describing: type(of: $0)) } ?? "nil") key=\(w.isKeyWindow)")
                    }
                    state()
                    key(String(UnicodeScalar(NSDownArrowFunctionKey)!), 125)
                    key("\r", 36)
                    let loc = bar.convert(NSPoint(x: r.midX, y: r.midY), to: nil)
                    if let e = NSEvent.mouseEvent(with: .rightMouseDown, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                        bar.rightMouseDown(with: e)
                    }
                    log("menu returned"); state()
                    for d in [0.1, 0.5] { DispatchQueue.main.asyncAfter(deadline: .now() + d) { state() } }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { for ch in "Work" { key(String(ch), 0) } }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { state() }
                    }
                case "quick": QuickTerminalController.shared.show()
                case "settings": SettingsWindowController.shared.present()
                case "settings-text": SettingsWindowController.shared.present(.text)
                case "settings-shortcuts": SettingsWindowController.shared.present(.shortcuts)
                case "settings-aliases": SettingsWindowController.shared.present(.aliases)
                case "settings-preferences": SettingsWindowController.shared.present(.preferences)
                default:
                    if action.hasPrefix("later-keys:") {
                        // Same as keys:, once something async (e.g. the git branch list) has had time to open.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            guard let w = NSApp.keyWindow else { return }
                            for ch in action.dropFirst(11) {
                                let chars = ch == "⏎" ? "\r" : String(ch)
                                if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                            windowNumber: w.windowNumber, context: nil, characters: chars,
                                                            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: ch == "⏎" ? 36 : 0) {
                                    w.sendEvent(e)
                                }
                            }
                        }
                    }
                    if action.hasPrefix("keys:"), let w = NSApp.keyWindow ?? c.window {
                        // Synthesize real key events (exercises keyDown + menu key equivalents).
                        for ch in action.dropFirst(5) {
                            let isReturn = ch == "⏎"
                            let chars = isReturn ? "\r" : String(ch)
                            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                        windowNumber: w.windowNumber, context: nil, characters: chars,
                                                        charactersIgnoringModifiers: chars, isARepeat: false, keyCode: isReturn ? 36 : 0) {
                                w.sendEvent(e)
                            }
                        }
                    }
                    if action == "cmd-delete", let w = NSApp.keyWindow ?? c.window,
                       let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: w.windowNumber,
                                                context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51) {
                        w.sendEvent(e)   // ⌘⌫
                    }
                    if action.hasPrefix("cmdkey:"), let w = NSApp.keyWindow ?? c.window {
                        let k = String(action.dropFirst(7))
                        if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                                                    windowNumber: w.windowNumber, context: nil, characters: k,
                                                    charactersIgnoringModifiers: k, isARepeat: false, keyCode: 2) {
                            NSApp.sendEvent(e)
                        }
                    }
                    if action.hasPrefix("click:") || action.hasPrefix("click-input:"), let w = c.window {
                        // click:<col>:<row> — a plain single click on a screen cell.
                        // click-input:<col> — the same on the first row of an agent's input box.
                        var n = action.dropFirst(action.hasPrefix("click:") ? 6 : 12).split(separator: ":").compactMap { Double($0) }
                        if action.hasPrefix("click-input:"), let b = pane.terminal.currentBlock, let rows = pane.terminal.agentInputRows(b) {
                            n.append(Double(rows.lowerBound - pane.terminal.screenTopAbs))
                        }
                        if n.count == 2 {
                            let p = NSPoint(x: pane.padX + (n[0] + 0.5) * pane.fonts.cellW, y: pane.padTop + (n[1] + 0.5) * pane.fonts.cellH)
                            let loc = pane.convert(p, to: nil)
                            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                                if let e = NSEvent.mouseEvent(with: type, location: loc, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                                              context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                                    if type == .leftMouseDown { pane.mouseDown(with: e) } else { pane.mouseUp(with: e) }
                                }
                            }
                        }
                    }
                    if action.hasPrefix("edit:"), let f = c.tabBar.subviews.compactMap({ $0 as? NSTextField }).first {
                        // Types into the open tab/group name editor and commits it by moving focus away.
                        f.stringValue = String(action.dropFirst(5))
                        c.window?.makeFirstResponder(pane)
                    }
                    if action.hasPrefix("later-edit:") {
                        // Same as edit:, but after a paced tabbar-drag has finished.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak c] in
                            guard let c, let f = c.tabBar.subviews.compactMap({ $0 as? NSTextField }).first else { return }
                            f.stringValue = String(action.dropFirst(11))
                            c.window?.makeFirstResponder(pane)
                        }
                    }
                    if action.hasPrefix("tabbar-drag:") || action.hasPrefix("tabbar-drag-hold:") || action.hasPrefix("chip-drag"), let w = c.window {
                        // tabbar-drag:<x1>:<x2> — press at x1 (points) in the tab bar, drag in steps to x2, release.
                        // tabbar-drag-hold: stops before releasing, to capture the drag in progress.
                        // chip-drag:<x2> / chip-drag-hold:<x2> — the same, starting on the first group chip.
                        let hold = action.hasPrefix("tabbar-drag-hold:") || action.hasPrefix("chip-drag-hold:")
                        var n = action.split(separator: ":").dropFirst().compactMap { Double($0) }
                        if action.hasPrefix("chip-drag"), let chip = c.tabBar.firstChipRect { n.insert(Double(chip.midX), at: 0) }
                        let bar = c.tabBar
                        bar.layoutSubtreeIfNeeded()
                        func send(_ type: NSEvent.EventType, _ x: Double) {
                            let loc = bar.convert(NSPoint(x: x, y: bar.bounds.midY), to: nil)
                            if let e = NSEvent.mouseEvent(with: type, location: loc, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                                          context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                                switch type {
                                case .leftMouseDown: bar.mouseDown(with: e)
                                case .leftMouseDragged: bar.mouseDragged(with: e); bar.layoutSubtreeIfNeeded()
                                default: bar.mouseUp(with: e)
                                }
                            }
                        }
                        if n.count == 2 {
                            // One event per run-loop pass, like real input, so work queued by mouseDown (focus) runs first.
                            send(.leftMouseDown, n[0])
                            for i in 1...21 {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02 * Double(i)) {
                                    if i <= 20 { send(.leftMouseDragged, n[0] + (n[1] - n[0]) * Double(i) / 20) } else if !hold { send(.leftMouseUp, n[1]) }
                                }
                            }
                        }
                    }
                    if action.hasPrefix("select-tab:"), let i = Int(action.dropFirst(11)) { c.select(index: i) }
                    if action.hasPrefix("tab-drop:") || action.hasPrefix("tab-drop-hold:"), let w = c.window {
                        // tab-drop:<i>:<fx>:<fy> — press on tab i of the focused column's strip, drag to (fx, fy) as
                        // fractions of the window, release. tab-drop-hold: stops before releasing (to see the preview).
                        let hold = action.hasPrefix("tab-drop-hold:")
                        let n = action.split(separator: ":").dropFirst().compactMap { Double($0) }
                        let bar = c.tabBar
                        bar.layoutSubtreeIfNeeded()
                        if n.count == 3, let line = bar.layoutSummary.split(separator: "\n").first(where: { $0.hasPrefix("tab\(Int(n[0])) ") }),
                           let xs = line.split(separator: "=").last?.split(separator: "-").compactMap(Double.init), xs.count == 2 {
                            let start = bar.convert(NSPoint(x: (xs[0] + xs[1]) / 2, y: bar.bounds.midY), to: nil)
                            let root = c.rootView
                            let end = root.convert(NSPoint(x: root.bounds.width * n[1], y: root.bounds.height * n[2]), to: nil)
                            func send(_ type: NSEvent.EventType, _ loc: NSPoint) {
                                guard let e = NSEvent.mouseEvent(with: type, location: loc, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                                                 context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
                                switch type {
                                case .leftMouseDown: bar.mouseDown(with: e)
                                case .leftMouseDragged: bar.mouseDragged(with: e)
                                default: bar.mouseUp(with: e)
                                }
                            }
                            send(.leftMouseDown, start)
                            for k in 1...21 {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02 * Double(k)) {
                                    let t = Double(k) / 20
                                    let pt = NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
                                    if k <= 20 { send(.leftMouseDragged, pt) } else if !hold { send(.leftMouseUp, end) }
                                }
                            }
                        }
                    }
                    if action.hasPrefix("open-file-tab:") {
                        c.focused.addFileTab(FileEditorView(fs: LocalFileSystem.shared, path: String(action.dropFirst(14))))
                    }
                    if action.hasPrefix("open-diff:") { c.activeTab?.openFile(LocalFileSystem.shared, String(action.dropFirst(10)), mode: .diff) }
                    if action.hasPrefix("open-preview:") { c.activeTab?.openFile(LocalFileSystem.shared, String(action.dropFirst(13)), mode: .preview) }
                    if action == "format-file" { c.activeTab?.editor?.formatDocument(nil) }
                    if action.hasPrefix("open-graph:") { c.activeTab?.openFile(LocalFileSystem.shared, String(action.dropFirst(11)), mode: .graph) }
                    if action.hasPrefix("hover-graph:"), let row = Int(action.dropFirst(12)) { c.activeTab?.editor?.devHoverGraph(row) }
                    if action == "toggle-terminal" { c.activeTab?.toggleTerminal() }
                    if action == "restore-prompt" { (NSApp.delegate as? AppDelegate)?.offerRestore(SessionState(windows: [c.sessionState])) }
                    if action == "editor-drag-out", let tab = c.activeTab, let ed = tab.editor {
                        // Drags the active file's sub-tab onto the middle of the focused column's tab strip and drops it.
                        let bar = c.tabBar
                        c.editorDragOver(ed, from: tab, at: bar.convert(NSPoint(x: bar.bounds.midX, y: bar.bounds.midY), to: nil))
                        c.performEditorDrop()
                    }
                    if action.hasPrefix("select-input:"), let b = pane.terminal.currentBlock, let rows = pane.terminal.agentInputRows(b) {
                        // select-input:<row0>:<col0>:<row1>:<col1> — selects text in an agent's input box (rows from its first row).
                        let n = action.dropFirst(13).split(separator: ":").compactMap { Int($0) }
                        if n.count == 4 {
                            let a = GridPos(line: rows.lowerBound + n[0], col: n[1]), z = GridPos(line: rows.lowerBound + n[2], col: n[3])
                            pane.selection = Selection(mode: .char, aStart: a, aEnd: a, hStart: z, hEnd: z)
                        }
                    }
                    if action.hasPrefix("drag-input:"), let b = pane.terminal.currentBlock, let rows = pane.terminal.agentInputRows(b), let w = pane.window {
                        // drag-input:<row0>:<col0>:<row1>:<col1>:<seconds> — a real mouse drag across an agent's input box (rows from
                        // its first row), the button held for <seconds> with the pointer still, then released.
                        let n = action.dropFirst(11).split(separator: ":").compactMap { Double($0) }
                        pane.computeRowMap()
                        func point(_ row: Int, _ col: Int) -> NSPoint? {
                            guard let r = pane.rowMap.firstIndex(of: rows.lowerBound + row) else { return nil }
                            let v = NSPoint(x: pane.padX + (CGFloat(col) + 0.5) * pane.fonts.cellW, y: pane.padTop + (CGFloat(r) + 0.5) * pane.fonts.cellH)
                            return pane.convert(v, to: nil)
                        }
                        if n.count == 5, let p0 = point(Int(n[0]), Int(n[1])), let p1 = point(Int(n[2]), Int(n[3])) {
                            func event(_ t: NSEvent.EventType, _ p: NSPoint) -> NSEvent? {
                                NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                            }
                            event(.leftMouseDown, p0).map(pane.mouseDown)
                            let steps = Int(n[4] / 0.1)
                            for k in 0...steps {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1 * Double(k)) {
                                    event(.leftMouseDragged, p1).map(pane.mouseDragged)
                                    if k == steps { event(.leftMouseUp, p1).map(pane.mouseUp) }
                                }
                            }
                        }
                    }
                    if action == "print-selection" {
                        let t = pane.selection.map { pane.textForSelection($0) } ?? "none"
                        FileHandle.standardError.write("selection=\(t) lines=\(pane.selection.map { "\($0.start.line)-\($0.end.line)" } ?? "-")\n".data(using: .utf8)!)
                    }
                    if action == "delete-selection" { FileHandle.standardError.write("deleted=\(pane.deleteSelectedInput())\n".data(using: .utf8)!) }
                    if action == "print-ssh" {
                        // What the shell integration reported for the last ssh, and the command that would reopen it.
                        let args = pane.terminal.sshArgs
                        let r = RemoteSession(controlPath: "/tmp/none", sshArgs: args)
                        FileHandle.standardError.write("sshArgs=\(args ?? "nil")\nreconnect=\(r.reconnectCommand(in: "/home/me/my project") ?? "nil")\n".data(using: .utf8)!)
                    }
                    if action == "close-file" { c.activeTab?.editor?.requestClose() }
                    if action == "hover-title" { c.rootView.sidebar.devHoverTitle() }
                    if action == "print-sidebar" { let r = c.rootView.sidebar.frame; FileHandle.standardError.write("sidebar x=\(Int(r.minX)) w=\(Int(r.width)) hidden=\(c.rootView.sidebar.isHidden) terminals.x=\(Int(c.rootView.columnArea.minX))\n".data(using: .utf8)!) }
                    if action.hasPrefix("sidebar-expand:") { c.rootView.sidebar.devExpand(String(action.dropFirst(15))) }
                    if action.hasPrefix("sidebar-import:") { c.rootView.sidebar.devImport(String(action.dropFirst(15))) }
                    if action.hasPrefix("status-transfer:") { c.rootView.statusBar.setTransfer(String(action.dropFirst(16)), from: c) }
                    if action == "print-rows" {
                        FileHandle.standardError.write("rows (status: \(c.rootView.statusBar.devTransfer ?? "-")):\n\(c.rootView.sidebar.devRows)\n".data(using: .utf8)!)
                    }
                    if action == "print-pins" {
                        let tabs = c.allTabs.map { $0.pinnedFolder?.path ?? "-" }.joined(separator: ", ")
                        FileHandle.standardError.write("pins tabs=[\(tabs)] active=\(c.activeIndex) sidebarPinned=\(c.rootView.sidebar.isPinned)\n".data(using: .utf8)!)
                    }
                    if action == "refresh-tab" { c.refreshTab(nil) }
                    if action == "glide-bottom" { pane.smoothScroll(to: 0) }
                    if action == "print-scroll" { FileHandle.standardError.write("scroll offset=\(pane.scrollOffset) shift=\(String(format: "%.1f", pane.scrollPixelShift))\n".data(using: .utf8)!) }
                    if action == "reopen-tab" { c.reopenClosedTab(nil) }
                    if action == "split-columns" { c.splitIntoColumns(nil) }
                    if action == "close-split" { c.closeSplit(nil) }
                    if action == "move-tab-other" { c.moveTabToOtherColumn(nil) }
                    if action == "right-sidebar" { c.toggleRightSidebar(nil) }
                    if action == "focus-other" { c.focusOtherColumn(nil) }
                    if action == "close-right-tabs" { c.closeSplitAndTabs() }
                    if action == "print-columns" {
                        let cols = c.columns.enumerated().map { i, col in
                            "col\(i)\(col === c.focused ? "*" : "") [" + col.tabs.map { t in
                                let files = t.editors.map { ($0.path as NSString).lastPathComponent }
                                return (t.customTitle ?? (t.showsTerminal ? "-" : "file:" + t.title)) + (files.isEmpty || !t.showsTerminal ? "" : "{" + files.joined(separator: ",") + "}")
                            }.joined(separator: " ") + "] active=\(col.activeIndex) bar.x=\(Int(col.tabBar.frame.minX))-\(Int(col.tabBar.frame.maxX))"
                        }
                        FileHandle.standardError.write("== \(cols.joined(separator: " | ")) drop=\(c.rootView.dropPreview.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "-") pending=\(c.hasPendingTabDrop)\n".data(using: .utf8)!)
                    }
                    if action == "print-anim" { FileHandle.standardError.write("\(c.tabBar.animSummary)\n".data(using: .utf8)!) }
                    if action.hasPrefix("close-tab:"), let i = Int(action.dropFirst(10)) { c.closeTab(at: i) }
                    if action == "print-tabs" { FileHandle.standardError.write("--\n\(c.tabBar.layoutSummary)\n".data(using: .utf8)!) }
                    if action == "group-picked" { c.focused.addToNewGroup(c.tabBar.selectedTabs) }
                    if action == "name-tabs" { for (ci, col) in c.columns.enumerated() { for (i, t) in col.tabs.enumerated() { col.renameTab(t, to: "\(ci == 0 ? "T" : "R")\(i)") } } }
                    if action.hasPrefix("cmd-click-tab:"), let i = Int(action.dropFirst(14)), let w = c.window {
                        // A ⌘-click on tab i (picks it for a multi-tab action).
                        let bar = c.tabBar
                        bar.layoutSubtreeIfNeeded()
                        let x = bar.layoutSummary.split(separator: "\n").first { $0.hasPrefix("tab\(i) ") }
                            .flatMap { $0.split(separator: "=").last?.split(separator: "-").compactMap { Double($0) } }
                        if let x, x.count == 2 {
                            let loc = bar.convert(NSPoint(x: (x[0] + x[1]) / 2, y: bar.bounds.midY), to: nil)
                            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                                if let e = NSEvent.mouseEvent(with: type, location: loc, modifierFlags: [.command], timestamp: 0, windowNumber: w.windowNumber,
                                                              context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                                    type == .leftMouseDown ? bar.mouseDown(with: e) : bar.mouseUp(with: e)
                                }
                            }
                        }
                    }
                    if action == "history" { pane.showHistory(nil) }
                    // theme-new copies the current theme into a new custom one and opens it in the editor;
                    // theme-bg:<hex> then recolors the active custom theme's background the way the editor does.
                    if action == "theme-new" { SettingsWindowController.shared.present(); SettingsWindowController.shared.edit(ThemeLibrary.duplicate(Config.shared.theme)) }
                    if action.hasPrefix("theme-bg:") {
                        var t = Config.shared.theme
                        if t.isCustom {
                            t.background = NSColor(hex: String(action.dropFirst(9)))
                            t.background2 = nil
                            ThemeLibrary.save(t)
                            Config.shared.commit()
                        }
                    }
                    if action.hasPrefix("insert-command:") { pane.insertCommand(String(action.dropFirst(15)), run: false) }
                    if action.hasPrefix("history-query:") {
                        let q = String(action.dropFirst(14))
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            if let f = c.window?.firstResponder as? NSTextView, let field = f.delegate as? NSTextField {
                                field.stringValue = q
                                NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
                            }
                        }
                    }
                    // select-input:<from>:<to> selects characters from..<to of the command being typed, then deletes them.
                    if action.hasPrefix("select-input:"), let b = pane.terminal.currentBlock, let line = b.commandLine {
                        let n = action.dropFirst(13).split(separator: ":").compactMap { Int($0) }
                        if n.count == 2 {
                            let a = GridPos(line: line, col: b.commandCol + n[0]), z = GridPos(line: line, col: b.commandCol + n[1] - 1)
                            pane.selection = Selection(mode: .char, aStart: a, aEnd: a, hStart: z, hEnd: z)
                            pane.deleteSelectedInput()
                        }
                    }
                    if action.hasPrefix("select-cmd:"), let b = pane.terminal.currentBlock, let line = b.commandLine {
                        // select-cmd:<from>:<to> — selects characters of the command being typed (without deleting them).
                        let n = action.dropFirst(11).split(separator: ":").compactMap { Int($0) }
                        if n.count == 2 {
                            let a = GridPos(line: line, col: b.commandCol + n[0]), z = GridPos(line: line, col: b.commandCol + n[1] - 1)
                            pane.selection = Selection(mode: .char, aStart: a, aEnd: a, hStart: z, hEnd: z)
                        }
                    }
                    if action.hasPrefix("type:") { pane.send(String(action.dropFirst(5)).replacingOccurrences(of: "\\r", with: "\r")) }
                    if action.hasPrefix("newtab-run:") { c.addTab(cwd: nil).focusedPane.pendingCommand = String(action.dropFirst(11)) }
                    if action == "git-branches" { c.git?.showBranches() }
                    if action == "open-config" { (NSApp.delegate as? AppDelegate)?.openConfigFile(nil) }
                    if action.hasPrefix("open-file:"), let fs = c.activeTab?.focusedPane.fileSystem { c.activeTab?.openFile(fs, String(action.dropFirst(10))) }
                    if action.hasPrefix("collapse-group:"), let i = Int(action.dropFirst(15)), c.groups.indices.contains(i) {
                        c.focused.setCollapsed(c.groups[i], true)
                    }
                    if action.hasPrefix("theme:") {
                        Config.shared.themeName = String(action.dropFirst(6))
                        FontSet.invalidate()
                        NotificationCenter.default.post(name: .solanumConfigChanged, object: nil)
                    }
                }
            }
            run(0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let target: NSWindow?
            switch env["SOLANUM_SNAPSHOT_WINDOW"] {
            case "quick": target = QuickTerminalController.shared.window
            case "settings": target = SettingsWindowController.shared.window
            default: target = wc()?.window
            }
            guard let w = target, let v = w.contentView,
                  let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { exit(2) }
            // The behind-window blur can't be captured offscreen; hide it so the themed background shows.
            v.subviews.compactMap { $0 as? NSVisualEffectView }.forEach { $0.isHidden = true }
            v.cacheDisplay(in: v.bounds, to: rep)
            // Composite onto the theme background since blur isn't captured.
            let img = NSImage(size: v.bounds.size)
            img.lockFocus()
            Config.shared.theme.background.setFill()
            NSRect(origin: .zero, size: v.bounds.size).fill()
            rep.draw(in: NSRect(origin: .zero, size: v.bounds.size))
            img.unlockFocus()
            if let tiff = img.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff),
               let png = bmp.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: out))
            }
            if env["SOLANUM_SNAPSHOT_KEEP"] == nil {
                for c in NSApp.windows.compactMap({ $0.windowController as? TerminalWindowController }) { c.tabs.forEach { $0.terminateAll() } }
                exit(0)
            }
        }
    }
}
