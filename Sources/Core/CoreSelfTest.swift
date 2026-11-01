import Foundation

/// Emulator self-tests that need nothing but the emulator, so they run on every system:
/// `Solanum --selftest` (with the app's own checks on the Mac; see `SelfTest` in DevTools.swift).
enum CoreSelfTest {
    /// Counts checks and prints each one.
    final class Results {
        private var failures = 0
        private var count = 0

        func check(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
            count += 1
            if cond { print("  ✓ \(name)") } else { failures += 1; print("  ✗ \(name) \(detail())") }
        }

        /// Prints the total; true when everything passed.
        func finish() -> Bool {
            print(failures == 0 ? "All \(count) checks passed." : "\(failures) of \(count) checks FAILED.")
            return failures == 0
        }
    }

    final class Sink: TerminalDelegate {
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


    static func feed(_ t: Terminal, _ s: String) {
        Array(s.utf8).withUnsafeBufferPointer { t.feed($0) }
    }

    static func row(_ t: Terminal, _ r: Int) -> String { t.screen[r].text() }

    static func make(_ c: Int = 20, _ r: Int = 5) -> (Terminal, Sink) {
        let t = Terminal(cols: c, rows: r, scrollbackLimit: 1000)
        let s = Sink()
        t.delegate = s
        return (t, s)
    }

    static func run(_ results: Results) {
        func check(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
            results.check(name, cond, detail())
        }
        do {
            // Under ConPTY: nothing comes back from scrollback, rows move only to keep the cursor on screen.
            let (t, _) = make(20, 5)
            t.repaintedByConsole = true
            feed(t, "1\r\n2\r\n3\r\n4\r\n5\r\n6\r\n7")
            check("console resize: starts with scrollback", t.scrollback.count == 2 && t.cursorY == 4)
            t.resize(cols: 20, rows: 8)
            check("console resize: growing leaves scrollback and rows alone", t.scrollback.count == 2 && t.cursorY == 4
                  && row(t, 0) == "3" && row(t, 4) == "7" && t.screen.count == 8 && row(t, 7) == "",
                  "\(t.scrollback.count) \(t.cursorY)")
            t.resize(cols: 20, rows: 3)
            check("console resize: shrinking keeps the cursor on screen", t.scrollback.count == 4 && t.cursorY == 2
                  && row(t, 2) == "7" && t.scrollback[3].text() == "4" && t.screen.count == 3,
                  "\(t.scrollback.count) \(t.cursorY)")
            t.resize(cols: 10, rows: 3)
            check("console resize: width fits every row", t.screen.allSatisfy { $0.cells.count == 10 } && t.scrollback.count == 4)
        }
        do {
            check("agent session: by name, also a path or an .exe", Block.namesAgentSession("claude --resume")
                  && Block.namesAgentSession("/opt/bin/claude") && Block.namesAgentSession(#"C:\tools\claude.exe -c"#)
                  && !Block.namesAgentSession("claudette") && !Block.namesAgentSession("cat claude.txt"))
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
            feed(t, "see \u{1b}]8;id=1;https://example.com/a\u{1b}\\docs\u{1b}]8;;\u{1b}\\ now")
            let l = t.screen[0]
            check("OSC 8 links", (4...7).allSatisfy { l.links?[$0] == "https://example.com/a" } && l.links?[3] == nil && l.links?[8] == nil)
            feed(t, "\r\u{1b}[K")
            check("OSC 8 erased", t.screen[0].links?.isEmpty ?? true)
            feed(t, String(repeating: "x", count: 18) + "\u{1b}]8;;file:///tmp/f\u{7}abcd\u{1b}]8;;\u{7}")
            t.resize(cols: 10, rows: 8)
            let linked = (0..<4).flatMap { a in (0..<10).filter { t.screen[a].links?[$0] == "file:///tmp/f" }.map { "\(a):\($0)" } }
            check("OSC 8 links reflow", linked == ["1:8", "1:9", "2:0", "2:1"], linked.joined(separator: " "))
        }
        do {
            // Scrolling reuses lines and their cells: what comes back in must be blank, all the way across.
            let t = Terminal(cols: 20, rows: 3, scrollbackLimit: 100)
            feed(t, "long line here!!\r\na\r\nbb\r\nccc\r\n")
            check("scroll: scrollback keeps text", t.scrollback.count == 2 && t.scrollback[0].text() == "long line here!!"
                  && t.scrollback[1].text() == "a", t.scrollback.toArray().map { $0.text() }.description)
            check("scroll: scrollback lines trimmed", t.scrollback[1].cells.count == 1)
            check("scroll: new lines blank and full width", (0..<3).map { row(t, $0) } == ["bb", "ccc", ""]
                  && t.screen.allSatisfy { $0.cells.count == 20 } && t.screen[2].cells.allSatisfy { $0 == Cell() })
            feed(t, "\u{1b}[44m\r\n\r\n")
            check("scroll: erase color fills reused lines", t.screen[2].cells.allSatisfy { $0.bg == TermColor.indexed(4) })
            feed(t, "\u{1b}[0mx\r\n\r\n\r\n")
            check("scroll: plain lines after colored ones", t.screen.allSatisfy { $0.cells.allSatisfy { $0 == Cell() } || $0.text() == "x" })
            let r = Terminal(cols: 10, rows: 4, scrollbackLimit: 100)
            feed(r, "top\r\n\u{1b}[2;4r\u{1b}[2;1Hone\r\ntwo\r\nthree\r\nfour")
            check("scroll: region reuses its line blank", (0..<4).map { row(r, $0) } == ["top", "two", "three", "four"]
                  && r.scrollback.count == 0, (0..<4).map { row(r, $0) }.description)
            feed(r, "\u{1b}[2;1H\u{1b}M")
            check("scroll: reverse index in a region", (0..<4).map { row(r, $0) } == ["top", "", "two", "three"]
                  && r.screen[1].cells.count == 10, (0..<4).map { row(r, $0) }.description)
        }
    }
}
