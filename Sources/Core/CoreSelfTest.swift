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
            if cond { print("  ✓ \(name)") } else {
                failures += 1
                let d = detail()
                print("  ✗ \(name) \(d)")
                Self.annotate("error", name + (d.isEmpty ? "" : ": " + d))
            }
        }

        /// On GitHub's machines, a line its log turns into an annotation: those can be read without signing in, where the
        /// log itself can't. Nothing elsewhere.
        static func annotate(_ level: String, _ text: String) {
            guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else { return }
            let clipped = String(text.suffix(900))
            let escaped = clipped.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: "\r", with: "%0D").replacingOccurrences(of: "\n", with: "%0A")
            print("::\(level)::\(escaped)")
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
            // A prompt sent to Claude Code, painted grey across the width: found, so it can be drawn in the theme's colors.
            let (t, _) = make(30, 8)
            feed(t, "recap\r\n\u{1b}[48;2;55;55;55m\u{276F} explain Ax = B\u{1b}[K\r\n  and update it\u{1b}[K\u{1b}[0m\r\n  1 skill\r\n")
            feed(t, "\u{1b}[48;2;55;55;55m> next\u{1b}[K\u{1b}[0m\r\n")
            let bands = PromptBands.find({ t.line(abs: $0) }, from: 0, through: 7)
            check("prompt bands: a prompt's rows, and one after it on its own", bands.count == 2 && bands[0].first == 1 && bands[0].last == 2
                  && bands[1].first == 4 && bands[1].last == 4, "\(bands)")
        }
        do {
            // A pasted line starting ">" inside a prompt (npm's "> client@0.1.0 dev") is part of it, not a prompt of its own.
            let (t, _) = make(30, 8)
            feed(t, "\u{1b}[48;2;55;55;55m\u{276F} this seems off:\u{1b}[K\r\n  npm run dev\u{1b}[K\r\n  > client@0.1.0 dev\u{1b}[K\r\n  > vite\u{1b}[K\r\n  done\u{1b}[K\u{1b}[0m\r\n")
            let bands = PromptBands.find({ t.line(abs: $0) }, from: 0, through: 7)
            check("prompt bands: an indented \">\" line stays in its prompt", bands == [PromptBands.Band(first: 0, last: 4, bg: bands.first?.bg ?? 0)],
                  "\(bands)")
        }
        do {
            // Dropdowns, on both platforms: what typing leaves, where the highlight starts, and the arrows.
            struct Row: DropdownRow {
                var dropdownKind = DropdownRowKind.item
                var title = ""
                var detail: String?
                var isChecked = false
                var isEnabled = true
            }
            let rows = [Row(title: "All Branches"), Row(dropdownKind: .separator), Row(dropdownKind: .header, title: "Local"),
                        Row(title: "main", isChecked: true), Row(title: "feature/login", detail: "origin"), Row(title: "old", isEnabled: false)]
            check("dropdown: typing keeps matching items only, by title or detail, ignoring case",
                  Dropdown.filter(rows, query: "LOG").map(\.title) == ["feature/login"] && Dropdown.filter(rows, query: "orig").count == 1
                  && Dropdown.filter(rows, query: " ").count == rows.count)
            check("dropdown: opens on what's checked, else the first item",
                  Dropdown.initialHighlight(rows) == 3 && Dropdown.initialHighlight(Array(rows.prefix(3))) == 0)
            struct Host: DropdownRow {
                var dropdownKind = DropdownRowKind.item
                var title = ""
                var detail: String?
                var isChecked = false
                var isEnabled = true
                var fillsSearch = false
            }
            let hosts = [Host(title: "New Connection…", fillsSearch: true), Host(dropdownKind: .separator), Host(title: "pi"), Host(title: "build")]
            let made = [Host(title: "ssh me@box")]
            let onlySSH = Dropdown.shown(hosts, typed: "ssh ", prefix: "ssh ", separator: Host(dropdownKind: .separator))
            let typedHost = Dropdown.shown(hosts, typed: "ssh bu", prefix: "ssh ", made: made, separator: Host(dropdownKind: .separator))
            check("dropdown: the prefix alone shows every host, without New Connection, nothing highlighted",
                  onlySSH.rows.map(\.title) == ["pi", "build"] && onlySSH.highlight == nil)
            check("dropdown: past the prefix it searches, then what's typed as a row", typedHost.rows.map(\.title) == ["build", "ssh me@box"] && typedHost.highlight == 0)
            check("ssh: a typed target", SSHTarget.newTarget("ssh -p 2222 me@box") == "-p 2222 me@box" && SSHTarget.newTarget("me@box") == "me@box"
                  && SSHTarget.newTarget("box") == nil && SSHTarget.newTarget("ssh box; rm x") == nil)
            check("dropdown: arrows skip headers, lines and what's off, and stop at the ends",
                  Dropdown.step(rows, from: 0, by: 1) == 3 && Dropdown.step(rows, from: 4, by: 1) == 4 && Dropdown.step(rows, from: 3, by: -1) == 0
                  && Dropdown.step(rows, from: nil, by: -1) == 4)
        }
        do {
            // A finished command's buttons and badge, and what several picked ones copy or send.
            let (t, _) = make(40, 8)
            feed(t, "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}ls\r\n\u{1b}]133;C\u{07}a.txt\r\n\u{1b}]133;D;0\u{07}")
            feed(t, "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}false\r\n\u{1b}]133;C\u{07}\u{1b}]133;D;1\u{07}")
            let done = t.blocks.filter { $0.state == .finished }
            check("blocks: a command that printed something gets the buttons; one that printed nothing doesn't",
                  done.count == 2 && BlockActions.offersButtons(done[0]) && !BlockActions.offersButtons(done[1]))
            check("blocks: a failed one always shows its badge, the rest when picked or pointed at",
                  BlockActions.badge(done[1], shown: false)?.kind == .failed && BlockActions.badge(done[0], shown: false) == nil
                  && BlockActions.badge(done[0], shown: true)?.kind == .succeeded)
            check("blocks: picked in and out, in the order picked", BlockActions.toggle(3, in: BlockActions.toggle(5, in: [])) == [5, 3]
                  && BlockActions.toggle(5, in: [5, 3]) == [3])
            check("blocks: several, oldest first, as they're copied", BlockActions.transcript(BlockActions.chronological([done[1], done[0]]).map {
                BlockActions.entry(command: $0.command, output: $0.command == "ls" ? "a.txt" : "")
            }) == "$ ls\na.txt\n\n$ false" && BlockActions.selectionLabel(2) == "2 commands selected")
        }
        do {
            // Git Graph's filters: git does the filtering, from the whole history.
            var f = GraphFilter()
            check("graph filter: none is every branch", f.isEmpty && f.script().contains("--all") && !f.script().contains("--author"))
            f.user = "Jo O'Neil"; f.days = 7; f.path = "src/a b"; f.branch = "main"
            let s = f.script()
            check("graph filter: user, date, path and branch go to git log", s.contains("git log 'main'") && s.contains("--author='^Jo O'\\''Neil <'")
                  && s.contains("--since='7 days ago'") && s.contains("-- 'src/a b'\n") && f.keepsAncestry == false)
            f = GraphFilter(); f.text = "fix"
            check("graph filter: text searches messages, ignoring case", f.script().contains("--grep='fix' -F -i") && f.script().contains("--topo-order"))
        }
        do {
            // Which agent a command started, for continuing it with the command Settings has for it.
            check("agents: a command's agent, through npx or a full path", AgentResume.agent(typed: "claude --model x") == "claude"
                  && AgentResume.agent(typed: "npx codex") == "codex" && AgentResume.agent(typed: #"& 'C:\tools\agy.exe' -c"#) == "agy"
                  && AgentResume.agent(typed: "git status") == nil && AgentResume.command(continuing: "npx codex") == "codex resume --last")
        }
        do {
            // Command History: PowerShell's file (a backtick ends each line of a command but its last), bash's, newest first.
            let ps = HistoryFile.parsePowerShell("cd C:\\x\r\nGet-ChildItem |`\r\n  Select Name\r\ngit status\r\ncd C:\\x\r\n")
            check("history: PowerShell's file, a command over two lines kept whole", ps == ["cd C:\\x", "Get-ChildItem |\n  Select Name", "git status", "cd C:\\x"], "\(ps)")
            check("history: newest first, each once", HistoryFile.newestFirst(ps) == ["cd C:\\x", "git status", "Get-ChildItem |\n  Select Name"])
            check("history: bash's, its times left out", HistoryFile.parse("#1700000000\nls -la\n: 1700000001:0;make\n") == ["ls -la", "make"])
            // Clearing only the scrollback leaves the screen as it is.
            let (t, _) = make(10, 3)
            feed(t, "1\r\n2\r\n3\r\n4\r\n5")
            t.clearScrollback()
            check("clear: the scrollback alone goes, the screen stays", t.scrollback.count == 0 && row(t, 0) == "3" && row(t, 2) == "5" && t.cursorY == 2)
        }
        do {
            // A line that runs off the end of a row goes on onto the next; a row cleared and printed over isn't its rest.
            let (t, _) = make(10, 5)
            feed(t, "0123456789abcde")
            check("wrapping: a long line runs on onto the next row", t.screen[0].wrapped)
            feed(t, "\u{1b}[2;1H\u{1b}[Kfinal")
            check("wrapping: a row cleared from its start and printed over isn't the line above's rest",
                  !t.screen[0].wrapped && row(t, 1) == "final")
            feed(t, "\u{1b}[1;1H0123456789xyz")
            check("wrapping: running off the end again joins them again", t.screen[0].wrapped)
            // A shell redrawing a long command: back to where it starts, cleared from there, printed again.
            feed(t, "\u{1b}[1;4H\u{1b}[J3456789ABC")
            check("wrapping: a redraw from the middle of a row keeps the line whole", t.screen[0].wrapped && row(t, 1) == "ABC")
            feed(t, "\u{1b}[2;1H\u{1b}[L")
            check("wrapping: a line put in under a row ends its run", !t.screen[0].wrapped && row(t, 1) == "")
            feed(t, "\u{1b}[1;1H0123456789xyz\u{1b}[2;1H\u{1b}[2K")
            check("wrapping: clearing the whole next row ends it too", !t.screen[0].wrapped)
        }
        do {
            // Find in a file: the three toggles, separately and together.
            let text = "Cat cat concat\ncat.dog (cat)\nline three\n"
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
                return FindBuffer(t).matches(of: q, o).ranges == EditorFind.matches(of: e, in: t).ranges
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
            check("find in file: a plain search from lines as UTF-16", FindBuffer(units: Array("ab\nAB".utf16)).matches(of: "ab", EditorFindOptions()).ranges
                  == [NSRange(location: 0, length: 2), NSRange(location: 3, length: 2)])
            let e = try? EditorFind.expression("(\\w+)@(\\w+)", EditorFindOptions(regex: true))
            let mail = "me@host"
            let m = e.flatMap { $0.firstMatch(in: mail, range: NSRange(location: 0, length: mail.utf16.count)) }
            check("find in file: a regex's replacement fills in its groups", m.map { EditorFind.replacement("$2/$1", for: $0, in: mail, e!, regex: true) } == "host/me"
                  && m.map { EditorFind.replacement("$2", for: $0, in: mail, e!, regex: false) } == "$2")
        }
        do {
            // Find in the terminal with VS Code's toggles (Windows' bar), through the file editor's matching.
            let (t, _) = make(40, 5)
            feed(t, "Cat cat concat\r\ncat.dog (cat)\r\n")
            func count(_ q: String, _ o: EditorFindOptions) -> Int? { (try? TerminalSearch.matches(q, in: t, scope: .all, options: o))?.count }
            check("terminal find: ignores case, as the toggle's off", count("cat", EditorFindOptions()) == 5)
            check("terminal find: match case", count("Cat", EditorFindOptions(matchCase: true)) == 1)
            check("terminal find: whole word", count("cat", EditorFindOptions(wholeWord: true)) == 4)
            check("terminal find: a regular expression, and its columns", count("c.t$", EditorFindOptions(regex: true)) == 1
                  && (try? TerminalSearch.matches("^cat", in: t, scope: .all, options: EditorFindOptions(regex: true)))?.contains(SearchMatch(line: t.firstAbs + 1, start: 0, end: 2)) == true)
            check("terminal find: a regular expression that doesn't parse throws", count("(", EditorFindOptions(regex: true)) == nil)
            check("terminal find: the Mac's way, case only with a capital", TerminalSearch.matches("cat", in: t, scope: .all).count == 5
                  && TerminalSearch.matches("Cat", in: t, scope: .all).count == 1)
        }
        do {
            // Logs, line by line as an editor draws them (Windows): a stack trace takes its exception's level, from wherever
            // the drawing starts.
            let log = ["2026-11-08 10:00:00 INFO  app.Main - started",
                       "2026-11-08 10:00:01 ERROR app.Db - query failed",
                       "java.lang.IllegalStateException: closed",
                       "    at app.Db.run(Db.java:42)",
                       "    at app.Main.main(Main.java:7)",
                       "2026-11-08 10:00:02 INFO  app.Main - [OK] retried"]
            let cache = LogPaintCache(format: .builtIn)
            let fromBelow = cache.paint(4, in: log)
            check("logs: a stack trace's line takes its entry's level, drawn first", fromBelow.continues && fromBelow.level == .error && fromBelow.wash == .palette(1))
            check("logs: lines after it don't", cache.paint(5, in: log).level == .info && cache.paint(5, in: log).wash == nil, "\(cache.paint(5, in: log))")
            check("logs: the error line tints", cache.paint(1, in: log).wash == .palette(1) && cache.paint(0, in: log).wash == nil)
            // Markers chosen in one app are a rules file both read: kept in the folder for log formats.
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("solanum-logformats-\(ProcessInfo.processInfo.processIdentifier)")
            let was = LogFormatStore.configFolder
            LogFormatStore.configFolder = dir
            defer {
                LogFormatStore.configFolder = was
                try? FileManager.default.removeItem(at: dir)
            }
            if ProcessInfo.processInfo.environment["SOLANUM_LOG_FORMATS_DIR"] == nil {
                LogFormatStore.setMarker("[OK]", LogStyle(color: .palette(2), bold: true), in: LogFormatStore.allLogsFile)
                let format = LogFormatStore.builtIn
                check("logs: a marker is saved and read back", format.markerStyle("[OK]") == LogStyle(color: .palette(2), bold: true))
                cache.reset(format: format)
                let ok = cache.paint(5, in: log)
                let at = NSString(string: log[5]).range(of: "[OK]")
                check("logs: a marker colors its text", ok.paints.last == LogPaint(range: at, color: .palette(2), bold: true), "\(ok.paints.last.map { "\($0)" } ?? "none")")
                LogFormatStore.setMarker("[OK]", nil, in: LogFormatStore.allLogsFile)
                check("logs: and taken out again", LogFormatStore.builtIn.markerStyle("[OK]") == nil)
            }
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
            // Claude Code's finished edits: the diff under "⎿ Added …" is what's hidden; the header and summary stay, and
            // an edit still asking for approval (no "⎿") keeps its diff.
            let (t, _) = make(60, 40)
            let rule = String(repeating: "─", count: 60)
            feed(t, "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}claude\r\n\u{1b}]133;C\u{07}")
            feed(t, "⏺ Update(README.md)\r\n  ⎿  Added 2 lines\r\n       7\r\n       8 +(Demo line)\r\n       9 +\r\n      10  ## Features\r\n\r\n")
            feed(t, "⏺ Write(a/Example.swift)\r\n  ⎿  Wrote 3 lines to a/Example.swift\r\n       1 struct A {}\r\n       2 \r\n       … +1 line (ctrl+o to expand)\r\n\r\n")
            feed(t, "⏺ Done, both edited.\r\n\r\n⏺ Update(b.swift)\r\n\r\n Do you want to make this edit to b.swift?\r\n       1 -x\r\n       1 +y\r\n\r\n")
            // A shell command's output, then what it changed (the diff folds), then one whose output says "Added" (it stays).
            feed(t, "⏺ Bash(python3 edit.py)\r\n  ⎿  ✓ Built\r\n     ✓ tests\r\n  ⎿  Updated a.swift +1 -1\r\n      141 let a = 1\r\n      142 -old\r\n      142 +new\r\n\r\n")
            feed(t, "⏺ Bash(git add .)\r\n  ⎿  Added 3 files\r\n     done\r\n\r\n")
            feed(t, "⏺ Bash(rm one.swift)\r\n  ⎿  Deleted one.swift -2\r\n       1 -struct One {\r\n       2 -}\r\n  ⎿  Allowed by auto mode\r\n\r\n")
            feed(t, "\(rule)\r\n❯ \r\n\(rule)")
            let hidden = t.blocks.last.map { t.agentEditDiffRanges(in: $0) } ?? []
            check("agent edits: the diffs under finished edits and under a command's changes", hidden == [3...6, 10...12, 26...28, 36...37],
                  hidden.map { "\($0)" }.joined(separator: " "))
        }
        do {
            // The text being typed, a stop at a time from the keyboard (⇧ and the arrows).
            let (t, _) = make(20, 6)
            feed(t, "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}echo hello world and")
            let b = t.currentBlock!
            let run = t.commandRun(line: b.commandLine!, col: b.commandCol)
            let text = t.commandText(start: run.start, col: run.col, last: run.last)
            let end = text.stops.count - 1
            check("keys: a stop between every character of a wrapped command", end == 20 && text.index(of: GridPos(line: t.cursorAbs, col: t.cursorX)) == end,
                  "\(end) \(text.stops)")
            check("keys: ⌥← to the word before, ⌥→ to the word's end", text.wordLeft(end) == 17 && text.wordLeft(17) == 11 && text.wordRight(5) == 10)
            check("keys: ⌘ goes to the ends of the whole command", text.lineStart(15) == 0 && text.lineEnd(3) == end)
            if let (lo, hi) = text.cells(5, 10) {
                check("keys: a selection's cells", lo.line == hi.line && t.line(abs: lo.line)?.text(from: lo.col, to: hi.col, trim: false) == "hello")
            } else { check("keys: a selection's cells", false) }
            check("keys: nothing selected between a stop and itself", text.cells(4, 4) == nil)
            // Claude Code's box: ⌘ goes to its row's ends; a row break is a stop of its own.
            let (a, _) = make(30, 8)
            feed(a, "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}claude\r\n\u{1b}]133;C\u{07}")
            let rule = String(repeating: "─", count: 30)
            feed(a, "\(rule)❯ one two\r\n  three\r\n\(rule)\u{1b}[3;6H")
            if let rows = a.agentInputRows(a.currentBlock!) {
                let box = a.agentInputText(rows)
                let row2 = box.index(of: GridPos(line: rows.lowerBound + 1, col: 2))
                check("keys: Claude Code's rows", box.stops.count == 14 && row2 == 8 && box.lineEnd(2) == 7 && box.lineStart(10) == 8
                      && box.vertical(3, by: 1) == 11 && box.vertical(11, by: -1) == 3 && box.vertical(3, by: -1) == 0,
                      "\(box.stops)")
            } else { check("keys: Claude Code's rows", false) }
            // An ssh host's prompt has no marks: what's typed after it is found from its shape.
            let (h, _) = make(40, 6)
            feed(h, "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}ssh box\r\n\u{1b}]133;C\u{07}\u{1b}]1337;SolanumSSH=/tmp/s\u{07}Welcome!\r\n")
            feed(h, "[me@box ~]$ ")
            h.remoteKeyPressed()
            feed(h, "kubectl get pods")
            let host = h.hostCommandRun()
            check("keys: an ssh host's command starts after its prompt", host?.start == h.cursorAbs && host?.col == 12
                  && host.map { h.commandText(start: $0.start, col: $0.col, last: $0.last).stops.count } == 17, "\(String(describing: host?.col))")
            h.remoteEnterPressed()
            feed(h, "\r\nNAME READY\r\n")
            h.remoteKeyPressed()
            check("keys: nothing to edit while it runs", h.hostCommandRun() == nil)
        }
        do {
            // Clicks in the line being typed.
            let (t, _) = make(20, 6)
            feed(t, "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}hello world and more")
            let b = t.currentBlock!
            check("click: in the command", t.shellCursorArrows(b, line: t.cursorAbs - 1, col: 3) == -19,
                  "\(String(describing: t.shellCursorArrows(b, line: t.cursorAbs - 1, col: 3)))")
            check("click: past its end stays at the end", t.shellCursorArrows(b, line: t.cursorAbs, col: 15) == 0)
            check("click: above the command is no place", t.shellCursorArrows(b, line: t.cursorAbs + 3, col: 1) == nil)
            let picked = t.shellSelection(b, start: (t.cursorAbs - 1, 8), end: (t.cursorAbs - 1, 13))
            check("selection: offsets in the command", picked?.from == 6 && picked?.to == 11 && picked?.cursor == 20, "\(String(describing: picked))")
            let clipped = t.shellSelection(b, start: (t.cursorAbs - 1, 16), end: (t.cursorAbs + 2, 0))
            check("selection: clipped to the command", clipped?.from == 14 && clipped?.to == 20, "\(String(describing: clipped))")
            check("selection: outside the command", t.shellSelection(b, start: (t.cursorAbs + 1, 0), end: (t.cursorAbs + 2, 3)) == nil)
            let (a, _) = make(30, 8)
            feed(a, "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}claude\r\n\u{1b}]133;C\u{07}")
            let rule = String(repeating: "─", count: 30)
            feed(a, "\(rule)❯ typing here\r\n\(rule)\u{1b}[3;14H")
            let rows = a.agentInputRows(a.currentBlock!)
            check("click: finds Claude Code's input box", rows == (a.screenTopAbs + 2)...(a.screenTopAbs + 2), "\(String(describing: rows)) \(a.cursorAbs)")
            check("click: left in the input box", a.agentCursorArrows(toCol: 4) == -9, "\(a.agentCursorArrows(toCol: 4)) \(a.cursorX)")
            check("click: not past its text", a.agentCursorArrows(toCol: 25) == 0)
            check("click: not into the gutter", a.agentCursorArrows(toCol: 0) == -11)
            check("selection: offsets in Claude Code's input", rows.map { a.agentInputOffset($0, line: $0.lowerBound, col: 8) } == 6)

            // Corner cards: when they're due and what they say.
            check("notices: durations as the Mac writes them", NoticeRules.formatDuration(0.85) == "850ms" && NoticeRules.formatDuration(12.44) == "12.4s"
                  && NoticeRules.formatDuration(185) == "3m 5s" && NoticeRules.formatDuration(4320) == "1h 12m")
            check("notices: a quick command gets none", NoticeRules.commandFinished(command: "ls", duration: 2, exitCode: 0, threshold: 10, place: "t") == nil
                  && NoticeRules.commandFinished(command: "make", duration: 60, exitCode: 0, threshold: 0, place: "t") == nil)
            let failed = NoticeRules.commandFinished(command: "make", duration: 75, exitCode: 2, threshold: 10, place: "Build \u{203A} api")
            check("notices: a long failed command", failed == NoticeRules.Card(title: "Command failed", mark: .failed,
                                                                               lines: ["Build \u{203A} api", "make", "Took 1m 15s \u{00B7} exit 2"]), "\(String(describing: failed))")
            let waiting = NoticeRules.agentStopped(agent: "Claude", waiting: true, worked: 42, prompt: "fix the\ntests", place: "api")
            check("notices: an agent waiting", waiting.title == "Claude needs your input" && waiting.lines == ["api", "\u{276F} fix the tests", "Worked 42.0s"])
            var watch = AgentStopWatch()
            let t0 = Date()
            watch.update(working: true, now: t0)
            watch.update(working: false, now: t0.addingTimeInterval(30))
            let early = watch.settled(now: t0.addingTimeInterval(31), stillStopped: true)
            watch.update(working: true, now: t0.addingTimeInterval(31.5))
            watch.update(working: false, now: t0.addingTimeInterval(50))
            let worked = watch.settled(now: t0.addingTimeInterval(53), stillStopped: true)
            check("notices: an agent's pause isn't a stop; a stop counts from when it began working", early == nil && worked == 50, "\(String(describing: worked))")

            // Open files keeping up with the disk.
            check("file sync: what a signature on disk means", FileSync.action(known: "1 5", now: "1 5", hasUnsavedEdits: false) == .nothing
                  && FileSync.action(known: "1 5", now: "2 9", hasUnsavedEdits: false) == .reload
                  && FileSync.action(known: "1 5", now: "2 9", hasUnsavedEdits: true) == .changedUnderEdits
                  && FileSync.action(known: "1 5", now: nil, hasUnsavedEdits: true) == .deleted)
            let stats = FileSync.parseStats("1\t2026-11-07 10:00:00.1 120 77\n2\t-\nnoise\n", paths: ["/a b", "/c"])
            check("file sync: a host's stats, gone files included", stats["/a b"] == .some("2026-11-07 10:00:00.1 120 77") && stats["/c"] == .some(nil) && stats.count == 2)
            check("file sync: the stat script quotes paths", FileSync.statScript(["/it's"]).contains(#"'/it'\''s'"#))
            let diff = TextDiff.rows(old: ["a", "b", "c", "d"], new: ["a", "B", "c", "d", "e"])
            check("compare: the same lines line up, a change pairs off, an addition stands alone",
                  diff.map(\.kind) == [.same, .changed, .same, .same, .added] && diff[1].left?.text == "b" && diff[1].right?.text == "B"
                  && diff[4].left == nil && diff[4].right?.number == 5, "\(diff.map(\.kind))")

            // Claude's code boxes: code matched from its transcript, tables and quotes from the screen.
            let (cb, _) = make(48, 20)
            feed(cb, "\u{23FA} Run this:\r\n\r\n  git log --oneline --graph --decorate\r\n    --all\r\n\r\n"
                 + "  \u{250C}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{252C}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2510}\r\n"
                 + "  \u{2502} Key \u{2502} Use \u{2502}\r\n"
                 + "  \u{251C}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{253C}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2524}\r\n"
                 + "  \u{2502} J   \u{2502} jump\u{2502}\r\n"
                 + "  \u{2514}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2534}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2518}\r\n\r\n"
                 + "  \u{258E} One more from the same\r\n  \u{258E} incident.\r\n\r\nDone.\r\n")
            let found = cb.snapshot().findBoxes(code: ["git log --oneline --graph --decorate --all"])
            let code = found.first { $0.kind == .code }, table = found.first { $0.kind == .table }, quote = found.first { $0.kind == .quote }
            check("code boxes: a code block, a table and a quote", found.count == 3, found.map { "\($0.kind) \($0.first)-\($0.last)" }.description)
            check("code boxes: code copies as the original, unwrapped", code?.copyText == "git log --oneline --graph --decorate --all" && code?.first == 2 && code?.last == 3)
            check("code boxes: part of the code selected copies as the original",
                  code?.sourceText(from: GridPos(line: 2, col: 10), to: GridPos(line: 3, col: 8), columns: 48) == "--oneline --graph --decorate --all",
                  code?.sourceText(from: GridPos(line: 2, col: 10), to: GridPos(line: 3, col: 8), columns: 48) ?? "-")
            check("code boxes: a table copies as markdown, and HTML", table?.copyText == "| Key | Use |\n|---|---|\n| J | jump |"
                  && table?.html?.contains("<th style") == true, table?.copyText ?? "-")
            check("code boxes: a quote copies without its bar", quote?.copyText == "One more from the same incident.")
            check("code boxes: Claude's folder for a Windows path", ClaudeTranscript.projectFolder(cwd: "C:\\nowhere at all", home: "C:\\nope") == nil)

            // Big pastes in pieces, none cutting a character or a sequence.
            var pasteBytes: [UInt8] = []
            for i in 0..<300 { pasteBytes += Array("\u{1b}[0;0;233;1;0;1_\u{1b}[0;0;233;0;0;1_ line \(i) é ✦ 🌱 \u{1b}[200~x\u{1b}[201~\r".utf8) }
            let pieces = PasteChunks.split(pasteBytes, size: 512)
            let rejoined = pieces.flatMap { $0 }
            let cleanCuts = pieces.dropFirst().allSatisfy { p in
                guard let first = p.first else { return false }
                return first & 0xC0 != 0x80
            } && pieces.allSatisfy { p in
                // Every escape sequence a piece starts, it finishes.
                var esc = false, body = false
                for b in p {
                    if esc { if body { if b >= 0x40 && b <= 0x7E { esc = false; body = false } } else if b == 0x5B { body = true } else { esc = false } }
                    else if b == 0x1B { esc = true }
                }
                return !esc
            }
            check("paste: pieces join up to the paste", rejoined == pasteBytes && pieces.count > 10)
            check("paste: no piece cuts a character or an escape sequence", cleanCuts)
            check("paste: pieces stay near the size", pieces.allSatisfy { $0.count <= 512 + 40 })
            check("paste: small ones go as they are", PasteChunks.split(Array("hi".utf8)) == [Array("hi".utf8)])

            // Icon packs.
            check("icon packs: icons one folder up from the manifest, never outside the extension",
                  IconThemeManifest.inside("C:/p/ext/dist", "./../icons/git.svg", within: "C:/p/ext") == "C:/p/ext/icons/git.svg"
                  && IconThemeManifest.inside("C:/p/ext/dist", "../../evil.svg", within: "C:/p/ext") == nil
                  && IconThemeManifest.inside("C:/p/ext", "icons/a.svg") == "C:/p/ext/icons/a.svg")
            check("icon packs: Catppuccin follows light and dark", IconPackCatalog.shownID(setting: "catppuccin-frappe", isDark: false) == "catppuccin-latte"
                  && IconPackCatalog.shownID(setting: "catppuccin-latte", isDark: true) == "catppuccin-mocha"
                  && IconPackCatalog.shownID(setting: "catppuccin-frappe", isDark: true) == "catppuccin-frappe"
                  && IconPackCatalog.shownID(setting: "material-icon-theme", isDark: false) == "material-icon-theme")
            check("icon packs: font icons' glyphs and colors", IconThemeManifest.glyph("\\E001") == "\u{E001}"
                  && IconThemeManifest.color("#519aba")?.rgb == 0x519ABA && IconThemeManifest.color("#fff8")?.alpha == Float(0x88) / 255)
            check("icon packs: a pack's folder name stays in the packs folder",
                  IconPackCatalog.folderName(packageJSON: Data(#"{"publisher":"pub","name":"a/../b"}"#.utf8)) == "pub.a-..-b"
                  && IconPackCatalog.folderName(packageJSON: Data(#"{"publisher":"../x","name":"b"}"#.utf8)) == nil
                  && IconPackCatalog.folderName(packageJSON: nil) == nil)

            // Pasted images, as Claude Code shows them.
            let (im, _) = make(40, 6)
            feed(im, "\u{276F} look at [Image #3] please\r\n  \u{23BF}  [Image #3] [Image #12]\r\n  \u{23BF}  see [Image #4]\r\n")
            let first = im.line(abs: im.screenTopAbs).map(ImageTokens.tokens) ?? []
            check("images: \"[Image #N]\" in a prompt", first == [ImageTokens.Token(start: 10, length: 10, number: 3)], "\(first)")
            let listed = im.line(abs: im.screenTopAbs + 1).flatMap(ImageTokens.attachments)
            check("images: a sent prompt's attachments", listed?.map(\.number) == [3, 12], "\(String(describing: listed))")
            check("images: an image mentioned in a line isn't an attachment", im.line(abs: im.screenTopAbs).flatMap(ImageTokens.attachments) == nil
                  && im.line(abs: im.screenTopAbs + 2).flatMap(ImageTokens.attachments) == nil)
            // A resumed session numbers from 1 again in the same folder: its new "1.jpg" beside the old "1.png" wins.
            let imageDir = NSTemporaryDirectory() + "solanum-images-\(UUID().uuidString)/"
            try? FileManager.default.createDirectory(atPath: imageDir, withIntermediateDirectories: true)
            _ = FileManager.default.createFile(atPath: imageDir + "1.png", contents: Data([1]),
                                               attributes: [.modificationDate: Date(timeIntervalSinceNow: -3600)])
            _ = FileManager.default.createFile(atPath: imageDir + "1.jpg", contents: Data([2]))
            let newest = ImageTokens.newestFile(1, in: imageDir)?.path
            check("images: a resumed session's new image beats the old one with its number", newest?.hasSuffix("1.jpg") == true
                  && ImageTokens.newestFile(2, in: imageDir) == nil, "\(String(describing: newest))")
            try? FileManager.default.removeItem(atPath: imageDir)

            // NumPy files: a .npy's header and values, Fortran order, a .npz (zip64, as np.savez writes it), deflate.
            func npy(_ descr: String, _ shape: String, fortran: Bool = false, _ values: [UInt8]) -> [UInt8] {
                var h = "{'descr': '\(descr)', 'fortran_order': \(fortran ? "True" : "False"), 'shape': \(shape), }"
                h += String(repeating: " ", count: (64 - (11 + h.utf8.count) % 64) % 64) + "\n"
                return [0x93] + Array("NUMPY".utf8) + [1, 0, UInt8(h.utf8.count & 0xFF), UInt8(h.utf8.count >> 8)] + Array(h.utf8) + values
            }
            func le32(_ v: Int32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> ($0 * 8)) } }
            // 2 × 3 int32, stored column by column: [[0, 1, 2], [10, 11, 12]].
            let fortranBytes = npy("<i4", "(2, 3)", fortran: true, [0, 10, 1, 11, 2, 12].flatMap { le32($0) })
            let fortranFile = NumpyFile(fortranBytes, name: "f.npy")
            check("numpy: a Fortran-order array's rows as NumPy shows them",
                  fortranFile.lines == ["int32  \u{00B7}  shape (2, 3)  \u{00B7}  6 values  \u{00B7}  Fortran order", "",
                                        "     0    1    2", "0    0    1    2", "1   10   11   12"], "\(fortranFile.lines)")
            check("numpy: a 2-D array makes a heatmap", fortranFile.picture?.caption == "2 × 3  \u{00B7}  0 (dark) to 12 (light)"
                  && fortranFile.picture?.bitmap.prefix(2) == [0x42, 0x4D], "\(String(describing: fortranFile.picture?.caption))")
            check("numpy: pickled objects are never read",
                  NumpyFile(npy("|O", "(2,)", [0x80, 4, 0x4E, 0x2E]), name: "o.npy").lines.first?.hasPrefix("Holds Python objects") == true)
            // A stored zip entry with its sizes in a zip64 field.
            let inner = npy("<f8", "(2,)", [0.5, -2].flatMap { d -> [UInt8] in (0..<8).map { UInt8(truncatingIfNeeded: d.bitPattern >> ($0 * 8)) } })
            func le(_ v: Int, _ n: Int) -> [UInt8] { (0..<n).map { UInt8(truncatingIfNeeded: v >> ($0 * 8)) } }
            let zip64 = le(1, 2) + le(16, 2) + le(inner.count, 8) + le(inner.count, 8)
            let entry = le(0x04034B50, 4) + le(45, 2) + le(0, 2) + le(0, 2) + le(0, 4) + le(0, 4) + le(0xFFFF_FFFF, 4) + le(0xFFFF_FFFF, 4)
                + le(5, 2) + le(zip64.count, 2) + Array("x.npy".utf8) + zip64 + inner
            let archive = NumpyFile(entry, name: "d.npz")
            check("numpy: a .npz's arrays, by name", archive.lines.prefix(2) == ["1 array", "  x   float64   (2,)"]
                  && archive.lines.suffix(2) == ["0    0.5", "1   -2.0"], "\(archive.lines)")
            // zlib's raw deflate of 'numpy numpy numpy! ' × 40 then every byte.
            let packed = "cb2bcd2da854c843908ac89c51a151a1e129c4c0c8c4ccc2cac6cec1c9c5cdc3cbc72f2028242c222a262e2129252d232b27afa0a8a4aca2aaa6aea1a9a5ada3aba76f6068646c626a666e6169656d636b67efe0e8e4ece2eae6eee1e9e5ede3ebe71f1018141c121a161e1119151d131b179f9098949c929a969e9199959d939b975f5058545c525a565e5159555d535b57dfd0d8d4dcd2dad6ded1d9d5ddd3dbd73f61e2a4c953a64e9b3e63e6acd973e6ce9bbf60e1a2c54b962e5bbe62e5aad56bd6ae5bbf61e3a6cd5bb66edbbe63e7aedd7bf6eedb7fe0e0a1c3478e1e3b7ee2e4a9d367ce9e3b7fe1e2a5cb57ae5ebb7ee3e6addb77eedebbffe0e1a3c74f9e3e7bfee2e5abd76fdebe7bffe1e3a7cf5fbe7efbfee3e7afdf7ffefefb0f00"
            let packedBytes = stride(from: 0, to: packed.count, by: 2).map { i -> UInt8 in
                let s = packed.index(packed.startIndex, offsetBy: i)
                return UInt8(packed[s..<packed.index(s, offsetBy: 2)], radix: 16) ?? 0
            }
            let unpacked = Inflate.inflate(packedBytes[...])
            check("numpy: deflate unpacks as zlib packed it",
                  unpacked == Array(String(repeating: "numpy numpy numpy! ", count: 40).utf8) + (0...255).map { UInt8($0) }, "\(unpacked.count) bytes")
            let laid = ImageTokens.wrap([(1600, 900), (400, 400)], in: ImageTokens.Rect(x: 10, y: 0, width: 300, height: 40), bottom: false, minHeight: 12)
            check("images: thumbnails share a row, one height, in order", laid.count == 2 && laid[0].height == laid[1].height
                  && laid[0].x == 10 && laid[1].x > laid[0].maxX && laid[1].maxX <= 310, "\(laid)")
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
            // A connection that drops under tmux (or vim, less…) leaves the screen and modes as the remote set them;
            // the session ending puts them back for the shell here, so it isn't stuck on tmux's screen.
            let (t, _) = make()
            feed(t, "main\u{1b}]1337;SolanumSSH=/tmp/sock\u{07}\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1006h\u{1b}[?1h\u{1b}[?25l\u{1b}[2;3rtmux"
                 + "\u{1b}]1337;SolanumSSHExit=255\u{07}\u{1b}]1337;SolanumSSH=\u{07}")
            check("ssh end restores the screen and modes", !t.usingAlt && t.mouseMode == .none && !t.mouseSGR && !t.appCursorKeys
                  && t.cursorVisible && t.screen[0].text().hasPrefix("main"), "alt=\(t.usingAlt) mouse=\(t.mouseMode)")
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
        do {
            // git, read on either system.
            let status = "C:/Users/me/repo\n# branch.oid 1234567890\0# branch.head main\0# branch.upstream origin/main\0# branch.ab +2 -1\0"
                + "1 M. N... 100644 100644 100644 a b src/app.swift\0" + "1 .M N... 100644 100644 100644 a b README.md\0" + "? notes.txt\0"
            let info = GitInfo(statusOutput: Data(status.utf8))
            check("git: status from Windows' git", info?.root == "C:/Users/me/repo" && info?.branch == "main" && info?.ahead == 2 && info?.behind == 1
                  && info?.changes.count == 3)
            check("git: staged apart from not", info?.changes[0].staged == "M" && info?.changes[0].unstaged == "." && info?.changes[1].staged == "."
                  && info?.changes[1].unstaged == "M" && info?.changes[2].unstaged == "?")
            let refs = "refs/heads/main\0main\03 days ago\nrefs/heads/fix\0fix\01 hour ago\nrefs/remotes/origin/main\0origin/main\03 days ago\n"
                + "refs/remotes/origin/HEAD\0origin/HEAD\03 days ago\nrefs/remotes/origin/wip\0origin/wip\0a week ago\n"
            check("git: branches, with remote twins left out", GitBranch.parse(Data(refs.utf8)).map(\.name) == ["main", "fix", "origin/wip"])
            let log = "c3\n" + ["c3\u{1f}c2 b1\u{1f}Ann\u{1f}100\u{1f}Merge\u{1f}HEAD -> main", "b1\u{1f}c1\u{1f}Ann\u{1f}90\u{1f}Side\u{1f}fix",
                                  "c2\u{1f}c1\u{1f}Ann\u{1f}80\u{1f}Two\u{1f}", "c1\u{1f}\u{1f}Ann\u{1f}70\u{1f}One\u{1f}tag: v1"].joined(separator: "\u{1e}\n")
            let graph = GraphCommit.parse(Data(log.utf8))
            let rows = GraphLayout.rows(graph.commits)
            check("graph: commits and lanes", graph.head == "c3" && rows.count == 4 && rows[0].lane == 0 && rows[1].lane == 1 && rows[2].lane == 0 && rows[3].lane == 0
                  && rows.map(\.width).max() == 2, rows.map { "\($0.lane)/\($0.width)" }.description)
            check("graph: labels, current branch first", GraphLabel.labels(["origin/main", "HEAD -> main", "tag: v1"]).map(\.name) == ["main", "v1"])
            check("diff: kinds of line", [GitDiffKind.of("@@ -1 +1 @@"), .of("+added"), .of("-gone"), .of("--- a/x"), .of(" same")] == [.hunk, .added, .removed, .header, .context])
            let found = WorkspaceMatch.parse(Data("./src/a.swift\012:let x = 1\nREADME.md\03\0see x\n".utf8))
            check("search: matches from grep and git grep", found == [WorkspaceMatch(path: "src/a.swift", line: 12, text: "let x = 1"), WorkspaceMatch(path: "README.md", line: 3, text: "see x")])
            let urls = TextLinks.urls(in: "see https://example.com/a?b=1, or localhost:3000.")
            check("links: web addresses, punctuation left off", urls.map(\.url.absoluteString) == ["https://example.com/a?b=1", "http://localhost:3000"])
            check("agents: what continues them after a restart",
                  AgentResume.command(continuing: "claude") == "claude -c" && AgentResume.command(continuing: "npx codex --model x") == "codex resume --last"
                  && AgentResume.command(continuing: #"C:\Users\me\.local\bin\claude.exe --verbose"#) == "claude -c"
                  && AgentResume.command(continuing: "git commit -m claude") == nil && AgentResume.command(continuing: "npm test") == nil)
            check("beautify: JSON", (try? Prettifier.format(#"{"a":1,"b":[1,2],"c":{}}"#, as: .json)) == "{\n  \"a\": 1,\n  \"b\": [\n    1,\n    2\n  ],\n  \"c\": {}\n}\n")
            check("beautify: YAML", Prettifier.yaml("a:    1\nb:\n    c:  2\n\n\n\nd: 3  \n") == "a: 1\nb:\n  c: 2\n\nd: 3\n")
            let xml = try? Prettifier.indentXML("<?xml version=\"1.0\"?><root><a x=\"1\">hi</a><b><c/></b><!-- note --></root>")
            check("beautify: XML", xml == "<?xml version=\"1.0\"?>\n<root>\n  <a x=\"1\">hi</a>\n  <b>\n    <c/>\n  </b>\n  <!-- note -->\n</root>\n", xml ?? "failed")
            check("beautify: XML left open is reported", (try? Prettifier.indentXML("<a><b></a>")) == nil)
            check("beautify: which files", SyntaxLanguage(path: #"C:\x\app.config"#) == .xml && SyntaxLanguage(path: "/a/b.yml") == .yaml
                  && SyntaxLanguage(path: "notes.txt") == nil)
            let md = MarkdownDoc.parse("# Title\n\nSome **bold** and *it*, `code` and [a link](https://x.y).\n\n- one\n  more\n- [x] done\n\n```swift\nlet a = 1\n```\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n---\n> quoted\n")
            check("markdown: blocks", md.count == 8, String(describing: md))
            if md.count == 8, case .paragraph(let spans) = md[1], case .listItem(_, _, let checked, _) = md[3] {
                check("markdown: inline styles", spans.map(\.style) == [.plain, .bold, .plain, .italic, .plain, .code, .plain, .link("https://x.y"), .plain] && checked == true,
                      String(describing: spans))
            }
            let jsonTokens = SyntaxScanner.tokens(in: #"{"a": 1, "b": true} // note"#, as: .json).map(\.token)
            check("syntax: JSON keys, numbers, literals, comments", jsonTokens == [.key, .number, .key, .literal, .comment], String(describing: jsonTokens))
            let yamlTokens = SyntaxScanner.tokens(in: "name: \"x\" # c\nlist:\n  - true\n", as: .yaml).map(\.token)
            check("syntax: YAML", yamlTokens == [.key, .string, .comment, .key, .literal], String(describing: yamlTokens))
            let xmlTokens = SyntaxScanner.tokens(in: #"<a x="1">&amp;</a>"#, as: .xml).map(\.token)
            check("syntax: XML", xmlTokens == [.punctuation, .tag, .punctuation, .attribute, .punctuation, .string, .entity, .punctuation, .tag, .punctuation],
                  String(describing: xmlTokens))
            let jsonl = [
                #"{"type":"user","message":{"content":"first question"}}"#,
                #"{"type":"assistant","message":{"content":[{"type":"text","text":"First answer"}]}}"#,
                #"{"type":"user","message":{"content":[{"type":"image"},{"type":"text","text":"[Image #2] latest question"}]}}"#,
                #"{"type":"user","isMeta":true,"message":{"content":[{"type":"text","text":"[Image: source: /tmp/x.png]"}]}}"#,
                #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}]}}"#,
                #"{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}"#,
                #"{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"a subagent"}]}}"#,
                ###"{"type":"assistant","message":{"content":[{"type":"text","text":"## Done\n- **Fixed** the `card`."}]}}"###,
            ].joined(separator: "\n")
            let exchange = ClaudeTranscript.lastExchange(Data(jsonl.utf8))
            check("agent card: the latest prompt and Claude's answer, from its transcript",
                  exchange.prompt == "[Image #2] latest question" && exchange.reply.map { ClaudeTranscript.summary($0) } == "Done",
                  String(describing: exchange))
            check("indentation: a file's own way wins, else the settings",
                  Indentation.detect("def f():\n    x = 1\n    if x:\n        y()\n", spaces: true, size: 2) == Indentation(tabs: false, size: 4)
                  && Indentation.detect("a:\n  b:\n    c: 1\n  d: 2\n", spaces: true, size: 4) == Indentation(tabs: false, size: 2)
                  && Indentation.detect("all:\n\tcc a.c\n\tcc b.c\n", spaces: true, size: 4) == Indentation(tabs: true, size: 4)
                  && Indentation.detect("no indent here\n", spaces: true, size: 4) == Indentation(tabs: false, size: 4)
                  && Indentation.detect("", spaces: true, size: 4, tabsByDefault: true).tabs
                  && Indentation.detect("/*\n * doc\n */\nint x;\n", spaces: true, size: 4) == Indentation(tabs: false, size: 4))
            let four = Indentation(tabs: false, size: 4)
            check("indentation: Tab to the next stop, Backspace back to the one before",
                  four.spaces(at: 0) == "    " && four.spaces(at: 2) == "  " && four.spaces(at: 5) == "   "
                  && four.backspace(at: 8, spacesBefore: 8) == 4 && four.backspace(at: 6, spacesBefore: 6) == 2
                  && four.column(of: "\tab"[...].utf16, upTo: 2) == 5)
            check("syntax: every code grammar compiles", CodeLanguage.allCases.allSatisfy { $0.grammar.regex.pattern != "(?!)" && $0.grammar.kinds.count == $0.grammar.regex.numberOfCaptureGroups })
            check("syntax: languages by name, extension and #! line",
                  SyntaxLanguage(path: "/a/run.sh") == .code(.shell) && SyntaxLanguage(path: ".zshrc") == .code(.shell)
                  && SyntaxLanguage(path: "Dockerfile") == .code(.dockerfile) && SyntaxLanguage(path: "x.d.ts") == .code(.javascript)
                  && SyntaxLanguage(path: "a.py") == .code(.python) && SyntaxLanguage(path: "README.md") == .code(.markdown)
                  && SyntaxLanguage(path: "tsconfig.json") == .json && SyntaxLanguage(firstLine: "#!/usr/bin/env python3") == .code(.python)
                  && SyntaxLanguage(firstLine: "#!/bin/bash -e") == .code(.shell) && SyntaxLanguage(firstLine: "hello") == nil
                  && SyntaxLanguage(path: "a.py")?.canFormat == false)
            let pyTokens = SyntaxScanner.tokens(in: "def f(self, x=1):  # c\n    return 'a#b' if obj.default else None\n", as: .code(.python)).map(\.token)
            check("syntax: Python", pyTokens == [.keyword, .function, .variable, .number, .comment, .keyword, .string, .keyword, .keyword, .literal],
                  String(describing: pyTokens))
            // An ini / .properties value is one string: digits inside a password or URL aren't numbers; a whole-value
            // number or boolean is, and placeholders and continuations inside a value are picked out.
            let props = "# c\nTOKEN=6QlAD9z-west-2\nserver.port = 8080\nssl: true\nurl=jdbc:x://h:5432/?a=b\nuser=${DB_USER:admin}\nmulti=one \\\n  two\n[section]\n"
            let propTokens = SyntaxScanner.tokens(in: props, as: .code(.ini))
            let propText = { (t: SyntaxToken) in propTokens.filter { $0.token == t }.map { (props as NSString).substring(with: $0.range) } }
            check("syntax: properties values", propText(.comment) == ["# c"] && propText(.number) == ["8080"] && propText(.literal) == ["true"]
                  && propText(.key) == ["TOKEN", "server.port", "ssl", "url", "user", "multi"] && propText(.variable) == ["${DB_USER:admin}"]
                  && propText(.string).contains("one \\\n  two") && propText(.string).contains("jdbc:x://h:5432/?a=b") && propText(.type) == ["[section]"]
                  && propText(.punctuation).filter { $0 == "\\" }.count == 1)
            let shTokens = SyntaxScanner.tokens(in: "echo \"$HOME\" ${x} -n # c\nformat=1\n", as: .code(.shell)).map(\.token)
            check("syntax: shell", shTokens == [.function, .string, .variable, .attribute, .comment, .number], String(describing: shTokens))
            check("file kinds", FileKind(name: "a.PNG") == .image && FileKind(name: #"C:\x\run.ps1"#) == .code && FileKind(name: ".bashrc") == .other
                  && VSCodeLanguages.id(forFileName: "Dockerfile") == "dockerfile" && VSCodeLanguages.id(forFileName: "x.d.ts") == "typescript")
            check("markdown: snake_case isn't italic", MarkdownDoc.inline("a snake_case_name").count == 1)
            // A commit's page: its files (one renamed) with their line counts, from a Windows repository's top folder.
            let commitOut = "C:/Users/me/repo\nabc123\u{1f}abc1\u{1f}Ann\u{1f}2 days ago\u{1f}Fix it\nparent1\u{1e}"
                + "M\0src/a.swift\0R100\0old.txt\0new.txt\0\u{1e}" + "3\t1\tsrc/a.swift\0" + "0\t0\t\0old.txt\0new.txt\0"
            let commit = GitCommitReport(output: Data(commitOut.utf8))
            check("commit: its files and line counts", commit?.root == "C:/Users/me/repo" && commit?.subject == "Fix it" && commit?.base == "parent1"
                  && commit?.files.map(\.path) == ["src/a.swift", "new.txt"] && commit?.files[1].oldPath == "old.txt" && commit?.added == 3 && commit?.removed == 1,
                  String(describing: commit?.files))
            let diff = GitPageLine.parse(Data("diff --git a/x b/x\n@@ -4,2 +4,3 @@ func\r\n same\n-gone\n+new\n+more\n\\ No newline at end of file\n".utf8))
            check("commit: a file's lines, numbered", diff.map(\.kind) == [.hunk, .context, .removed, .added, .added] && diff[1].old == 4 && diff[1].new == 4
                  && diff[2].old == 5 && diff[3].new == 5 && diff[4].new == 6 && diff[0].text == "@@ -4,2 +4,3 @@ func", diff.description)
            atlassian(results)
            promptChanges(results)
        }
    }

    /// Jira and Bitbucket records, rich text, branch names and pull request diffs (Atlassian.swift).
    static func promptChanges(_ results: Results) {
        func check(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") { results.check(name, cond, detail()) }
        let lines = [
            #"{"type":"user","promptId":"p1","message":{"role":"user","content":"fix the drawer"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit"}]}}"#,
            #"{"type":"user","promptId":"p1","message":{"content":[{"type":"tool_result"}]},"toolUseResult":{"filePath":"/r/a.swift","structuredPatch":[{"oldStart":3,"oldLines":2,"newStart":3,"newLines":3,"lines":[" keep","-old","+new","+more"]}]}}"#,
            #"{"type":"user","promptId":"p1","message":{"content":[{"type":"tool_result"}]},"toolUseResult":{"filePath":"/r/a.swift","structuredPatch":[{"oldStart":20,"oldLines":1,"newStart":21,"newLines":1,"lines":["-x","+y"]}]}}"#,
            #"{"type":"user","promptId":"p1","message":{"content":[{"type":"tool_result"}]},"toolUseResult":{"type":"create","filePath":"/r/new.md","content":"one\ntwo\n","structuredPatch":[]}}"#,
            #"{"type":"user","isMeta":true,"promptId":"m","message":{"content":"<local-command-caveat>"}}"#,
            #"{"type":"user","promptId":"p2","message":{"content":[{"type":"text","text":"<command-name>/clear</command-name>"}]}}"#,
            #"{"type":"user","promptId":"p3","message":{"content":[{"type":"text","text":"now the tests"},{"type":"image"}]}}"#,
        ]
        var scan = PromptChanges.Scan()
        PromptChanges.scan(Data(lines.joined(separator: "\n").utf8), into: &scan)
        let a = scan.edits["p1"]?.first
        check("prompt changes: prompts from a transcript, not tool results, notes or commands", scan.prompts.map(\.text) == ["fix the drawer", "now the tests"]
              && scan.latest?.id == "p3", scan.prompts.map(\.text).joined(separator: " | "))
        check("prompt changes: a prompt's edits, a file's together, and a file written whole",
              scan.edits["p1"]?.map(\.path) == ["/r/a.swift", "/r/new.md"] && a?.added == 3 && a?.removed == 2
              && a?.lines.filter { $0.kind == .hunk }.count == 2 && a?.lines.first { $0.kind == .added }?.new == 4
              && scan.edits["p1"]?.last?.added == 2 && scan.edits["p1"]?.last?.oldPath == nil && scan.edits["p3"] == nil, "")
        let files = PromptChanges.files(raw: ":100644 100644 aaa bbb M\0Sources/a b.swift\0:000000 100644 000 ccc A\0new.md\0:100644 000000 ddd 000 D\0gone.txt\0",
                                        numstat: "3\t1\tSources/a b.swift\0" + "2\t0\tnew.md\0" + "-\t-\tgone.txt\0")
        check("prompt changes: git's files and counts", files == [
            ChangedFile(path: "Sources/a b.swift", change: .modified, added: 3, removed: 1),
            ChangedFile(path: "new.md", change: .added, added: 2, removed: 0),
            ChangedFile(path: "gone.txt", change: .deleted, added: 0, removed: 0, binary: true)], String(describing: files))
        let tail = DiffFile.parse("diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1 +1,2 @@\n hi\n+two\n")
        check("diff: the output's last line break isn't a line", tail.first?.lines.count == 3, String(describing: tail.first?.lines))
        let one = DiffFile.parse("diff --git a/a.swift b/a.swift\n--- a/a.swift\n+++ b/a.swift\n@@ -1,2 +1,2 @@\n keep\n-old\n+new\n").first
        let asked = PromptChanges.ask(about: [(ChangedFile(path: "a.swift", added: 1, removed: 1), one)])
        check("prompt changes: asking about one change, by where it is", asked == "About your change to a.swift (line 2, +1 −1): ", asked)
        let spread = DiffFile.parse("diff --git a/b b/b\n--- a/b\n+++ b/b\n@@ -1,3 +1,4 @@\n x\n+a\n+b\n y\n@@ -20,2 +21,3 @@\n z\n+c\n w\n@@ -40 +42 @@\n-q\n+r\n@@ -60 +62 @@\n-s\n+t\n").first
        let gone = DiffFile.parse("diff --git a/c b/c\n--- a/c\n+++ b/c\n@@ -5,2 +4,0 @@\n-one\n-two\n").first
        let many = PromptChanges.ask(about: [(ChangedFile(path: "src/a.swift", added: 1, removed: 1), one),
                                             (ChangedFile(path: "b.png", change: .added, added: 0, removed: 0, binary: true), nil),
                                             (ChangedFile(path: "b", added: 5, removed: 2), spread),
                                             (ChangedFile(path: "c", added: 0, removed: 2), gone)])
        check("prompt changes: asking about them all, in a line", many == "About the changes you made for my last prompt (a.swift: line 2, +1 −1; "
              + "b.png: new file, +0; b: lines 2–3, 22, 42 and more, +5 −2; c: removed at lines 5–6, +0 −2): ", many)
        check("prompt changes: paths from the repository's top", PromptChanges.relative("/r/x/a.swift", to: "/r") == "x/a.swift"
              && PromptChanges.relative("/elsewhere/a", to: "/r") == "/elsewhere/a", "")
    }

    static func atlassian(_ results: Results) {
        func check(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") { results.check(name, cond, detail()) }
        func json(_ s: String) -> Any? { try? JSONSerialization.jsonObject(with: Data(s.utf8)) }
        check("jira: branch name from a ticket", BranchNames.forIssue(key: "EZ-569", summary: "Add login page (OAuth) — v2!") == "EZ-569-add-login-page-oauth-v2"
              && BranchNames.forIssue(key: "EZ-1", summary: "Fix it", prefix: "feature/") == "feature/EZ-1-fix-it"
              && BranchNames.forIssue(key: "EZ-2", summary: String(repeating: "word ", count: 30)).count <= 60, "")
        check("jira: a team's branch prefix from its branches", BranchNames.prefix(usedIn: ["EZ-1-a", "EZ-2-b", "QA", "remotes/origin/EZ-3-c"]) == nil
              && BranchNames.prefix(usedIn: ["feature/EZ-1-a", "feature/EZ-2-b", "bugfix/EZ-3"]) == "feature", "")
        let dev = JiraBranch.parse(devStatus: json(#"{"detail":[{"branches":[{"name":"EZ-5-a","url":"https://bitbucket.org/ws/repo/branch/EZ-5-a","repository":{"name":"repo","url":"https://bitbucket.org/ws/repo"}},{"name":"EZ-5-b","repository":{"name":"Other"}}]}]}"#))
        let linked = JiraBranch.merged(dev, key: "EZ-5", local: ["main", "EZ-5-a", "origin/EZ-5-c", "origin/EZ-50-x", "ez-5-d"], repo: "ws/repo")
        check("jira: a ticket's branches, from Jira and the repository", dev.map(\.repository) == ["ws/repo", "Other"]
              && linked.map(\.name) == ["EZ-5-a", "EZ-5-c", "ez-5-d", "EZ-5-b"] && linked.map(\.inRepo) == [true, true, true, false],
              linked.map { "\($0.name)@\($0.repository ?? "-")\($0.inRepo)" }.joined(separator: " "))
        let byID = JiraBranch.parse(devStatus: json(#"{"detail":[{"branches":[{"name":"EZ-7-x","repository":{"name":"Web App","url":"https://bitbucket.org/{}/{e945b092-acfe}"}},{"name":"EZ-7-y","repository":{"name":"other","url":"https://bitbucket.org/{}/{aa}"}}]}]}"#))
        let once = JiraBranch.merged(byID, key: "EZ-7", local: ["origin/EZ-7-x"], repo: "ws/web-app")
        check("jira: a branch Jira knows by its repository's id isn't listed twice, nor labeled with the id",
              byID.map(\.repository) == ["Web App", "other"] && once.map(\.name) == ["EZ-7-x", "EZ-7-y"] && once.map(\.inRepo) == [true, false],
              once.map { "\($0.name)@\($0.repository ?? "-")\($0.inRepo)" }.joined(separator: " "))
        let types = BranchType.parse(model: json(#"{"branch_types":[{"kind":"feature","prefix":"feature/","enabled":true},{"kind":"bugfix","prefix":"bugfix/","enabled":true},{"kind":"release","prefix":"release/","enabled":false}]}"#))
        check("jira: a repository's branch types, and a ticket's by default", types.map(\.prefix) == ["feature/", "bugfix/"]
              && BranchType.suggested(for: "Bug", from: types)?.kind == "bugfix" && BranchType.suggested(for: "Story", from: types)?.kind == "feature"
              && BranchType.suggested(for: "Task", from: []) == nil, "")
        let named = JiraBoard(json(#"{"id":466,"name":"ABC board","type":"simple","location":{"projectKey":"ABC","projectName":"Acme Web "}}"#))
        let own = JiraBoard(json(#"{"id":7,"name":"Release train","type":"scrum","location":{"projectKey":"ABC","projectName":"Acme Web"}}"#))
        check("jira: a board Jira named for its project's key goes by the project's name", named?.title == "Acme Web" && own?.title == "Release train", "")
        check("jira: branch names git takes", BranchNames.isValid("EZ-1-a/b") && !BranchNames.isValid("a..b") && !BranchNames.isValid("a b")
              && !BranchNames.isValid("x.lock") && !BranchNames.isValid("-x"), "")
        check("jira: issue keys in text", IssueKeys.all(in: "EZ-569-login and ez-12, not AB-x or 1EZ-3 or EZ-4a") == ["EZ-569", "EZ-12"]
              && IssueKeys.first(in: "feature/PATH2-77-x") == "PATH2-77", String(describing: IssueKeys.all(in: "EZ-569-login and ez-12, not AB-x or 1EZ-3 or EZ-4a")))
        let issue = JiraIssue(json(#"{"id":"1","key":"EZ-5","fields":{"summary":"S","status":{"id":"11023","name":"In Progress","statusCategory":{"key":"indeterminate"}},"issuetype":{"name":"Improvement ","subtask":false},"priority":{"name":"High"},"assignee":{"accountId":"a1","displayName":"Ann","avatarUrls":{"48x48":"https://x/a.png"}},"parent":{"key":"EZ-1","fields":{"summary":"Epic"}},"customfield_10704":3,"updated":"2026-11-12T17:14:03.123-0800","description":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Hi "},{"type":"mention","attrs":{"text":"@Bo"}}]},{"type":"bulletList","content":[{"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"one"}]},{"type":"bulletList","content":[{"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"deep"}]}]}]}]}]},{"type":"codeBlock","content":[{"type":"text","text":"x = 1"}]}]}}}"#),
                              storyPointsField: "customfield_10704")
        check("jira: an issue from the API", issue?.type == "Improvement" && issue?.status.category == "indeterminate" && issue?.assignee?.avatarURL == "https://x/a.png"
              && issue?.parentSummary == "Epic" && issue?.storyPoints == 3 && issue?.updated != nil && issue?.projectKey == "EZ", String(describing: issue))
        check("jira: rich text as blocks", issue?.description == [DocBlock(kind: .paragraph, text: "Hi @Bo"), DocBlock(kind: .item(depth: 0, number: nil), text: "one"),
                                                                   DocBlock(kind: .item(depth: 1, number: nil), text: "deep"), DocBlock(kind: .code, text: "x = 1")],
              String(describing: issue?.description))
        let typed = "First line\nsecond\n\n- a\n- b\n\n1. x\n\n```\ncode\n```"
        let round = ADF.blocks(ADF.document(typed))
        check("jira: typed text to rich text and back", round.map(\.kind) == [.paragraph, .item(depth: 0, number: nil), .item(depth: 0, number: nil), .item(depth: 0, number: 1), .code]
              && round[0].text == "First line\nsecond" && ADF.plainText(round) == "First line\nsecond\n\n- a\n- b\n\n1. x\n\n```\ncode\n```", ADF.plainText(round))
        let config = JiraBoardConfig(json(#"{"columnConfig":{"columns":[{"name":"Backlog","statuses":[]},{"name":"To Do","statuses":[{"id":"1"}]},{"name":"Doing","statuses":[{"id":"2"},{"id":"3"}]}]},"estimation":{"field":{"fieldId":"customfield_9"}}}"#))
        check("jira: a board's columns (empty ones left out)", config?.columns.map(\.name) == ["To Do", "Doing"] && config?.storyPointsField == "customfield_9"
              && config?.column(of: JiraStatus(id: "3", name: "", category: "")) == 1, String(describing: config))
        let ts = [JiraTransition(id: "21", name: "Start", to: JiraStatus(id: "3", name: "Review", category: "indeterminate")),
                  JiraTransition(id: "31", name: "Done", to: JiraStatus(id: "9", name: "Done", category: "done"))]
        check("jira: the transition into a column", JiraTransition.into(["2", "3"], from: ts)?.id == "21" && JiraTransition.into(["7"], from: ts) == nil, "")
        check("bitbucket: a repository from its remote", BitbucketRepo(remote: "git@bitbucket.org:acme/web-app.git")?.path == "acme/web-app"
              && BitbucketRepo(remote: "https://me@bitbucket.org/ws/repo-x")?.slug == "repo-x" && BitbucketRepo(remote: "ssh://git@bitbucket.org/ws/r.git/")?.slug == "r"
              && BitbucketRepo(remote: "git@github.com:a/b.git") == nil, "")
        let pr = BitbucketPullRequest(json(#"{"id":7,"title":"EZ-9: Thing","state":"OPEN","source":{"branch":{"name":"EZ-9-thing"},"commit":{"hash":"abc"}},"destination":{"branch":{"name":"QA"},"repository":{"full_name":"ws/r"}},"participants":[{"user":{"uuid":"{u1}","display_name":"Ann"},"role":"REVIEWER","approved":true,"state":"approved"},{"user":{"uuid":"{u2}","display_name":"Bo"},"role":"PARTICIPANT","approved":false,"state":"changes_requested"}],"comment_count":2,"links":{"html":{"href":"https://bitbucket.org/ws/r/pull-requests/7"}}}"#))
        check("bitbucket: a pull request", pr?.issueKey == "EZ-9" && pr?.approvals == 1 && pr?.changesRequested == true && pr?.approved(by: "{u1}") == true
              && pr?.repo?.path == "ws/r" && pr?.destination == "QA", String(describing: pr))
        let files = DiffFile.parse("diff --git a/a.txt b/a.txt\nindex 1..2 100644\n--- a/a.txt\n+++ b/a.txt\n@@ -1,2 +1,2 @@\n keep\n-old\n+new\n"
                                   + "diff --git a/new.bin b/new.bin\nnew file mode 100644\nBinary files /dev/null and b/new.bin differ\n"
                                   + "diff --git a/x.txt b/x.txt\ndeleted file mode 100644\n--- a/x.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-gone\n")
        check("bitbucket: a pull request's diff, file by file", files.count == 3 && files[0].added == 1 && files[0].removed == 1 && files[0].lines[1].old == 1
              && files[0].lines[3].new == 2 && files[1].isBinary && files[2].newPath == nil && files[2].path == "x.txt" && files[2].removed == 1, String(describing: files))
    }
}
