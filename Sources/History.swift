import AppKit

/// Commands for the ⌃H history search: the shell's history file plus everything run in Solanum since launch
/// (bash only writes its file as each prompt appears, via the shell integration, or on exit).
final class CommandHistory {
    static let shared = CommandHistory()
    private var session: [String] = []
    private static let limit = 10_000

    func record(_ command: String) {
        let c = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return }
        session.append(c)
        if session.count > Self.limit { session.removeFirst(session.count - Self.limit) }
    }

    /// Most recent first, without duplicates.
    func localEntries() -> [String] {
        var files: [URL] = []
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch (ShellIntegration.userShell() as NSString).lastPathComponent {
        case "zsh":
            let zdot = ProcessInfo.processInfo.environment["ZDOTDIR"].map { URL(fileURLWithPath: $0) } ?? home
            files = [zdot.appendingPathComponent(".zsh_history")]
        default:
            files = [home.appendingPathComponent(".bash_history")]
        }
        let fromFiles = files.flatMap { url -> [String] in
            guard let data = try? Data(contentsOf: url) else { return [] }
            return Self.parse(String(decoding: data, as: UTF8.self))
        }
        return Self.newestFirst(fromFiles + session)
    }

    /// The remote user's bash and zsh history files.
    func remoteEntries(_ remote: RemoteSession, _ done: @escaping ([String]) -> Void) {
        remote.run("tail -n \(Self.limit) ~/.bash_history 2>/dev/null; tail -n \(Self.limit) ~/.zsh_history 2>/dev/null", timeout: 10) { _, out, _ in
            done(Self.newestFirst(Self.parse(String(decoding: out, as: UTF8.self))))
        }
    }

    /// Oldest-first lines → newest-first unique commands (Core's HistoryFile, shared with Windows).
    static func newestFirst(_ commands: [String]) -> [String] { HistoryFile.newestFirst(commands) }

    /// bash and zsh history files, as Core's HistoryFile reads them.
    static func parse(_ text: String) -> [String] { HistoryFile.parse(text) }
}

extension TerminalView {
    /// At a shell prompt, or inside an ssh session (whose remote prompt Solanum can't see) outside full-screen programs.
    var canShowHistory: Bool {
        guard !exited, !terminal.usingAlt else { return false }
        return remote != nil || !hasRunningJob
    }

    /// ⌃H: search past commands. ↩ puts the command at the prompt for editing; ⌘↩ runs it.
    @objc func showHistory(_ sender: Any?) {
        guard canShowHistory, let w = window else { return NSSound.beep() }
        if let remote, remote.isReady {
            CommandHistory.shared.remoteEntries(remote) { [weak self] entries in
                self?.presentHistory(entries, in: w, host: remote.hostLabel)
            }
        } else {
            presentHistory(CommandHistory.shared.localEntries(), in: w, host: nil)
        }
    }

    private func presentHistory(_ entries: [String], in w: NSWindow, host: String?) {
        guard window === w else { return }
        let items = entries.map { cmd in
            CommandPalette.Item(title: cmd.replacingOccurrences(of: "\n", with: " ⏎ "), path: "", shortcut: "",
                                alternate: { [weak self] in self?.insertCommand(cmd, run: true) }) { [weak self] in
                self?.insertCommand(cmd, run: false)
            }
        }
        let place = host.map { "on \($0)" } ?? "history"
        CommandPalette.show(in: w, items: items, placeholder: "Search \(place) — ↩ to edit, ⌘↩ to run", keepsOrder: true, icon: "clock.arrow.circlepath")
    }

    /// Replaces whatever is typed at the prompt with `cmd` (⌃E ⌃U clears the line in bash and zsh).
    func insertCommand(_ cmd: String, run: Bool) {
        guard canShowHistory else { return NSSound.beep() }
        window?.makeFirstResponder(self)
        send("\u{05}\u{15}")
        sendPaste(cmd)
        if run { send("\r") }
    }
}
