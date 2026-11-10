import CCanvas
import Foundation
import WinSDK

/// A shell a tab can run: Windows PowerShell, PowerShell 7, Command Prompt, Git Bash, or a WSL distribution.
struct ShellOption: Equatable {
    /// "powershell", "pwsh", "cmd", "git-bash", or "wsl:<distribution>".
    let id: String
    let name: String
    /// The program, a full path where there is one.
    let executable: String
    /// How it starts, PowerShell's with Solanum's hook (see `Shells.commandLine`).
    let arguments: [String]

    var isPowerShell: Bool { id == "powershell" || id == "pwsh" }
}

/// The shells on this PC, the default one (Settings › Preferences › Shell), and which one a tab is running. Windows only:
/// the Mac has its login shell.
enum Shells {
    /// What's installed, found once (WSL's distributions are asked for off the window's thread, and added when known).
    private(set) static var available: [ShellOption] = find()
    private static var wslAsked = false

    private static func find() -> [ShellOption] {
        let env = ProcessInfo.processInfo.environment
        let system = env["SystemRoot"] ?? "C:\\Windows"
        var out: [ShellOption] = []
        let fm = FileManager.default
        let windowsPS = system + "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"
        if fm.fileExists(atPath: windowsPS) { out.append(ShellOption(id: "powershell", name: "Windows PowerShell", executable: windowsPS, arguments: [])) }
        if let pwsh = search("pwsh.exe") ?? [env["ProgramFiles"].map { $0 + "\\PowerShell\\7\\pwsh.exe" }].compactMap({ $0 }).first(where: fm.fileExists) {
            out.append(ShellOption(id: "pwsh", name: "PowerShell 7", executable: pwsh, arguments: []))
        }
        out.append(ShellOption(id: "cmd", name: "Command Prompt", executable: env["ComSpec"] ?? system + "\\System32\\cmd.exe", arguments: []))
        let gitBash = [env["ProgramFiles"], env["ProgramFiles(x86)"], env["LOCALAPPDATA"].map { $0 + "\\Programs" }]
            .compactMap { $0.map { $0 + "\\Git\\bin\\bash.exe" } }.first(where: fm.fileExists)
        if let gitBash { out.append(ShellOption(id: "git-bash", name: "Git Bash", executable: gitBash, arguments: ["--login", "-i"])) }
        return out
    }

    private static func search(_ name: String) -> String? {
        var path = [UInt16](repeating: 0, count: Int(MAX_PATH))
        let n = SearchPathW(nil, Array(name.utf16) + [0], nil, DWORD(path.count), &path, nil)
        return n > 0 ? String(decoding: path[..<Int(n)], as: UTF16.self) : nil
    }

    /// Asks WSL for its distributions (once), off the window's thread; `done` there with whether any were added.
    static func findWSL(post: @escaping (@escaping () -> Void) -> Void, done: @escaping () -> Void) {
        guard !wslAsked else { return }
        wslAsked = true
        let system = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
        let wsl = system + "\\System32\\wsl.exe"
        guard FileManager.default.fileExists(atPath: wsl), let p = HiddenProcess(executable: wsl, arguments: ["-l", "-q"], extraEnvironment: [:]) else { return }
        var output = Data()
        let lock = NSLock()
        p.onOutput = { data in lock.lock(); output.append(data); lock.unlock() }
        p.onExit = { code in
            lock.lock()
            let data = output
            lock.unlock()
            // wsl.exe writes UTF-16.
            let text = String(decoding: data.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }, as: UTF16.self)
            let names = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{0}"))) }
                .filter { !$0.isEmpty && !$0.hasPrefix("docker-desktop") }
            guard code == 0, !names.isEmpty else { return }
            post {
                available += names.map { ShellOption(id: "wsl:" + $0, name: "\($0) (WSL)", executable: wsl, arguments: ["-d", $0]) }
                done()
            }
        }
    }

    /// The command line a tab starts with: PowerShell with Solanum's hook (when shell integration is on), the rest as they are.
    static func commandLine(_ shell: ShellOption) -> String {
        if shell.isPowerShell {
            return AppSettings.shared.shellIntegration ? PowerShellIntegration.commandLine(executable: HiddenProcess.quote(shell.executable)) : "\(HiddenProcess.quote(shell.executable)) -NoLogo"
        }
        return ([shell.executable] + shell.arguments).map(HiddenProcess.quote).joined(separator: " ")
    }

    /// What Settings › Preferences › Shell keeps for it: empty for the default (PowerShell 7 where it's installed, else
    /// Windows PowerShell), else its command line.
    static func setting(for shell: ShellOption) -> String {
        if shell.id == "pwsh" || (shell.id == "powershell" && !available.contains { $0.id == "pwsh" }) { return "" }
        if shell.isPowerShell { return shell.executable }
        return ([shell.executable] + shell.arguments).map(HiddenProcess.quote).joined(separator: " ")
    }

    /// The shell a command line runs, if it's one of these.
    static func identify(_ commandLine: String) -> ShellOption? {
        let line = commandLine.trimmingCharacters(in: .whitespaces)
        let first: String
        if line.hasPrefix("\"") { first = String(line.dropFirst().prefix { $0 != "\"" }) } else { first = String(line.prefix { $0 != " " }) }
        let exe = (first.split(separator: "\\").last.map(String.init) ?? first).lowercased()
        switch exe {
        case "pwsh", "pwsh.exe": return available.first { $0.id == "pwsh" }
        case "powershell", "powershell.exe": return available.first { $0.id == "powershell" }
        case "cmd", "cmd.exe": return available.first { $0.id == "cmd" }
        case "bash.exe", "bash", "git-bash.exe": return first.lowercased().contains("git") ? available.first { $0.id == "git-bash" } : nil
        case "wsl", "wsl.exe":
            let parts = line.split(separator: " ").map(String.init)
            if let d = parts.firstIndex(of: "-d"), d + 1 < parts.count { return available.first { $0.id == "wsl:" + parts[d + 1] } }
            return available.first { $0.id.hasPrefix("wsl:") }
        default: return nil
        }
    }

    /// The default shell: the one Settings names, else PowerShell 7 or Windows PowerShell.
    static var defaultShell: ShellOption? {
        let configured = AppSettings.shared.shell.trimmingCharacters(in: .whitespaces)
        if configured.isEmpty { return available.first { $0.id == "pwsh" } ?? available.first { $0.id == "powershell" } }
        return identify(configured)
    }

    static func option(_ id: String?) -> ShellOption? { id.flatMap { id in available.first { $0.id == id } } }

    // MARK: Marks

    /// Each shell's color and letters, drawn as a small rounded tile: in menus' minds and on the status bar's button.
    static func mark(_ shell: ShellOption?) -> (color: UInt32, text: String) {
        switch shell?.id {
        case "powershell": return (0x2671BE, ">_")
        case "pwsh": return (0x3C8FD8, ">_")
        case "cmd": return (0x3A3A3A, "C:")
        case "git-bash": return (0xF05133, "$")
        case let id? where id.hasPrefix("wsl:"): return (0xE95420, "~")
        default: return (0x6B6B6B, ">")
        }
    }

    /// A shell's tile in a square at (x, y).
    static func drawMark(_ shell: ShellOption?, x: Float, y: Float, side: Float, on canvas: Canvas, alpha: Float = 1) {
        let m = mark(shell), c = canvas.raw
        sol_canvas_fill_rounded(c, x, y, side, side, side * 0.22, m.color, alpha)
        sol_canvas_stroke_rounded(c, x + 0.5, y + 0.5, side - 1, side - 1, side * 0.22, 0xFFFFFF, 0.18 * alpha, 1)
        let units = Array(m.text.utf16), px = side * (m.text.count > 1 ? 0.5 : 0.62)
        let w = sol_canvas_measure_label(c, units, Int32(units.count), px, 1)
        sol_canvas_draw_label(c, x + (side - w) / 2, y, w + 2, side, units, Int32(units.count), px, 1, 0xFFFFFF, alpha)
    }
}
