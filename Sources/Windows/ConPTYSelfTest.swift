import Foundation
import WinSDK

/// Real programs through a real pseudoconsole into the emulator: `Solanum-test --selftest`.
enum ConPTYSelfTest {
    /// A terminal joined to a running program, as a pane will be. The emulator isn't thread-safe, so a lock guards it.
    private final class Session: TerminalDelegate {
        let terminal: Terminal
        private let lock = NSLock()
        private(set) var pty: ConPTY?
        private var raw: [UInt8] = []
        private var exitCode: Int32?
        private(set) var finished: [Block] = []

        init?(_ commandLine: String, cols: Int = 100, rows: Int = 30) {
            terminal = Terminal(cols: cols, rows: rows, scrollbackLimit: 1000)
            terminal.delegate = self
            guard let pty = ConPTY(commandLine: commandLine, cols: cols, rows: rows) else { return nil }
            self.pty = pty
            pty.onData = { [unowned self] bytes in
                locked {
                    raw += bytes
                    terminal.feed(bytes)
                }
            }
            pty.onExit = { [unowned self] code in locked { exitCode = code } }
        }

        @discardableResult
        private func locked<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }

        var text: String {
            locked {
                let old = terminal.scrollback.toArray().map { $0.text() }
                return (old + terminal.screen.map { $0.text() }).joined(separator: "\n")
            }
        }
        var code: Int32? { locked { exitCode } }
        var cwd: String? { locked { terminal.cwd } }
        var blocks: [Block] { locked { finished } }
        /// What came out of the console, with control characters visible, for a failed check's message.
        var rawDescription: String {
            locked {
                String(decoding: raw.suffix(1500), as: UTF8.self).unicodeScalars.map { s in
                    s.value < 32 ? "<\(String(s.value, radix: 16))>" : String(s)
                }.joined()
            }
        }

        func send(_ text: String) { pty?.write(Array(text.utf8)) }

        func terminalSend(_ bytes: [UInt8]) { pty?.write(bytes) }
        func terminalTitleChanged(_ t: Terminal) {}
        func terminalCwdChanged(_ t: Terminal) {}
        func terminalBell(_ t: Terminal) {}
        func terminalBlockFinished(_ t: Terminal, block: Block) { finished.append(block) }
        func terminalClipboardWrite(_ t: Terminal, text: String) {}
        func terminalScreenSwitched(_ t: Terminal) {}
        func terminalSyncEnded(_ t: Terminal) {}
        func terminalColor(_ t: Terminal, code: Int) -> (UInt8, UInt8, UInt8) { (0, 0, 0) }
        func terminalPixelSize(_ t: Terminal) -> (width: Int, height: Int) { (800, 600) }
        func terminalSSHExited(_ t: Terminal, status: Int) {}
    }

    /// Waits for `condition`, up to `seconds`.
    @discardableResult
    private static func wait(_ seconds: Double = 30, until condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return condition()
    }

    static func run(_ results: CoreSelfTest.Results) {
        func check(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
            results.check(name, cond, detail())
        }
        print("ConPTY")
        do {
            let s = Session("cmd.exe /c echo hello-conpty")
            let done = s.map { x in wait { x.code != nil } } ?? false
            check("conpty: output reaches the emulator", done && s?.text.contains("hello-conpty") == true, s?.rawDescription ?? "didn't start")
            check("conpty: exit code", s?.code == 0, "\(String(describing: s?.code))")
        }
        do {
            let s = Session("cmd.exe /c exit 3")
            if let s { wait { s.code != nil } }
            check("conpty: failing exit code", s?.code == 3, "\(String(describing: s?.code))")
        }
        do {
            // Only running the line produces "typed-ok": the echoed input still has the variable in it.
            let s = Session("cmd.exe")
            s?.send("set WORD=ok\r\necho typed-%WORD%\r\nexit\r\n")
            let done = s.map { x in wait { x.code != nil } } ?? false
            check("conpty: input reaches the program", done && s?.text.contains("\ntyped-ok") == true, s?.rawDescription ?? "didn't start")
        }
        do {
            let s = Session(#"powershell.exe -NoLogo -NoProfile -Command "[Console]::OutputEncoding = [Text.Encoding]::UTF8; [Console]::Out.Write('h' + [char]0xe9 + 'llo ' + [char]0x2726)""#)
            let done = s.map { x in wait { x.code != nil } } ?? false
            check("conpty: unicode output", done && s?.text.contains("héllo ✦") == true, s?.rawDescription ?? "didn't start")
        }
        do {
            let s = Session(#"powershell.exe -NoLogo -NoProfile -Command "Write-Output ('width=' + $Host.UI.RawUI.WindowSize.Width)""#, cols: 97)
            let done = s.map { x in wait { x.code != nil } } ?? false
            check("conpty: program sees the size", done && s?.text.contains("width=97") == true, s?.rawDescription ?? "didn't start")
        }
        do {
            let s = Session(#"powershell.exe -NoLogo -NoProfile -Command "Start-Sleep -Seconds 4; Write-Output ('width=' + $Host.UI.RawUI.WindowSize.Width)""#, cols: 97)
            Thread.sleep(forTimeInterval: 1)
            s?.pty?.resize(cols: 111, rows: 30)
            let done = s.map { x in wait { x.code != nil } } ?? false
            check("conpty: program sees a resize", done && s?.text.contains("width=111") == true, s?.rawDescription ?? "didn't start")
        }
        do {
            // The child would keep running an hour on its own: the job has to stop the whole tree.
            let s = Session(#"cmd.exe /c "powershell.exe -NoProfile -Command Start-Sleep -Seconds 3600""#)
            Thread.sleep(forTimeInterval: 1)
            let started = Date()
            s?.pty?.terminate()
            let done = s.map { x in wait { x.code != nil } } ?? false
            check("conpty: terminate stops the program and reports it", done && Date().timeIntervalSince(started) < 15,
                  "\(Date().timeIntervalSince(started))s")
        }
        print("PowerShell hook")
        for executable in ["powershell.exe", "pwsh.exe"] {
            var path = [UInt16](repeating: 0, count: Int(MAX_PATH))
            let name = Array(executable.utf16) + [0]
            guard SearchPathW(nil, name, nil, DWORD(path.count), &path, nil) > 0 else {
                print("  - \(executable) isn't installed")
                continue
            }
            let label = executable.replacingOccurrences(of: ".exe", with: "")
            let s = Session(PowerShellIntegration.commandLine(executable: executable, loadProfile: false))
            guard let s else {
                check("\(label): starts", false)
                continue
            }
            let reachedPrompt = wait { s.cwd != nil }
            check("\(label): reports its folder", reachedPrompt, s.rawDescription)
            s.send("cmd /c exit 7\r")
            let failed = wait(15) { s.blocks.contains { $0.exitCode == 7 } }
            check("\(label): a block with its exit status", failed, s.rawDescription)
            let command = s.blocks.first { $0.exitCode == 7 }?.command ?? ""
            check("\(label): the block knows its command", command.contains("exit 7"), "\"\(command)\"")
            let folder = ProcessInfo.processInfo.environment["SystemRoot"] ?? #"C:\Windows"#
            s.send("cd '\(folder)'\r")
            let moved = wait(15) { s.cwd?.lowercased() == folder.lowercased() }
            check("\(label): follows cd", moved, "\(s.cwd ?? "nil") \(s.rawDescription)")
            // The Windows PowerShell default is the system's old code page, which turns this into "?".
            s.send("[Console]::Out.WriteLine('mark-' + [char]0x2726)\r")
            let unicode = wait(15) { s.text.contains("mark-✦") }
            check("\(label): unicode output", unicode, s.rawDescription)
            s.send("exit\r")
            let ended = wait(15) { s.code != nil }
            check("\(label): exits", ended, s.rawDescription)
            if !ended { s.pty?.terminate() }
        }
    }
}
