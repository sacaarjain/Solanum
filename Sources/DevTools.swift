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
        do {
            // Readable text: enough contrast afterwards, the hue kept, and what's already fine or hidden left alone.
            let light = CGColor(srgbRed: 0.78, green: 0.79, blue: 0.81, alpha: 1), yellow = CGColor(srgbRed: 0.82, green: 0.76, blue: 0.25, alpha: 1)
            let dark = CGColor(srgbRed: 0.14, green: 0.15, blue: 0.17, alpha: 1)
            let fixed = RenderPalette.adjusted(yellow, over: light, minimum: 4.5, dim: false)
            check("faint text gains contrast", RenderPalette.contrast(fixed, light) >= 4.5 && RenderPalette.contrast(fixed, light) < 4.7)
            if let f = RenderPalette.rgb(fixed) { check("its hue stays", f.r > f.b && f.g > f.b) }
            check("readable text is left alone", RenderPalette.adjusted(dark, over: light, minimum: 4.5, dim: false) === dark)
            check("hidden text stays hidden", RenderPalette.adjusted(light, over: light, minimum: 4.5, dim: false) === light)
            let lifted = RenderPalette.adjusted(dark, over: dark.copy(alpha: 1)!.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)!, minimum: 4.5, dim: false)
            check("same color is hidden on dark too", lifted === dark)
            let onDark = RenderPalette.adjusted(CGColor(srgbRed: 0.25, green: 0.25, blue: 0.3, alpha: 1), over: dark, minimum: 4.5, dim: false)
            check("over a dark cell it lightens", RenderPalette.contrast(onDark, dark) >= 4.5)
        }
        do {
            // Git Status: a file both staged and changed again is in both groups, renames keep their old name.
            let out = "/repo\n# branch.oid abcdef1234\0# branch.head main\0# branch.upstream origin/main\0# branch.ab +2 -1\0"
                + "1 MM N... 100644 100644 100644 a b both.txt\0"
                + "2 R. N... 100644 100644 100644 a b R100 new name.txt\0old name.txt\0"
                + "1 .D N... 100644 100644 100644 a b gone.txt\0"
                + "u UU N... 100644 100644 100644 100644 a b c fight.txt\0"
                + "? fresh.txt\0\u{1E}"
                + "3\t1\tboth.txt\00\t0\t\0old name.txt\0new name.txt\0\u{1E}"
                + "2\t0\tboth.txt\00\t4\tgone.txt\0-\t-\tpic.png\0\u{1E}"
                + "Fix it\0" + "2 hours ago\n"
            if let r = GitStatusReport(output: Data(out.utf8)) {
                check("status: branch and upstream", r.branch == "main" && r.upstream == "origin/main" && r.ahead == 2 && r.behind == 1)
                check("status: a file in both groups", r.staged.first?.path == "both.txt" && r.staged.first?.added == 3 && r.changed.first?.path == "both.txt" && r.changed.first?.added == 2)
                check("status: rename", r.staged.last?.path == "new name.txt" && r.staged.last?.oldPath == "old name.txt" && r.staged.last?.code == "R")
                check("status: deleted, conflict, untracked", r.changed.last?.code == "D" && r.changed.last?.removed == 4 && r.conflicts.first?.path == "fight.txt" && r.untracked.first?.path == "fresh.txt")
                check("status: last commit", r.lastCommit == "Fix it" && r.lastCommitDate == "2 hours ago")
            } else {
                check("status: parses", false)
            }
            check("status: not a repository", GitStatusReport(output: Data()) == nil)
            let diff = "diff --git a/x b/x\nindex 1..2 100644\n--- a/x\n+++ b/x\n@@ -3,3 +3,3 @@ func\n keep\n-old\n+new\n\\ No newline at end of file\n"
            let lines = GitDiffLine.parse(Data(diff.utf8))
            check("diff: hunk and numbers", lines.map(\.kind) == [.hunk, .context, .removed, .added] && lines[1].old == 3 && lines[1].new == 3 && lines[2].old == 4 && lines[3].new == 4 && lines[3].text == "new")
            check("diff: binary", GitDiffLine.parse(Data("Binary files a/x and b/x differ\n".utf8)).first?.kind == .note)
            let conflict = GitDiffLine.parse(Data("diff --cc x\n@@@ -1,1 -1,1 +1,5 @@@\n++<<<<<<< HEAD\n +ours\n- theirs\n".utf8))
            check("diff: conflict", conflict.map(\.kind) == [.hunk, .added, .added, .removed] && conflict[1].new == nil)
            check("diff: nothing", GitDiffLine.parse(Data()).isEmpty)
            let commit = "/repo\nabc123\u{1F}abc\u{1F}Ada\u{1F}2 days ago\u{1F}Fix: it, really\nparent1\u{1E}"
                + "M\0a.txt\0R100\0old.txt\0new.txt\0A\0b c.txt\0\u{1E}"
                + "3\t1\ta.txt\00\t0\t\0old.txt\0new.txt\0-\t-\tb c.txt\0"
            if let r = GitStatusReport(commitOutput: Data(commit.utf8)), let c = r.commit {
                check("commit: header", c.short == "abc" && c.author == "Ada" && c.subject == "Fix: it, really" && c.base == "parent1")
                check("commit: files", r.changed.map(\.path) == ["a.txt", "new.txt", "b c.txt"] && r.changed[0].added == 3 && r.changed[1].oldPath == "old.txt" && r.changed[1].code == "R" && r.changed[2].added == nil)
            } else {
                check("commit: parses", false)
            }
        }
        do {
            // Search in Project Folder: all three tools' output, odd names, and long lines.
            let rg = WorkspaceMatch.parse(Data("./src/a b.txt\u{0}12:  hello: world\nc.txt\u{0}3:hello\n".utf8))
            check("find: ripgrep and grep", rg == [WorkspaceMatch(path: "src/a b.txt", line: 12, text: "  hello: world"), WorkspaceMatch(path: "c.txt", line: 3, text: "hello")])
            let gitGrep = WorkspaceMatch.parse(Data("src/x:y.txt\u{0}7\u{0}hello\nz.txt\u{0}8:hello\n".utf8))
            check("find: git grep", gitGrep.map(\.path) == ["src/x:y.txt", "z.txt"] && gitGrep[0].line == 7 && gitGrep[0].text == "hello")
            check("find: not a match line", WorkspaceMatch.parse(Data("Binary file x matches\n".utf8)).isEmpty)
            let long = String(repeating: "x", count: 100) + "needle"
            check("find: long line starts near the match", WorkspaceMatch.excerpt(long, query: "NEEDLE").hasPrefix("…") && WorkspaceMatch.excerpt(long, query: "NEEDLE").contains("needle"))
            check("find: trims indentation", WorkspaceMatch.excerpt("    let a = 1", query: "a") == "let a = 1")
        }
        do {
            // Find in a file: the three toggles, separately and together.
            let text = "Cat cat concat\ncat.dog (cat)\nline three\n" as NSString
            func count(_ q: String, _ o: EditorFindOptions) -> Int? {
                (try? EditorFind.expression(q, o)).map { EditorFind.matches(of: $0, in: text).ranges.count }
            }
            check("find in file: ignores case by default", count("cat", EditorFindOptions()) == 5)
            check("find in file: match case", count("Cat", EditorFindOptions(matchCase: true)) == 1)
            check("find in file: whole word", count("cat", EditorFindOptions(wholeWord: true)) == 4)
            check("find in file: both", count("cat", EditorFindOptions(matchCase: true, wholeWord: true)) == 3)
            check("find in file: text isn't a pattern", count("cat.dog", EditorFindOptions()) == 1 && count(".", EditorFindOptions()) == 1 && count("(cat)", EditorFindOptions()) == 1)
            check("find in file: regex", count("c.t", EditorFindOptions(regex: true)) == 5 && count("^cat", EditorFindOptions(regex: true)) == 2)
            check("find in file: bad regex", count("(", EditorFindOptions(regex: true)) == nil)
            check("find in file: empty matches don't count", count("x*", EditorFindOptions(regex: true)) == 0)
            // Plain search has to find exactly what the regex engine does, on awkward text and on random text.
            func same(_ q: String, _ t: String, _ o: EditorFindOptions) -> Bool {
                guard let e = try? EditorFind.expression(q, o) else { return false }
                return FindBuffer(t as NSString).matches(of: q, o).ranges == EditorFind.matches(of: e, in: t as NSString).ranges
            }
            let combos = [EditorFindOptions(), EditorFindOptions(matchCase: true), EditorFindOptions(wholeWord: true), EditorFindOptions(matchCase: true, wholeWord: true)]
            let awkward = [("aa", "aaaaa"), ("cat", "cat"), ("cat", "ca"), ("a", "a a_a a-a 1a"), ("ab", "abab ab"), (".", "a.b."), ("(x", "(x (x)"), ("-a", "b-a -a"), ("é", "é cé é"), ("x", "😀x😀 x"), ("cat", "“cat” cat’s")]
            check("find in file: plain matches regex on awkward text", awkward.allSatisfy { q, t in combos.allSatisfy { same(q, t, $0) } })
            var seed: UInt64 = 42
            func next(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(n)) }
            let alphabet = Array("abAB_ 1.-\n")
            var agree = true
            for _ in 0..<400 {
                let t = String((0..<next(60)).map { _ in alphabet[next(alphabet.count)] })
                let q = String((0..<(1 + next(4))).map { _ in alphabet[next(alphabet.count)] })
                if !combos.allSatisfy({ same(q, t, $0) }) { agree = false }
            }
            check("find in file: plain matches regex on random text", agree)
            check("find in file: plain search used when it can be", FindBuffer.canSearch("cat", EditorFindOptions()) && !FindBuffer.canSearch("cat", EditorFindOptions(regex: true)) && !FindBuffer.canSearch("é", EditorFindOptions()) && FindBuffer.canSearch("é", EditorFindOptions(matchCase: true)))
            let ranges = [NSRange(location: 5, length: 1), NSRange(location: 10, length: 1)]
            check("find in file: starts at or after the caret, then wraps", EditorFind.index(of: ranges, from: 0) == 0 && EditorFind.index(of: ranges, from: 6) == 1 && EditorFind.index(of: ranges, from: 11) == 0 && EditorFind.index(of: [], from: 0) == nil)
        }
        do {
            // Reconnecting keeps just how to reach the host, whatever the session ran there.
            let c = RemoteSession.connectionArgs
            check("ssh args: plain", c("myhost") == "myhost" && c("-p 2222 me@host") == "-p 2222 me@host" && c("-p2222 -i ~/k host") == "-p2222 -i ~/k host")
            check("ssh args: a reconnect's command dropped", c("-t mb1.example.com cd\\ \\'/mnt\\'\\ 2\\>/dev/null\\;\\ exec\\ \\\"\\$SHELL\\\"\\ -l") == "mb1.example.com")
            check("ssh args: quoted command dropped", c("-t -o 'ProxyJump bastion' host 'cd /x; exec $SHELL -l'") == "-o 'ProxyJump bastion' host")
            check("ssh args: flags kept, -t dropped", c("-A -tt -v host ls") == "-A -v host" && c("-o") == nil && c("") == nil)
        }
        do {
            // Background commands over ssh wait their turn rather than go past the server's limit.
            let gate = ChannelGate(limit: 2)
            var started: [Int] = []
            for i in 0..<5 { gate.enter { started.append(i) } }
            check("channels: only so many at once", started == [0, 1])
            gate.leave()
            check("channels: the next goes as one ends", started == [0, 1, 2])
            gate.leave(); gate.leave(); gate.leave(); gate.leave()
            check("channels: all get their turn, in order", started == [0, 1, 2, 3, 4])
            gate.enter { started.append(5) }
            check("channels: room again once they've ended", started.last == 5)
        }
        do {
            // Closing a pane stops what's running in it, also jobs a script put in process groups of their own (`set -m`),
            // which the shell doesn't know about. Jobs the user kept (nohup, disown) keep running.
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("solanum-hangup-\(getpid())").path
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let script = """
            #!/bin/bash
            set -m
            echo $$ > '\(dir)/script'
            sleep 300 & echo $! > '\(dir)/nested'
            nohup sleep 300 >/dev/null 2>&1 & echo $! > '\(dir)/nohup'
            wait
            """
            try? script.write(toFile: dir + "/run.sh", atomically: true, encoding: .utf8)
            func pid(_ name: String) -> pid_t? {
                (try? String(contentsOfFile: dir + "/" + name, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
            func alive(_ p: pid_t?) -> Bool { p.map { kill($0, 0) == 0 } ?? false }
            func waitUntil(_ cond: () -> Bool) { for _ in 0..<100 where !cond() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) } }
            let pty = PTYProcess(executable: "/bin/bash", args: ["bash", "--noprofile", "--norc", "-i"], env: ["TERM": "dumb", "PATH": "/usr/bin:/bin"], cwd: dir, cols: 80, rows: 24)
            pty?.start()
            pty?.write(Array("sleep 300 & echo $! > disowned; disown; /bin/bash run.sh\n".utf8))
            waitUntil { pid("disowned") != nil && pid("script") != nil && pid("nested") != nil && pid("nohup") != nil }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
            check("hangup: all started", alive(pid("disowned")) && alive(pid("script")) && alive(pid("nested")) && alive(pid("nohup")))
            pty?.terminate()
            waitUntil { !alive(pid("script")) && !alive(pid("nested")) }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
            check("hangup: the script stops", !alive(pid("script")))
            check("hangup: its job in a process group of its own stops too", !alive(pid("nested")))
            check("hangup: nohup keeps running", alive(pid("nohup")))
            check("hangup: disowned keeps running", alive(pid("disowned")))
            for name in ["script", "nested", "nohup", "disowned"] { if let p = pid(name) { kill(p, SIGKILL) } }
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
        do {
            func urls(_ s: String) -> [String] { TerminalView.links(in: s).map(\.url.absoluteString) }
            check("links: trailing punctuation", urls("It's up at http://127.0.0.1:3007.") == ["http://127.0.0.1:3007"])
            check("links: bare localhost gets http", urls("ready on localhost:5173/app, go") == ["http://localhost:5173/app"])
            check("links: 0.0.0.0 opens as localhost", urls("listening on http://0.0.0.0:8000") == ["http://localhost:8000"])
            check("links: no port, no link", urls("ssh localhost and 127.0.0.1") == [])
            check("links: inside a scheme link once", urls("(see https://localhost:3000/x)") == ["https://localhost:3000/x"])
            func named(_ s: String) -> [String] { FileLinks.mentions(in: s).map { $0.path + ($0.line.map { ":\($0)" } ?? "") } }
            check("file links: with a line", named("at Sources/AgentStatus.swift:52.") == ["at", "Sources/AgentStatus.swift:52"])
            check("file links: line and column", named("x.swift:7:3: error") == ["x.swift:7", "error"])
            check("file links: in quotes and brackets", named("(`~/a.md`) \"b/c\",") == ["~/a.md", "b/c"])
            check("file links: no line 0", FileLinks.mentions(in: "a.txt:0").first?.line == nil)
            check("file links: quoted, with spaces", named("open \"My Notes/a.md\" now").first == "My Notes/a.md")
            check("file links: quoted, line inside or after", named("'a b.txt:4'").first == "a b.txt:4" && named("`a b.txt`:9").first == "a b.txt:9")
            check("file links: quoted, other characters", named("\"report (1).pdf\"").first == "report (1).pdf")
            check("file links: quoted, words inside still count", named("\"see a/b.txt:3 now\"") == ["see a/b.txt:3 now", "see", "a/b.txt:3", "now"])
            check("file links: apostrophes aren't quotes", named("it's dogs' a.txt") == ["it", "s", "dogs", "a.txt"])
            check("file links: backslashed", named(#"cat My\ Notes/a.md:7 x"#) == ["cat", "My Notes/a.md:7", "x"])
            check("file links: unquoted spaces stay apart", named("My Notes/a.md") == ["My", "Notes/a.md"])
            let folders = ["/proj/sub", "/pin"]
            check("file links: relative, nearest first", FileLinks.locations(of: "a/b.txt", in: folders, home: "/h") == ["/proj/sub/a/b.txt", "/pin/a/b.txt"])
            check("file links: dots", FileLinks.locations(of: "../c.txt", in: ["/proj/sub"], home: nil) == ["/proj/c.txt"])
            check("file links: home and absolute", FileLinks.locations(of: "~/n.md", in: folders, home: "/h") == ["/h/n.md"]
                  && FileLinks.locations(of: "/etc/hosts", in: folders, home: "/h") == ["/etc/hosts"])
            check("file links: inside a folder", FileLinks.isInside("/a/b/c", "/a") && FileLinks.isInside("/a/b", "/a/b") && FileLinks.isInside("/a", "/")
                  && !FileLinks.isInside("/ab/c", "/a"))
            check("file links: worth a look over ssh", FileLinks.looksLikePath("a/b") && FileLinks.looksLikePath("a.txt")
                  && !FileLinks.looksLikePath("word") && !FileLinks.looksLikePath("/") && !FileLinks.looksLikePath("..") && !FileLinks.looksLikePath("dir/"))
            do {
                // A question near the top of a tall screen counts, as it does at the bottom; old menus further up don't.
                let (t, _) = make(40, 50)
                feed(t, "Trust this folder?\r\n❯ 1. Yes\r\n  2. No\r\n")
                check("agent status: question at the top of a tall screen", t.agentScreenStatus() == .waiting)
                feed(t, String(repeating: "line\r\n", count: 30))
                check("agent status: an old question far above isn't live", t.agentScreenStatus() == .done)
            }
            check("chats: commands join oldest first", AgentChats.transcript(["$ a\n1", "$ b\n2"]) == "$ a\n1\n\n$ b\n2")
            check("chats: agents found on PATH", InstalledAgents.parse("noise\nsolanum-agent:codex\nsolanum-agent:claude\nsolanum-agent:nonsense\n").map(\.command) == ["claude", "codex"])
            check("chats: every known agent can start", AgentKind.known.allSatisfy { !$0.command.isEmpty } && AgentKind.known.contains(.other("aider")))
            check("agents: astra is found by its command", AgentKind.detect(name: "astra", path: "/usr/local/bin/astra", args: []) == .other("astra"))
            check("agents: continue commands", AgentKind.claude.defaultContinueCommand == "claude -c" && AgentKind.codex.defaultContinueCommand == "codex resume --last"
                  && AgentKind.gemini.defaultContinueCommand == "gemini --resume latest" && AgentKind.other("amp").defaultContinueCommand.isEmpty)
            check("agents: known by their commands", AgentKind.known.allSatisfy { AgentKind.named($0.command) == $0 } && AgentKind.named("zsh") == nil)
            check("agents: continue goes through an alias", AgentKind.claude.throughAlias("claude -c", alias: "c") == "c -c"
                  && AgentKind.claude.throughAlias("claudette -c", alias: "c") == "claudette -c" && AgentKind.codex.throughAlias("codex resume --last", alias: nil) == "codex resume --last")
            check("session: Claude from an older session still continues", {
                let old = try? JSONDecoder().decode(PaneState.self, from: Data(#"{"claude":true}"#.utf8))
                return old?.claude == true && old?.agent == nil
            }())
            check("agents: logos load", AgentLogos.gemini.isValid && AgentLogos.openAI(.white) != nil)
            check("chats: paste waits", !AgentChats.readyForPaste(bracketed: false, status: .done, quietFor: 9)
                  && !AgentChats.readyForPaste(bracketed: true, status: nil, quietFor: 9)
                  && !AgentChats.readyForPaste(bracketed: true, status: .waiting, quietFor: 9)
                  && !AgentChats.readyForPaste(bracketed: true, status: .done, quietFor: 0.1)
                  && AgentChats.readyForPaste(bracketed: true, status: .done, quietFor: 1)
                  && AgentChats.readyForPaste(bracketed: true, status: .working, quietFor: 1))
            check("links: local or not", TerminalView.isLocal(URL(string: "http://localhost:3000")!)
                  && !TerminalView.isLocal(URL(string: "https://github.com")!))
        }
        print(failures == 0 ? "All \(count) checks passed." : "\(failures) of \(count) checks FAILED.")
        return failures == 0
    }
}

/// Development aid: SOLANUM_SNAPSHOT=/path.png renders the first window to a PNG after a delay.
/// SOLANUM_SNAPSHOT_INPUT types text first; SOLANUM_SNAPSHOT_ACTIONS=split,palette,select-block,collapse,jump-prompt,find,find-commands,find-output,click:<col>:<row>,keys:<text>,theme:<name>,
/// newtab,rename-tab,new-group,edit:<text>,select-tab:<i>,collapse-group:<i>,split-down,save-session,
/// tabbar-drag:<x1>:<x2>,chip-menu-rename,open-config,git-branches,later-keys:<text>,newtab-run:<command>,pin-sidebar,collapse-sidebar,print-claude-fg,undo,redo,print-input,sleep:<seconds>,print-boxes,print-return-keys,hover-last-block,scrollbar:<y0>:<y1>,print-tabs,cmd-click-tab:<i>,group-picked,name-tabs,chip-drag[-hold]:<x>,print-anim,close-tab:<i>,newtab-group,click-input:<col>,split-columns,close-split,move-tab-other,right-sidebar,focus-other,close-right-tabs,print-columns,tab-drop[-hold]:<i>:<fx>:<fy>,open-file-tab:<path>,open-diff:<path>,open-graph:<path>,open-preview:<path>,format-file,hover-graph:<row>,toggle-terminal,restore-prompt,editor-drag-out,select-input:<r0>:<c0>:<r1>:<c1>,drag-input:<r0>:<c0>:<r1>:<c1>:<seconds>,delete-selection,cmd-delete,select-cmd:<from>:<to>,print-selection,print-ssh,close-file,hover-title,print-sidebar,print-pins,sidebar-expand:<name>,sidebar-rename:<name>,sidebar-rename-to:<name>,sidebar-import:<path>,print-rows,status-transfer:<text>,pane-send:<text>,lost-bar:<Reconnect|Close>,print-lost-bar,refresh-sidebar,refresh-tab,glide-bottom,print-scroll,reopen-tab,quantum:<home|flower|folders>,nomai-read,palette-query:<text>,palette-run,print-cwds,sidebar-click:<name>,press-return,print-focus,print-editors,crumb-menu[:<item>],press-beautify,print-header,header-press:<tooltip start>,editor-scroll-x:<points>,file-icons:<id>,print-icons,minimum-contrast:<true|false>,icon-popup[:<label>],settings-size:<w>:<h>,settings-bottom,folder-icon:<path>,open-status:<repo>,status-click:<path>,status-open:<path>,status-all,graph-changes:<row>,find-in-folder:<query>,print-editor-place,sidebar-search,find-bar:<q>,find-case,find-word,find-regex,find-step,find-replace:<text>,find-replace-one,find-replace-all,print-find,find-close,find-speed:<q>,find-latency:<q>,find-type:<text>,editor-wrap,tab-arrow:<-1|1>,print-tab-scroll,press-key:<text>,hover-link:<col>:<row>,cmd-hover-link:<col>:<row>,cmd-click:<col>:<row>,set-pin:<path>,print-tab-files,print-blocks,block-copy,print-clipboard,send-menu,send-menu-run:<title start>,send-menu-mark:<title end>,send-menu-real[:<path>],settings-page:<title>,settings-press:<title>,settings-page-png:<path>,send-menu-png:<path>,bar-press:<title>,press-send-pill,press-copy-pill,print-agent-tail,print-context-menu:<col>:<row>
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
                    if action.hasPrefix("hover-link:") || action.hasPrefix("cmd-hover-link:") {
                        // hover-link:<col>:<row> — the pointer moves onto a screen cell (⌘ held, for cmd-hover-link); prints the link found there.
                        let cmd = action.hasPrefix("cmd-")
                        let n = action.dropFirst(cmd ? 15 : 11).split(separator: ":").compactMap { Double($0) }
                        if n.count == 2 {
                            pane.updateLinkHover(NSPoint(x: pane.padX + (n[0] + 0.5) * pane.fonts.cellW,
                                                         y: pane.padTop + (n[1] + 0.5) * pane.fonts.cellH), cmd: cmd)
                            print("link: \(pane.hoverURL.map { "\($0.url.absoluteString) cols \($0.start)-\($0.end) · \($0.opener)" } ?? "none")")
                        }
                    }
                    if action.hasPrefix("click:") || action.hasPrefix("click-input:") || action.hasPrefix("cmd-click:"), let w = c.window {
                        // click:<col>:<row> — a plain single click on a screen cell (cmd-click: with ⌘).
                        // click-input:<col> — the same on the first row of an agent's input box.
                        let flags: NSEvent.ModifierFlags = action.hasPrefix("cmd-click:") ? [.command] : []
                        var n = action.dropFirst(action.hasPrefix("click-input:") ? 12 : flags.isEmpty ? 6 : 10).split(separator: ":").compactMap { Double($0) }
                        if action.hasPrefix("click-input:"), let b = pane.terminal.currentBlock, let rows = pane.terminal.agentInputRows(b) {
                            n.append(Double(rows.lowerBound - pane.terminal.screenTopAbs))
                        }
                        if n.count == 2 {
                            let p = NSPoint(x: pane.padX + (n[0] + 0.5) * pane.fonts.cellW, y: pane.padTop + (n[1] + 0.5) * pane.fonts.cellH)
                            let loc = pane.convert(p, to: nil)
                            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                                if let e = NSEvent.mouseEvent(with: type, location: loc, modifierFlags: flags, timestamp: 0, windowNumber: w.windowNumber,
                                                              context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                                    if type == .leftMouseDown { pane.mouseDown(with: e) } else { pane.mouseUp(with: e) }
                                }
                            }
                        }
                    }
                    if action == "print-blocks" {
                        let list = pane.selectedBlocks.map(\.command)
                        FileHandle.standardError.write("blocks: selected=\(list) bar=\(pane.selectionBar != nil) visible=\(pane.terminal.blocks.filter { $0.state == .finished }.map(\.command))\n".data(using: .utf8)!)
                    }
                    if action == "block-copy" { pane.copyBlockOutput(nil) }
                    if action == "print-clipboard" { FileHandle.standardError.write("clipboard: \(String(reflecting: AgentChats.clipboard.string(forType: .string) ?? ""))\n".data(using: .utf8)!) }
                    if action == "send-menu" || action.hasPrefix("send-menu-run:") {
                        // The send menu for the selected commands: prints its items, or runs the one starting with the given title.
                        let text = pane.selectedBlocks.isEmpty ? pane.targetBlock.map { pane.blockText($0, includeCommand: true) } ?? "" : pane.selectedTranscript
                        let items = AgentChats.menu(sending: text, from: pane).items
                        FileHandle.standardError.write("send-menu: \(items.map { ($0.isSeparatorItem ? "---" : $0.title) + ($0.isEnabled ? "" : " [off]") })\n".data(using: .utf8)!)
                        if action.hasPrefix("send-menu-run:"), let item = items.first(where: { $0.title.hasPrefix(action.dropFirst(14)) }), let a = item.action {
                            NSApp.sendAction(a, to: item.target, from: item)
                        }
                    }
                    if action.hasPrefix("send-menu-mark:") {
                        // As highlighting the send menu's item ending in the given title does.
                        let menu = AgentChats.menu(sending: "", from: pane)
                        pane.devSendMenu = menu
                        AgentChats.devMark(menu, title: String(action.dropFirst(15)))
                    }
                    if action.hasPrefix("send-menu-png:") {
                        // Draws the send menu's item titles, chips and all, to a file (a real menu can't be snapshotted).
                        let items = AgentChats.menu(sending: "", from: pane).items.filter { !$0.isSeparatorItem }
                        let image = NSImage(size: NSSize(width: 420, height: 26 * items.count + 8), flipped: true) { r in
                            NSColor.white.setFill()
                            r.fill()
                            for (i, item) in items.enumerated() {
                                let title = item.attributedTitle ?? NSAttributedString(string: item.title, attributes: [.font: NSFont.menuFont(ofSize: 0)])
                                title.draw(at: NSPoint(x: 30, y: 8 + 26 * i))
                                item.image?.draw(in: NSRect(x: 10, y: 9 + 26 * i, width: 14, height: 14), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                            }
                            return true
                        }
                        // At 2x, as on a Retina screen.
                        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width) * 2, pixelsHigh: Int(image.size.height) * 2, bitsPerSample: 8,
                                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
                            rep.size = image.size
                            NSGraphicsContext.saveGraphicsState()
                            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                            image.draw(in: NSRect(origin: .zero, size: image.size))
                            NSGraphicsContext.restoreGraphicsState()
                            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: String(action.dropFirst(14))))
                        }
                    }
                    if action == "send-menu-real" || action.hasPrefix("send-menu-real:"), let w = pane.window {
                        // The real menu, stepped down with posted keys: prints what's highlighted and marked after each, then closes.
                        // With a path, also writes the menu's window with each of the first two chats highlighted (<path>-<n>.png).
                        let shots = action.hasPrefix("send-menu-real:") ? String(action.dropFirst(15)) : nil
                        for (n, delay) in [0.9, 1.5].enumerated() {
                            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                                guard let shots else { return }
                                for other in NSApp.windows where other !== w && other.isVisible && String(describing: type(of: other)).contains("Menu") {
                                    guard let v = other.contentView?.superview ?? other.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
                                    v.cacheDisplay(in: v.bounds, to: rep)
                                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(shots)-\(n).png"))
                                }
                            }
                        }
                        NSApp.activate(ignoringOtherApps: true)
                        w.makeKeyAndOrderFront(nil)
                        func report() {
                            let marked = c.columns.compactMap { $0.tabBar.sendTarget?.customTitle }
                            FileHandle.standardError.write("send-menu-real: highlighted=\(pane.devSendMenu?.highlightedItem?.title ?? "-") marked=\(marked) unpainted=\(c.columns.contains { $0.tabBar.needsDisplay })\n".data(using: .utf8)!)
                        }
                        for (n, delay) in [0.5, 1.0].enumerated() {
                            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                                if n == 0 { report() }
                                let down = String(UnicodeScalar(NSDownArrowFunctionKey)!)
                                if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                                            context: nil, characters: down, charactersIgnoringModifiers: down, isARepeat: false, keyCode: 125) { NSApp.postEvent(e, atStart: false) }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: report)
                            }
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { pane.devSendMenu?.cancelTrackingWithoutAnimation() }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.3, execute: report)
                        // From a timer: a menu opened in a main-queue block would hold the queue, and the reports above, until it closes.
                        Timer.scheduledTimer(withTimeInterval: 0.01, repeats: false) { _ in pane.showSendMenu(for: pane.targetBlock.map { [$0] } ?? [], at: NSPoint(x: 40, y: 80)) }
                    }
                    if action.hasPrefix("print-context-menu:") {
                        // print-context-menu:<col>:<row> — what a right-click on a screen cell offers.
                        let n = action.dropFirst(19).split(separator: ":").compactMap { Double($0) }
                        if n.count == 2, let w = c.window,
                           let e = NSEvent.mouseEvent(with: .rightMouseDown, location: pane.convert(NSPoint(x: pane.padX + (n[0] + 0.5) * pane.fonts.cellW, y: pane.padTop + (n[1] + 0.5) * pane.fonts.cellH), to: nil),
                                                      modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                            let items = pane.menu(for: e)?.items ?? []
                            FileHandle.standardError.write("context-menu: \(items.filter { !$0.isSeparatorItem }.map { $0.title + ($0.submenu.map { " > \($0.items.map(\.title))" } ?? "") })\n".data(using: .utf8)!)
                        }
                    }
                    if action.hasPrefix("bar-press:") { pane.selectionBar?.devPress(String(action.dropFirst(10))) }
                    if action == "press-copy-pill", let button = pane.blockCopyButton, let w = pane.window {
                        // A real press and release on "Copy output".
                        let loc = pane.convert(NSPoint(x: button.rect.midX, y: button.rect.midY), to: nil)
                        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                            if let e = NSEvent.mouseEvent(with: type, location: loc, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                                          context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                                if type == .leftMouseDown { pane.mouseDown(with: e) } else { pane.mouseUp(with: e) }
                            }
                        }
                    }
                    if action == "press-send-pill", let button = pane.blockSendButton, let w = pane.window {
                        // A real press on "Send to chat"; its menu reports what it offers, then closes.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            FileHandle.standardError.write("pill-menu: \(pane.devSendMenu?.items.map(\.title) ?? [])\n".data(using: .utf8)!)
                            pane.devSendMenu?.cancelTrackingWithoutAnimation()
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { pane.devSendMenu?.cancelTrackingWithoutAnimation() }
                        let loc = pane.convert(NSPoint(x: button.rect.midX, y: button.rect.midY), to: nil)
                        if let e = NSEvent.mouseEvent(with: .leftMouseDown, location: loc, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                                      context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { pane.mouseDown(with: e) }
                    }
                    if action == "print-agent-tail" {
                        let tail = (max(pane.terminal.firstAbs, pane.terminal.lastAbs - 30)...pane.terminal.lastAbs).compactMap { pane.terminal.line(abs: $0)?.text() }.filter { !$0.isEmpty }
                        FileHandle.standardError.write("agent=\(pane.agent?.summary ?? "none") paste-waiting=\(pane.chatPaste != nil) bracketed=\(pane.terminal.bracketedPaste)\ntail: \(tail.suffix(12).joined(separator: " | "))\n".data(using: .utf8)!)
                    }
                    if action.hasPrefix("set-pin:") { c.activeTab?.pinnedFolder = (pane.fileSystem, String(action.dropFirst(8))) }
                    if action == "print-tab-files" {
                        let tabs = c.allTabs.map { t in
                            "[\(t === c.activeTab ? "*" : "")\(t.showsTerminal ? "term" : "file") \(t.editors.map { $0.displayName + ":\($0.devCaretLine)" }) showing \(t.editor?.displayName ?? "-")]"
                        }
                        FileHandle.standardError.write("tab-files: \(tabs.joined(separator: " "))\n".data(using: .utf8)!)
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
                    if action.hasPrefix("open-status:") { c.activeTab?.openFile(LocalFileSystem.shared, String(action.dropFirst(12)), mode: .status) }
                    if action.hasPrefix("status-click:") { c.activeTab?.editor?.devStatusView?.devClick(String(action.dropFirst(13))) }
                    if action.hasPrefix("graph-changes:"), let r = Int(action.dropFirst(14)) { c.activeTab?.editor?.devGraphView?.devViewChanges(r) }
                    if action.hasPrefix("status-open:") { c.activeTab?.editor?.devStatusView?.devOpen(String(action.dropFirst(12))) }
                    if action == "status-all" { c.activeTab?.editor?.devStatusView?.devToggleAll() }
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
                    if action.hasPrefix("sidebar-rename:") { c.rootView.sidebar.devBeginRename(String(action.dropFirst(15))) }
                    if action.hasPrefix("sidebar-rename-to:") { c.rootView.sidebar.devFinishRename(String(action.dropFirst(18))) }
                    if action.hasPrefix("sidebar-click:") { c.rootView.sidebar.devClick(String(action.dropFirst(14))) }
                    if action == "press-cmd-return", let w = c.window,
                       let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: w.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                                isARepeat: false, keyCode: 36) { NSApp.sendEvent(e) }
                    if action == "press-return", let w = c.window,
                       let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: w.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                                isARepeat: false, keyCode: 36) { w.sendEvent(e) }
                    if action == "print-editors" {
                        let eds = c.allTabs.flatMap { $0.editors.map { "\($0.displayName) @ \($0.path)" } }
                        FileHandle.standardError.write("editors: \(eds)\n".data(using: .utf8)!)
                    }
                    if action == "press-beautify", let w = c.window,
                       let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: w.windowNumber, context: nil, characters: "ƒ", charactersIgnoringModifiers: "f",
                                                isARepeat: false, keyCode: 3) { _ = NSApp.mainMenu?.performKeyEquivalent(with: e) }
                    if action == "print-header" {
                        FileHandle.standardError.write("header: \(c.activeTab?.editor?.displayName ?? "-") \(c.activeTab?.editor?.devHeader.devButtons ?? [])\n".data(using: .utf8)!)
                    }
                    if action.hasPrefix("header-press:") { c.activeTab?.editor?.devHeader.devPress(String(action.dropFirst(13))) }
                    if action.hasPrefix("editor-scroll-x:"), let x = Double(action.dropFirst(16)) { c.activeTab?.editor?.devScroll(x: CGFloat(x)) }
                    if action.hasPrefix("minimum-contrast:") {
                        Config.shared.minimumContrast = action.hasSuffix("true")
                        NotificationCenter.default.post(name: .solanumConfigChanged, object: nil)
                    }
                    if action.hasPrefix("file-icons:") {
                        Config.shared.fileIcons = String(action.dropFirst(11))
                        NotificationCenter.default.post(name: .solanumConfigChanged, object: nil)
                    }
                    if action.hasPrefix("settings-size:") {
                        // A Settings window of any size, past the screen's if need be, to see a whole page at once.
                        let n = action.dropFirst(14).split(separator: ":").compactMap { Double($0) }
                        if n.count == 2, let w = SettingsWindowController.shared.window { w.setFrame(NSRect(x: 0, y: 0, width: n[0], height: n[1]), display: true) }
                    }
                    if action.hasPrefix("folder-icon:") {
                        // The Icon pack row's folder, to a PNG; nil (Solanum's own icons) writes nothing.
                        let img = IconPacks.current?.icon(forName: "folder", directory: true, light: !Config.shared.theme.isDark)
                        FileHandle.standardError.write("folder: \(Config.shared.fileIcons) on \(Config.shared.theme.name) -> \(IconPacks.shownID): \(img == nil ? "none" : "image")\n".data(using: .utf8)!)
                        if let img, let t = img.tiffRepresentation, let png = NSBitmapImageRep(data: t)?.representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: String(action.dropFirst(12))))
                        }
                    }
                    if action.hasPrefix("settings-page:") {
                        // Opens the Settings page with this title.
                        SettingsWindowController.shared.present()
                        if let p = SettingsWindowController.Page.allCases.first(where: { $0.title == action.dropFirst(14) }) { SettingsWindowController.shared.show(p) }
                    }
                    if action.hasPrefix("settings-press:") {
                        // A real press on the toggle of the row with this title, on the page showing.
                        func rows(_ v: NSView) -> [SettingRow] { ((v as? SettingRow).map { [$0] } ?? []) + v.subviews.flatMap(rows) }
                        if let root = SettingsWindowController.shared.window?.contentView {
                            let row = rows(root).first { $0.devTitle == action.dropFirst(15) }
                            let at = row.map { $0.convert(NSPoint(x: $0.bounds.midX, y: $0.bounds.midY), to: nil) } ?? .zero
                            let hit = root.superview.flatMap { $0.hitTest(at) } ?? root.hitTest(at)
                            FileHandle.standardError.write("settings-press: \(action.dropFirst(15)) found=\(row != nil) titles=\(rows(root).map(\.devTitle).suffix(3)) at=\(at) window=\(root.frame.size) hit=\(hit.map { String(describing: type(of: $0)) } ?? "nil")\n".data(using: .utf8)!)
                            row?.devPress()
                        }
                    }
                    if action.hasPrefix("settings-page-png:") {
                        // The page showing, all of it however it's scrolled, to a PNG (its background is the window's, so clear).
                        func pages(_ v: NSView) -> [SettingsPageView] { ((v as? SettingsPageView).map { [$0] } ?? []) + v.subviews.flatMap(pages) }
                        if let root = SettingsWindowController.shared.window?.contentView, let page = pages(root).first,
                           let rep = page.bitmapImageRepForCachingDisplay(in: page.bounds) {
                            page.cacheDisplay(in: page.bounds, to: rep)
                            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: String(action.dropFirst(18))))
                        }
                    }
                    if action == "settings-bottom" {
                        // Settings scrolled to the file icons, which sit under the theme cards.
                        func scrolls(_ v: NSView) -> [NSScrollView] { ((v as? NSScrollView).map { [$0] } ?? []) + v.subviews.flatMap(scrolls) }
                        func popups(_ v: NSView) -> [ChoicePopup] { ((v as? ChoicePopup).map { [$0] } ?? []) + v.subviews.flatMap(popups) }
                        let root = SettingsWindowController.shared.window?.contentView
                        if let p = root.map(popups)?.first(where: { $0.itemTitles.contains("Solanum") }) { p.scrollToVisible(p.bounds.insetBy(dx: 0, dy: -120)) }
                        _ = root.map(scrolls)
                    }
                    if action.hasPrefix("icon-popup") {
                        // The Settings icon pack menu: optionally choosing an item, then what it shows.
                        func popups(_ v: NSView) -> [ChoicePopup] { ((v as? ChoicePopup).map { [$0] } ?? []) + v.subviews.flatMap(popups) }
                        let p = SettingsWindowController.shared.window?.contentView.map(popups)?.first { $0.itemTitles.contains("Solanum") }
                        if action.hasPrefix("icon-popup:"), let p {
                            p.selectItem(withTitle: String(action.dropFirst(11)))
                            p.sendAction(p.action, to: p.target)
                        }
                        let q = SettingsWindowController.shared.window?.contentView.map(popups)?.first { $0.itemTitles.contains("Solanum") }
                        FileHandle.standardError.write("popup: checked=\(q?.titleOfSelectedItem ?? "-") note=\(IconPacks.flavorNote ?? "-") setting=\(Config.shared.fileIcons) on \(Config.shared.theme.name)\n".data(using: .utf8)!)
                    }
                    if action == "print-icons" { FileHandle.standardError.write("icons: \(Config.shared.fileIcons) -> \(IconPacks.shownID) on \(Config.shared.theme.name)\n".data(using: .utf8)!) }
                    if action == "sidebar-search" { c.rootView.sidebar.devPressSearch() }
                    if action.hasPrefix("find-in-folder:") { c.findInFolder(query: String(action.dropFirst(15))) }
                    if action == "print-editor-place", let ed = c.activeTab?.editor {
                        FileHandle.standardError.write("place: \(ed.displayName) line \(ed.devCaretLine) selected '\(ed.devSelection)' focus \(c.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "-")\n".data(using: .utf8)!)
                    }
                    if action.hasPrefix("find-bar:"), let ed = c.activeTab?.editor {
                        ed.showFind(nil)
                        ed.devFindBar?.field.stringValue = String(action.dropFirst(9))
                        ed.devFindBar?.onQueryChange?()
                    }
                    if action == "find-close" { c.activeTab?.editor?.devCloseFind() }
                    if action == "find-case" { c.activeTab?.editor?.devFindBar?.flip(\.matchCase) }
                    if action == "find-word" { c.activeTab?.editor?.devFindBar?.flip(\.wholeWord) }
                    if action == "find-regex" { c.activeTab?.editor?.devFindBar?.flip(\.regex) }
                    if action == "find-step" { c.activeTab?.editor?.devStepFind(1) }
                    if action.hasPrefix("find-replace:"), let ed = c.activeTab?.editor {
                        ed.devFindBar?.devShowReplace()
                        ed.devFindBar?.replaceField.stringValue = String(action.dropFirst(13))
                    }
                    if action == "find-replace-one" { c.activeTab?.editor?.devReplace(all: false) }
                    if action == "find-replace-all" { c.activeTab?.editor?.devReplace(all: true) }
                    if action.hasPrefix("tab-arrow:"), let d = Int(action.dropFirst(10)) { c.tabBar.devPressArrow(d) }
                    if action == "print-tab-scroll" { FileHandle.standardError.write("tabs: \(c.tabBar.devScrollState)\n".data(using: .utf8)!) }
                    if action.hasPrefix("press-key:"), let w = c.window {
                        // A real key event for each character, sent to the focused pane.
                        for ch in action.dropFirst(10) {
                            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                                        context: nil, characters: String(ch), charactersIgnoringModifiers: String(ch), isARepeat: false, keyCode: 0) { w.sendEvent(e) }
                        }
                    }
                    if action == "editor-wrap" { c.activeTab?.editor?.toggleWrap(nil) }
                    if action.hasPrefix("find-type:"), let w = c.window, let ed = c.activeTab?.editor {
                        // Real key events, one at a time: how long each holds up the main thread, drawing included.
                        ed.showFind(nil)
                        for (i, ch) in String(action.dropFirst(10)).enumerated() {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 * Double(i + 1)) {
                                let t0 = CACurrentMediaTime()
                                if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                                            context: nil, characters: String(ch), charactersIgnoringModifiers: String(ch), isARepeat: false, keyCode: 0) { w.sendEvent(e) }
                                let t1 = CACurrentMediaTime()
                                w.layoutIfNeeded()
                                let t2 = CACurrentMediaTime()
                                w.displayIfNeeded()
                                let t3 = CACurrentMediaTime()
                                FileHandle.standardError.write(String(format: "key '%@': event=%.1fms layout=%.1fms draw=%.1fms total=%.1fms state: %@\n", String(ch), (t1 - t0) * 1000, (t2 - t1) * 1000, (t3 - t2) * 1000, (t3 - t0) * 1000, ed.devFindState).data(using: .utf8)!)
                            }
                        }
                    }
                    if action.hasPrefix("find-latency:"), let ed = c.activeTab?.editor {
                        FileHandle.standardError.write("latency: \(ed.devFindLatency(String(action.dropFirst(13))))\n".data(using: .utf8)!)
                    }
                    if action.hasPrefix("find-speed:"), let ed = c.activeTab?.editor {
                        FileHandle.standardError.write("speed: \(ed.devFindMillis(String(action.dropFirst(11)), EditorFindOptions()))\n".data(using: .utf8)!)
                    }
                    if action == "print-find", let ed = c.activeTab?.editor {
                        FileHandle.standardError.write("find: \(ed.devFindBar?.field.stringValue ?? "-") \(ed.devFindState)\n".data(using: .utf8)!)
                    }
                    if action == "print-focus" {
                        let sheet = c.window?.attachedSheet.map { String(describing: type(of: $0)) } ?? "none"
                        FileHandle.standardError.write("focus: \(c.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "none") sheet: \(sheet)\n".data(using: .utf8)!)
                    }
                    if action.hasPrefix("crumb-menu") { c.rootView.statusBar.devFolderMenu(run: action.hasPrefix("crumb-menu:") ? String(action.dropFirst(11)) : nil) }
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
                    if action.hasPrefix("pane-send:") { pane.send(action.dropFirst(10).replacingOccurrences(of: "\\r", with: "\r")) }
                    if action.hasPrefix("lost-bar:") { c.activeTab?.panes.compactMap(\.devLostBar).first?.devPress(String(action.dropFirst(9))) }
                    if action == "print-lost-bar" {
                        let frames = c.activeTab?.panes.map { p in p.devLostBar.map { "\(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))x\(Int($0.frame.height)) of \(Int(p.bounds.width))x\(Int(p.bounds.height))" } ?? "none" } ?? []
                        FileHandle.standardError.write("lost-bar panes=\(frames)\n".data(using: .utf8)!)
                    }
                    if action == "refresh-sidebar" { c.rootView.sidebar.refresh(nil) }
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
                    if action.hasPrefix("palette-query:"), let w = c.window {
                        CommandPalette.show(in: w, items: CommandPalette.collectItems(), tracksRecents: true, query: String(action.dropFirst(14)))
                    }
                    if action.hasPrefix("goto-folder") { c.goToFolder(nil) }
                    if action == "palette-run" { CommandPalette.devRunSelected() }
                    if action == "print-cwds" {
                        let cwds = c.allTabs.map { $0.focusedPane.currentDirectory ?? "-" }
                        FileHandle.standardError.write("cwds: \(cwds) active=\(c.activeIndex)\n".data(using: .utf8)!)
                    }
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
                    if action == "nomai-read" {
                        func bars(_ v: NSView) -> [StatusBarView] { (v as? StatusBarView).map { [$0] } ?? v.subviews.flatMap(bars) }
                        c.window?.contentView.map(bars)?.first?.devClickMoon()
                    }
                    if action.hasPrefix("quantum:"), let spot = QuantumMoon.Spot.allCases.first(where: { "\($0)" == action.dropFirst(8) }) {
                        QuantumMoon.move(to: spot)
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
