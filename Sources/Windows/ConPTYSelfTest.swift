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

        /// As the window sends what's typed.
        func send(_ text: String) {
            let bytes = Array(text.utf8)
            pty?.write(locked { terminal.win32InputMode } ? Win32Input.encode(bytes) : bytes)
        }

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

    /// Tries each way of sending characters outside ASCII through each PowerShell installed here, and prints which
    /// survive, since that depends on the Windows and PSReadLine versions: `Solanum-test --input-probe`.
    static func probeInput() {
        func key(_ vk: Int, _ unit: UInt16, down: Bool) -> String { "\u{1b}[\(vk);0;\(unit);\(down ? 1 : 0);0;1_" }
        func keys(_ text: String, vk: Int, upToo: Bool) -> [UInt8] {
            var out = ""
            for unit in text.utf16 {
                out += key(vk, unit, down: true)
                if upToo { out += key(vk, unit, down: false) }
            }
            return Array(out.utf8)
        }
        let encodings: [(name: String, encode: (String) -> [UInt8])] = [
            ("utf-8", { Array($0.utf8) }),
            ("vk-packet", { keys($0, vk: 0xE7, upToo: true) }),
            ("vk-packet, down only", { keys($0, vk: 0xE7, upToo: false) }),
            ("vk-0", { keys($0, vk: 0, upToo: true) }),
            ("vk-0, down only", { keys($0, vk: 0, upToo: false) }),
        ]
        let samples = ["é", "✦", "日", "🌱"]
        for executable in ["powershell.exe", "pwsh.exe"] {
            var path = [UInt16](repeating: 0, count: Int(MAX_PATH))
            guard SearchPathW(nil, Array(executable.utf16) + [0], nil, DWORD(path.count), &path, nil) > 0 else {
                print("\(executable): not installed")
                continue
            }
            guard let s = Session(PowerShellIntegration.commandLine(executable: executable, loadProfile: false)),
                  wait(until: { s.cwd != nil }) else {
                print("\(executable): didn't reach a prompt")
                continue
            }
            func line(after prefix: String) -> String? {
                guard let found = s.text.range(of: "\n" + prefix, options: .backwards) else { return nil }
                let rest = s.text[found.upperBound...]
                return String(rest.prefix { $0 != "\n" })
            }
            s.send("echo (\"info=PS $($PSVersionTable.PSVersion) PSReadLine $((Get-Module PSReadLine).Version) Windows $([Environment]::OSVersion.Version) input-cp $([Console]::InputEncoding.CodePage)\")\r")
            wait(15) { line(after: "info=") != nil }
            print("\(executable): \(line(after: "info=") ?? "no version information")")
            var number = 0
            for encoding in encodings {
                var results: [String] = []
                for sample in samples {
                    number += 1
                    let prefix = "p\(number)-"
                    s.pty?.write(Array("echo '\(prefix)".utf8) + encoding.encode(sample) + Array("-end'\r".utf8))
                    wait(6) { line(after: prefix) != nil }
                    let got = line(after: prefix)?.replacingOccurrences(of: "-end", with: "")
                    results.append(got == sample ? "\(sample) ok" : "\(sample) LOST")
                }
                print("  \(encoding.name): \(results.joined(separator: "  "))")
            }
            s.pty?.terminate()
            wait(10) { s.code != nil }
        }
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
        do {
            let s = Session("cmd.exe")
            s?.send("chcp 65001\r\necho typed-é-✦\r\nexit\r\n")
            let done = s.map { x in wait { x.code != nil } } ?? false
            check("conpty: unicode input in cmd", done && s?.text.contains("\ntyped-é-✦") == true, s?.rawDescription ?? "didn't start")
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
            s.send("echo 'typed-é-✦'\r")
            let typed = wait(15) { s.text.contains("\ntyped-é-✦") }
            check("\(label): unicode input", typed, s.rawDescription)
            s.send("exit\r")
            let ended = wait(15) { s.code != nil }
            check("\(label): exits", ended, s.rawDescription)
            if !ended { s.pty?.terminate() }
        }
    }
}
