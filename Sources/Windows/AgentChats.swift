import Foundation

/// Send to Chat (Ctrl+Alt+S), as the Mac's ⌥⌘S: a finished command and what it printed go to a coding agent's chat, one
/// running in any tab or a new one, as a paste that's never submitted: it waits in the chat's input box for you to add to
/// and send. If it can't be pasted safely (the agent is asking a question, or never got ready), it goes on the clipboard
/// and a card says so.
enum AgentChats {
    /// A running chat's text, in the Mac's form: each command with what it printed, "$ " first, blank lines between.
    static func transcript(_ parts: [String]) -> String { parts.joined(separator: "\n\n") }

    /// Whether a chat just started can take the paste: the agent's on screen, isn't asking a question (trusting the
    /// folder, say), and has stopped drawing. Windows' console host doesn't pass on an agent asking for pastes to be
    /// marked, so (unlike the Mac) that isn't waited for: pastes to agents are always marked (see TerminalPane.pasteText).
    static func readyForPaste(status: AgentStatus?, quietFor: TimeInterval) -> Bool {
        guard let status, status != .waiting else { return false }
        return quietFor >= 0.4
    }
}

/// The agents you can start on this PC: what's on the PATH (an .exe, or npm's .cmd and .ps1 shims), looked for in the
/// background at launch and again when the menu opens, at most once a minute.
final class InstalledAgents {
    static let shared = InstalledAgents()
    private(set) var kinds: [AgentKind] = []
    private(set) var scanned = false
    private var lastScan: Date?
    private let lock = NSLock()

    /// `post` runs what's found on the window's thread.
    func refresh(post: @escaping (@escaping () -> Void) -> Void) {
        if let last = lastScan, Date().timeIntervalSince(last) < 60 { return }
        lastScan = Date()
        Thread.detachNewThread { [weak self] in
            let found = Self.scan()
            post {
                self?.kinds = found
                self?.scanned = true
            }
        }
    }

    /// For tests: what's on a given PATH.
    static func scan(path: String? = nil) -> [AgentKind] {
        let env = ProcessInfo.processInfo.environment
        let dirs = (path ?? env["PATH"] ?? env["Path"] ?? "").split(separator: ";").map(String.init).filter { !$0.isEmpty }
        let fm = FileManager.default
        return AgentKind.known.filter { kind in
            dirs.contains { dir in [".exe", ".cmd", ".ps1", ".bat"].contains { fm.fileExists(atPath: dir + "\\" + kind.command + $0) } }
        }
    }
}
