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
        }
    }
}
