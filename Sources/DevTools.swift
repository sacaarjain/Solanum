import AppKit

/// Emulator self-tests: `Solanum.app/Contents/MacOS/Solanum --selftest`
enum SelfTest {
    private typealias Sink = CoreSelfTest.Sink
    private static func feed(_ t: Terminal, _ s: String) { CoreSelfTest.feed(t, s) }
    private static func row(_ t: Terminal, _ r: Int) -> String { CoreSelfTest.row(t, r) }
    private static func make(_ c: Int = 20, _ r: Int = 5) -> (Terminal, Sink) { CoreSelfTest.make(c, r) }

    static func run() -> Bool {
        let results = CoreSelfTest.Results()
        func check(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
            results.check(name, cond, detail())
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
            // Sleeper: points under a league's own scoring, with projections' kicking buckets matched to the league's.
            let scoring: [String: Double] = ["rec": 0.5, "rec_yd": 0.1, "rush_att": 0.2, "fgm_50_59": 5, "fgmiss": -1]
            check("sleeper scoring", Sleeper.points(["rec": 4, "rec_yd": 50, "rush_att": 10, "pass_yd": 300], scoring) == 9)
            check("sleeper kicking buckets", Sleeper.points(["fgm_50p": 1, "fgmiss_40_49": 0.5, "fgmiss_50p": 0.5], scoring) == 4)
            check("sleeper number format", Sleeper.format(12) == "12" && Sleeper.format(12.5) == "12.5" && Sleeper.format(19.489999) == "19.49")
            let r = SleeperRoster(["roster_id": 3, "players": ["a", "b", "c", "d"], "starters": ["a"], "reserve": ["d"],
                                   "settings": ["wins": 5, "losses": 3, "fpts": 900, "fpts_decimal": 45]])
            check("sleeper roster", r?.bench == ["b", "c"] && r?.pointsFor == 900.45 && r?.recordText == "5-3")
            check("sleeper advice: the week it's for, kept or from its title",
                  Sleeper.Advice(["summary": "x", "title": "Week 9: Antonio Williams start/sit"])?.week == 9
                  && Sleeper.Advice(["summary": "x", "week": 11, "title": "Week 9 lineup"])?.week == 11
                  && Sleeper.Advice(["summary": "x", "title": "Waiver targets"])?.week == nil)
            check("sleeper slot names", SleeperLeagueSnapshot.slotName("SUPER_FLEX") == "SF" && SleeperLeagueSnapshot.slotName("WRRB_FLEX") == "W/R")
            // The MCP server: handshake, tool list, and an unknown tool refused (all offline).
            let tools = SleeperTools()
            let ini = MCPServer.handle(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]], tools)
            check("mcp initialize", (ini?["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-06-18")
            check("mcp notification unanswered", MCPServer.handle(["jsonrpc": "2.0", "method": "notifications/initialized"], tools) == nil)
            let list = (MCPServer.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/list"], tools)?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
            check("mcp tools listed", (list?.count ?? 0) >= 15 && list?.allSatisfy { $0["inputSchema"] != nil } == true)
            let bad = MCPServer.handle(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "nope"]], tools)
            check("mcp unknown tool refused", (bad?["error"] as? [String: Any])?["code"] as? Int == -32602)
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
            // Reconnecting keeps just how to reach the host, whatever the session ran there.
            let c = RemoteSession.connectionArgs
            check("ssh args: plain", c("myhost") == "myhost" && c("-p 2222 me@host") == "-p 2222 me@host" && c("-p2222 -i ~/k host") == "-p2222 -i ~/k host")
            check("ssh args: a reconnect's command dropped", c("-t mb1.example.com cd\\ \\'/mnt\\'\\ 2\\>/dev/null\\;\\ exec\\ \\\"\\$SHELL\\\"\\ -l") == "mb1.example.com")
            check("ssh args: quoted command dropped", c("-t -o 'ProxyJump bastion' host 'cd /x; exec $SHELL -l'") == "-o 'ProxyJump bastion' host")
            check("ssh args: flags kept, -t dropped", c("-A -tt -v host ls") == "-A -v host" && c("-o") == nil && c("") == nil)
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
        CoreSelfTest.run(results)
        do {
            check("OSC 8 link schemes", TerminalView.hyperlinkURL("https://a.com/x")?.absoluteString == "https://a.com/x"
                  && TerminalView.hyperlinkURL("file://localhost/tmp/a%20b")?.path == "/tmp/a b"
                  && TerminalView.hyperlinkURL("file://some-other-host.example/tmp/a") == nil
                  && TerminalView.hyperlinkURL("x-apple.systempreferences:foo") == nil)
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
                // A shell from sudo -i -u reporting its user (Follow This Shell's Folder), and the line that has it do so.
                let (t, _) = make(20, 80)
                feed(t, "\u{1b}]1337;SolanumUser=svc:/home/svc\u{07}")
                check("sudo shell: no user outside ssh", t.remoteUser == nil)
                feed(t, "\u{1b}]1337;SolanumSSH=/tmp/x\u{07}\u{1b}]7;file://host/opt/app\u{07}\u{1b}]1337;SolanumUser=svc:/home/svc\u{07}")
                check("sudo shell: its folder and user", t.remoteCwd == "/opt/app" && t.remoteUser?.name == "svc" && t.remoteUser?.home == "/home/svc")
                feed(t, "\u{1b}]1337;SolanumSSH=\u{07}")
                check("sudo shell: forgotten when ssh ends", t.remoteUser == nil && t.remoteCwd == nil)
                check("sudo shell: commands that switch user", ["sudo -i -u pipelineservice", "sudo -iu svc", "sudo su - svc", "sudo -s",
                    "su - svc", "su", "sudo -u svc bash", "x$ sudo -i"].allSatisfy(TerminalView.switchesUser)
                      && !["sudo ls", "sudo -u svc ls /tmp", "sudo systemctl restart x", "summary", "ls -s", "sudo cat -s x"].contains(where: TerminalView.switchesUser))
                let follow = TerminalView.followCommand(promptWidth: 30, columns: 80)
                check("sudo shell: erases the lines it took", follow.hasSuffix("printf '\\033[\((30 + follow.count - 1) / 80 + 1)A\\033[J'"), follow)
                let (p, _) = make(40, 5)
                feed(p, "\u{1b}]1337;SolanumSSH=/tmp/x\u{07}[sudo] password for sjain: ")
                check("sudo shell: not at a password question", !p.atEmptyHostPrompt())
                feed(p, "\r\n[svc@host ~]$ ")
                check("sudo shell: at the new shell's prompt", p.atEmptyHostPrompt())
                feed(p, "ls")
                check("sudo shell: not with something typed", !p.atEmptyHostPrompt())
                check("sudo shell: the follow line", TerminalView.followLine.hasPrefix(" PROMPT_COMMAND=")
                      && TerminalView.followLine.contains("SolanumUser=%s:%s") && TerminalView.followLine.contains("${PROMPT_COMMAND:+;$PROMPT_COMMAND}"))
            }
            do {
                // A new terminal on an ssh host shares the open connection (no password again); logs in afresh once it's gone.
                let sock = NSTemporaryDirectory() + "solanum-selftest-sock-\(getpid())"
                FileManager.default.createFile(atPath: sock, contents: Data())
                let r = RemoteSession(controlPath: sock, sshArgs: "lanode11")
                let shared = r.newTerminalCommand(in: "/srv/app") ?? ""
                check("ssh: new terminals share the connection", shared.hasPrefix("SOLANUM_SSH_ARGS='bGFub2RlMTEg' ssh -t -S ")
                      && shared.contains("-o ControlMaster=no solanum-remote") && shared.contains("cd '\\''/srv/app'\\''"), shared)
                try? FileManager.default.removeItem(atPath: sock)
                check("ssh: and log in again once it's gone", r.newTerminalCommand(in: "/srv/app")?.hasPrefix("ssh -t lanode11 ") == true,
                      r.newTerminalCommand(in: "/srv/app") ?? "nil")
            }
            do {
                // Only the selection keeps an alpha: the window's transparency is the Background opacity setting.
                let t = Theme(name: "t", bg: "#11223344", bg2: "#00000080", fg: "#EEEEEE80", selection: "#8ED8FF4D", accent: "#8ED8FF80",
                              ansi: ["#11111180"])
                check("themes: only the selection is see-through", t.background.hexString == "#112233" && t.background2?.hexString == "#000000"
                      && t.foreground.hexString == "#EEEEEE" && t.accent.hexString == "#8ED8FF" && t.ansi[0].hexString == "#111111"
                      && t.selection.hexString == "#8ED8FF4D", t.background.hexString)
            }
            do {
                // The Git Graph's filters, as git log arguments, and the commits as laid out.
                var f = GraphFilter()
                check("graph filter: all branches", f.script().contains("git log --all --parents") && !f.script().contains("--grep"))
                f.text = "fix"; f.user = "Ben Guo"; f.days = 7; f.path = "Sources/a b.swift"; f.branch = "origin/main"
                let sc = f.script()
                check("graph filter: everything", sc.contains("git log 'origin/main' --parents") && sc.contains("--author='^Ben Guo <'")
                      && sc.contains("--since='7 days ago'") && sc.contains("--grep='fix' -F -i") && sc.contains("-- 'Sources/a b.swift'\n") && sc.hasSuffix("git log 'origin/main' --topo-order -n 50000 --format='%H %P'"), sc)
                f = GraphFilter(); f.text = "f607a7e"; f.regex = true; f.matchCase = true
                check("graph filter: a hash too", f.script().contains("--grep='f607a7e' -E\n") && f.script().contains("rev-parse -q --verify 'f607a7e^{commit}'"))
                let c = { (h: String, p: [String], t: Double) in GraphCommit(hash: h, parents: p, author: "a", date: Date(timeIntervalSince1970: t), subject: h, refs: []) }
                let arranged = f.arrange([c("b", ["a"], 2), c("c", ["b"], 3), c("b", ["a"], 2)])
                check("graph filter: a search shows a list", arranged.map(\.hash) == ["c", "b"] && arranged[0].parents == ["b"] && arranged[1].parents.isEmpty)
                // Shown: d, b. Hidden: c (d's parent) and a. d connects to b through c; b's parent a isn't shown.
                let topo: [(String, [String])] = [("d", ["c"]), ("c", ["b", "x"]), ("x", ["a"]), ("b", ["a"]), ("a", [])]
                let linked = f.arrange([c("d", ["c"], 4), c("b", ["a"], 2)], topology: topo)
                check("graph filter: a search connects through hidden commits", linked.map(\.parents) == [["b"], []], "\(linked.map(\.parents))")
                let split = GraphFilter.split(Data("h\nrec\u{1e}\u{1d}d c\nc b x\n".utf8))
                check("graph filter: shape read after the commits", split.topology?.map(\.0) == ["d", "c"] && String(decoding: split.log, as: UTF8.self) == "h\nrec\u{1e}")
                check("graph refs", GraphRefs.parse(Data("main\n\u{1e}refs/heads/main\nrefs/remotes/origin/HEAD\nrefs/remotes/origin/main\nrefs/tags/v1\n".utf8)).remotes == ["origin/main"])
            }
            do {
                // Logs: a logback file written with %highlight / %cyan, its config imported, and the built-in coloring.
                let esc = "\u{1B}"
                let line = "2026-07-21 18:09:05.778 [main] \(esc)[34mINFO \(esc)[0;39m \(esc)[36mVipsLogger\(esc)[0;39m - \(esc)[32mVipsLogger initialized: D:\\x\\y.log\(esc)[0m"
                let st = ANSIText.strip(line)
                check("logs: escapes taken out", st.visible == "2026-07-21 18:09:05.778 [main] INFO  VipsLogger - VipsLogger initialized: D:\\x\\y.log", st.visible)
                check("logs: their colors kept", st.colors.map(\.color) == [.palette(4), .palette(6), .palette(2)]
                      && (line as NSString).substring(with: st.colors[0].range) == "INFO ")
                let ns = line as NSString
                let open = ns.range(of: "\(esc)[34m").location
                check("logs: an escape found from inside it", ANSIText.escapeStart(ns, open + 3) == open && ANSIText.escapeStart(ns, open + 4) == open
                      && ANSIText.escapeStart(ns, open + 5) == nil && ANSIText.escapeStart(ns, 0) == nil
                      && ANSIText.escapeRange(ns, around: open + 2) == NSRange(location: open, length: 5))
                check("logs: copying leaves escapes out", ANSIText.removing("a\(esc)[1;31mb\(esc)[0mc") == "abc")
                let xml = """
                <configuration>
                  <appender name="CONSOLE" class="ch.qos.logback.core.ConsoleAppender"><encoder>
                    <!-- <pattern>%msg</pattern> -->
                    <pattern>%d{yyyy-MM-dd HH:mm:ss.SSS} [%thread] %highlight(%-5level) %cyan(%logger{0}) - %msg%n</pattern>
                  </encoder></appender>
                  <appender name="FILE"><file>{PATH_TO_LOGS}/service-output.log</file><encoder>
                    <pattern>%d{yyyy-MM-dd HH:mm:ss.SSS} [%thread] %highlight(%-5level) %cyan(%logger{0}) - %msg%n</pattern></encoder>
                    <rollingPolicy><fileNamePattern>{PATH_TO_LOGS}/service-output-%d{yyyy-MM-dd}.%i.log</fileNamePattern></rollingPolicy>
                  </appender>
                  <appender name="ERROR_FILE"><file>{PATH_TO_LOGS}/nativelogs/service-error.log</file>
                    <encoder><pattern>%d{yyyy-MM-dd HH:mm:ss.SSS} [%thread] %-5level %logger{0} - %msg%n</pattern></encoder>
                  </appender>
                </configuration>
                """
                let j = try? LogFormats.convert(xml, name: "logback.xml", folder: "PathoDaemon")
                check("logs: logback config imported", j?["name"] as? String == "PathoDaemon" && (j?["patterns"] as? [String])?.count == 1
                      && j?["files"] as? [String] == ["service-output.log", "service-output-*.*.log", "service-error.log"], "\(j ?? [:])")
                if let j, let f = try? LogFormat(json: j) {
                    let p = f.paint(line, carried: nil)
                    let painted = { (p: LogLinePaint, text: String) in p.paints.filter { (line as NSString).substring(with: $0.range) == text }.map(\.color) }
                    check("logs: the layout's fields", p.isHeader && p.level == .info && painted(p, "2026-07-21 18:09:05.778") == [.dim]
                          && painted(p, "main") == [.dim] && painted(p, "D:\\x\\y.log") == [.palette(4)], "\(p)")
                    let err = f.paint("2026-07-21 18:09:06.000 [pool-1] ERROR Main - boom java.io.IOException: disk 'D' full at 99%", carried: nil)
                    check("logs: an error line", err.level == .error && err.wash == .palette(1) && err.paints.contains { $0.color == .palette(1) && $0.bold })
                    let frame = f.paint("\tat com.x.Y.z(Y.java:12)", carried: .error)
                    check("logs: its stack trace goes with it", frame.continues && frame.wash == .palette(1) && !frame.isHeader)
                    check("logs: caused by", f.paint("Caused by: java.lang.IllegalStateException: x", carried: .warn).wash == .palette(3))
                    check("logs: a plain line after doesn't", f.paint("plain words", carried: .error).wash == nil)
                    check("logs: the format chosen by its lines", LogFormats.choose(for: "issue.log", sample: [line, line, ""], among: [f]).name == "PathoDaemon"
                          && LogFormats.choose(for: "other.log", sample: ["hello", "world"], among: [f]).name == LogFormat.builtIn.name)
                    check("logs: and by its file names", f.matches(fileName: "service-output-2026-07-21.0.log") && !f.matches(fileName: "issue.log"))
                } else {
                    check("logs: imported format reads", false)
                }
                let generic = LogFormat.builtIn.paint("2026-07-21T18:09:05.120Z [worker-3] WARN  com.acme.Sync - retrying in 500ms (attempt 2)", carried: nil)
                check("logs: built-in time, thread, level", generic.isHeader && generic.level == .warn && generic.wash == .palette(3)
                      && generic.paints.contains { $0.color == .palette(6) } && generic.paints.filter { $0.color == .palette(5) }.count == 2, "\(generic)")
                check("logs: built-in bracketed and level=", LogFormat.builtIn.paint("[error] x", carried: nil).level == .error
                      && LogFormat.builtIn.paint("ts=1 level=debug msg=hi", carried: nil).level == .debug
                      && LogFormat.builtIn.paint("an error occurred", carried: nil).level == nil)
                let py = LogLayout.regex(fromPattern: "%(asctime)s - %(name)s - %(levelname)s - %(message)s")
                check("logs: Python layouts", py.flatMap { try? NSRegularExpression(pattern: $0) }?.firstMatch(in: "2026-07-21 18:09:05,123 - app.db - WARNING - slow", range: NSRange(location: 0, length: 49)) != nil)
                check("logs: date patterns", LogLayout.dateRegex("dd/MMM/yyyy:HH:mm:ss Z") == #"\d{2}/[A-Za-z]{3}/\d{4}:\d{2}:\d{2}:\d{2}\s+(?:Z|[A-Z]{2,5}|[+-]\d{2}:?\d{2})"#)
                check("logs: globs", LogFormats.glob("app-*.log", "APP-1.log") && LogFormats.glob("a?c", "abc") && !LogFormats.glob("*.log", "a.txt"))
                check("logs: color names", LogColor(name: "bright-red") == .palette(9) && LogColor(name: "#ff8800") == .rgb(255, 136, 0) && LogColor(name: "nope") == nil)
                let rules = try? LogFormat(json: ["name": "R", "rules": [["match": "heartbeat", "color": "dim", "line": true], ["match": "slide (\\d+)", "color": "yellow", "bold": true]]])
                let ruled = rules?.paint("INFO heartbeat for slide 42", carried: nil)
                check("logs: rules files", ruled?.wash == .dim && ruled?.paints.last == LogPaint(range: NSRange(location: 25, length: 2), color: .palette(3), bold: true))
                check("logs: bad rules say why", (try? LogFormat(json: ["rules": [["match": "x", "color": "nope"]]])) == nil
                      && (try? LogFormats.convert("<configuration/>", name: "logback.xml", folder: "x")) == nil)
                check("logs: styles in words", LogStyle(text: "bright-red bold tint") == LogStyle(color: .palette(9), bold: true, tint: true)
                      && LogStyle(text: "dim fade")?.text == "dim fade" && LogStyle(text: "#00FF00")?.text == "#00FF00" && LogStyle(text: "loud") == nil)
                if let j, let base = try? LogFormat(json: j),
                   let all = try? LogFormat(json: ["colors": ["time": "yellow", "logger": "red"], "rules": [["text": "[OK]", "style": "green bold"]]], colorsOnly: true),
                   let mine = try? LogFormat(json: ["colors": ["logger": "magenta bold"], "rules": [["text": "Main", "style": "bright-blue tint"], ["text": "noise", "style": "fade"]]]) {
                    var f = base
                    f.styles = mine.styles
                    f.rules = mine.rules
                    f = f.merged(over: all)
                    check("logs: a format's colors over all logs'", f.style(.logger).style.color == .palette(5) && f.style(.time).style.color == .palette(3)
                          && f.style(.thread).chosen == false && f.markerStyle("[OK]")?.bold == true)
                    let p = f.paint(line, carried: nil)
                    let logger = (line as NSString).range(of: "VipsLogger")
                    // Chosen colors go over the file's own (cyan), which go over the defaults.
                    check("logs: chosen colors win over the file's", p.paints.last { NSIntersectionRange($0.range, logger).length > 0 }?.color == .palette(5))
                    let ok = f.paint("2026-07-21 18:11:08.525 [main] INFO  StartupHealthCheck - StartupHealthCheck: [OK]   PLM Auth", carried: nil)
                    check("logs: a marker", ok.paints.last == LogPaint(range: NSRange(location: 78, length: 4), color: .palette(2), bold: true), "\(ok.paints.last.map { "\($0)" } ?? "")")
                    let main = f.paint("2026-07-21 18:09:06.733 [main] INFO  Main - Loaded MainWindow", carried: nil)
                    check("logs: a marker is a whole word, and tints", main.wash == .palette(12) && main.paints.filter { $0.color == .palette(12) }.count == 1)
                    let faded = f.paint("2026-07-21 18:09:06.733 [main] ERROR Main - noise", carried: nil)
                    check("logs: fading a line", faded.paints == [LogPaint(range: NSRange(location: 0, length: 49), color: .faint)] && faded.wash == nil)
                    var spans: [(String, LogStyleKey)] = []
                    let msg = "GET https://x.io/a?b=1, file C:\\data\\a.svs and /var/log/x.log took 4812ms at 10.0.0.1:8080 id 9f3c2a1e-7b44-4c1a-9d2e-0a1b2c3d4e5f 'ai_retry' \"q\" ok=true v1.2.3 pool-2-thread-1 java.io.IOException 3rd"
                    let mu = Array(msg.utf16)
                    LogMessageScanner.scan(mu, in: NSRange(location: 0, length: mu.count)) { r, k in spans.append(((msg as NSString).substring(with: r), k)) }
                    check("logs: message parts", spans.map(\.0) == ["https://x.io/a?b=1", "C:\\data\\a.svs", "/var/log/x.log", "4812ms", "10.0.0.1:8080",
                                                                    "9f3c2a1e-7b44-4c1a-9d2e-0a1b2c3d4e5f", "'ai_retry'", "\"q\"", "true", "java.io.IOException"]
                          && spans.map(\.1) == [.url, .path, .path, .number, .number, .number, .string, .string, .literal, .exception], "\(spans)")
                }
                check("logs: log files", SyntaxLanguage(path: "/a/issue.log") == .log && SyntaxLanguage(path: "/a/app.log.1") == .log && SyntaxLanguage(path: "/a/b.txt") == nil)
            }
            do {
                // A question near the top of a tall screen counts, as it does at the bottom; old menus further up don't.
                let (t, _) = make(40, 50)
                feed(t, "Trust this folder?\r\n❯ 1. Yes\r\n  2. No\r\n")
                check("agent status: question at the top of a tall screen", t.agentScreenStatus() == .waiting)
                feed(t, String(repeating: "line\r\n", count: 30))
                check("agent status: an old question far above isn't live", t.agentScreenStatus() == .done)
            }
            check("files: a change on disk changes the signature, even at the same size", {
                let f = NSTemporaryDirectory() + "solanum-sig-\(UUID().uuidString).txt"
                defer { try? FileManager.default.removeItem(atPath: f) }
                try? "alpha\n".write(toFile: f, atomically: false, encoding: .utf8)
                let before = LocalFileSystem.signature(f)
                usleep(2000)
                try? "ALPHA\n".write(toFile: f, atomically: false, encoding: .utf8)
                return before != nil && LocalFileSystem.signature(f) != before && LocalFileSystem.signature(f + ".gone") == nil
            }())
            do {
                // The ssh watch, run here with sh: not up at first (no connection yet), it keeps trying, and once it
                // can run it reports the file and then a change to it.
                let f = NSTemporaryDirectory() + "solanum-watch-\(UUID().uuidString).txt"
                defer { try? FileManager.default.removeItem(atPath: f) }
                try? "one\n".write(toFile: f, atomically: false, encoding: .utf8)
                var up = false
                let watch = RemoteFileWatch { script in
                    guard up else { return nil }
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/bin/sh")
                    p.arguments = ["-c", script]
                    return p
                }
                var seen: [String?] = []
                func spin(_ limit: TimeInterval, until cond: () -> Bool) {
                    let end = Date(timeIntervalSinceNow: limit)
                    while !cond(), Date() < end { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
                }
                let token = watch.watch(f) { seen.append($0) }
                spin(5) { watch.live == false }
                check("ssh watch: says it isn't updating while it can't run", watch.live == false && seen.isEmpty)
                up = true
                spin(6) { watch.live == true && !seen.isEmpty }
                check("ssh watch: starts once it can, and reports the file", watch.live == true && seen.count == 1 && seen[0] != nil)
                try? "one\ntwo\n".write(toFile: f, atomically: false, encoding: .utf8)
                spin(4) { seen.count >= 2 }
                check("ssh watch: reports a change within a couple of seconds", seen.count == 2 && seen[1] != nil && seen[1] != seen[0])
                withExtendedLifetime(token) {}
            }
            do {
                // A read of a growing file stops at the size its signature says (so the next read carries on from
                // there and the watch agrees nothing else changed), here and through the ssh script (run by sh).
                let f = NSTemporaryDirectory() + "solanum-part-\(UUID().uuidString).log"
                defer { try? FileManager.default.removeItem(atPath: f) }
                try? String(repeating: "0123456789\n", count: 100).write(toFile: f, atomically: false, encoding: .utf8)
                let sock = NSTemporaryDirectory() + "solanum-devssh-socket"
                FileManager.default.createFile(atPath: sock, contents: nil)
                for (name, fs) in [("here", LocalFileSystem.shared as FileSystem), ("over ssh", RemoteSession(devLocal: sock, latency: 0))] {
                    // (They may finish in either order.)
                    var whole: FilePart?, rest: FilePart?
                    fs.readPart(f, from: nil, whole: 1 << 20, tail: 1 << 20) { if case .success(let p) = $0 { whole = p } }
                    fs.readPart(f, from: 1000, whole: 0, tail: 1 << 20) { if case .success(let p) = $0 { rest = p } }
                    let end = Date(timeIntervalSinceNow: 5)
                    while whole == nil || rest == nil, Date() < end { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
                    let got = [whole, rest].compactMap { $0 }
                    let sized = got.allSatisfy { p in p.signature?.split(separator: " ").dropLast().last.flatMap { Int($0) } == p.size }
                    check("files: a read's signature has the size it read up to (\(name))", got.count == 2 && sized
                          && whole?.data.count == 1100 && rest?.data.count == 100)
                    // Lines before a byte (a big file's line numbers): 100 lines of 11 bytes, so 45 before byte 500.
                    var counted: [Int?] = []
                    fs.countLines(f, upTo: 500) { counted.append($0) }
                    fs.countLines(f, upTo: 1100) { counted.append($0) }
                    let until = Date(timeIntervalSinceNow: 5)
                    while counted.count < 2, Date() < until { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
                    check("files: lines counted up to a byte (\(name))", Set(counted.compactMap { $0 }) == [45, 100])
                }
            }
            check("ssh: a typed host to connect to", SSHHosts.newTarget("ssh bob@build9") == "bob@build9"
                  && SSHHosts.newTarget("  bob@build9 ") == "bob@build9" && SSHHosts.newTarget("ssh -p 2222 bob@h.example.com") == "-p 2222 bob@h.example.com"
                  && SSHHosts.newTarget("build") == nil && SSHHosts.newTarget("ssh ") == nil && SSHHosts.newTarget("ssh bob@") == nil
                  && SSHHosts.newTarget("ssh -p") == nil && SSHHosts.newTarget("ssh h; rm x") == nil && SSHHosts.newTarget("ssh $(x)@h") == nil)
            check("chats: commands join oldest first", AgentChats.transcript(["$ a\n1", "$ b\n2"]) == "$ a\n1\n\n$ b\n2")
            check("chats: agents found on PATH", InstalledAgents.parse("noise\nsolanum-agent:codex\nsolanum-agent:claude\nsolanum-agent:nonsense\n").map(\.command) == ["claude", "codex"])
            check("chats: every known agent can start", AgentKind.known.allSatisfy { !$0.command.isEmpty } && AgentKind.known.contains(.other("aider")))
            check("agents: continue commands", AgentKind.claude.defaultContinueCommand == "claude -c" && AgentKind.codex.defaultContinueCommand == "codex resume --last"
                  && AgentKind.antigravity.defaultContinueCommand == "agy -c" && AgentKind.other("amp").defaultContinueCommand.isEmpty)
            check("agents: known by their commands", AgentKind.known.allSatisfy { AgentKind.named($0.command) == $0 } && AgentKind.named("zsh") == nil)
            check("agents: continue goes through an alias", AgentKind.claude.throughAlias("claude -c", alias: "c") == "c -c"
                  && AgentKind.claude.throughAlias("claudette -c", alias: "c") == "claudette -c" && AgentKind.codex.throughAlias("codex resume --last", alias: nil) == "codex resume --last")
            check("session: Claude resumes its own chat, not the folder's newest", {
                let id = "95c88082-9cd8-4ae9-bc0a-c8645ac3bb71"
                return ClaudeSessions.resuming("claude -c", session: id, exists: true) == "claude --resume \(id)"
                    && ClaudeSessions.resuming("claude --continue --model opus", session: id, exists: true) == "claude --resume \(id) --model opus"
                    && ClaudeSessions.resuming("claude -c", session: id, exists: false) == "claude"
                    && ClaudeSessions.resuming("claude --model opus", session: id, exists: true) == "claude --model opus"
                    && ClaudeSessions.resuming("claude -c", session: "x; rm -rf ~", exists: true) == "claude -c"
            }())
            check("session: Claude from an older session still continues", {
                let old = try? JSONDecoder().decode(PaneState.self, from: Data(#"{"claude":true}"#.utf8))
                return old?.claude == true && old?.agent == nil
            }())
            check("agents: Antigravity is found by its command", AgentKind.detect(name: "agy", path: "/usr/local/bin/agy", args: []) == .antigravity && AgentKind.named("agy") == .antigravity)
            check("keep awake: durations read short", Config.shortDuration(28800) == "8h" && Config.shortDuration(5400) == "1h 30m"
                  && Config.shortDuration(90) == "1m 30s" && Config.shortDuration(45) == "45s" && Config.shortDuration(3661) == "1h 1m 1s")
            check("keep awake: defaults to 8 hours", Config.defaultKeepAwakeSeconds == 28800)
            do {
                // A theme's picture, written and read back as Windows writes it.
                let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("solanum-themes-\(UUID().uuidString)")
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: dir); ThemeLibrary.loadCustomThemes(from: Config.shared.themesDir) }
                var t = Theme(name: "Pictured", bg: "#101010", fg: "#EEEEEE", accent: "#AA88FF", ansi: [])
                t.image = ThemeImage(file: "pictured-background.jpg", blur: 12.5, tint: 0.4)
                if let data = try? JSONSerialization.data(withJSONObject: t.json) { try? data.write(to: dir.appendingPathComponent("pictured.json")) }
                ThemeLibrary.loadCustomThemes(from: dir)
                let back = ThemeLibrary.custom.first { $0.name == "Pictured" }?.image
                check("themes: a background picture saved and read back", back == ThemeImage(file: "pictured-background.jpg", blur: 12.5, tint: 0.4)
                      && (t.json["background-image-tint"] as? Double) == 0.4)
            }
            check("keep awake: time left as the status bar shows it", KeepAwake.shortDuration(28800) == "8h" && KeepAwake.shortDuration(28740) == "7h 59m"
                  && KeepAwake.shortDuration(2700) == "45m" && KeepAwake.shortDuration(30) == "30s" && KeepAwake.shortDuration(3601) == "1h 1m")
            do {
                // In the self-test it's only the state: no caffeinate runs.
                KeepAwake.start(seconds: 7200)
                let started = KeepAwake.isOn && (7190...7200).contains(KeepAwake.secondsLeft ?? 0)
                KeepAwake.extend(by: 3600)
                let added = (10790...10800).contains(KeepAwake.secondsLeft ?? 0)
                KeepAwake.extend(by: -3600)
                let taken = (7190...7200).contains(KeepAwake.secondsLeft ?? 0)
                KeepAwake.extend(by: -7200)
                let endedWhenNoneLeft = !KeepAwake.isOn && KeepAwake.secondsLeft == nil
                KeepAwake.start(seconds: 60)
                KeepAwake.stop()
                check("keep awake: starts, an hour more, an hour less, ends when none's left", started && added && taken && endedWhenNoneLeft && !KeepAwake.isOn)
            }
            check("agents: logo loads", AgentLogos.openAI(.white) != nil)
            check("chats: paste waits", !AgentChats.readyForPaste(bracketed: false, status: .done, quietFor: 9)
                  && !AgentChats.readyForPaste(bracketed: true, status: nil, quietFor: 9)
                  && !AgentChats.readyForPaste(bracketed: true, status: .waiting, quietFor: 9)
                  && !AgentChats.readyForPaste(bracketed: true, status: .done, quietFor: 0.1)
                  && AgentChats.readyForPaste(bracketed: true, status: .done, quietFor: 1)
                  && AgentChats.readyForPaste(bracketed: true, status: .working, quietFor: 1))
            check("links: local or not", TerminalView.isLocal(URL(string: "http://localhost:3000")!)
                  && !TerminalView.isLocal(URL(string: "https://github.com")!))
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
            // Commands on an ssh host, found from Enter at its prompt.
            let t = Terminal(cols: 60, rows: 20, scrollbackLimit: 100)
            feed(t, "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}ssh box\r\n\u{1b}]133;C\u{07}\u{1b}]1337;SolanumSSH=/tmp/s\u{07}Welcome!\r\n")
            func type(_ text: String) { t.remoteKeyPressed(); feed(t, text) }
            feed(t, "sacaar@box:~$ ")
            type("ls")
            t.remoteEnterPressed()
            feed(t, "\r\nnotes.txt  logs\r\nsacaar@box:~$ ")
            let quiet = t.remoteOutputQuiet()
            let ls = t.blocks.last
            check("host: Enter at its prompt starts a command", ls?.onHost == true && ls?.command == "ls" && ls?.promptLine == 2 && ls?.outputLine == 3)
            check("host: it finishes when the prompt is back", quiet && ls?.state == .finished && ls?.endLine == 3)
            // Enter before the host has echoed what was typed, as over a slow link.
            t.remoteKeyPressed()
            t.remoteEnterPressed()
            feed(t, "pwd\r\n/home/sacaar\r\nsacaar@box:~$ ")
            check("host: what's typed can echo after Enter", t.remoteOutputQuiet() && t.blocks.last?.command == "pwd" && t.blocks.last?.endLine == 5,
                  t.blocks.map { "\($0.command) \($0.promptLine)-\($0.endLine ?? -1)" }.description)
            type("rm -i notes.txt")
            t.remoteEnterPressed()
            feed(t, "\r\nrm: remove regular file 'notes.txt'? ")
            type("y")
            t.remoteEnterPressed()
            feed(t, "\r\n[other@box ~]$ ")
            let rm = t.blocks.last
            check("host: Enter at a question is input, not a command", rm?.command == "rm -i notes.txt" && t.blocks.filter(\.onHost).count == 3)
            check("host: a sudo -i prompt is a prompt too", t.remoteOutputQuiet() && rm?.state == .finished && rm?.endLine == 7)
            type("whoami")
            t.remoteEnterPressed()
            feed(t, "\r\nother\r\n")
            feed(t, "\u{1b}]1337;SolanumSSH=\u{07}")
            check("host: leaving the host finishes the last one", t.blocks.last?.command == "whoami" && t.blocks.last?.state == .finished && t.blocks.last?.endLine == 9)
            check("host: a password isn't a command", HostPrompt.end(of: "sacaar@box's password: ", noted: "sacaar@box's password: ", heads: [], firstCommand: true) == nil
                  && HostPrompt.end(of: "Continue? [y/N] y", noted: "Continue? [y/N] ", heads: [], firstCommand: false) == nil)
            check("host: a prompt pasted into has its shape", HostPrompt.end(of: "pi@raspberrypi:~/app $ make", noted: nil, heads: [], firstCommand: false) == 23
                  && HostPrompt.end(of: "root@box:/# ls", noted: nil, heads: [], firstCommand: false) == 12)
            check("host: an unusual prompt is learned from the first command", HostPrompt.end(of: "box | git log", noted: "box | ", heads: [], firstCommand: true) == 6
                  && HostPrompt.head("box | ") == "box" && HostPrompt.isPrompt("box ~/x | ", heads: ["box"]))
        }
        do {
            // Claude's quotes: a dim ▎ bar, hard-wrapped. Copy joins each paragraph into one line, without the bar.
            let t = Terminal(cols: 40, rows: 12, scrollbackLimit: 100)
            feed(t, "\u{23FA} Here's the note:\r\n\r\n  \u{1b}[2m\u{258E}\u{1b}[0m \u{1b}[3mOne more from the same\r\n"
                 + "  \u{1b}[2m\u{258E}\u{1b}[0m \u{1b}[3mincident: PO-49142 failed.\r\n  \u{258E}\r\n"
                 + "  \u{258E} - first\r\n  \u{258E} - second\r\n\r\nAfter it.\r\n")
            let boxes = t.snapshot().findBoxes(code: [])
            let q = boxes.first { $0.kind == .quote }
            check("quote: found from its bar", boxes.count == 1 && q?.first == 2 && q?.last == 6 && q?.indent == 4, boxes.map { "\($0.kind) \($0.first)-\($0.last)" }.description)
            check("quote: copies as paragraphs", q?.copyText == "One more from the same incident: PO-49142 failed.\n\n- first\n- second", q?.copyText ?? "-")
            check("quote: every letter maps to the copy", q?.offsets[GridPos(line: 3, col: 4)] == 23)
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
        return results.finish()
    }
}

/// Development aid: snapshot runs (SOLANUM_SNAPSHOT) are headless, so a test never shows up over someone's work or
/// takes their keyboard. There's no Dock icon or menu bar, the app never activates (nor hands activation to another
/// app), and every window (sheets, panels, tooltips) is fully transparent and click-through while
/// still laying out and drawing as usual: the snapshot is drawn from the views, not read off the screen. Opening a
/// link or file in another app only prints "headless: open <url>".
/// SOLANUM_SNAPSHOT_VISIBLE=1 shows the windows, to watch a run.
enum Headless {
    static let active: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["SOLANUM_SNAPSHOT"] != nil && env["SOLANUM_SNAPSHOT_VISIBLE"] == nil
    }()

    static func install() {
        guard active else { return }
        swap(NSWindow.self, #selector(NSWindow.order(_:relativeTo:)), #selector(NSWindow.headlessOrder(_:relativeTo:)))
        swap(NSWindow.self, #selector(setter: NSWindow.alphaValue), #selector(NSWindow.headlessSetAlphaValue(_:)))
        swap(NSApplication.self, #selector(NSApplication.activate(ignoringOtherApps:)), #selector(NSApplication.headlessActivate(ignoringOtherApps:)))
        swap(NSApplication.self, #selector(NSApplication.activate as (NSApplication) -> () -> Void),
             #selector(NSApplication.headlessActivate as (NSApplication) -> () -> Void))
        swap(NSRunningApplication.self, #selector(NSRunningApplication.activate(options:)), #selector(NSRunningApplication.headlessActivate(options:)))
        swap(NSWorkspace.self, #selector(NSWorkspace.open(_:)), #selector(NSWorkspace.headlessOpen(_:)))
    }

    private static func swap(_ cls: AnyClass, _ a: Selector, _ b: Selector) {
        guard let m = class_getInstanceMethod(cls, a), let n = class_getInstanceMethod(cls, b) else { return }
        method_exchangeImplementations(m, n)
    }
}

// Swapped in by Headless.install, so each calls the original under its own name.
extension NSWindow {
    @objc fileprivate func headlessOrder(_ place: NSWindow.OrderingMode, relativeTo other: Int) {
        if place != .out { alphaValue = 0; hasShadow = false; ignoresMouseEvents = true }
        headlessOrder(place, relativeTo: other)
    }

    @objc fileprivate func headlessSetAlphaValue(_ value: CGFloat) { headlessSetAlphaValue(0) }
}

extension NSApplication {
    @objc fileprivate func headlessActivate(ignoringOtherApps flag: Bool) {}
    @objc fileprivate func headlessActivate() {}
}

extension NSRunningApplication {
    @objc fileprivate func headlessActivate(options: NSApplication.ActivationOptions) -> Bool { false }
}

extension NSWorkspace {
    @objc fileprivate func headlessOpen(_ url: URL) -> Bool {
        FileHandle.standardError.write("headless: open \(url.absoluteString)\n".data(using: .utf8)!)
        return true
    }
}

/// Development aid: SOLANUM_SNAPSHOT=/path.png renders the first window to a PNG after a delay.
/// SOLANUM_SNAPSHOT_INPUT types text first; SOLANUM_SNAPSHOT_ACTIONS=split,palette,select-block,collapse,jump-prompt,find,term-find:<q>,term-toggle:<case|word|regex>,print-term-find,find-commands,find-output,click:<col>:<row>,keys:<text>,theme:<name>,
/// newtab,rename-tab,new-group,edit:<text>,select-tab:<i>,collapse-group:<i>,split-down,save-session,
/// tabbar-drag:<x1>:<x2>,chip-menu-rename,open-config,git-branches,later-keys:<text>,newtab-run:<command>,pin-sidebar,collapse-sidebar,print-claude-fg,undo,redo,print-input,right-click:<fx>:<fy>,left-click:<fx>:<fy>,preview-find:<q>,preview-find-toggle:<case|word|regex>,preview-find-next,switch-theme:<name>,pretend-claude,pane-up,sleep:<seconds>,screen-boxes,hover-box:<i>,code-box:<code>,move-to:<x>:<y>,print-boxes,print-return-keys,hover-last-block,scrollbar:<y0>:<y1>,print-tabs,cmd-click-tab:<i>,group-picked,name-tabs,chip-drag[-hold]:<x>,print-anim,close-tab:<i>,newtab-group,click-input:<col>,split-columns,print-bars,close-split,move-tab-other,right-sidebar,focus-other,close-right-tabs,print-columns,tab-drop[-hold]:<i>:<fx>:<fy>,open-file-tab:<path>,open-file:<path>,editor-key:<tab|backtab|backspace|start|all>,sleeper:<view>[:<player id>],status-hover:<x>,hover-at:<x>:<y>,click-at:<x>:<y>,open-diff:<path>,open-graph:<path>,open-preview:<path>,format-file,hover-graph:<row>,toggle-terminal,editor-drag-hold:<x>,sidebar-width:<points>,strip-scroll:<points>,strip-activate:<i>,strip-arrow:<-1|1>,print-strip-scroll,restore-prompt,editor-drag-out,select-input:<r0>:<c0>:<r1>:<c1>,drag-input:<r0>:<c0>:<r1>:<c1>:<seconds>,delete-selection,cmd-delete,select-cmd:<from>:<to>,print-selection,print-ssh,close-file,hover-title,print-sidebar,print-pins,sidebar-expand:<name>,sidebar-rename:<name>,sidebar-rename-to:<name>,sidebar-import:<path>,print-rows,status-transfer:<text>,pane-send:<text>,lost-bar:<Reconnect|Close>,print-lost-bar,refresh-sidebar,refresh-tab,glide-bottom,print-scroll,reopen-tab,quantum:<home|flower|folders>,nomai-read,palette-query:<text>,palette-run,print-cwds,sidebar-click:<name>,press-return,print-focus,print-editors,print-editor-text,open-slow-file-tab:<path>,open-devssh-file-tab:<path>,print-sidebar-rows,lost-notice:<command>,notice-reconnect,notice-close,print-lost,toggle-group:<i>,notice-secret:<text>,print-notice,editor-insert:<text>,editor-save,editor-conflict:<Compare|Overwrite|Revert|Cancel>,watch-tag:<live|off>,editor-race,freeze:<seconds>,crash-trap,editor-tail,live-scroll,print-window,print-view,wheel-up:<points>,window-jump:<fraction>,editor-scroll-steps:<n>:<dy>,editor-live-steps:<n>:<dy>,print-editor-end,crumb-menu[:<item>],crumb-context[:<label>[:<item>]],drop-files:<index>:<path>|<path>,drop-hover:<x>,press-beautify,print-header,header-press:<tooltip start>,editor-scroll-x:<points>,file-icons:<id>,print-icons,minimum-contrast:<true|false>,icon-popup[:<label>],settings-size:<w>:<h>,settings-bottom,settings-scroll-to:<label>,folder-icon:<path>,open-status:<repo>,status-click:<path>,status-open:<path>,status-all,git-action:<name>[:<path>],git-message:<text>,git-press:<button>,print-git-box,graph-changes:<row>,find-in-folder:<query>,print-editor-place,sidebar-search,find-bar:<q>,find-case,find-word,find-regex,find-step,find-replace:<text>,find-replace-one,find-replace-all,print-find,find-close,find-speed:<q>,find-latency:<q>,find-type:<text>,editor-wrap,tab-arrow:<-1|1>,tabbar-scroll:<points>,print-tab-scroll,press-key:<text>,hover-link:<col>:<row>,cmd-hover-link:<col>:<row>,cmd-click:<col>:<row>,set-pin:<path>,print-tab-files,print-blocks,block-copy,print-clipboard,send-menu,send-menu-run:<title start>,send-menu-mark:<title end>,app-reopen,app-quit,app-new-window,restart-fresh,window-red-button,sheet-press:<title>,send-menu-real[:<path>],settings-page:<title>,settings-press:<title>,settings-page-png:<path>,send-menu-png:<path>,bar-press:<title>,press-send-pill,press-copy-pill,print-agent-tail,print-context-menu:<col>:<row>,log-menu[:<menu>>…>item],graph-type:<text>,graph-press:<Branch|User|Date|Paths>,graph-click:<Branch|User|Date|Paths>,dropdown-type:<text>,hosts-dropdown,keep-awake-start:<seconds>,keep-awake-menu,keep-awake-stop,print-keep-awake,extensions,dropdown-option,chip-dropdown,print-watch-script:<path>|<path>,dropdown-run:<title>,graph-menu-run:<title>,graph-branch:<title>,graph-branch-filter:<text>,graph-path:<path>,print-graph,log-marker-text:<text>,log-select:<text>,editor-end,editor-edge-drag:<fraction>:<seconds>,print-deleted,editor-lost-bar:<host>,print-time,hang-watch,display-time,log-import:<path>,print-log-format,theme-edit:<name>,theme-icon:<setting|/path>,theme-background:<hex>,theme-ansi:<i>:<hex>,theme-bar:<Save Changes|Reset>,theme-leave:<page>,print-theme,print-samehost,release-history,print-releases,settings-window-png:<path>,settings-sheet-press:<title>,themed-alert[:problem],themed-alert-ok,window-png:<path>,settings-sidebar-png:<path>
/// (with SOLANUM_SESSION_FILE set, which also makes the run restore from that file).
/// Dev aid: files on this Mac, served as if from an ssh host whose folder listings take `delay` seconds (DevTools
/// open-slow-file-tab), to see what the sidebar shows while one is on its way.
final class DevSlowFileSystem: FileSystem {
    static let shared = DevSlowFileSystem()
    var delay: TimeInterval = 3
    var isRemote: Bool { true }
    var hostLabel: String? { "slow@test" }
    var home: String? { NSHomeDirectory() }
    func list(_ dir: String, _ done: @escaping (Result<[FileItem], Error>) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { LocalFileSystem.shared.list(dir, done) }
    }
    func read(_ path: String, limit: Int, _ done: @escaping (Result<Data, Error>) -> Void) { LocalFileSystem.shared.read(path, limit: limit, done) }
    /// The next file read takes this long (a slow host), to see what lands while it's on its way.
    var slowNextRead: TimeInterval = 0
    func readPart(_ path: String, from offset: Int?, whole: Int, tail: Int, _ done: @escaping (Result<FilePart, Error>) -> Void) {
        let wait = slowNextRead
        slowNextRead = 0
        LocalFileSystem.shared.readPart(path, from: offset, whole: whole, tail: tail) { r in
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { done(r) }
        }
    }
    func write(_ data: Data, to path: String, _ done: @escaping (Error?) -> Void) { LocalFileSystem.shared.write(data, to: path, done) }
    func countLines(_ path: String, upTo offset: Int, _ done: @escaping (Int?) -> Void) { LocalFileSystem.shared.countLines(path, upTo: offset, done) }
    func perform(_ op: FileOp, _ done: @escaping (Error?) -> Void) { LocalFileSystem.shared.perform(op, done) }
}

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
                // These work with no window open.
                if action == "app-quit" { NSApp.terminate(nil) }
                if action == "app-new-window" { (NSApp.delegate as? AppDelegate)?.newWindow(nil) }
                if action == "app-reopen" { _ = (NSApp.delegate as? AppDelegate)?.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false) }
                if action == "restart-fresh" { (NSApp.delegate as? AppDelegate)?.restartFresh(nil) }
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
                case let a where a.hasPrefix("term-find:"):
                    let q = String(a.dropFirst(10))
                    pane.showFind(nil); pane.searchBar?.field.stringValue = q; pane.performSearch(q)
                case let a where a.hasPrefix("term-toggle:"):
                    let key: WritableKeyPath<EditorFindOptions, Bool> = a.hasSuffix("case") ? \.matchCase : a.hasSuffix("word") ? \.wholeWord : \.regex
                    pane.searchBar?.flip(key)
                case "print-term-find":
                    FileHandle.standardError.write("term find \"\(pane.searchQuery)\": \(pane.searchBar?.devCount ?? "-") (\(pane.searchMatches.count) matches) options \(EditorFindBar.lastOptions)\n".data(using: .utf8)!)
                case "newtab": c.newTab(nil)
                case "newtab-host": c.newTabOnSameHost(nil)
                case "hosts-dropdown": c.devShowHosts()
                case "extensions": c.showExtensions(nil)
                case let a where a.hasPrefix("keep-awake-start:"): KeepAwake.start(seconds: Int(a.dropFirst(17)) ?? 3600)
                case "keep-awake-menu": c.devClickKeepAwake()
                case "keep-awake-stop": KeepAwake.stop()
                case "print-keep-awake":
                    FileHandle.standardError.write("keep awake: \(KeepAwake.isOn ? "on" : "off"), left \(KeepAwake.secondsLeft.map(String.init) ?? "-"), menu \"\(KeepAwake.menuTitle)\", tip \"\(KeepAwake.tip)\"\n".data(using: .utf8)!)
                case "dropdown-option": ThemedDropdown.devHoldOption()
                case "chip-dropdown": c.tabBar.devShowGroupMenu()
                case let a where a.hasPrefix("print-watch-script:"): print(RemoteFileWatch.script(a.dropFirst(19).split(separator: "|").map(String.init)))
                case let a where a.hasPrefix("dropdown-run:"): ThemedDropdown.devRun(String(a.dropFirst(13)))
                case "newtab-group": c.newTabInGroup(nil)
                case "sidebar": c.toggleFileSidebar(nil)
                case let a where a.hasPrefix("sidebar-width:"):
                    // As a drag of the sidebar's edge does each step (not saved).
                    c.rootView.sidebarWidth = CGFloat(Double(a.dropFirst(14)) ?? 240)
                    c.rootView.needsLayout = true
                    c.rootView.layoutSubtreeIfNeeded()
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
                case let a where a.hasPrefix("hover-box:"):
                    pane.hoverBox = Int(a.dropFirst(10))
                    pane.needsDisplay = true
                case let a where a.hasPrefix("move-to:"):
                    // move-to:<x>:<y> — the pointer moves to that point of the pane (points, from its top left); prints the
                    // code box hovered and where its Copy button is.
                    let f = a.dropFirst(8).split(separator: ":").compactMap { Double($0) }
                    if f.count == 2, let w = pane.window {
                        let at = pane.convert(NSPoint(x: f[0], y: f[1]), to: nil)
                        if let e = NSEvent.mouseEvent(with: .mouseMoved, location: at, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                                      context: nil, eventNumber: 0, clickCount: 0, pressure: 0) { pane.mouseMoved(with: e) }
                        pane.display()
                        print("hover box: \(pane.hoverBox.map(String.init) ?? "none") button: \(pane.devCopyButtons)")
                    }
                case let a where a.hasPrefix("code-box:"):
                    // A code block with this code (as Claude's transcript would give it), found on the screen.
                    pane.codeBoxes = pane.terminal.snapshot().findBoxes(code: [String(a.dropFirst(9))])
                    pane.needsDisplay = true
                case "screen-boxes":
                    // The boxes found from the screen alone (tables and quotes), as if Claude were running.
                    pane.codeBoxes = pane.terminal.snapshot().findBoxes(code: [])
                    pane.needsDisplay = true
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
                case "pane-up": pane.send("\u{1b}[A")
                case "pretend-claude": pane.devPretendClaude()
                case let a where a.hasPrefix("left-click:"):
                    // left-click:<fx>:<fy> — a click at that spot (fractions of the window).
                    let f = a.dropFirst(11).split(separator: ":").compactMap { Double($0) }
                    if f.count == 2, let w = c.window, let content = w.contentView {
                        let p = NSPoint(x: content.bounds.width * f[0], y: content.bounds.height * (1 - f[1]))
                        if let v = content.hitTest(p) {
                            FileHandle.standardError.write("click on \(type(of: v))\n".data(using: .utf8)!)
                            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                                if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                                              context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                                    if type == .leftMouseDown { v.mouseDown(with: e) } else { v.mouseUp(with: e) }
                                }
                            }
                        }
                    }
                case let a where a.hasPrefix("right-click:"):
                    // right-click:<fx>:<fy> — a right-click at that spot (fractions of the window), on whatever's there.
                    let f = a.dropFirst(12).split(separator: ":").compactMap { Double($0) }
                    if f.count == 2, let w = c.window, let content = w.contentView {
                        let p = NSPoint(x: content.bounds.width * f[0], y: content.bounds.height * (1 - f[1]))
                        if let v = content.hitTest(p), let e = NSEvent.mouseEvent(with: .rightMouseDown, location: p, modifierFlags: [], timestamp: 0,
                                                                                   windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                            FileHandle.standardError.write("right-click on \(type(of: v))\n".data(using: .utf8)!)
                            v.rightMouseDown(with: e)
                        }
                    }
                case let a where a.hasPrefix("preview-find:"):
                    // ⌘F in the Markdown preview showing, typing this; prints the count a moment later.
                    if let ed = c.activeTab?.editor {
                        ed.showFind(nil)
                        ed.devFindBar?.field.stringValue = String(a.dropFirst(13))
                        ed.devFindBar?.onQueryChange?()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            FileHandle.standardError.write("preview find \"\(a.dropFirst(13))\": \(ed.devFindBar?.countText ?? "-")\n".data(using: .utf8)!)
                        }
                    }
                case let a where a.hasPrefix("preview-find-toggle:"):
                    let key: WritableKeyPath<EditorFindOptions, Bool> = a.hasSuffix("case") ? \.matchCase : a.hasSuffix("word") ? \.wholeWord : \.regex
                    if let bar = c.activeTab?.editor?.devFindBar {
                        bar.flip(key)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            FileHandle.standardError.write("preview find after \(a.dropFirst(20)): \(bar.countText)\n".data(using: .utf8)!)
                        }
                    }
                case "preview-find-next":
                    c.activeTab?.editor?.findNext(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        FileHandle.standardError.write("preview find next: \(c.activeTab?.editor?.devFindBar?.countText ?? "-")\n".data(using: .utf8)!)
                    }
                case let a where a.hasPrefix("switch-theme:"):
                    // As the theme menu does; prints whether the window's easing into it, then again once it's done.
                    Config.shared.themeName = String(a.dropFirst(13))
                    Config.shared.commit()
                    FileHandle.standardError.write("theme fade: \(c.rootView.devFading ? "fading" : "none")\n".data(using: .utf8)!)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        FileHandle.standardError.write("theme fade after 0.6 s: \(c.rootView.devFading ? "fading" : "none")\n".data(using: .utf8)!)
                    }
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
                            print("link: \(pane.hoverURL.map { "\($0.url.absoluteString) cols \($0.start)-\($0.end) rows \($0.rows.map { "\($0.start)-\($0.end)" }.joined(separator: ",")) · \($0.opener)" } ?? "none")")
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
                            let items = pane.contextMenu(for: e)?.items ?? []
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
                    if action.hasPrefix("open-devssh-file-tab:") {
                        // A file "over ssh" to this Mac (see RemoteSession.init(devLocal:)), with a link this slow.
                        let sock = NSTemporaryDirectory() + "solanum-devssh-socket"
                        FileManager.default.createFile(atPath: sock, contents: nil)
                        let session = RemoteSession(devLocal: sock, latency: 0.15)
                        c.focused.addFileTab(FileEditorView(fs: session, path: String(action.dropFirst(21))))
                    }
                    if action.hasPrefix("open-slow-file-tab:") {
                        c.focused.addFileTab(FileEditorView(fs: DevSlowFileSystem.shared, path: String(action.dropFirst(19))))
                    }
                    if action.hasPrefix("lost-notice:") { pane.devShowLostNotice(host: "sjain@box", command: String(action.dropFirst(12))) }
                    if action == "notice-reconnect" { pane.devLostNotice?.devPressButton() }
                    if action == "notice-close" { pane.devLostNotice?.dismiss() }
                    if action == "print-lost" { FileHandle.standardError.write("lost: \(pane.devLostState)\n".data(using: .utf8)!) }
                    if action.hasPrefix("notice-secret:") { pane.devLostNotice?.devSubmitSecret(String(action.dropFirst(14))) }
                    if action == "print-notice" {
                        let n = pane.devLostNotice
                        FileHandle.standardError.write("notice: \(n.map { "\($0.devTitle.debugDescription) field=\($0.devHasSecretField) shown=\($0.superview != nil)" } ?? "none")\n".data(using: .utf8)!)
                    }
                    if action == "print-sidebar-rows" { FileHandle.standardError.write("sidebar rows: \(c.rootView.sidebar.devRowsState)\n".data(using: .utf8)!) }
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
                    if action.hasPrefix("hover-at:"), let w = c.window, let content = w.contentView {
                        // hover-at:<x>:<y> — the pointer over that point of the window (points from its top left), as the
                        // view there sees it: entering it, then moving in it. Prints which view that is.
                        let f = action.dropFirst(9).split(separator: ":").compactMap { Double($0) }
                        if f.count == 2 {
                            let p = NSPoint(x: f[0], y: content.bounds.height - f[1])
                            if let v = content.hitTest(p) {
                                FileHandle.standardError.write("hover on \(type(of: v))\n".data(using: .utf8)!)
                                for type in [NSEvent.EventType.mouseEntered, .mouseMoved] {
                                    let e = type == .mouseMoved
                                        ? NSEvent.mouseEvent(with: .mouseMoved, location: p, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                                             context: nil, eventNumber: 0, clickCount: 0, pressure: 0)
                                        : NSEvent.enterExitEvent(with: .mouseEntered, location: p, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                                                 context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)
                                    if let e { type == .mouseMoved ? v.mouseMoved(with: e) : v.mouseEntered(with: e) }
                                }
                            }
                        }
                    }
                    if action.hasPrefix("click-at:"), let w = c.window, let content = w.contentView {
                        // click-at:<x>:<y> — a press and release at that point of the window (points from its top left).
                        let f = action.dropFirst(9).split(separator: ":").compactMap { Double($0) }
                        if f.count == 2 {
                            let p = NSPoint(x: f[0], y: content.bounds.height - f[1])
                            if let v = content.hitTest(p) {
                                FileHandle.standardError.write("click on \(type(of: v))\n".data(using: .utf8)!)
                                // A button's own press waits for a real release (its tracking loop): clicked as a click is.
                                if let button = v as? NSButton { button.performClick(nil); return }
                                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                                    if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                                                  context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                                        type == .leftMouseDown ? v.mouseDown(with: e) : v.mouseUp(with: e)
                                    }
                                }
                            }
                        }
                    }
                    if action.hasPrefix("status-hover:"), let x = Double(action.dropFirst(13)), let w = c.window {
                        // The pointer over the window's first status bar at x (points from its left).
                        let bar = c.rootView.statusBar
                        let at = bar.convert(NSPoint(x: CGFloat(x), y: bar.bounds.midY), to: nil)
                        if let e = NSEvent.mouseEvent(with: .mouseMoved, location: at, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                                      context: nil, eventNumber: 0, clickCount: 0, pressure: 0) { bar.mouseMoved(with: e) }
                    }
                    if action.hasPrefix("open-file:") { c.activeTab?.openFile(LocalFileSystem.shared, String(action.dropFirst(10))) }
                    if action.hasPrefix("open-preview:") { c.activeTab?.openFile(LocalFileSystem.shared, String(action.dropFirst(13)), mode: .preview) }
                    if action == "format-file" { c.activeTab?.editor?.formatDocument(nil) }
                    if action == "log-menu" || action.hasPrefix("log-menu:") {
                        c.activeTab?.editor?.devLogMenu(run: action.hasPrefix("log-menu:") ? String(action.dropFirst(9)) : nil)
                    }
                    if action.hasPrefix("editor-lost-bar:") {
                        c.activeTab?.editor?.devShowLostBar(host: String(action.dropFirst(16)))
                        c.activeTab?.editor?.layoutSubtreeIfNeeded()
                        let f = c.activeTab?.editor?.devLostBar?.frame ?? .zero
                        FileHandle.standardError.write("lost bar: \(f) in \(c.activeTab?.editor?.bounds ?? .zero)\n".data(using: .utf8)!)
                    }
                    if action == "print-deleted" {
                        FileHandle.standardError.write("deleted: \(c.activeTab?.editor?.devIsDeleted == true) title \(c.activeTab?.title ?? "-")\n".data(using: .utf8)!)
                    }
                    if action.hasPrefix("editor-edge-drag:") {
                        let n = action.dropFirst(17).split(separator: ":").compactMap { Double($0) }
                        if n.count == 2 { c.activeTab?.editor?.devEdgeDrag(fraction: CGFloat(n[0]), seconds: n[1]) }
                    }
                    if action == "editor-end" { c.activeTab?.editor?.devScrollToEnd() }
                    if action == "editor-tail" { c.activeTab?.editor?.devToggleTail() }
                    if action.hasPrefix("editor-scroll-steps:") || action.hasPrefix("editor-live-steps:") {
                        let v = action.split(separator: ":").dropFirst().compactMap { Double($0) }
                        if v.count == 2 { c.activeTab?.editor?.devScrollSteps(Int(v[0]), CGFloat(v[1]), live: action.hasPrefix("editor-live")) }
                    }
                    if action == "display-time" {
                        let a = Date()
                        if let v = c.window?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                            v.layoutSubtreeIfNeeded()
                            v.cacheDisplay(in: v.bounds, to: rep)
                        }
                        FileHandle.standardError.write("display: \(Int(Date().timeIntervalSince(a) * 1000)) ms\n".data(using: .utf8)!)
                    }
                    if action == "hang-watch" {
                        // Prints each stall of the main thread past 250 ms, as it ends.
                        var last = Date()
                        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                            let gap = Date().timeIntervalSince(last)
                            if gap > 0.25 { FileHandle.standardError.write("hang: \(Int(gap * 1000)) ms at \(Date().timeIntervalSince1970)\n".data(using: .utf8)!) }
                            last = Date()
                        }
                    }
                    if action == "print-time" { FileHandle.standardError.write("time: \(Date().timeIntervalSince1970)\n".data(using: .utf8)!) }
                    if action.hasPrefix("log-select:") { c.activeTab?.editor?.devSelect(String(action.dropFirst(11))) }
                    if action.hasPrefix("log-marker-text:") { LogColorMenu.devMarkerText = String(action.dropFirst(16)) }
                    if action.hasPrefix("log-import:") { c.activeTab?.editor?.devImportLogFormat(String(action.dropFirst(11))) }
                    if action == "print-log-format" {
                        FileHandle.standardError.write("log format: \(c.activeTab?.editor?.devLogFormatName ?? "none")\n".data(using: .utf8)!)
                    }
                    if action.hasPrefix("open-status:") { c.activeTab?.openFile(LocalFileSystem.shared, String(action.dropFirst(12)), mode: .status) }
                    if action.hasPrefix("status-click:") { c.activeTab?.editor?.devStatusView?.devClick(String(action.dropFirst(13))) }
                    if action.hasPrefix("graph-changes:"), let r = Int(action.dropFirst(14)) { c.activeTab?.editor?.devGraphView?.devViewChanges(r) }
                    if action.hasPrefix("status-open:") { c.activeTab?.editor?.devStatusView?.devOpen(String(action.dropFirst(12))) }
                    if action.hasPrefix("git-action:") {
                        // git-action:<name>[:<path>], as the Git Changes page's buttons and links.
                        let f = action.dropFirst(11).split(separator: ":", maxSplits: 1).map(String.init)
                        c.activeTab?.editor?.devStatusView?.devAction(f[0], f.count > 1 ? f[1] : nil)
                    }
                    if action.hasPrefix("git-message:") { c.activeTab?.editor?.devStatusView?.devCommitBox.text.string = String(action.dropFirst(12)) }
                    if action.hasPrefix("git-press:") { c.activeTab?.editor?.devStatusView?.devCommitBox.devPress(String(action.dropFirst(10))) }
                    if action == "print-git-box" {
                        FileHandle.standardError.write("git box: \(c.activeTab?.editor?.devStatusView?.devCommitBox.devState ?? "-")\n".data(using: .utf8)!)
                    }
                    if action == "status-all" { c.activeTab?.editor?.devStatusView?.devToggleAll() }
                    if action.hasPrefix("open-graph:") { c.activeTab?.openFile(LocalFileSystem.shared, String(action.dropFirst(11)), mode: .graph) }
                    if action.hasPrefix("hover-graph:"), let row = Int(action.dropFirst(12)) { c.activeTab?.editor?.devHoverGraph(row) }
                    if let g = c.activeTab?.editor?.devGraphView {
                        if action.hasPrefix("graph-type:") { g.devToolbar.devType(String(action.dropFirst(11))) }
                        if action.hasPrefix("graph-press:") { g.devToolbar.devPress(String(action.dropFirst(12))) }
                        if action.hasPrefix("graph-click:") { g.devToolbar.devClick(String(action.dropFirst(12))) }
                        if action.hasPrefix("graph-path:") { g.devToolbar.devPath(String(action.dropFirst(11))) }
                        if action.hasPrefix("graph-menu-run:") { ThemedDropdown.devRun(String(action.dropFirst(15))) }
                        if action.hasPrefix("graph-branch:") { g.devBranchList.devPick(String(action.dropFirst(13))) }
                        if action.hasPrefix("graph-branch-filter:") { g.devBranchList.devFilter(String(action.dropFirst(20))) }
                        if action == "print-graph" {
                            FileHandle.standardError.write("graph: \(g.devRowCount) rows, filters \(g.devToolbar.devButtons), list \(g.devBranchList.devTitles.prefix(12))\n".data(using: .utf8)!)
                        }
                    }
                    if action == "toggle-terminal" { c.activeTab?.toggleTerminal() }
                    if action.hasPrefix("strip-scroll:"), let x = Double(action.dropFirst(13)) { c.activeTab?.editorArea.strip.scroll(by: CGFloat(x)) }
                    if action.hasPrefix("strip-activate:"), let i = Int(action.dropFirst(15)) { c.activeTab?.activateEditor(i) }
                    if action.hasPrefix("strip-arrow:"), let d = Int(action.dropFirst(12)) { c.activeTab?.editorArea.strip.slide(d) }
                    if action == "print-strip-scroll", let st = c.activeTab?.editorArea.strip { print("strip: \(st.devScrollState)") }
                    if action == "restore-prompt" { (NSApp.delegate as? AppDelegate)?.offerRestore(SessionState(windows: [c.sessionState])) }
                    if action == "editor-drag-out", let tab = c.activeTab, let ed = tab.editor {
                        // Drags the active file's sub-tab onto the middle of the focused column's tab strip and drops it.
                        let bar = c.tabBar
                        c.editorDragOver(ed, from: tab, at: bar.convert(NSPoint(x: bar.bounds.midX, y: bar.bounds.midY), to: nil))
                        c.performEditorDrop()
                    }
                    if action.hasPrefix("editor-drag-hold:"), let tab = c.activeTab, let ed = tab.editor, let x = Double(action.dropFirst(17)) {
                        // Holds the active file's sub-tab over the focused column's tab strip at x (points), not dropped.
                        let bar = c.tabBar
                        c.editorDragOver(ed, from: tab, at: bar.convert(NSPoint(x: CGFloat(x), y: bar.bounds.midY), to: nil))
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
                    if action.hasPrefix("opt-drag:"), let w = pane.window {
                        // opt-drag:<col0>:<row0>:<col1>:<row1> — an ⌥-drag between two screen cells (a rectangular selection).
                        let n = action.dropFirst(9).split(separator: ":").compactMap { Double($0) }
                        if n.count == 4 {
                            func at(_ col: Double, _ row: Double) -> NSPoint {
                                pane.convert(NSPoint(x: pane.padX + (col + 0.5) * pane.fonts.cellW, y: pane.padTop + (row + 0.5) * pane.fonts.cellH), to: nil)
                            }
                            for (t, p) in [(NSEvent.EventType.leftMouseDown, at(n[0], n[1])), (.leftMouseDragged, at(n[2], n[3])), (.leftMouseUp, at(n[2], n[3]))] {
                                guard let e = NSEvent.mouseEvent(with: t, location: p, modifierFlags: [.option], timestamp: 0, windowNumber: w.windowNumber,
                                                                 context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
                                switch t {
                                case .leftMouseDown: pane.mouseDown(with: e)
                                case .leftMouseDragged: pane.mouseDragged(with: e)
                                default: pane.mouseUp(with: e)
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
                    if action.hasPrefix("sleeper:") {
                        // sleeper:<team|matchup|standings|waivers|trending|activity|player>[:<player id>] — the Sleeper page,
                        // above the focused tab's terminal, on that view.
                        let parts = action.dropFirst(8).split(separator: ":").map(String.init)
                        if let ed = Extensions.showPage(SleeperExtension.id, in: c.activeTab), let page = ed.pageView as? SleeperPageView {
                            var info = ["view": parts.first ?? "team"]
                            if parts.count > 1 { info["player_id"] = parts[1] }
                            page.navigate(info)
                        }
                    }
                    if action.hasPrefix("editor-key:") { c.activeTab?.editor?.devKey(String(action.dropFirst(11))) }
                    if action == "print-editor-text" {
                        for ed in c.allTabs.flatMap(\.editors) {
                            FileHandle.standardError.write("editor text: \(ed.displayName): \(ed.devTextState)\n".data(using: .utf8)!)
                        }
                    }
                    if action.hasPrefix("editor-insert:") { c.activeTab?.editor?.devInsert(String(action.dropFirst(14))) }
                    if action == "editor-save" { c.activeTab?.editor?.devSave() }
                    if action.hasPrefix("editor-conflict:") { c.activeTab?.editor?.devConflict(String(action.dropFirst(16))) }
                    if action == "print-editor-end", let ed = c.activeTab?.editor { FileHandle.standardError.write("editor end: \(ed.devTextEnd)\n".data(using: .utf8)!) }
                    if action == "editor-race" { c.activeTab?.editor?.devRefreshRace() }
                    if action.hasPrefix("freeze:"), let s = Double(action.dropFirst(7)) { Thread.sleep(forTimeInterval: s) }
                    if action == "crash-trap" { let a: [Int] = []; _ = a[Int(ProcessInfo.processInfo.processIdentifier) % 1 + 1] }
                    if action == "live-scroll", let ed = c.activeTab?.editor { ed.devLiveScroll() }
                    if action == "print-window", let ed = c.activeTab?.editor {
                        FileHandle.standardError.write("window: \(ed.devWindowState)\ntop line: \(ed.devTopLine)\n".data(using: .utf8)!)
                    }
                    if action.hasPrefix("wheel-up:"), let p = Double(action.dropFirst(9)) { c.activeTab?.editor?.devWheelUp(CGFloat(p)) }
                    if action == "print-view", let ed = c.activeTab?.editor { FileHandle.standardError.write("view: \(ed.devView)\n".data(using: .utf8)!) }
                    if action.hasPrefix("window-jump:"), let f = Double(action.dropFirst(12)) { c.activeTab?.editor?.devJump(f) }
                    if action.hasPrefix("watch-tag:") { c.activeTab?.editor?.devWatchTag(String(action.dropFirst(10))) }
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
                    // A real press on the window's red button, and on a button of the sheet it may bring up.
                    if action == "window-red-button" { c.window?.standardWindowButton(.closeButton)?.performClick(nil) }
                    if action.hasPrefix("sheet-press:") {
                        func buttons(_ v: NSView) -> [NSButton] { ((v as? NSButton).map { [$0] } ?? []) + v.subviews.flatMap(buttons) }
                        c.window?.attachedSheet?.contentView.map(buttons)?.first { $0.title == action.dropFirst(12) }?.performClick(nil)
                    }
                    if action.hasPrefix("settings-page:") {
                        // Opens the Settings page with this title.
                        SettingsWindowController.shared.present()
                        if let p = SettingsWindowController.Page.allCases.first(where: { $0.title == action.dropFirst(14) }) { SettingsWindowController.shared.show(p) }
                    }
                    if action.hasPrefix("theme-edit:") {
                        SettingsWindowController.shared.present()
                        if let t = ThemeLibrary.custom.first(where: { $0.name == String(action.dropFirst(11)) }) { SettingsWindowController.shared.edit(t) }
                    }
                    // theme-icon:<setting or /path> — the edited theme's icon: "planet:Quantum Moon", "flower", "none", "auto",
                    // or a picture's full path, copied in as the editor's Picture… does.
                    if action.hasPrefix("theme-icon:"), let model = SettingsWindowController.shared.themeDraft {
                        let v = String(action.dropFirst(11))
                        if v.hasPrefix("/") { ThemeEditor.setIcon(v, model, SettingsWindowController.shared) } else {
                            model.theme.icon = v == "auto" ? nil : v
                            model.changed()
                        }
                    }
                    if action.hasPrefix("theme-background:"), let model = SettingsWindowController.shared.themeDraft {
                        model.theme.background = NSColor(hex: String(action.dropFirst(17)))
                        model.changed()
                    }
                    if action.hasPrefix("theme-ansi:"), let model = SettingsWindowController.shared.themeDraft {
                        let f = action.dropFirst(11).split(separator: ":")
                        if f.count == 2, let i = Int(f[0]) { model.palette?.devSet(i, String(f[1])) }
                        FileHandle.standardError.write("palette: \(model.palette?.devEditing ?? "-")\n".data(using: .utf8)!)
                    }
                    if action.hasPrefix("theme-bar:") {
                        (SettingsWindowController.shared.footer as? ThemeSaveBar)?.devPress(String(action.dropFirst(10)))
                    }
                    if action.hasPrefix("theme-leave:") {
                        // Leaves the editor for a page, as the sidebar does (an unsaved-changes sheet shows first).
                        if let p = SettingsWindowController.Page.allCases.first(where: { $0.title == action.dropFirst(12) }) { SettingsWindowController.shared.show(p) }
                    }
                    if action.hasPrefix("settings-window-png:"), let root = SettingsWindowController.shared.window?.contentView,
                       let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                        root.cacheDisplay(in: root.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: String(action.dropFirst(20))))
                    }
                    if action == "release-history" {
                        SettingsWindowController.shared.present(.system)
                        SettingsWindowController.shared.showReleases(true)
                    }
                    if action == "print-releases" {
                        func timelines(_ v: NSView) -> [ReleaseTimelineView] { ((v as? ReleaseTimelineView).map { [$0] } ?? []) + v.subviews.flatMap(timelines) }
                        let t = SettingsWindowController.shared.window?.contentView.map(timelines)?.first
                        FileHandle.standardError.write("releases: \(t?.releases.count ?? -1): \(t?.devSummary ?? "-")\n".data(using: .utf8)!)
                    }
                    if action == "print-samehost" {
                        let r = RemoteSession(awaiting: "sjain@lanode11", sshArgs: "lanode11")
                        let dir = "/tmp/solanum q test/a b'c"
                        let inner = "cd \(shellQuote(dir)) 2>/dev/null; exec \"$SHELL\" -l"
                        FileHandle.standardError.write("samehost-sudo: \(r.reconnectCommand(in: dir, then: "sudo -i -u \(shellQuote("pipelineservice")) sh -c \(shellQuote(inner))")!)\nsamehost: \(r.reconnectCommand(in: dir)!)\n".data(using: .utf8)!)
                    }
                    if action == "print-theme" {
                        let bar = (SettingsWindowController.shared.footer as? ThemeSaveBar)?.devState ?? "no bar"
                        let file = ThemeLibrary.custom.first { $0.file == SettingsWindowController.shared.editingTheme }
                        FileHandle.standardError.write("theme: \(bar); live bg \(Config.shared.theme.background.hexString); saved bg \(file?.background.hexString ?? "-"); sheet \(SettingsWindowController.shared.window?.attachedSheet != nil)\n".data(using: .utf8)!)
                    }
                    if action.hasPrefix("settings-sheet-press:") {
                        func buttons(_ v: NSView) -> [NSButton] { ((v as? NSButton).map { [$0] } ?? []) + v.subviews.flatMap(buttons) }
                        SettingsWindowController.shared.window?.attachedSheet?.contentView.map(buttons)?.first { $0.title == action.dropFirst(21) }?.performClick(nil)
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
                    if action == "themed-alert" || action == "themed-alert:problem" {
                        // The updater's alert over Settings (or this window): themed-alert[:problem].
                        let w = SettingsWindowController.shared.window?.isVisible == true ? SettingsWindowController.shared.window : c.window
                        if action.hasSuffix(":problem") {
                            ThemedAlertView.show("Couldn't check for updates", "fatal: unable to access 'https://example.com/solanum.git/': Could not resolve host: example.com",
                                                 symbol: ("exclamationmark", Config.shared.theme.yellow), in: w)
                        } else {
                            ThemedAlertView.show("Solanum is up to date", "This build (6de9362) has everything on main.", in: w)
                        }
                    }
                    if action == "themed-alert-ok" {
                        func alerts(_ v: NSView) -> [ThemedAlertView] { ((v as? ThemedAlertView).map { [$0] } ?? []) + v.subviews.flatMap(alerts) }
                        let w = SettingsWindowController.shared.window?.isVisible == true ? SettingsWindowController.shared.window : c.window
                        let found = w?.contentView.map(alerts) ?? []
                        found.first?.devPress()
                        FileHandle.standardError.write("themed-alert-ok: \(found.count) alert(s), first responder after: \(w?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")\n".data(using: .utf8)!)
                    }
                    if action.hasPrefix("window-png:") {
                        // The Settings window (or this one), whole, to a PNG.
                        let w = SettingsWindowController.shared.window?.isVisible == true ? SettingsWindowController.shared.window : c.window
                        if let v = w?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                            v.cacheDisplay(in: v.bounds, to: rep)
                            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: String(action.dropFirst(11))))
                        }
                    }
                    if action.hasPrefix("settings-sidebar-png:") {
                        // The Settings page list, to a PNG.
                        func bars(_ v: NSView) -> [SettingsSidebar] { ((v as? SettingsSidebar).map { [$0] } ?? []) + v.subviews.flatMap(bars) }
                        if let bar = SettingsWindowController.shared.window?.contentView.map(bars)?.first,
                           let rep = bar.bitmapImageRepForCachingDisplay(in: bar.bounds) {
                            bar.cacheDisplay(in: bar.bounds, to: rep)
                            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: String(action.dropFirst(21))))
                        }
                    }
                    if action.hasPrefix("settings-scroll-to:") {
                        // Scrolls Settings to the row whose title (or any label) reads this.
                        let want = String(action.dropFirst(19))
                        func labels(_ v: NSView) -> [NSTextField] { ((v as? NSTextField).map { [$0] } ?? []) + v.subviews.flatMap(labels) }
                        if let l = SettingsWindowController.shared.window?.contentView.map(labels)?.first(where: { $0.stringValue == want }) {
                            l.scrollToVisible(l.bounds.insetBy(dx: 0, dy: -160))
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
                        if action.hasPrefix("icon-popup:"), let p { p.choose(String(action.dropFirst(11))) }
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
                    if action.hasPrefix("tabbar-scroll:"), let d = Double(action.dropFirst(14)) { c.tabBar.devScrollTabs(by: CGFloat(d)) }
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
                    if action.hasPrefix("drop-files:") {
                        // drop-files:<index>:<path>|<path>… — files and folders dropped on the tab strip before tab <index>.
                        let parts = action.dropFirst(11).split(separator: ":", maxSplits: 1).map(String.init)
                        if parts.count == 2, let i = Int(parts[0]) {
                            let paths = parts[1].split(separator: "|").map(String.init)
                            let folders = Set(paths.filter { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: $0, isDirectory: &d) && d.boolValue })
                            c.focused.tabBar.openDropped((LocalFileSystem.shared, paths, folders), at: i)
                        }
                    }
                    if action.hasPrefix("drop-hover:") { c.focused.tabBar.devDropHover(x: Double(action.dropFirst(11)).map { CGFloat($0) }) }
                    if action.hasPrefix("crumb-context") {
                        // crumb-context[:<label>[:<item>]]
                        let parts = action.split(separator: ":", maxSplits: 2).dropFirst().map(String.init)
                        c.rootView.statusBar.devContextMenu(label: parts.first.flatMap { $0.isEmpty ? nil : $0 }, run: parts.count > 1 ? parts[1] : nil)
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
                    if action == "print-bars" {
                        // Each column's strip: its tabs' and chips' x ranges in the window's root view, as fractions of its width.
                        let root = c.rootView
                        for (ci, col) in c.columns.enumerated() {
                            let bar = col.tabBar
                            let rows = bar.layoutSummary.split(separator: "\n").compactMap { line -> String? in
                                guard let xs = line.split(separator: "=").last?.split(separator: "-").compactMap(Double.init), xs.count == 2 else { return nil }
                                let a = bar.convert(NSPoint(x: xs[0], y: 0), to: root).x / root.bounds.width, b = bar.convert(NSPoint(x: xs[1], y: 0), to: root).x / root.bounds.width
                                return "\(line.split(separator: " ").first ?? "") \(String(format: "%.3f-%.3f", a, b))"
                            }
                            let y = bar.convert(NSPoint(x: 0, y: bar.bounds.midY), to: root).y / root.bounds.height
                            FileHandle.standardError.write("bar\(ci) y=\(String(format: "%.3f", root.isFlipped ? y : 1 - y)): \(rows.joined(separator: ", "))\n".data(using: .utf8)!)
                        }
                    }
                    if action == "print-columns" {
                        let cols = c.columns.enumerated().map { i, col in
                            "col\(i)\(col === c.focused ? "*" : "") [" + col.tabs.map { t in
                                let files = t.editors.map { ($0.path as NSString).lastPathComponent }
                                let name: String = t.customTitle ?? (t.showsTerminal ? "-" : "file:" + t.title)
                                let fileList: String = files.isEmpty || !t.showsTerminal ? "" : "{" + files.joined(separator: ",") + "}"
                                let group: String = t.group.map { "@" + ($0.name.isEmpty ? $0.color.rawValue : $0.name) } ?? ""
                                return name + fileList + group
                            }.joined(separator: " ") + "] active=\(col.activeIndex) bar.x=\(Int(col.tabBar.frame.minX))-\(Int(col.tabBar.frame.maxX))"
                        }
                        FileHandle.standardError.write("== \(cols.joined(separator: " | ")) drop=\(c.rootView.dropPreview.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "-") pending=\(c.hasPendingTabDrop) ghost=\(c.rootView.devGhostShown)\n".data(using: .utf8)!)
                    }
                    if action == "print-anim" { FileHandle.standardError.write("\(c.tabBar.animSummary)\n".data(using: .utf8)!) }
                    if action.hasPrefix("close-tab:"), let i = Int(action.dropFirst(10)) { c.closeTab(at: i) }
                    if action.hasPrefix("dropdown-type:") { ThemedDropdown.devType(String(action.dropFirst(14))) }
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
                    // toggle-group:<i> — as clicking that group's chip does: open it if it's closed, close it if it's open.
                    if action.hasPrefix("toggle-group:"), let i = Int(action.dropFirst(13)), c.groups.indices.contains(i) {
                        c.focused.setCollapsed(c.groups[i], !c.groups[i].collapsed)
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
            // Blended over it: a plain draw copies the capture's alpha, leaving see-through holes where the background is
            // translucent (background-opacity) or a view clears behind its text.
            rep.draw(in: NSRect(origin: .zero, size: v.bounds.size), from: .zero, operation: .sourceOver, fraction: 1,
                     respectFlipped: false, hints: nil)
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
